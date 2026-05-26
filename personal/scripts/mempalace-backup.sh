#!/usr/bin/env bash
# MemPalace daily backup script
#
# Backs up the palace + Claude Code transcripts, keeps last N days.
# Skips when mine is actively running (probes the mine lock).
#
# === Install ===
#   cp personal/scripts/mempalace-backup.sh ~/.claude/
#   chmod +x ~/.claude/mempalace-backup.sh
#   # Set MEMPALACE_BACKUP_ROOT below (or export it before scheduling).
#   # Register a daily cron / Windows Task Scheduler entry — see README.md.
#
# === Tunables ===
# Override via env vars or edit the defaults below.
#   MEMPALACE_BACKUP_ROOT — where snapshots live (default: $HOME/.mempalace-backups)
#   MEMPALACE_KEEP_DAYS   — how many daily snapshots to retain (default: 7)
#   MEMPALACE_DIR         — palace location (default: $HOME/.mempalace)
#   CLAUDE_PROJECTS_DIR   — Claude Code transcript dir (default: $HOME/.claude/projects)

set -u

BACKUP_ROOT="${MEMPALACE_BACKUP_ROOT:-$HOME/.mempalace-backups}"
KEEP_DAYS="${MEMPALACE_KEEP_DAYS:-7}"
SRC_MEMPALACE="${MEMPALACE_DIR:-$HOME/.mempalace}"
SRC_PROJECTS="${CLAUDE_PROJECTS_DIR:-$HOME/.claude/projects}"
LOG="$BACKUP_ROOT/backup.log"

mkdir -p "$BACKUP_ROOT"

TODAY=$(date +%Y%m%d)
DEST="$BACKUP_ROOT/daily-$TODAY"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$LOG"; }

log "===== backup start ====="

# 1. Probe the mine lock — if mempalace is actively mining, skip this run
#    to avoid copying a half-written palace. The lock filename matches
#    mempalace/palace.py:mine_palace_lock() — sha256(realpath(palace))[:16].
PALACE_PATH="$SRC_MEMPALACE/palace"
if [ -d "$PALACE_PATH" ]; then
    PALACE_KEY=$(python3 -c "
import hashlib, os, sys
p = os.path.realpath(sys.argv[1])
print(hashlib.sha256(p.encode()).hexdigest()[:16])
" "$PALACE_PATH" 2>/dev/null)
    MINE_LOCK="$SRC_MEMPALACE/locks/mine_palace_${PALACE_KEY}.lock"

    if [ -e "$MINE_LOCK" ]; then
        if flock -n "$MINE_LOCK" true 2>/dev/null; then
            log "mine lock file exists but unheld, continuing"
        else
            log "mine in progress (holds $MINE_LOCK), skipping this run"
            exit 0
        fi
    fi
fi

# 2. Overwrite same-day backup on re-run
if [ -d "$DEST" ]; then
    log "same-day backup exists, overwriting: $DEST"
    rm -rf "$DEST"
fi
mkdir -p "$DEST"

# 3. Backup the palace
if [ -d "$SRC_MEMPALACE" ]; then
    log "copying $SRC_MEMPALACE -> $DEST/mempalace/"
    cp -a "$SRC_MEMPALACE" "$DEST/mempalace" 2>>"$LOG"
    SIZE_MP=$(du -sh "$DEST/mempalace" 2>/dev/null | cut -f1)
    log "  mempalace size: $SIZE_MP"
else
    log "  warn: $SRC_MEMPALACE not found, skipping"
fi

# 4. Backup Claude Code transcripts (source data for mine)
if [ -d "$SRC_PROJECTS" ]; then
    log "copying $SRC_PROJECTS -> $DEST/projects/"
    cp -a "$SRC_PROJECTS" "$DEST/projects" 2>>"$LOG"
    SIZE_PJ=$(du -sh "$DEST/projects" 2>/dev/null | cut -f1)
    log "  projects size: $SIZE_PJ"
else
    log "  warn: $SRC_PROJECTS not found, skipping"
fi

TOTAL=$(du -sh "$DEST" 2>/dev/null | cut -f1)
log "backup done, total size: $TOTAL"

# 5. Prune snapshots older than KEEP_DAYS
log "pruning snapshots older than $KEEP_DAYS days:"
CUTOFF=$(date -d "$KEEP_DAYS days ago" +%Y%m%d 2>/dev/null || date -v-${KEEP_DAYS}d +%Y%m%d)
for d in "$BACKUP_ROOT"/daily-*; do
    [ -d "$d" ] || continue
    NAME=$(basename "$d")
    DATESTR="${NAME#daily-}"
    if [ "$DATESTR" -lt "$CUTOFF" ] 2>/dev/null; then
        log "  removing old snapshot: $NAME"
        rm -rf "$d"
    fi
done

# 6. List retained snapshots
log "retained snapshots:"
ls -1 "$BACKUP_ROOT" 2>/dev/null | grep "^daily-" | sort | while read d; do
    SZ=$(du -sh "$BACKUP_ROOT/$d" 2>/dev/null | cut -f1)
    log "  $d ($SZ)"
done

log "===== backup end ====="
