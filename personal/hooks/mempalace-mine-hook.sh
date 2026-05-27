#!/usr/bin/env bash
# Claude Code SessionEnd 钩子 — MemPalace 自动入库
#
# 行为：
#   - 全部 mine 工作放进单个后台子 shell，钩子立即返回，不阻塞会话关闭。
#   - 子 shell 进入后先抢全局 hook 锁，确保所有项目所有会话排队串行执行。
#     原因：mempalace 在 palace 级别强制单写者，多个 mine 并发会抢锁失败。
#   - 锁内串行执行：先 convos mine（会话归档），再 files mine（项目代码/文档）。
#   - convos mine 无条件每次跑，mempalace 自带去重。
#   - files mine 每项目每天最多一次。首次见到该项目自动全量。
#
# 状态文件：$STATE_DIR/proj_<proj_key>
#   proj_key = sha256(cwd)[:16]，mtime 表示上次成功 files mine 时间。
#
# 安装：
#   cp personal/hooks/mempalace-mine-hook.sh ~/.claude/
#   chmod +x ~/.claude/mempalace-mine-hook.sh
#   # 在 ~/.claude/settings.json 的 SessionEnd 钩子里指向它
#
# 可调环境变量：
#   MEMPALACE_HOOK_LOG     钩子日志路径 默认 $HOME/.mempalace/hook_state/hook.log
#   MEMPALACE_HOOK_STATE   状态目录    默认 $HOME/.mempalace/hook_state
#   MEMPALACE_HOOK_LOCK    全局排队锁  默认 $MEMPALACE_HOOK_STATE/hook_mine.lock
#   MEMPALACE_HOOK_TIMEOUT 等锁超时秒  默认 1800（30 分钟）
#   MEMPAL_PYTHON_BIN      Python 可执行 默认 python3
#   MEMPALACE_HOOK_AUTOINIT 首见项目时是否自动 init 默认 true（值 false/0/no 关）
#     首次见到某项目且目录无 mempalace.yaml/mempal.yaml 时，
#     钩子会尝试 `mempalace init --yes --no-llm` 生成基本配置。
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

set -u

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

# flock 可用性探测（Windows Git Bash 通常没装）
if command -v flock >/dev/null 2>&1; then
    HAVE_FLOCK=true
else
    HAVE_FLOCK=false
fi

mkdir -p "$STATE_DIR"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$LOG"; }

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
$VERBOSE && log "环境 PY=$PY VERBOSE=$VERBOSE HAVE_FLOCK=$HAVE_FLOCK REQUIRE_FLOCK=$REQUIRE_FLOCK STATE_DIR=$STATE_DIR"

# 强制要求 flock 但没装 → 拒绝执行（避免静默无锁）
if [ "$REQUIRE_FLOCK" = "true" ] && [ "$HAVE_FLOCK" = "false" ]; then
    log "错误 flock 命令不可用且 MEMPALACE_HOOK_REQUIRE_FLOCK=true，整个钩子放弃执行"
    exit 0
fi

