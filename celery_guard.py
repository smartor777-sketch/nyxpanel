"""Helper: ensure Celery worker is running before submitting tasks."""
import subprocess
import logging

logger = logging.getLogger(__name__)


def ensure_celery_running() -> None:
    """Start celery-prod.service if not active. Non-blocking, best-effort."""
    try:
        result = subprocess.run(
            ["systemctl", "is-active", "celery-prod.service"],
            capture_output=True, text=True, timeout=5,
        )
        if result.stdout.strip() == "active":
            return
        logger.info("Celery worker not active, starting...")
        subprocess.run(
            ["systemctl", "start", "celery-prod.service"],
            capture_output=True, timeout=10,
        )
    except Exception as e:
        logger.warning("Failed to ensure celery is running: %s", e)
