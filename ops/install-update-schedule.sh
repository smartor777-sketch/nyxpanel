#!/usr/bin/env bash
# install-update-schedule.sh — установить расписание обновлений на хосте.
#
#   ./install-update-schedule.sh [каталог_с_файлами]
#
# Ставит:
#   * apt-daily.timer        -> 01:30 UTC (скачивание индексов)
#   * apt-daily-upgrade.timer-> 02:00 UTC (security-обновления Debian)
#   * nyx-docker-engine-update.timer -> 1-й вторник месяца, 03:00 UTC
#   * nyx-containers-update.timer    -> 2-й вторник янв/апр/июл/окт, 03:00 UTC
#   * nyx-apps-inventory.timer       -> 1-й вторник месяца, 03:30 UTC
#
# Идемпотентен. Docker-таймеры ставятся только если в системе есть docker.
# Инвентарь приложений ставится всегда (нужен python3), список приложений —
# /etc/nyx-updates/apps-inventory.tsv, его можно править на хосте.
# См. docs/UPDATE_PLAN.md §5 и §11.
set -euo pipefail

SRC=${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}
[[ -d "$SRC" ]] || { echo "no such dir: $SRC" >&2; exit 2; }
cd "$SRC"

need() { [[ -f $1 ]] || { echo "missing $1" >&2; exit 2; }; }
need apt-daily.timer.override.conf
need apt-daily-upgrade.timer.override.conf

echo "== apt timers (security updates 02:00 UTC)"
install -d -m 0755 /etc/systemd/system/apt-daily.timer.d /etc/systemd/system/apt-daily-upgrade.timer.d
install -m 0644 apt-daily.timer.override.conf        /etc/systemd/system/apt-daily.timer.d/override.conf
install -m 0644 apt-daily-upgrade.timer.override.conf /etc/systemd/system/apt-daily-upgrade.timer.d/override.conf

if command -v docker >/dev/null 2>&1; then
  echo "== docker update scripts and timers"
  need nyx-docker-engine-update.sh
  need nyx-containers-update.sh
  need nyx-docker-engine-update.service
  need nyx-docker-engine-update.timer
  need nyx-containers-update.service
  need nyx-containers-update.timer
  install -m 0755 nyx-docker-engine-update.sh /usr/local/sbin/
  install -m 0755 nyx-containers-update.sh    /usr/local/sbin/
  install -m 0644 nyx-docker-engine-update.service /etc/systemd/system/
  install -m 0644 nyx-docker-engine-update.timer   /etc/systemd/system/
  install -m 0644 nyx-containers-update.service    /etc/systemd/system/
  install -m 0644 nyx-containers-update.timer      /etc/systemd/system/
else
  echo "== docker not found: engine/image timers skipped"
fi

if command -v python3 >/dev/null 2>&1; then
  echo "== apps inventory (native layer, 1st Tuesday 03:30 UTC)"
  need nyx-apps-inventory.py
  need nyx-apps-inventory.service
  need nyx-apps-inventory.timer
  need apps-inventory.tsv
  install -d -m 0755 /etc/nyx-updates
  # не перезатираем локальные правки: кладём список только если его ещё нет
  if [[ -f /etc/nyx-updates/apps-inventory.tsv ]]; then
    echo "   keep existing /etc/nyx-updates/apps-inventory.tsv"
  else
    install -m 0644 apps-inventory.tsv /etc/nyx-updates/apps-inventory.tsv
  fi
  install -m 0755 nyx-apps-inventory.py /usr/local/sbin/
  install -m 0644 nyx-apps-inventory.service /etc/systemd/system/
  install -m 0644 nyx-apps-inventory.timer   /etc/systemd/system/
else
  echo "== python3 not found: apps inventory skipped"
fi

echo "== reload"
systemctl daemon-reload
systemctl enable --now apt-daily.timer apt-daily-upgrade.timer

if command -v docker >/dev/null 2>&1; then
  systemctl enable --now nyx-docker-engine-update.timer nyx-containers-update.timer
fi

if [[ -f /etc/systemd/system/nyx-apps-inventory.timer ]]; then
  systemctl enable --now nyx-apps-inventory.timer
fi

echo
echo "== next runs"
systemctl list-timers apt-daily.timer apt-daily-upgrade.timer \
  nyx-docker-engine-update.timer nyx-containers-update.timer \
  nyx-apps-inventory.timer --no-pager
