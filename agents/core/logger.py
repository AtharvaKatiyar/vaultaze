"""
agents/core/logger.py
─────────────────────
Shared structured-logging setup.

Usage:
    from core.logger import get_logger
    log = get_logger(__name__)
    log.info("safe_mode_triggered", health=95, price=42000.0)

Output (json format):
    {"event": "safe_mode_triggered", "health": 95, "price": 42000.0,
     "logger": "agents.risk_sentinel", "level": "info",
     "timestamp": "2026-02-24T12:00:00Z"}
"""

from __future__ import annotations

import logging
import sys

import structlog


def configure_logging(level: str = "INFO", fmt: str = "json") -> None:
    """
    Call once at startup (from main.py) to configure the global log pipeline.

    Parameters
    ----------
    level:
        One of DEBUG / INFO / WARNING / ERROR.
    fmt:
        "json"    — machine-readable (production / docker)
        "console" — human-readable coloured output (development)
    """
    # Standard library root logger
    logging.basicConfig(
        format="%(message)s",
        stream=sys.stdout,
        level=getattr(logging, level.upper(), logging.INFO),
    )

    shared_processors: list = [
        structlog.contextvars.merge_contextvars,
        structlog.stdlib.add_log_level,
        structlog.processors.TimeStamper(fmt="iso", utc=True),
        structlog.processors.StackInfoRenderer(),
        structlog.processors.format_exc_info,
    ]

    if fmt == "console":
        renderer = structlog.dev.ConsoleRenderer(colors=True)
    else:
        renderer = structlog.processors.JSONRenderer()

    structlog.configure(
        processors=shared_processors + [renderer],
        wrapper_class=structlog.make_filtering_bound_logger(
            getattr(logging, level.upper(), logging.INFO)
        ),
        context_class=dict,
        logger_factory=structlog.PrintLoggerFactory(),
        cache_logger_on_first_use=True,
    )


def get_logger(name: str) -> structlog.BoundLogger:
    """Return a named structlog bound logger."""
    return structlog.get_logger(name)
