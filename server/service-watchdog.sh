#!/bin/bash
# service-watchdog.sh — checks services, restarts if down, logs actions
# Deploy to /usr/local/bin/service-watchdog.sh
# Add to crontab: */5 * * * * /usr/local/bin/service-watchdog.sh

SERVICES="xray caddy hysteria-server hysteria2 mita olcrtc awg-quick@awg0 trojan-go"
LOG="/var/log/service-watchdog.log"
MAX_LOG_LINES=1000

log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') $1" >> "$LOG"
}

rotate_log() {
    if [ -f "$LOG" ] && [ "$(wc -l < "$LOG")" -gt "$MAX_LOG_LINES" ]; then
        tail -n $((MAX_LOG_LINES / 2)) "$LOG" > "${LOG}.tmp"
        mv "${LOG}.tmp" "$LOG"
        log "Log rotated (kept last $((MAX_LOG_LINES / 2)) lines)"
    fi
}

restarted=0
for svc in $SERVICES; do
    # skip services that aren't installed
    if ! systemctl cat "${svc}.service" &>/dev/null; then
        continue
    fi
    status=$(systemctl is-active "$svc" 2>/dev/null)
    if [ "$status" != "active" ]; then
        log "WARN: $svc is $status — restarting"
        systemctl restart "$svc"
        sleep 2
        new_status=$(systemctl is-active "$svc" 2>/dev/null)
        if [ "$new_status" = "active" ]; then
            log "OK: $svc restarted successfully"
        else
            log "ERROR: $svc restart failed (status=$new_status)"
        fi
        restarted=$((restarted + 1))
    fi
done

if [ "$restarted" -eq 0 ]; then
    log "OK: all services active"
fi

rotate_log
