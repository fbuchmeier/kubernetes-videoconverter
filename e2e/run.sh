#!/usr/bin/env bash
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CLUSTER_NAME="${E2E_CLUSTER_NAME:-videoconverter-e2e}"
NAMESPACE="${E2E_NAMESPACE:-videoconverter-e2e}"
RELEASE_NAME="${E2E_RELEASE_NAME:-videoconverter}"
MEDIA_DIR="${E2E_MEDIA_DIR:-${REPO_DIR}/.e2e/media}"
MEDIA_NODE_DIR="${E2E_MEDIA_NODE_DIR:-/mnt/videoconverter-e2e}"
SAMPLE_NAME="${E2E_SAMPLE_NAME:-BigBuckBunny.mp4}"
SAMPLE_URL="${E2E_SAMPLE_URL:-https://test-videos.co.uk/vids/bigbuckbunny/mp4/h264/360/Big_Buck_Bunny_360_10s_1MB.mp4}"
SAMPLE_URL_FALLBACK="${E2E_SAMPLE_URL_FALLBACK:-https://test-videos.co.uk/vids/bigbuckbunny/mp4/h264/720/Big_Buck_Bunny_720_10s_1MB.mp4}"
CONTROLLER_IMAGE="${E2E_CONTROLLER_IMAGE:-localhost/videoconverter:e2e}"
ENCODER_IMAGE="${E2E_ENCODER_IMAGE:-localhost/videoconverter-encoder:e2e}"
OUTPUT_TIMEOUT_SECONDS="${E2E_OUTPUT_TIMEOUT_SECONDS:-1200}"
LOG_DIR="${REPO_DIR}/.e2e/logs"

export KIND_EXPERIMENTAL_PROVIDER="${KIND_EXPERIMENTAL_PROVIDER:-podman}"

KIND_BIN="$(command -v kind || true)"
KIND=("${KIND_BIN:-kind}")
if [[ -n "$KIND_BIN" ]] && [[ "$(uname -s)" == "Linux" ]] && (( EUID != 0 )) \
    && command -v systemd-run >/dev/null 2>&1 \
    && systemd-run --scope --user --quiet true >/dev/null 2>&1; then
    KIND=(systemd-run --scope --user -p Delegate=yes --quiet --setenv="KIND_EXPERIMENTAL_PROVIDER=${KIND_EXPERIMENTAL_PROVIDER}" -- "$KIND_BIN")
fi

mkdir -p "$LOG_DIR" "$MEDIA_DIR"

log() {
    printf '[e2e] %s\n' "$*"
}

STAGE_TOTAL=10
CURRENT_STAGE="startup"
STAGE_LINE="============================================================"

stage() {
    local n="$1"
    local title="$2"
    CURRENT_STAGE="stage ${n}/${STAGE_TOTAL}: ${title}"
    printf '\n[e2e] %s\n' "$STAGE_LINE"
    printf '[e2e] STAGE %s/%s: %s\n' "$n" "$STAGE_TOTAL" "$title"
    printf '[e2e] %s\n' "$STAGE_LINE"
}

run_kind() {
    "${KIND[@]}" "$@"
}

require_tools() {
    local tool
    for tool in podman kind kubectl helm jq curl; do
        if ! command -v "$tool" >/dev/null 2>&1; then
            printf 'Missing required dependency: %s\n' "$tool" >&2
            exit 1
        fi
    done
    if ! podman info >/dev/null 2>&1; then
        printf 'Podman is not running. On macOS, run: podman machine start\n' >&2
        exit 1
    fi
}

dump_diagnostics() {
    kubectl get nodes -o wide || true
    kubectl get all -n "$NAMESPACE" -o wide || true
    kubectl get pv,pvc -n "$NAMESPACE" -o wide || true
    kubectl describe jobs -n "$NAMESPACE" || true
    kubectl describe pods -n "$NAMESPACE" || true
    kubectl logs -n "$NAMESPACE" -l app.kubernetes.io/instance="$RELEASE_NAME" --tail=200 || true
}

cleanup() {
    local status=$?
    trap - EXIT
    if (( status != 0 )); then
        log "E2E failed (exit ${status}) during [${CURRENT_STAGE}]; collecting diagnostics"
        dump_diagnostics 2>&1 | tee "$LOG_DIR/diagnostics.log" || true
    fi
    log "Deleting kind cluster ${CLUSTER_NAME}"
    run_kind delete cluster --name "$CLUSTER_NAME" >/dev/null 2>&1 || true
    exit "$status"
}
trap cleanup EXIT

download_sample() {
    local url
    for url in "$SAMPLE_URL" "$SAMPLE_URL_FALLBACK"; do
        log "Downloading sample video from ${url}"
        if curl -fsSL --retry 3 --retry-delay 2 --connect-timeout 10 \
            -o "$MEDIA_DIR/$SAMPLE_NAME" "$url"; then
            return 0
        fi
    done
    return 1
}

stage 1 "Check prerequisites"
require_tools

log "Using kind provider: ${KIND_EXPERIMENTAL_PROVIDER}"
stage 2 "Download sample video"
download_sample
[[ -s "$MEDIA_DIR/$SAMPLE_NAME" ]]
log "Sample video: $(du -h "$MEDIA_DIR/$SAMPLE_NAME" | cut -f1)"

stage 3 "Create kind cluster"
cat > "$LOG_DIR/kind-config.yaml" <<EOF
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
nodes:
  - role: control-plane
    extraMounts:
      - hostPath: ${MEDIA_DIR}
        containerPath: ${MEDIA_NODE_DIR}
        readOnly: false
