from __future__ import annotations

import hashlib
import re
import time
from pathlib import Path

from kubernetes import client, config


class KubernetesJobManager:
    def __init__(
        self,
        namespace: str,
        job_prefix: str,
        mount_path: str,
        pvc_name: str,
        image: str = "ghcr.io/example/videoconverter-encoder:latest",
        job_script_path: str = "/usr/local/bin/encode_movie.sh",
    ):
        self.namespace = namespace
        self.job_prefix = re.sub(r"[^a-z0-9-]", "-", job_prefix.lower()).strip("-") or "video-convert"
        self.mount_path = mount_path.rstrip("/") or "/mnt/media"
        self.pvc_name = pvc_name
        self.image = image
        self.job_script_path = job_script_path
        self.batch = self._load_client()

    def _load_client(self):
        try:
            config.load_incluster_config()
        except config.ConfigException:
            config.load_kube_config()
        return client.BatchV1Api()

    def _file_label(self, file_path: Path) -> str:
        return hashlib.sha1(str(file_path.resolve()).encode("utf-8")).hexdigest()[:12]

    def _sanitized_job_name(self, file_path: Path) -> str:
        digest = self._file_label(file_path)
        safe_name = re.sub(r"[^a-z0-9-]", "-", file_path.name.lower())
        safe_name = safe_name[:35].strip("-") or "movie"
        return f"{self.job_prefix}-{safe_name}-{digest}"

    def _build_job_body(self, source_path: Path) -> dict:
        job_name = self._sanitized_job_name(source_path)
        job_label = self._file_label(source_path)
        source_value = str(source_path)
        shell_script = (
            "set -euo pipefail; "
            f"export DATA_DIR='{self.mount_path}'; "
            "export CACHE_DIR='/tmp/videoconverter-cache'; "
            f"export INPUT_FILE='{source_value}'; "
            f"exec '{self.job_script_path}' '$INPUT_FILE'"
        )
        return {
            "apiVersion": "batch/v1",
            "kind": "Job",
            "metadata": {"name": job_name, "namespace": self.namespace},
            "spec": {
                "backoffLimit": 0,
                "ttlSecondsAfterFinished": 3600,
                "template": {
                    "metadata": {"labels": {"app": self.job_prefix, "movie-file": job_label}},
                    "spec": {
                        "restartPolicy": "Never",
                        "containers": [
                            {
                                "name": "encoder",
                                "image": self.image,
                                "command": ["/bin/bash", "-lc", shell_script],
                                "env": [
                                    {"name": "DATA_DIR", "value": self.mount_path},
                                    {"name": "CACHE_DIR", "value": "/tmp/videoconverter-cache"},
                                    {"name": "INPUT_FILE", "value": source_value},
                                ],
                                "volumeMounts": [{"name": "media", "mountPath": self.mount_path}],
                            }
                        ],
                        "volumes": [{
                            "name": "media",
                            "persistentVolumeClaim": {"claimName": self.pvc_name},
                        }],
                    },
                },
            },
        }

    def create_job(self, source_path: Path) -> str:
        job_name = self._sanitized_job_name(source_path)
        job_body = self._build_job_body(source_path)
        try:
            self.batch.create_namespaced_job(body=job_body, namespace=self.namespace)
        except client.ApiException as exc:
            if exc.status == 409:
                return job_name
            raise
        return job_name

    def job_is_done(self, job_name: str) -> tuple[bool, bool]:
        job = self.batch.read_namespaced_job(name=job_name, namespace=self.namespace)
        succeeded = job.status.succeeded or 0
        failed = job.status.failed or 0
        if succeeded > 0:
            return True, True
        if failed > 0:
            return True, False
        return False, False

    def wait_for_job(self, job_name: str, timeout_seconds: int = 1800, poll_interval: float = 10.0) -> bool:
        started = time.time()
        while time.time() - started < timeout_seconds:
            done, success = self.job_is_done(job_name)
            if done:
                return success
            time.sleep(poll_interval)
        return False

    def delete_job(self, job_name: str) -> None:
        try:
            self.batch.delete_namespaced_job(name=job_name, namespace=self.namespace)
        except client.ApiException as exc:
            if exc.status != 404:
                raise

    def is_active_job_for_file(self, file_path: Path) -> bool:
        label_selector = f"movie-file={self._file_label(file_path)}"
        jobs = self.batch.list_namespaced_job(namespace=self.namespace, label_selector=label_selector)
        return any((job.status.active or 0) > 0 for job in jobs.items)
