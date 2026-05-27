#!/usr/bin/env bash
# MemPalace 每日备份脚本
#
# 备份范围：palace 全部 + Claude Code transcript，保留最近 N 天。
# mine 在跑时会跳过本次备份（通过试探 mine 锁文件判断）。
#
# === 安装 ===
#   cp personal/scripts/mempalace-backup.sh ~/.claude/
#   chmod +x ~/.claude/mempalace-backup.sh
#   # 在下面设置 MEMPALACE_BACKUP_ROOT（或在调度器里 export 进去）
#   # 然后注册 cron / Windows 计划任务 —— 参考 README.md
#
# === 可调环境变量 ===
# 覆盖下面的默认值，或者直接改默认值。
#   MEMPALACE_BACKUP_ROOT —— 备份根目录（默认 $HOME/.mempalace-backups）
#   MEMPALACE_KEEP_DAYS   —— 保留天数（默认 7）
#   MEMPALACE_DIR         —— palace 路径（默认 $HOME/.mempalace）
#   CLAUDE_PROJECTS_DIR   —— Claude Code transcript 路径（默认 $HOME/.claude/projects）

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

log "===== 备份开始 ====="

# 1. 试探 mine 锁 —— 如果 mempalace 正在 mine，跳过本次备份，
#    避免复制到半写状态的 palace。锁文件名对应
#    mempalace/palace.py:mine_palace_lock()，sha256(realpath(palace))[:16]。
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
            log "mine 锁文件存在但无人持有，继续备份"
        else
            log "mine 正在运行（持有 $MINE_LOCK），跳过本次备份"
            exit 0
        fi
    fi
fi

# 2. 同一天重跑则覆盖
if [ -d "$DEST" ]; then
    log "同日已有备份，覆盖：$DEST"
    rm -rf "$DEST"
fi
mkdir -p "$DEST"

# 3. 备份 palace
if [ -d "$SRC_MEMPALACE" ]; then
    log "复制 $SRC_MEMPALACE -> $DEST/mempalace/"
    cp -a "$SRC_MEMPALACE" "$DEST/mempalace" 2>>"$LOG"
    SIZE_MP=$(du -sh "$DEST/mempalace" 2>/dev/null | cut -f1)
    log "  mempalace 大小: $SIZE_MP"
else
    log "  警告: $SRC_MEMPALACE 不存在，跳过"
fi

# 4. 备份 Claude Code transcript（mine 的原始数据源）
if [ -d "$SRC_PROJECTS" ]; then
    log "复制 $SRC_PROJECTS -> $DEST/projects/"
    cp -a "$SRC_PROJECTS" "$DEST/projects" 2>>"$LOG"
    SIZE_PJ=$(du -sh "$DEST/projects" 2>/dev/null | cut -f1)
    log "  projects 大小: $SIZE_PJ"
else
    log "  警告: $SRC_PROJECTS 不存在，跳过"
fi

TOTAL=$(du -sh "$DEST" 2>/dev/null | cut -f1)
log "本次备份完成，总大小: $TOTAL"

# 5. 清理超过 KEEP_DAYS 天的旧备份
log "清理超过 $KEEP_DAYS 天的旧备份："
CUTOFF=$(date -d "$KEEP_DAYS days ago" +%Y%m%d 2>/dev/null || date -v-${KEEP_DAYS}d +%Y%m%d)
for d in "$BACKUP_ROOT"/daily-*; do
    [ -d "$d" ] || continue
    NAME=$(basename "$d")
    DATESTR="${NAME#daily-}"
    if [ "$DATESTR" -lt "$CUTOFF" ] 2>/dev/null; then
        log "  删除旧备份: $NAME"
        rm -rf "$d"
    fi
done

# 6. 列出当前保留的备份
log "当前保留的备份："
ls -1 "$BACKUP_ROOT" 2>/dev/null | grep "^daily-" | sort | while read d; do
    SZ=$(du -sh "$BACKUP_ROOT/$d" 2>/dev/null | cut -f1)
    log "  $d ($SZ)"
done

log "===== 备份结束 ====="
