#!/usr/bin/env bash
# Claude Code SessionEnd 钩子 — MemPalace 自动入库
#
# 行为：
#   - 钩子本身只解析输入、计算变量、立即返回；真正干活在 worker 脚本里。
#   - 用 nohup 把 worker 丢到后台，不阻塞会话关闭。
#   - 后台进程通过 flock 抢全局锁，确保所有项目所有会话排队串行执行。
#     原因：mempalace 在 palace 级别强制单写者，多个 mine 并发会抢锁失败。
#   - worker 内部串行执行：先 convos mine（会话归档），再 files mine（项目代码/文档）。
#   - convos mine 无条件每次跑，mempalace 自带去重。
#   - files mine 每项目每天最多一次。首次见到该项目自动全量。
#
# 状态文件：$STATE_DIR/proj_<proj_key>
#   proj_key = sha256(cwd)[:16]，mtime 表示上次成功 files mine 时间。
#
# 安装：
#   cp personal/hooks/mempalace-mine-hook.sh ~/.claude/
#   cp personal/hooks/mempalace-mine-worker.sh ~/.claude/
#   chmod +x ~/.claude/mempalace-mine-hook.sh ~/.claude/mempalace-mine-worker.sh
#   # 在 ~/.claude/settings.json 的 SessionEnd 钩子里指向 hook.sh
#   # hook.sh 会在同目录找 worker.sh
#
# 可调环境变量：
#   MEMPALACE_HOOK_LOG     钩子日志路径 默认 $HOME/.mempalace/hook_state/hook.log
#   MEMPALACE_HOOK_STATE   状态目录    默认 $HOME/.mempalace/hook_state
#   MEMPALACE_HOOK_LOCK    全局排队锁  默认 $MEMPALACE_HOOK_STATE/hook_mine.lock
#   MEMPALACE_HOOK_TIMEOUT 等锁超时秒  默认 1800（30 分钟）
#   MEMPAL_PYTHON_BIN      Python 可执行 默认 python3
#   MEMPALACE_HOOK_AUTOINIT 首见项目时是否自动 init 默认 true（值 false/0/no 关）
#     首次见到某项目且目录无 mempalace.yaml/mempal.yaml 时，
#     worker 会尝试 `mempalace init --yes --no-llm` 生成基本配置。
#     成功失败都不阻塞 files mine（mempalace 自带降级到 general room）。
#     注意：会在项目根目录写 mempalace.yaml/entities.json/signature 三个文件。
#     不希望污染项目仓库的用户应自行加入 .gitignore，或设此变量为 false。
#   MEMPALACE_HOOK_VERBOSE  详细日志开关 默认 false（值 true/1/yes 开）
#     开启后每一步打印开始/结束/耗时/退出码，便于排查问题。
#   MEMPALACE_HOOK_REQUIRE_FLOCK 是否强制要求 flock 默认 false
#     某些 Windows + Git Bash 环境没装 flock。默认 false 时：找不到 flock
#     就退化到无全局锁的串行执行（mempalace 内部 palace 锁仍会防止双写
#     冲突，但并发会话有任务被丢的可能）。设 true 强制要求 flock，
#     找不到时整个钩子放弃执行（避免无锁退化的不确定性）。
#   MEMPALACE_FLOCK_BIN    flock 可执行的绝对路径（可选）
#     默认探测顺序：PATH 中的 flock → 同目录的 mempalace-flock.py（Python 实现，跨平台保底）
#     用户装在别处时通过此变量指定。
#     注意：不要用 MSYS2 的 flock.exe，它在 Git Bash 下会丢 HOME/TZ/USERPROFILE 等
#     环境变量，导致 mempalace 子进程跑不起来。Python 锁脚本透传完整 os.environ，无此问题。

set -u

# ---------- 路径自解析（让 hook.sh 找到同目录的 worker.sh + flock.py） ----------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKER="$SCRIPT_DIR/mempalace-mine-worker.sh"
PYFLOCK="$SCRIPT_DIR/mempalace-flock.py"

PY="${MEMPAL_PYTHON_BIN:-python3}"
STATE_DIR="${MEMPALACE_HOOK_STATE:-$HOME/.mempalace/hook_state}"
LOG="${MEMPALACE_HOOK_LOG:-$STATE_DIR/hook.log}"
HOOK_LOCK="${MEMPALACE_HOOK_LOCK:-$STATE_DIR/hook_mine.lock}"
LOCK_TIMEOUT="${MEMPALACE_HOOK_TIMEOUT:-1800}"
VERBOSE="${MEMPALACE_HOOK_VERBOSE:-false}"
REQUIRE_FLOCK="${MEMPALACE_HOOK_REQUIRE_FLOCK:-false}"

# 布尔值规范化
case "$VERBOSE" in true|1|yes) VERBOSE=true;; *) VERBOSE=false;; esac
case "$REQUIRE_FLOCK" in true|1|yes) REQUIRE_FLOCK=true;; *) REQUIRE_FLOCK=false;; esac

