#!/usr/bin/env bash
# MemPalace mine worker —— 真正干活的脚本
#
# 设计动机：
#   原本所有逻辑都塞在 mempalace-mine-hook.sh 的 `nohup bash -c "..."` 里，
#   想加全局排队锁就得再嵌一层 `flock LOCKFILE bash -c "..."`，
#   双层引号转义易踩坑。把干活的部分抽到独立脚本后，主钩子只需要：
#     flock LOCKFILE worker.sh
#   引号嵌套问题彻底消失。worker 也可以独立测试。
#
# 全部参数通过位置参数传入（不用环境变量的原因：MSYS2 flock.exe 在 Windows
# 上会丢掉调用方设置的非系统环境变量，导致 worker 收不到 PY/LOG 等关键参数）：
#
#   $1 PY             Python 可执行（必填）
#   $2 LOG            日志文件路径（必填）
#   $3 VERBOSE        true/false
#   $4 TRANSCRIPT_DIR transcript 所在目录（必填）
#   $5 CWD            项目 Windows 风格路径（可空，空则跳过 files mine）
#   $6 MSYS_CWD       项目 MSYS 风格路径（CWD 非空时必填）
#   $7 STATE_FILE     状态文件路径（CWD 非空时必填）
#   $8 AUTOINIT       true/false
#
# 此脚本不负责加锁。锁由调用方（主钩子）通过 flock 包裹本脚本来实现。

set -u

# ---------- 参数校验 ----------
if [ $# -lt 8 ]; then
    echo "worker: 参数不足，需要 8 个 (PY LOG VERBOSE TRANSCRIPT_DIR CWD MSYS_CWD STATE_FILE AUTOINIT)，收到 $#" >&2
    exit 2
fi

PY="$1"
LOG="$2"
VERBOSE="$3"
TRANSCRIPT_DIR="$4"
CWD="$5"
MSYS_CWD="$6"
STATE_FILE="$7"
AUTOINIT="$8"

if [ -z "$PY" ] || [ -z "$LOG" ] || [ -z "$TRANSCRIPT_DIR" ]; then
    echo "worker: PY/LOG/TRANSCRIPT_DIR 不能为空" >&2
    exit 2
fi

case "$VERBOSE" in true|1|yes) VERBOSE=true;; *) VERBOSE=false;; esac
case "$AUTOINIT" in false|0|no) AUTOINIT=false;; *) AUTOINIT=true;; esac

# ---------- 日志函数 ----------
log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$LOG"; }
log_v() { [ "$VERBOSE" = "true" ] && log "[VERBOSE] $*"; }

log_v "worker 启动 pid=$$ TRANSCRIPT_DIR=$TRANSCRIPT_DIR CWD=${CWD:-<无>}"

# ---------- 1) convos mine（无条件） ----------
log "convos mine 启动 dir=$TRANSCRIPT_DIR"
CV_T0=$(date +%s)
"$PY" -m mempalace mine "$TRANSCRIPT_DIR" --mode convos --extract general >> "$LOG" 2>&1
CV_RC=$?
CV_T1=$(date +%s)
if [ $CV_RC -eq 0 ]; then
    log "convos mine 完成 耗时=$((CV_T1-CV_T0))s"
else
    log "convos mine 失败 exit=$CV_RC 耗时=$((CV_T1-CV_T0))s"
fi

# ---------- 2) files mine（每项目每天一次） ----------
if [ -z "$CWD" ]; then
    log "files mine 跳过 原因=transcript 无 cwd"
    exit 0
fi
if [ -z "$MSYS_CWD" ] || [ ! -d "$MSYS_CWD" ]; then
    log "files mine 跳过 原因=cwd 目录不存在 ($CWD)"
    exit 0
fi
if [ -z "$STATE_FILE" ]; then
    log "files mine 跳过 原因=state_file 未传入"
    exit 0
fi
if [ -f "$STATE_FILE" ]; then
    STATE_DATE=$(date -r "$STATE_FILE" +%Y%m%d 2>/dev/null)
    TODAY=$(date +%Y%m%d)
    if [ "$STATE_DATE" = "$TODAY" ]; then
        log "files mine 跳过 原因=今日已完成 ($CWD)"
        exit 0
    fi
fi

# 首见该项目 + yaml 缺失 → 尝试 auto-init（开关可关）
# 状态文件不存在意味着 mempalace 这边也没记录过该项目，是真正的首次。
# 失败不阻塞下面的 files mine（mempalace 会降级到 general room）。
if [ "$AUTOINIT" = "true" ] \
   && [ ! -f "$MSYS_CWD/mempalace.yaml" ] \
   && [ ! -f "$MSYS_CWD/mempal.yaml" ] \
   && [ ! -f "$STATE_FILE" ]; then
    log "首见该项目，尝试 auto-init cwd=$CWD"
    IN_T0=$(date +%s)
    "$PY" -m mempalace init "$CWD" --yes --no-llm >> "$LOG" 2>&1
    IN_RC=$?
    IN_T1=$(date +%s)
    if [ $IN_RC -eq 0 ]; then
        log "auto-init 成功 耗时=$((IN_T1-IN_T0))s"
    else
        log "auto-init 失败 exit=$IN_RC 耗时=$((IN_T1-IN_T0))s 不阻塞 files mine（mempalace 降级到 general room）"
    fi
else
    YAML_EXISTS=$([ -f "$MSYS_CWD/mempalace.yaml" ] && echo yes || echo no)
    STATE_EXISTS=$([ -f "$STATE_FILE" ] && echo yes || echo no)
    log_v "auto-init 跳过 (autoinit=$AUTOINIT, yaml=$YAML_EXISTS, state=$STATE_EXISTS)"
fi

log "files mine 启动 cwd=$CWD"
FM_T0=$(date +%s)
"$PY" -m mempalace mine "$CWD" --mode projects >> "$LOG" 2>&1
FM_RC=$?
FM_T1=$(date +%s)
if [ $FM_RC -eq 0 ]; then
    touch "$STATE_FILE"
    log "files mine 完成 cwd=$CWD 耗时=$((FM_T1-FM_T0))s"
else
    log "files mine 失败 cwd=$CWD exit=$FM_RC 耗时=$((FM_T1-FM_T0))s 状态文件未刷新 下次会话将重试"
fi
