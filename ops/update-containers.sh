#!/usr/bin/env bash
# update-containers.sh — безопасное обновление одного compose-стека на prod.
#
# Делает: фиксирует текущие образы под тегом rollback-<дата>, бэкапит compose-файл,
# затем (с --apply) выполняет pull + up -d и печатает состояние.
# Без --apply работает как dry-run и ничего не меняет.
#
# Использование:
#   ./update-containers.sh /opt/telegram-bot-api
#   ./update-containers.sh /opt/telegram-bot-api --apply
#
# См. docs/UPDATE_PLAN.md §4.
set -euo pipefail

DIR=${1:-}
MODE=${2:-}

if [[ -z "$DIR" || ! -d "$DIR" ]]; then
  echo "usage: $0 <compose_dir> [--apply]" >&2
  exit 2
fi

cd "$DIR"

if [[ -f docker-compose.yml ]]; then
  COMPOSE=docker-compose.yml
elif [[ -f docker-compose.yaml ]]; then
  COMPOSE=docker-compose.yaml
elif [[ -f compose.yml ]]; then
  COMPOSE=compose.yml
elif [[ -f compose.yaml ]]; then
  COMPOSE=compose.yaml
else
  echo "no compose file in $DIR" >&2
  exit 2
fi

STAMP=$(date +%Y%m%d-%H%M%S)
NAME=$(basename "$DIR")
BACKUP="/root/backups/containers/${NAME}-${STAMP}"

echo "== compose: $DIR/$COMPOSE"
echo "== backup:  $BACKUP"
mkdir -p "$BACKUP"

# retention: держим последние 4 бэкапа этого стека (совпадает с таймером, см. docs/UPDATE_PLAN.md §11)
KEEP=${KEEP:-4}
mapfile -t old < <(find /root/backups/containers -mindepth 1 -maxdepth 1 -type d -name "${NAME}-*" \
      -printf '%T@ %p\n' 2>/dev/null | sort -rn | tail -n +$((KEEP + 1)) | cut -d' ' -f2-)
if ((${#old[@]} > 0)); then
  rm -rf "${old[@]}"
  echo "   pruned ${#old[@]} old backup(s), keep=$KEEP"
fi

docker compose config > "$BACKUP/compose.resolved.yml"
docker compose config --images > "$BACKUP/images.txt"
docker ps -a --format '{{.Names}}\t{{.Image}}\t{{.Status}}' > "$BACKUP/containers.before.txt"
docker images --digests > "$BACKUP/docker-images.before.txt"

# repo без тега/дайджеста: ghcr.io/x/y:1.2 -> ghcr.io/x/y, reg:5000/x -> reg:5000/x
repo_of() {
  local ref=${1%%@*}
  if [[ ${ref##*/} == *:* ]]; then
    printf '%s' "${ref%:*}"
  else
    printf '%s' "$ref"
  fi
}

echo "== images in stack"
while IFS= read -r img; do
  [[ -z "$img" ]] && continue
  if docker image inspect "$img" >/dev/null 2>&1; then
    id=$(docker image inspect --format '{{.Id}}' "$img")
    rollback_ref="$(repo_of "$img"):rollback-${STAMP}"
    docker tag "$id" "$rollback_ref"
    printf '%s\t%s\n' "$rollback_ref" "$img" >> "$BACKUP/rollback-map.txt"
    printf '  %s -> %s\n' "$img" "$rollback_ref"
  else
    printf '  %s (not local yet)\n' "$img"
  fi
done < "$BACKUP/images.txt"

if [[ "$MODE" != "--apply" ]]; then
  echo
  echo "DRY-RUN. Для применения: $0 \"$DIR\" --apply"
  exit 0
fi

echo "== pull"
docker compose pull

echo "== up -d"
docker compose up -d --remove-orphans

echo "== state after"
docker compose ps
echo
echo "== last logs"
docker compose logs --tail 20 || true

echo
echo "== rollback (если что-то сломалось)"
echo "  cd $DIR"
if [[ -f "$BACKUP/rollback-map.txt" ]]; then
  echo "  # rollback-map.txt: <rollback_ref> <original_ref>"
  sed 's/^/  #   /' "$BACKUP/rollback-map.txt"
  echo "  # docker tag <rollback_ref> <original_ref> && docker compose up -d"
else
  echo "  # локальных образов не было — откат из $BACKUP"
fi
echo "  backup: $BACKUP"
