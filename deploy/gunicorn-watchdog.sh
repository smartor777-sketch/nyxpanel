#!/bin/bash
# Gunicorn watchdog: restart if master PID alive > MAX_AGE_HOURS
# Called by cron every 12 hours. If gunicorn master hasn't been
# recycled in MAX_AGE_HOURS, force-restart the service.

SERVICE="innercore-prod"
STATE_FILE="/var/run/gunicorn-master-start"
MAX_AGE_SECONDS=$((3 * 24 * 3600))  # 3 days

# Find gunicorn master PID
MASTER_PID=$(pgrep -f "gunicorn.*main:app" | head -1)

if [ -z "$MASTER_PID" ]; then
    echo "[$(date)] Gunicorn not running, starting $SERVICE" >> /var/log/gunicorn-watchdog.log
    systemctl start $SERVICE
    exit 0
fi

# Record start time on first detection
if [ ! -f "$STATE_FILE" ]; then
    echo "$MASTER_PID $(date +%s)" > "$STATE_FILE"
    echo "[$(date)] Recorded initial master PID $MASTER_PID" >> /var/log/gunicorn-watchdog.log
    exit 0
fi

SAVED_PID=$(cut -d' ' -f1 "$STATE_FILE")
SAVED_TS=$(cut -d' ' -f2 "$STATE_FILE")
NOW=$(date +%s)
AGE=$((NOW - SAVED_TS))

# If PID changed (worker recycle or manual restart), reset timer
if [ "$MASTER_PID" != "$SAVED_PID" ]; then
    echo "$MASTER_PID $NOW" > "$STATE_FILE"
    echo "[$(date)] Master PID changed ($SAVED_PID -> $MASTER_PID), timer reset" >> /var/log/gunicorn-watchdog.log
    exit 0
fi

# Same PID for too long — force restart
if [ $AGE -ge $MAX_AGE_SECONDS ]; then
    echo "[$(date)] Master PID $MASTER_PID alive for $((AGE/3600))h (>72h), restarting $SERVICE" >> /var/log/gunicorn-watchdog.log
    systemctl restart $SERVICE
    NEW_PID=$(pgrep -f "gunicorn.*main:app" | head -1)
    echo "$NEW_PID $(date +%s)" > "$STATE_FILE"
else
    REMAINING=$(( (MAX_AGE_SECONDS - AGE) / 3600 ))
    echo "[$(date)] Master PID $MASTER_PID alive for $((AGE/3600))h, ${REMAINING}h until forced restart" >> /var/log/gunicorn-watchdog.log
fi
