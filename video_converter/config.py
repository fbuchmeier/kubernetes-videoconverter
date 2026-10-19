from __future__ import annotations

import argparse
import os
from dataclasses import dataclass, field
from pathlib import Path


DEFAULT_VIDEO_EXTENSIONS = {
    ".3gp",
    ".avi",
    ".flv",
    ".m4v",
    ".mkv",
    ".mov",
    ".mp4",
    ".mpeg",
    ".mpg",
    ".mts",
    ".m2ts",
    ".ts",
    ".webm",
    ".wmv",
}


@dataclass
class AppConfig:
    scan_root: Path
    mount_path: str
    pvc_name: str
    desired_format: str = "mkv"
    poll_interval: int = 60
    max_parallel_jobs: int = 2
    max_retries: int = 3
    job_namespace: str = "default"
    job_prefix: str = "video-convert"
    output_suffix: str = ".converted"
    run_once: bool = False
    supported_extensions: set[str] = field(default_factory=lambda: set(DEFAULT_VIDEO_EXTENSIONS))
    image: str = "ghcr.io/example/videoconverter-encoder:latest"
    job_timeout_seconds: int = 1800
    job_script_path: str = "/usr/local/bin/encode_movie.sh"
    job_cpu_request: str = "500m"
    job_memory_request: str = "512Mi"
    job_cpu_limit: str = "2000m"
    job_memory_limit: str = "4Gi"

    def __post_init__(self) -> None:
        self.scan_root = Path(self.scan_root).expanduser().resolve()
        self.mount_path = str(self.mount_path).replace("\\", "/")
        self.desired_format = self.desired_format.lstrip(".").lower()
        self.supported_extensions = {ext.lower() for ext in self.supported_extensions}
        self.job_script_path = str(self.job_script_path).replace("\\", "/")

    @property
    def desired_extension(self) -> str:
        return "." + self.desired_format


def parse_args() -> AppConfig:
    parser = argparse.ArgumentParser(description="Scan a mounted volume for movies and encode each one via Kubernetes Jobs.")
    parser.add_argument("--scan-root", required=True, help="Filesystem path to scan for source movie files.")
    parser.add_argument("--mount-path", default=os.getenv("VIDEO_CONVERTER_MOUNT_PATH", "/mnt/media"), help="Mount path used by the PVC inside the job container.")
    parser.add_argument("--pvc-name", default=os.getenv("VIDEO_CONVERTER_PVC_NAME", "media-pvc"), help="Name of the PVC to mount in each Kubernetes Job.")
    parser.add_argument("--desired-format", default=os.getenv("VIDEO_CONVERTER_DESIRED_FORMAT", "mkv"), help="Target extension for converted files, e.g. mkv or mp4.")
    parser.add_argument("--job-namespace", default=os.getenv("VIDEO_CONVERTER_NAMESPACE", "default"), help="Namespace where the conversion jobs are created.")
    parser.add_argument("--job-prefix", default=os.getenv("VIDEO_CONVERTER_JOB_PREFIX", "video-convert"), help="Prefix for generated Kubernetes Job names.")
    parser.add_argument("--max-parallel-jobs", type=int, default=int(os.getenv("VIDEO_CONVERTER_MAX_PARALLEL_JOBS", "2")), help="Maximum number of files processed in parallel.")
    parser.add_argument("--max-retries", type=int, default=int(os.getenv("VIDEO_CONVERTER_MAX_RETRIES", "3")), help="Retry count for a given file after a failed encode.")
    parser.add_argument("--poll-interval", type=int, default=int(os.getenv("VIDEO_CONVERTER_POLL_INTERVAL", "60")), help="Seconds between re-scans while looping.")
    parser.add_argument("--run-once", action="store_true", help="Scan once and exit instead of repeatedly looping.")
    parser.add_argument("--image", default=os.getenv("VIDEO_CONVERTER_IMAGE", "ghcr.io/example/videoconverter-encoder:latest"), help="Container image to execute the transcode job.")
    parser.add_argument("--job-timeout-seconds", type=int, default=int(os.getenv("VIDEO_CONVERTER_JOB_TIMEOUT_SECONDS", "1800")), help="Per-job timeout in seconds.")
    parser.add_argument("--job-script-path", default=os.getenv("VIDEO_CONVERTER_JOB_SCRIPT_PATH", "/usr/local/bin/encode_movie.sh"), help="Path to the encode script inside the job container.")
    parser.add_argument("--job-cpu-request", default=os.getenv("VIDEO_CONVERTER_JOB_CPU_REQUEST", "500m"), help="CPU request assigned to each conversion Job.")
    parser.add_argument("--job-memory-request", default=os.getenv("VIDEO_CONVERTER_JOB_MEMORY_REQUEST", "512Mi"), help="Memory request assigned to each conversion Job.")
    parser.add_argument("--job-cpu-limit", default=os.getenv("VIDEO_CONVERTER_JOB_CPU_LIMIT", "2000m"), help="CPU limit assigned to each conversion Job.")
    parser.add_argument("--job-memory-limit", default=os.getenv("VIDEO_CONVERTER_JOB_MEMORY_LIMIT", "4Gi"), help="Memory limit assigned to each conversion Job.")
    args = parser.parse_args()

    config = AppConfig(
        scan_root=args.scan_root,
        mount_path=args.mount_path,
        pvc_name=args.pvc_name,
        desired_format=args.desired_format,
        poll_interval=args.poll_interval,
        max_parallel_jobs=args.max_parallel_jobs,
        max_retries=args.max_retries,
        job_namespace=args.job_namespace,
        job_prefix=args.job_prefix,
        run_once=args.run_once,
        image=args.image,
        job_timeout_seconds=args.job_timeout_seconds,
        job_script_path=args.job_script_path,
        job_cpu_request=args.job_cpu_request,
        job_memory_request=args.job_memory_request,
        job_cpu_limit=args.job_cpu_limit,
        job_memory_limit=args.job_memory_limit,
    )

    if config.max_parallel_jobs < 1:
        raise ValueError("--max-parallel-jobs must be at least 1")
    if config.max_retries < 0:
        raise ValueError("--max-retries must be 0 or higher")
    if config.poll_interval < 1:
        raise ValueError("--poll-interval must be at least 1")
    return config
