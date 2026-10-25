#!/usr/bin/env bash
set -euo pipefail

INPUT_FILE="${1:-}"

DEBUG=${DEBUG:-}
FORCE=${FORCE:-}

# Config (can be overridden via env)
DATA_DIR="${DATA_DIR:-/data}"
CACHE_DIR="${CACHE_DIR:-/cache}"
POD_NAME="${POD_NAME:-$(hostname)}"
LOCK_TTL_SECONDS="${LOCK_TTL_SECONDS:-3600}"
HB_CLI="${HB_CLI:-/usr/bin/HandBrakeCLI}"
FFPROBE="${FFPROBE:-/usr/bin/ffprobe}"

# rsync options for resumable copies (+ ensure files are writable)
RSYNC_OPTS=(--partial --inplace --chmod=ugo=rw --bwlimit=0 --info=progress2)

log() {
    echo "$(date -Is) [$POD_NAME] $*"
}

# Returns 0 if the file should be encoded (i.e. NOT hevc), 1 if should be skipped (is hevc)
is_hevc() {
    local file="$1"
    # get codec_name (e.g. hevc, h264)
    local codec
    codec=$("$FFPROBE" -v error -select_streams v:0 \
        -show_entries stream=codec_name -of default=noprint_wrappers=1:nokey=1 "$file" 2>/dev/null || true)

    if [[ -z "$codec" ]]; then
        # can't determine codec -> don't skip (attempt encode)
        return 1
    fi

    # if codec is hevc, return success (is hevc)
    if [[ "$codec" == "hevc" ]] || [[ "$codec" == "vc1" ]] ; then
        return 0
    fi

    return 1
}

# Acquire lock by creating lockdir atomically; returns 0 on success
acquire_lock() {
    local src="$1"
    local lockdir="${src}.lock"

    if mkdir "$lockdir" 2>/dev/null; then
        jq -n --arg pod "$POD_NAME" --arg ts "$(date -Is)" \
            '{"pod":$pod,"ts":$ts,"status":"in-progress"}' > "$lockdir/status.json"
        return 0
    fi

    # lock exists — check for stale
    if [[ -f "$lockdir/status.json" ]]; then
        local ts
        ts=$(jq -r .ts "$lockdir/status.json" 2>/dev/null || true)
        if [[ -n "$ts" ]]; then
            # compute age in seconds
            local age=$(( $(date +%s) - $(date -d "$ts" +%s) ))
            if (( age > LOCK_TTL_SECONDS )); then
                log "Stale lock (age=${age}s) on $src — reclaiming"
                rm -rf "$lockdir"
                if mkdir "$lockdir" 2>/dev/null; then
                    jq -n --arg pod "$POD_NAME" --arg ts "$(date -Is)" \
                        '{"pod":$pod,"ts":$ts,"status":"reclaimed"}' > "$lockdir/status.json"
                    return 0
                fi
            fi
        fi
    fi

    return 1
}

release_lock() {
    local src="$1"
    rm -rf "${src}.lock" || true
}

