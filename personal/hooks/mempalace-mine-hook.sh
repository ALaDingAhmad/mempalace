#!/usr/bin/env bash
# Claude Code SessionEnd hook — mine current session into MemPalace
#
# Wing is decided automatically by mempalace: Claude Code transcripts
# (matched by ~/.claude/projects/ path) all land in wing "wing_api".
#
# Install:
#   cp personal/hooks/mempalace-mine-hook.sh ~/.claude/
#   chmod +x ~/.claude/mempalace-mine-hook.sh
#   # Then add SessionEnd entry to ~/.claude/settings.json (see claude-settings.json.example)

INPUT=$(cat)
LOG="${MEMPALACE_HOOK_LOG:-/tmp/mempalace-hook.log}"

TRANSCRIPT=$(echo "$INPUT" | python3 -c "import sys,json; print(json.load(sys.stdin).get('transcript_path',''))" 2>/dev/null)

echo "[$(date)] transcript=$TRANSCRIPT" >> "$LOG"

if [ -n "$TRANSCRIPT" ] && [ -f "$TRANSCRIPT" ]; then
    TRANSCRIPT_DIR=$(python3 -c "import sys, os; print(os.path.dirname(sys.argv[1]))" "$TRANSCRIPT" 2>/dev/null)
    echo "[$(date)] mining $TRANSCRIPT_DIR" >> "$LOG"
    python3 -m mempalace mine "$TRANSCRIPT_DIR" --mode convos --extract general >> "$LOG" 2>&1
    echo "[$(date)] mine exit=$?" >> "$LOG"
else
    echo "[$(date)] transcript not found, skip" >> "$LOG"
fi
