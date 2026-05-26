# Personal MemPalace Setup

Personal automation layer for [MemPalace](https://github.com/MemPalace/mempalace) — Claude Code hooks plus daily backup.

These files live in `personal/` so they never collide with upstream syncs. They're meant to be copied into `~/.claude/` and `~/.mempalace-backups/`, not run from this directory.

## What's here

| File | Purpose |
|------|---------|
| `hooks/mempalace-mine-hook.sh` | Slim **SessionEnd** hook — mines the transcript when Claude Code closes. Wing detection delegated to mempalace (Claude Code paths land in `wing_api`). |
| `hooks/mempalace-precompact-hook.sh` | **PreCompact** hook — full upstream defensive version, but rewritten to call `python3 -m mempalace` so it works without `mempalace` on PATH. |
| `scripts/mempalace-backup.sh` | Daily backup of `~/.mempalace/` + `~/.claude/projects/`, configurable via env vars. Probes the mine lock to avoid mid-write copies. |
| `claude-settings.json.example` | Example snippet to merge into `~/.claude/settings.json`. |

## Why these exist

Two real gaps in vanilla mempalace usage:

1. **Compaction blind spot** — Claude Code auto-compacts long conversations, replacing verbatim content with a summary. Without a PreCompact hook, those messages are lost before mempalace ever sees them. This violates mempalace's verbatim-recall promise.
2. **No automatic backup** — mempalace doesn't snapshot itself. ChromaDB has known corruption modes (e.g. `dimensionality=None` metadata damage) and the only documented recovery path assumes you have a backup. Repair flow's error message literally says *"Restore from your most recent palace backup, then re-mine."*

## Install

### 1. Hooks

```bash
cp personal/hooks/mempalace-mine-hook.sh       ~/.claude/
cp personal/hooks/mempalace-precompact-hook.sh ~/.claude/
chmod +x ~/.claude/mempalace-*.sh
```

Then merge `claude-settings.json.example` into your `~/.claude/settings.json`. **Don't overwrite the file** — it has other settings (permissions, model, theme, etc.).

Restart Claude Code. Hooks are loaded at session start only.

### 2. Daily backup

```bash
cp personal/scripts/mempalace-backup.sh ~/.claude/
chmod +x ~/.claude/mempalace-backup.sh
```

Pick a backup destination — strongly recommend a **different physical disk** than your palace. Example:

```bash
export MEMPALACE_BACKUP_ROOT="/path/to/external/backups/mempalace"
# Add the export to ~/.bashrc or set inline in the scheduler entry
```

#### Linux/macOS (cron)

```cron
0 3 * * * MEMPALACE_BACKUP_ROOT=/path/to/backups /bin/bash $HOME/.claude/mempalace-backup.sh
```

#### Windows (Task Scheduler via Git Bash)

```powershell
schtasks /Create /TN "MemPalace Daily Backup" `
  /TR "C:\Program Files\Git\usr\bin\bash.exe -lc '$HOME/.claude/mempalace-backup.sh'" `
  /SC DAILY /ST 03:00 /RL HIGHEST /F
```

Adjust the bash path to where your Git Bash lives. Set `MEMPALACE_BACKUP_ROOT` in the user environment first, or hardcode it into the script.

Verify:

```bash
# Trigger immediately to test
schtasks /Run /TN "MemPalace Daily Backup"
# Inspect log
tail -20 "$MEMPALACE_BACKUP_ROOT/backup.log"
```

## Tunables

`mempalace-backup.sh` reads these env vars:

| Variable | Default | Purpose |
|----------|---------|---------|
| `MEMPALACE_BACKUP_ROOT` | `$HOME/.mempalace-backups` | Where snapshots live |
| `MEMPALACE_KEEP_DAYS`   | `7` | How many daily snapshots to keep |
| `MEMPALACE_DIR`         | `$HOME/.mempalace` | Source palace dir |
| `CLAUDE_PROJECTS_DIR`   | `$HOME/.claude/projects` | Claude Code transcripts |

`mempalace-mine-hook.sh` reads:

| Variable | Default | Purpose |
|----------|---------|---------|
| `MEMPALACE_HOOK_LOG` | `/tmp/mempalace-hook.log` | Where to log mine activity |

## Recovery

If your palace gets corrupted:

```bash
# 1. Stop everything writing to mempalace
# 2. Move the bad palace aside (don't delete — useful for forensics)
mv ~/.mempalace ~/.mempalace.crashed-$(date +%Y%m%d)

# 3. Restore the most recent good snapshot
cp -a "$MEMPALACE_BACKUP_ROOT/daily-YYYYMMDD/mempalace" ~/.mempalace

# 4. Verify
python3 -m mempalace status
```

## Notes on design choices

- **No `--wing` flag** in the SessionEnd hook. mempalace 3.3+ auto-detects Claude Code paths (`.claude/projects/`) and groups them under `wing_api`. Passing `--wing` would override this and fragment memories across wings.
- **`python3 -m mempalace` everywhere**. Avoids dependency on the `mempalace` shim being on PATH — common breakage on Windows Store Python.
- **Lock probing in backup**. ChromaDB writes are not atomic across files; copying mid-mine can yield an inconsistent snapshot. The probe uses `flock -n` so it never blocks waiting.