# Main processing logic for a single file
process_file() {
    local src="$1"
    local base
    base=$(basename "$src")
    local cache_in="${CACHE_DIR}/in/${base}"
    local cache_out="${CACHE_DIR}/out/${base}"
    local dest_tmp="${src}.hb.tmp"
    local dest_final="${src%.*}.hb.mkv"

    log "Copying to cache: $src -> $cache_in"
    rsync "${RSYNC_OPTS[@]}" "$src" "$cache_in"

    local hb_args=(
        --encoder x265
        --encoder-profile main10
        --quality 18.0
        --aencoder copy
        --audio-copy-mask ac3,eac3,dts,dtshd,truehd,flac
        --audio-fallback av_aac
        --subtitle scan
        --subtitle-burn scan
        --subtitle-lang-list ger,eng,fra
        --subtitle-default "none"                                                                                                 
        --audio-lang-list ger,eng,fra
        # --start-at duration:0                                                                                                      
        # --stop-at duration:120                                                                                                           
        --optimize  
	)

    log "Starting HandBrakeCLI encode: $cache_in -> $cache_out"
    # HandBrake config: x265 main10 (10-bit), keep audio tracks where possible, keep subtitles
    "$HB_CLI" -i "$cache_in" -o "$cache_out" ${hb_args[*]}
    if [[ $? -ne 0 ]] ; then
	    log "ERROR: failed to convert"
	    return 3
    fi

    if [[ ! -f "$cache_out" ]]; then
        log "ERROR: expected output $cache_out not found"
        return 2
    fi

    log "Uploading encoded file: $cache_out -> $dest_tmp"
    rsync "${RSYNC_OPTS[@]}" "$cache_out" "$dest_tmp"

    log "Moving into place: $dest_tmp -> $dest_final"
    mv -f "$dest_tmp" "$dest_final"

    # Optionally keep cache for debugging; remove to save space:
    if [[ -n "${INPUT_FILE}" ]] && [[ -f "${INPUT_FILE}" ]] ; then
      log "Keeping cache because input file is set"
    else
      log "Removing cached files $cache_in and $cache_out"
      rm -f "$cache_in" "$cache_out" || true
    fi

    return 0
}

# Main loop
main_loop() {
    log "Worker started. DATA_DIR=$DATA_DIR CACHE_DIR=$CACHE_DIR"

    # ensure cache dir exists
    mkdir -p "$CACHE_DIR"
    mkdir -p "$CACHE_DIR/in"
    mkdir -p "$CACHE_DIR/out"

    while true; do
        # find mkv files that are not already produced hb copies
        # exclude files with .hb.mkv suffix
        find "$DATA_DIR" -type f \( -iname '*.mkv' -o -iname '*.mp4' \) ! -iname '*.hb.mkv' | while read -r f; do
            if [[ -n "${INPUT_FILE}" ]] && [[ -f "${INPUT_FILE}" ]] ; then
              f="$INPUT_FILE"
	    fi

            # sanity check: file still exists
            [[ -f "$f" ]] || continue

            # skip if a .hb.mkv output already exists next to the source
            source_stem="${f%.*}"
            if [[ -f "${source_stem}.hb.mkv" ]] && [[ -z "$FORCE" ]] ; then
                continue
            fi

            # skip if already locked (another worker)
            if [[ -d "${f}.lock" ]] ; then
		log "Waiting for lock on $f to be released"
                continue
            fi

            # Quick codec check: skip if file is already HEVC
            if is_hevc "$f"; then
                log "SKIP (already HEVC): $f"
                # mark with a small status file so humans can see it quickly (optional)
                if mkdir "${f}.skip" 2>/dev/null; then
                    jq -n --arg pod "$POD_NAME" --arg ts "$(date -Is)" --arg note "already_hevc" '{"pod":$pod,"ts":$ts,"note":$note}' > "${f}.skip/status.json"
                fi
                continue
            fi

            # Try to acquire lock
            if acquire_lock "$f"; then
                log "Acquired lock for $f"
                local rc=0
                if process_file "$f"; then
                    jq -n --arg pod "$POD_NAME" --arg ts "$(date -Is)" --arg st "done" '{"pod":$pod,"ts":$ts,"status":$st}' > "${f}.lock/status.json"
                else
                    rc=$?
                    jq -n --arg pod "$POD_NAME" --arg ts "$(date -Is)" --arg st "failed" --arg code "$rc" '{"pod":$pod,"ts":$ts,"status":$st,"code":$code}' > "${f}.lock/status.json"
                    log "Processing failed for $f with code $rc"
		    break
                fi
                release_lock "$f"
            fi
        done

	# When only a single file is requested, exit early
	if [[ -n "${INPUT_FILE}" ]] && [[ -f "${INPUT_FILE}" ]] ; then
		break
	fi

        # brief sleep to avoid busy loop
        sleep 15

    done
}

# Start
if [ -n "$DEBUG" ] ; then
	set -x
fi
main_loop