# 单一后台子 shell：抢全局锁 → 串行 convos → files
# 用 nohup + bash -c 让父进程立即返回，所有等待全部在后台发生
nohup bash -c "
    LOG_BG='$LOG'
    VERBOSE_BG='$VERBOSE'
    HAVE_FLOCK_BG='$HAVE_FLOCK'
    log_bg() { echo \"[\$(date '+%Y-%m-%d %H:%M:%S')] \$*\" >> \"\$LOG_BG\"; }
    log_v()  { [ \"\$VERBOSE_BG\" = 'true' ] && log_bg \"[VERBOSE] \$*\"; }

    # 全局排队锁：所有项目所有会话共用一把
    # flock 不可用时退化到无锁串行执行（mempalace 内部 palace 锁仍存在，
    # 但是 LOCK_NB 非阻塞型，并发会话有任务被丢的概率）。
    if [ \"\$HAVE_FLOCK_BG\" = 'true' ]; then
        exec 9>'$HOOK_LOCK'
        LOCK_T0=\$(date +%s)
        if flock -w $LOCK_TIMEOUT 9; then
            LOCK_T1=\$(date +%s)
            log_bg \"拿到全局 hook 锁（等待 \$((LOCK_T1-LOCK_T0))s）\"
        else
            log_bg \"等待全局 hook 锁超时（$LOCK_TIMEOUT 秒），跳过本次 mine\"
            exit 0
        fi
    else
        log_bg \"警告 flock 不可用，退化到无锁执行（依赖 mempalace 内部 palace 锁）\"
    fi

    # 1) convos mine（无条件）
    log_bg \"convos mine 启动 dir=$TRANSCRIPT_DIR\"
    CV_T0=\$(date +%s)
    $PY -m mempalace mine '$TRANSCRIPT_DIR' --mode convos --extract general >> \"\$LOG_BG\" 2>&1
    CV_RC=\$?
    CV_T1=\$(date +%s)
    if [ \$CV_RC -eq 0 ]; then
        log_bg \"convos mine 完成 耗时=\$((CV_T1-CV_T0))s\"
    else
        log_bg \"convos mine 失败 exit=\$CV_RC 耗时=\$((CV_T1-CV_T0))s\"
    fi

    # 2) files mine（每项目每天一次）
    CWD_BG='$CWD'
    MSYS_CWD_BG='$MSYS_CWD'
    STATE_FILE_BG='$STATE_FILE'

    if [ -z \"\$CWD_BG\" ]; then
        log_bg 'files mine 跳过 原因=transcript 无 cwd'
        exit 0
    fi
    if [ ! -d \"\$MSYS_CWD_BG\" ]; then
        log_bg \"files mine 跳过 原因=cwd 目录不存在 (\$CWD_BG)\"
        exit 0
    fi
    if [ -z \"\$STATE_FILE_BG\" ]; then
        log_bg 'files mine 跳过 原因=proj_key 计算失败'
        exit 0
    fi
    if [ -f \"\$STATE_FILE_BG\" ]; then
        STATE_DATE=\$(date -r \"\$STATE_FILE_BG\" +%Y%m%d 2>/dev/null)
        TODAY=\$(date +%Y%m%d)
        if [ \"\$STATE_DATE\" = \"\$TODAY\" ]; then
            log_bg \"files mine 跳过 原因=今日已完成 (\$CWD_BG)\"
            exit 0
        fi
    fi

    # 首见该项目 + yaml 缺失 → 尝试 auto-init（开关可关）
    # 状态文件不存在意味着 mempalace 这边也没记录过该项目，是真正的首次。
    # 失败不阻塞下面的 files mine（mempalace 会降级到 general room）。
    AUTOINIT_BG='${MEMPALACE_HOOK_AUTOINIT:-true}'
    case \"\$AUTOINIT_BG\" in false|0|no) AUTOINIT_BG='false';; *) AUTOINIT_BG='true';; esac
    if [ \"\$AUTOINIT_BG\" = 'true' ] \\
       && [ ! -f \"\$MSYS_CWD_BG/mempalace.yaml\" ] \\
       && [ ! -f \"\$MSYS_CWD_BG/mempal.yaml\" ] \\
       && [ ! -f \"\$STATE_FILE_BG\" ]; then
        log_bg \"首见该项目，尝试 auto-init cwd=\$CWD_BG\"
        IN_T0=\$(date +%s)
        $PY -m mempalace init \"\$CWD_BG\" --yes --no-llm >> \"\$LOG_BG\" 2>&1
        IN_RC=\$?
        IN_T1=\$(date +%s)
        if [ \$IN_RC -eq 0 ]; then
            log_bg \"auto-init 成功 耗时=\$((IN_T1-IN_T0))s\"
        else
            log_bg \"auto-init 失败 exit=\$IN_RC 耗时=\$((IN_T1-IN_T0))s 不阻塞 files mine（mempalace 降级到 general room）\"
        fi
    else
        log_v \"auto-init 跳过 (autoinit=\$AUTOINIT_BG, yaml=\$([ -f \"\$MSYS_CWD_BG/mempalace.yaml\" ] && echo yes || echo no), state=\$([ -f \"\$STATE_FILE_BG\" ] && echo yes || echo no))\"
    fi

    log_bg \"files mine 启动 cwd=\$CWD_BG\"
    FM_T0=\$(date +%s)
    $PY -m mempalace mine \"\$CWD_BG\" --mode projects >> \"\$LOG_BG\" 2>&1
    FM_RC=\$?
    FM_T1=\$(date +%s)
    if [ \$FM_RC -eq 0 ]; then
        touch \"\$STATE_FILE_BG\"
        log_bg \"files mine 完成 cwd=\$CWD_BG 耗时=\$((FM_T1-FM_T0))s\"
    else
        log_bg \"files mine 失败 cwd=\$CWD_BG exit=\$FM_RC 耗时=\$((FM_T1-FM_T0))s 状态文件未刷新 下次会话将重试\"
    fi
" >> "$LOG" 2>&1 &

if [ "$HAVE_FLOCK" = "true" ]; then
    log "后台 mine 进程 pid=$! 等待全局锁"
else
    log "后台 mine 进程 pid=$! 直接执行（flock 不可用，无全局锁）"
fi

exit 0
