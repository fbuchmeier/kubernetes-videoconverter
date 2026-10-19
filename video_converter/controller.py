from __future__ import annotations

import threading
import time
from concurrent.futures import FIRST_COMPLETED, ThreadPoolExecutor, wait
from pathlib import Path
from typing import Dict, Iterable, Set

from .config import AppConfig
from .k8s_jobs import KubernetesJobManager
from .scanner import MovieScanner


class ConversionController:
    def __init__(self, config: AppConfig):
        self.config = config
        self.scanner = MovieScanner(config.scan_root, config.desired_extension, config.supported_extensions)
        self.k8s = KubernetesJobManager(
            namespace=config.job_namespace,
            job_prefix=config.job_prefix,
            mount_path=config.mount_path,
            pvc_name=config.pvc_name,
            image=config.image,
            job_script_path=config.job_script_path,
            cpu_request=config.job_cpu_request,
            memory_request=config.job_memory_request,
            cpu_limit=config.job_cpu_limit,
            memory_limit=config.job_memory_limit,
        )
        self.lock = threading.Lock()
        self.in_flight: Set[str] = set()
        self.retry_counts: Dict[str, int] = {}
        self._executor = ThreadPoolExecutor(max_workers=config.max_parallel_jobs)
        self._job_futures = set()

    @staticmethod
    def _file_key(path: Path) -> str:
        return str(path.resolve())

    def _source_in_container(self, file_path: Path) -> Path:
        try:
            relative = file_path.relative_to(self.config.scan_root)
        except ValueError:
            relative = Path(file_path.name)
        return Path(self.config.mount_path) / relative

    def _output_in_container(self, file_path: Path) -> Path:
        output_path = self.build_output_path(file_path)
        try:
            relative = output_path.relative_to(self.config.scan_root)
        except ValueError:
            relative = Path(output_path.name)
        return Path(self.config.mount_path) / relative

    def scan(self) -> list[Path]:
        return self.scanner.find_movie_files()

    def schedule(self, files: Iterable[Path]) -> None:
        for file_path in files:
            key = self._file_key(file_path)
            with self.lock:
                if key in self.in_flight:
                    continue
                if self.k8s.is_active_job_for_file(file_path):
                    continue
                self.in_flight.add(key)
            future = self._executor.submit(self.process_file, file_path)
            self._job_futures.add(future)

    def process_file(self, file_path: Path) -> None:
        key = self._file_key(file_path)
        try:
            self._convert_with_retries(file_path)
        except Exception as exc:
            print(f"Failed to process {file_path}: {exc}")
        finally:
            with self.lock:
                self.in_flight.discard(key)

    def _convert_with_retries(self, file_path: Path) -> None:
        retries_used = self.retry_counts.get(self._file_key(file_path), 0)
        while True:
            output_path = self.build_output_path(file_path)
            output_container = self._output_in_container(file_path)
            if output_path.exists():
                print(f"Output already exists for {file_path}; skipping conversion.")
                return

            source_container = self._source_in_container(file_path)
            job_name = self.k8s.create_job(source_container)
            success = self.k8s.wait_for_job(job_name, timeout_seconds=self.config.job_timeout_seconds, poll_interval=10.0)
            if success:
                print(f"Converted {file_path} to {output_path}")
                return

            if retries_used >= self.config.max_retries:
                raise RuntimeError(f"Encode failed for {file_path} after {self.config.max_retries} retries")

            retries_used += 1
            self.retry_counts[self._file_key(file_path)] = retries_used
            print(f"Retrying failed conversion for {file_path} ({retries_used}/{self.config.max_retries})")
            time.sleep(15)

    def build_output_path(self, path: Path) -> Path:
        if path.suffix.lower() == ".mkv":
            return path.with_name(path.stem + ".hb.mkv")
        if path.suffix.lower() == ".mp4":
            return path.with_name(path.stem + ".hb.mkv")
        return path.with_name(path.stem + ".hb.mkv")

    def run_once(self) -> None:
        self.schedule(self.scan())
        if not self._job_futures:
            return
        done, _ = wait(self._job_futures, return_when=FIRST_COMPLETED)
        for future in list(done):
            future.result()

    def run_loop(self) -> None:
        while True:
            self.schedule(self.scan())
            if not self._job_futures:
                time.sleep(self.config.poll_interval)
                continue
            done, _ = wait(self._job_futures, return_when=FIRST_COMPLETED)
            for future in list(done):
                future.result()
                self._job_futures.discard(future)
            if self.config.run_once:
                break
            time.sleep(self.config.poll_interval)


def run_controller(config: AppConfig) -> None:
    controller = ConversionController(config)
    if config.run_once:
        controller.run_once()
    else:
        controller.run_loop()
