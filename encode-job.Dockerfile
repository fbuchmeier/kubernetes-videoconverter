FROM debian:12-slim

ENV DEBIAN_FRONTEND=noninteractive \
    DATA_DIR=/data \
    CACHE_DIR=/cache \
    PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        bash \
        ca-certificates \
        ffmpeg \
        handbrake-cli \
        jq \
        rsync \
    && rm -rf /var/lib/apt/lists/* \
    && mkdir -p /data /cache

COPY scripts/encode_movie.sh /usr/local/bin/encode_movie.sh
RUN chmod +x /usr/local/bin/encode_movie.sh

ENTRYPOINT ["/usr/local/bin/encode_movie.sh"]