# ---------- flock 调用方式探测 ----------
# 优先级：用户指定 → PATH 上的原生 flock → 同目录的 Python flock 脚本（保底）
# 不再使用 MSYS2 的 flock.exe：实测它在 Git Bash 下启动子进程时会丢 HOME/TZ/
# USERPROFILE/APPDATA 等，导致 mempalace 进程 Path.home() 直接崩。
# Python flock 脚本走 subprocess 透传 os.environ，无此问题。
#
# 调用形式统一为：FLOCK_CMD -w TIMEOUT LOCKFILE WORKER ARGS...
# Python 脚本和原生 flock 的命令行兼容，钩子下游无需分支处理。
FLOCK_CMD=()
if [ -n "${MEMPALACE_FLOCK_BIN:-}" ] && [ -x "$MEMPALACE_FLOCK_BIN" ]; then
    FLOCK_CMD=("$MEMPALACE_FLOCK_BIN")
elif command -v flock >/dev/null 2>&1; then
    FLOCK_CMD=("$(command -v flock)")
elif [ -f "$PYFLOCK" ]; then
    FLOCK_CMD=("$PY" "$PYFLOCK")
fi

mkdir -p "$STATE_DIR"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$LOG"; }

# ---------- worker 自检 ----------
if [ ! -x "$WORKER" ]; then
    log "错误 worker 不存在或不可执行: $WORKER"
    exit 0
fi

# ---------- 解析 Claude Code 传入的 transcript_path ----------
INPUT=$(cat)

TRANSCRIPT=$(echo "$INPUT" | "$PY" -c "
import sys, json
try:
    print(json.load(sys.stdin).get('transcript_path', ''))
except Exception:
    pass
" 2>/dev/null)

if [ -z "$TRANSCRIPT" ] || [ ! -f "$TRANSCRIPT" ]; then
    log "transcript 不存在，全部跳过"
    exit 0
fi

TRANSCRIPT_DIR=$(dirname "$TRANSCRIPT")

# 从 transcript 第一条带 cwd 的记录里取真实项目目录
CWD=$("$PY" -c "
import json, sys
path = sys.argv[1]
try:
    with open(path, 'r', encoding='utf-8') as fh:
        for line in fh:
            try:
                d = json.loads(line)
                if 'cwd' in d and d['cwd']:
                    print(d['cwd'])
                    break
            except Exception:
                continue
except Exception:
    pass
" "$TRANSCRIPT" 2>/dev/null)

# 计算 proj_key + 状态文件路径（cwd 缺失也不影响 convos mine）
STATE_FILE=""
MSYS_CWD=""
if [ -n "$CWD" ]; then
    # 仅用于判断目录是否存在；mine 命令本身吃 Windows 原路径没问题
    DRIVE=$(echo "$CWD" | cut -c1 | tr 'A-Z' 'a-z')
    REST=$(echo "$CWD" | cut -c3- | tr '\\' '/')
    MSYS_CWD="/$DRIVE$REST"

    PROJ_KEY=$("$PY" -c "
import hashlib, sys
print(hashlib.sha256(sys.argv[1].encode('utf-8')).hexdigest()[:16])
" "$CWD" 2>/dev/null)
    [ -n "$PROJ_KEY" ] && STATE_FILE="$STATE_DIR/proj_$PROJ_KEY"
fi

log "钩子触发 transcript=$TRANSCRIPT cwd=${CWD:-<无>}"
$VERBOSE && log "环境 PY=$PY VERBOSE=$VERBOSE FLOCK_CMD=${FLOCK_CMD[*]:-<无>} REQUIRE_FLOCK=$REQUIRE_FLOCK STATE_DIR=$STATE_DIR"

# 强制要求 flock 但没装 → 拒绝执行（避免静默无锁）
if [ "$REQUIRE_FLOCK" = "true" ] && [ ${#FLOCK_CMD[@]} -eq 0 ]; then
    log "错误 flock 不可用且 MEMPALACE_HOOK_REQUIRE_FLOCK=true，整个钩子放弃执行"
    exit 0
fi

# ---------- 后台调用 worker ----------
# 参数通过【位置参数】传递。锁的生命周期 = worker 进程生命周期，
# worker 退出锁自动释放，后续会话的钩子拿到锁后才会启动自己的 worker。
# 注意：当走 Python flock 路径时，flock.py 会自动检测 .sh 后缀并用
# shutil.which("bash") 找到 bash 来包装；走原生 flock 时，flock 自己负责
# 启动子进程（cygwin/Linux 都直接认 .sh 的 shebang）。
AUTOINIT_VAL="${MEMPALACE_HOOK_AUTOINIT:-true}"
if [ ${#FLOCK_CMD[@]} -gt 0 ]; then
    nohup "${FLOCK_CMD[@]}" -w "$LOCK_TIMEOUT" "$HOOK_LOCK" \
        "$WORKER" \
        "$PY" "$LOG" "$VERBOSE" "$TRANSCRIPT_DIR" \
        "$CWD" "$MSYS_CWD" "$STATE_FILE" "$AUTOINIT_VAL" \
        >> "$LOG" 2>&1 &
    log "后台 mine 进程 pid=$! 等待全局锁（flock=${FLOCK_CMD[*]}）"
else
    # flock 完全不可用 → 无锁退化，直接跑 worker
    # mempalace 内部 palace 锁仍存在，但并发会话有任务被丢的概率
    nohup "$WORKER" \
        "$PY" "$LOG" "$VERBOSE" "$TRANSCRIPT_DIR" \
        "$CWD" "$MSYS_CWD" "$STATE_FILE" "$AUTOINIT_VAL" \
        >> "$LOG" 2>&1 &
    log "后台 mine 进程 pid=$! 直接执行（flock 不可用，无全局锁）"
fi

exit 0
