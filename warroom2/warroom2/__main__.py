"""warroom2.__main__ — ``python -m warroom2`` entrypoint."""

from __future__ import annotations

import os


def main() -> None:
    import uvicorn

    uvicorn.run(
        "warroom2.app:create_app",
        host=os.environ.get("WARROOM2_HOST", "0.0.0.0"),
        port=int(os.environ.get("WARROOM2_PORT", "8080")),
        factory=True,
        log_level=os.environ.get("WARROOM2_LOG_LEVEL", "info").lower(),
        access_log=True,
    )


if __name__ == "__main__":
    main()
