#!/bin/bash
# Celery watchdog: stops worker if Redis queue empty for IDLE_THRESHOLD runs
REDIS_CLI="redis-cli"
QUEUE_NAME="celery"
IDLE_THRESHOLD=3
STATE_FILE="/var/run/celery-watchdog-count"

count=$(cat $STATE_FILE 2>/dev/null || echo 0)

queue_len=$($REDIS_CLI LLEN $QUEUE_NAME 2>/dev/null)

if [ -z "$queue_len" ] || [ "$queue_len" = "0" ]; then
    count=$((count + 1))
    echo $count > $STATE_FILE
    if [ $count -ge $IDLE_THRESHOLD ]; then
        if systemctl is-active celery-prod.service >/dev/null 2>&1; then
            echo "[$(date)] Queue empty for $count intervals, stopping celery-prod" >> /var/log/celery-watchdog.log
            systemctl stop celery-prod.service
        fi
    fi
else
    echo 0 > $STATE_FILE
    if ! systemctl is-active celery-prod.service >/dev/null 2>&1; then
        echo "[$(date)] Queue has $queue_len tasks, starting celery-prod" >> /var/log/celery-watchdog.log
        systemctl start celery-prod.service
    fi
fi
