#!/bin/sh
# Single writer: deployed as one sidecar in a replicas=1/Recreate Deployment.
set -eu
export LC_ALL=C
DB_PATH=${DB_PATH:-/config/atuin.db}
BACKUP_DIR=${BACKUP_DIR:-/config/backup}

log() { printf '%s %s\n' "$(date -u +%FT%TZ)" "$*" >&2; }
valid() {
  [ -s "$1" ] && [ ! -L "$1" ] || return 1
  result=$(sqlite3 -readonly "$1" 'PRAGMA integrity_check;') || return 1
  [ "$result" = ok ]
}

snapshot() (
  # A subshell confines traps and working directory to this attempt.
  set -eu
  umask 077
  partial=
  trap '[ -z "$partial" ] || rm -f "$partial"' EXIT
  trap 'exit 1' HUP INT TERM
  [ -s "$DB_PATH" ] || { log "ERROR source database missing/empty; skipping retention"; exit 1; }
  mkdir -p "$BACKUP_DIR" || exit 1
  partial=$(mktemp "$BACKUP_DIR/.atuin-$(date -u +%Y-%m-%dT%H%M%SZ)-XXXXXX") || exit 1
  escaped=$(printf '%s' "$partial" | sed "s/'/''/g")
  if ! sqlite3 -readonly "$DB_PATH" ".timeout 30000" "VACUUM INTO '$escaped'"; then
    log "ERROR snapshot failed; skipping retention"
    exit 1
  fi
  if ! valid "$partial"; then
    log "ERROR snapshot integrity check failed; skipping retention"
    exit 1
  fi
  name=${partial##*/}
  final="$BACKUP_DIR/${name#.}.db"
  [ ! -e "$final" ] || { log "ERROR snapshot name collision; skipping retention"; exit 1; }
  mv "$partial" "$final" || { log "ERROR publishing snapshot failed; skipping retention"; exit 1; }
  partial=
  log "INFO snapshot verified: $final"

  # Only known generated names (including legacy daily snapshots), never symlinks.
  # Keep at least three integrity-checked generations, regardless of their age.
  # Invalid snapshots are preserved for operator inspection and do not count.
  cd "$BACKUP_DIR" || exit 1
  find . -maxdepth 1 -type f -name 'atuin-*.db' |
    grep -E '^./atuin-[0-9]{4}-[0-9]{2}-[0-9]{2}(T[0-9]{6}Z-[A-Za-z0-9]+)?\.db$' |
    sort -r |
    (
      kept=0
      while IFS= read -r file; do
        if ! valid "$file"; then
          log "WARN invalid existing snapshot preserved: $file"
          continue
        fi
        kept=$((kept + 1))
        [ "$kept" -gt 3 ] || continue
        # Keep the original >7-day policy as well as the minimum-generation gate.
        if [ -n "$(find "$file" -mtime +7 -print)" ]; then
          rm "$file" || exit 1
          log "INFO expired snapshot removed: $file"
        fi
      done
    )
)

case "${1:-}" in
  --once) snapshot ;;
  "")
    # Run immediately so frequent pod restarts cannot starve backups.
    while true; do
      if ! snapshot; then
        log "ERROR backup attempt failed; retrying in one hour"
        sleep 3600 &
      else
        sleep 86400 &
      fi
      wait $!
    done
    ;;
  *) log "ERROR usage: $0 [--once]"; exit 2 ;;
esac
