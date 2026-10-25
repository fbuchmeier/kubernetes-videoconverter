# Video Converter Controller

This Python application scans a media directory for movie files that are not already in the desired target format and creates Kubernetes Jobs to process them. The actual encode workload runs in a dedicated OCI image that includes HandBrake, ffmpeg, jq, and rsync, matching the logic in `scripts/encode_movie.sh`.

## Features

- Recursively scans a configured directory tree
- Ignores files already in the configured format or already recognized as HEVC
- Creates at most one active job per source file
- Retries failed processing up to a configured maximum
- Uses configurable concurrency limits for parallel jobs
- Pushes conversion work into Kubernetes Jobs that mount the shared PVC
- Writes results as `.hb.mkv` output next to the source file

## Encode workflow

The supplied script, `scripts/encode_movie.sh`, performs the following:

- checks the file codec via `ffprobe`
- skips files already reported as HEVC/VC1
- acquires a `.lock` directory per file to avoid duplicate processing
- copies the source into a cache directory under `CACHE_DIR`
- runs HandBrakeCLI with x265 main10 and subtitle/audio preservation settings
- syncs the output back to the source location as `<name>.hb.mkv`
- records status information in the lock directory

The controller does not execute ffmpeg directly. Instead, it schedules a Job using the dedicated encoder image, which includes all required dependencies needed by the HandBrake script.

## Install

```bash
python -m venv .venv
. .venv/bin/activate
pip install -r requirements.txt
```

## Releases and publishing

This repository uses `googleapis/release-please` to manage GitHub releases for the codebase, published container images, and the Helm chart version.

The release metadata is configured in `.github/release-please-config.json` and `.release-please-manifest.json`.

The repository also publishes:

- the Python/controller OCI image to GHCR via `.github/workflows/build-publish-ghcr.yml`
- the HandBrake encoder image to GHCR via `.github/workflows/build-publish-job-image.yml`
- the Helm chart as an OCI artifact via `.github/workflows/publish-helm-oci.yml`

## Container images

### Controller image

Build the controller image with UV:

```bash
docker build -t videoconverter:local .
```

The GitHub Action at `.github/workflows/build-publish-ghcr.yml` publishes this controller image to GHCR.

### Encoder job image

Build the dedicated encoding image for the Jobs:

```bash
docker build -f encode-job.Dockerfile -t videoconverter-encoder:local .
```

The GitHub Action at `.github/workflows/build-publish-job-image.yml` publishes this encode image to GHCR as an OCI artifact for use by the Kubernetes Jobs.

## Helm deployment

The chart in `helm/videoconverter` deploys the controller with:

- a Deployment for the controller process
- a ServiceAccount
- Role + RoleBinding for Job and ConfigMap access
- PVC mount wiring to the media share
- a default image reference to the GHCR encoder image

Example install:

```bash
helm upgrade --install videoconverter ./helm/videoconverter \
  --set image.repository=ghcr.io/<owner>/videoconverter \
  --set image.tag=latest \
  --set app.image=ghcr.io/<owner>/videoconverter-encoder:latest \
  --set app.scanRoot=/mnt/media \
  --set app.mountPath=/mnt/media \
  --set app.pvcName=media-pvc
```

## Example run

```bash
python -m video_converter \
  --scan-root /mnt/media \
  --mount-path /mnt/media \
  --pvc-name media-pvc \
  --desired-format mkv \
  --job-namespace media \
  --job-prefix video-convert \
  --max-parallel-jobs 2 \
  --max-retries 3 \
  --poll-interval 60 \
  --image ghcr.io/<owner>/videoconverter-encoder:latest
```

The application can also be used in one-shot mode:

```bash
python -m video_converter --scan-root /mnt/media --run-once
```

## Network-aware scheduling

Multiple jobs copying large files to the cache area at the same time can saturate the backing network and significantly slow down each conversion. To reduce this, the controller batches pending work, checks the size of each source file, and adds a delay proportional to the file size before it launches the conversion job.

The default assumption is a 1 GBit/s network, with a 5% delay factor applied to the theoretical copy time. This keeps the system parallel without a full simultaneous burst of large cache copies.

```bash
python -m video_converter \
  --scan-root /mnt/media \
  --mount-path /mnt/media \
  --pvc-name media-pvc \
  --max-parallel-jobs 2 \
  --job-start-delay-seconds 15 \
  --network-throughput-mbps 1000 \
  --network-delay-factor 0.05
```

For slower links or very large media files, lower `--network-throughput-mbps` and/or increase `--job-start-delay-seconds` to extend the spacing between launch times.

## Job behavior

Each Kubernetes Job mounts the PVC named by `--pvc-name` at `--mount-path`, sets `DATA_DIR` and `CACHE_DIR`, passes the source file path into `encode_movie.sh`, and runs the script in the dedicated encoder image. The controller keeps a single active job per file using a unique label derived from the source path.

The output filename is not a raw ffmpeg transcode to the requested extension; it follows the HandBrake script behavior and writes `<source>.hb.mkv` next to the original file.
