FROM python:3.12-slim AS builder

ENV UV_COMPILE_BYTECODE=1 \
    UV_LINK_MODE=copy \
    PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1

RUN pip install --no-cache-dir uv
WORKDIR /app

COPY pyproject.toml README.md ./
COPY video_converter ./video_converter
COPY scripts ./scripts

RUN uv pip install --system --no-cache-dir .

FROM python:3.12-slim

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1

WORKDIR /app

COPY --from=builder /usr/local /usr/local
COPY --from=builder /app/scripts ./scripts

CMD ["python", "-m", "video_converter", "--help"]
