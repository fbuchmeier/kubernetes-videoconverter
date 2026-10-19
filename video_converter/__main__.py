from __future__ import annotations

from .config import parse_args
from .controller import run_controller


if __name__ == "__main__":
    config = parse_args()
    run_controller(config)