EOF

log "Creating kind cluster ${CLUSTER_NAME}"
run_kind create cluster --name "$CLUSTER_NAME" --config "$LOG_DIR/kind-config.yaml" --wait 180s
kubectl config use-context "kind-${CLUSTER_NAME}"
kubectl cluster-info
kubectl wait --for=condition=Ready nodes --all --timeout=180s

stage 4 "Build container images"
log "Building controller image ${CONTROLLER_IMAGE}"
podman build --tag "$CONTROLLER_IMAGE" "$REPO_DIR" 2>&1 | tee "$LOG_DIR/controller-build.log"
podman image inspect "$CONTROLLER_IMAGE" >/dev/null

log "Building encoder image ${ENCODER_IMAGE}"
podman build --file "$REPO_DIR/encode-job.Dockerfile" --tag "$ENCODER_IMAGE" "$REPO_DIR" 2>&1 | tee "$LOG_DIR/encoder-build.log"
podman image inspect "$ENCODER_IMAGE" >/dev/null

stage 5 "Load images into kind"
for image in "$CONTROLLER_IMAGE" "$ENCODER_IMAGE"; do
    safe_name="$(printf '%s' "$image" | tr '/:' '__')"
    archive="${LOG_DIR}/${safe_name}.tar"
    log "Saving ${image} to ${archive}"
    podman save -o "$archive" "$image" 2>&1 | tee -a "$LOG_DIR/kind-load.log"
    log "Loading ${archive} into kind"
    run_kind load image-archive "$archive" --name "$CLUSTER_NAME" 2>&1 | tee -a "$LOG_DIR/kind-load.log"
done

stage 6 "Create namespace, PV, and PVC"
kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -
kubectl apply -n "$NAMESPACE" -f - <<EOF
apiVersion: v1
kind: PersistentVolume
metadata:
  name: ${RELEASE_NAME}-media-pv
spec:
  capacity:
    storage: 5Gi
  accessModes:
    - ReadWriteOnce
  persistentVolumeReclaimPolicy: Retain
  storageClassName: manual
  hostPath:
    path: ${MEDIA_NODE_DIR}
    type: Directory
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: media-pvc
  namespace: ${NAMESPACE}
spec:
  accessModes:
    - ReadWriteOnce
  resources:
    requests:
      storage: 5Gi
  storageClassName: manual
  volumeName: ${RELEASE_NAME}-media-pv
EOF

pvc_phase=""
for _ in {1..30}; do
    pvc_phase=$(kubectl get pvc media-pvc -n "$NAMESPACE" -o jsonpath='{.status.phase}')
    [[ "$pvc_phase" == "Bound" ]] && break
    sleep 2
done
[[ "$pvc_phase" == "Bound" ]]

stage 7 "Install Helm chart"
CONTROLLER_REPOSITORY="${CONTROLLER_IMAGE%:*}"
CONTROLLER_TAG="${CONTROLLER_IMAGE##*:}"

helm upgrade --install "$RELEASE_NAME" "$REPO_DIR/helm/videoconverter" \
    --namespace "$NAMESPACE" \
    --create-namespace \
    --values "$REPO_DIR/e2e/values.yaml" \
    --set "image.repository=${CONTROLLER_REPOSITORY}" \
    --set "image.tag=${CONTROLLER_TAG}" \
    --set "app.image=${ENCODER_IMAGE}" \
    --wait \
    --timeout 10m 2>&1 | tee "$LOG_DIR/helm-install.log"

stage 8 "Wait for deployment readiness"
kubectl rollout status "deployment/${RELEASE_NAME}" -n "$NAMESPACE" --timeout=300s

stage 9 "Wait for conversion output"
EXPECTED_OUTPUT="${MEDIA_DIR}/${SAMPLE_NAME%.*}.hb.mkv"
log "Waiting for converted file ${EXPECTED_OUTPUT}"
deadline=$((SECONDS + OUTPUT_TIMEOUT_SECONDS))
while [[ ! -s "$EXPECTED_OUTPUT" ]]; do
    failed_jobs=$(kubectl get jobs -n "$NAMESPACE" -o json | jq '[.items[] | select((.status.failed // 0) > 0)] | length')
    if (( failed_jobs > 0 )); then
        log "A conversion job failed"
        exit 1
    fi
    if (( SECONDS >= deadline )); then
        log "Timed out waiting for ${EXPECTED_OUTPUT}"
        exit 1
    fi
    sleep 5
done

log "Converted file present: $(du -h "$EXPECTED_OUTPUT" | cut -f1)"

stage 10 "Verify output codec"
codec=$(podman run --rm --network none \
    --entrypoint ffprobe \
    -v "${MEDIA_DIR}:/media:ro" \
    "$ENCODER_IMAGE" \
    -v error -select_streams v:0 -show_entries stream=codec_name \
    -of default=noprint_wrappers=1:nokey=1 \
    "/media/${SAMPLE_NAME%.*}.hb.mkv")
log "Output video codec: ${codec}"
[[ "$codec" == "hevc" ]]

kubectl logs -n "$NAMESPACE" "deployment/${RELEASE_NAME}" --tail=200 | tee "$LOG_DIR/controller.log"

printf '\n[e2e] %s\n' "$STAGE_LINE"
printf '[e2e] END-TO-END TEST PASSED\n'
printf '[e2e] %s\n' "$STAGE_LINE"
