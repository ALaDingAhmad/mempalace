#!/bin/bash
# MEMPALACE PRE-COMPACT 钩子 — 压缩前的紧急保存
#
# 本文件是 hooks/mempal_precompact_hook.sh 的个人定制分支。
# 与上游差异：把所有裸 `mempalace` 调用替换为 `"$MEMPAL_PYTHON_BIN" -m mempalace`，
# 这样在 `mempalace` 命令脚本不在 PATH 上的环境也能跑（常见于
# Windows Store Python、pyenv-shim 配置等）。
#
# 安装：
#   cp personal/hooks/mempalace-precompact-hook.sh ~/.claude/
#   chmod +x ~/.claude/mempalace-precompact-hook.sh
#   # 然后在 ~/.claude/settings.json 的 PreCompact 钩子里指向它
#   # 参考 claude-settings.json.example
#
# Claude Code 的 "PreCompact" 钩子。会在会话被压缩、释放上下文窗口之前触发。
#
# 这是最后的安全网。压缩一旦发生，AI 就会丢失之前对话的详细信息。
# 本钩子在那之前强制对所有内容做一次最终入库。
#
# 与 save 钩子不同（save 会按消息数门限 + MEMPAL_VERBOSE 控制是否触发），
# 本钩子在每一次 PreCompact 事件都同步执行 mine —— 压缩前永远值得入库。
# 钩子最终返回 ``{}``，不会向 Claude Code 发送 ``decision: block``；
# "每次都跑" 的语义放在 mine 调用本身，不依赖 Stop 钩子的 block 协议。
#
# === 安装示例 ===
# 加入 .claude/settings.local.json：
#
#   "hooks": {
#     "PreCompact": [{
#       "hooks": [{
#         "type": "command",
#         "command": "/absolute/path/to/mempal_precompact_hook.sh",
#         "timeout": 30
#       }]
#     }]
#   }
#
# 对应 Codex CLI 的 .codex/hooks.json：
#
#   "PreCompact": [{
#     "type": "command",
#     "command": "/absolute/path/to/mempal_precompact_hook.sh",
#     "timeout": 30
#   }]
#
# === 工作原理 ===
#
# Claude Code 通过 stdin 传入 JSON：
#   session_id      —— 会话唯一标识
#   transcript_path —— JSONL 转录文件路径
#
# 钩子同步执行 transcript 的 mine（下面的 ``mempalace mine`` 调用会阻塞
# 直到返回），然后向 stdout 输出 ``{}``，让 Claude Code 继续压缩流程。
# 我们不向钩子协议发 ``decision: block`` —— "压缩前必入库" 由同步 mine 本身保证，
# 不依赖 Stop 钩子的 block 契约。
#
# === MEMPALACE CLI ===
# 钩子永远会在压缩前同步入库当前会话的 transcript
# （`mempalace mine <transcript-dir> --mode convos`）。
# MEMPAL_DIR 是一个 *附加的* 可选目标，用来同时入库项目文件 ——
# 它是叠加，而不是替换。

STATE_DIR="$HOME/.mempalace/hook_state"
mkdir -p "$STATE_DIR"

# 可选：附加要入库的项目目录（代码 / 笔记 / 文档），用 --mode projects。
# 无论 MEMPAL_DIR 设没设，会话 transcript 都会被入库 —— 这里是叠加。
# 例：MEMPAL_DIR="$HOME/projects/my_app"
MEMPAL_DIR=""

# 解析 Python 解释器。规则与 mempal_save_hook.sh 一致：
# MEMPAL_PYTHON（显式覆盖）→ $(command -v python3) → 裸 python3。
MEMPAL_PYTHON_BIN="${MEMPAL_PYTHON:-}"
if [ -z "$MEMPAL_PYTHON_BIN" ] || [ ! -x "$MEMPAL_PYTHON_BIN" ]; then
    MEMPAL_PYTHON_BIN="$(command -v python3 2>/dev/null || echo python3)"
fi

# ── 静默模式 / 关闭开关 ────────────────────────────────────────────────
# 设 MEMPALACE_HOOKS_AUTO_SAVE=false 可完全关闭自动保存阻塞。
if [ -n "$MEMPALACE_HOOKS_AUTO_SAVE" ]; then
    case "$MEMPALACE_HOOKS_AUTO_SAVE" in
        false|0|no) echo "{}"; exit 0 ;;
    esac
else
    CONFIG_FILE="$HOME/.mempalace/config.json"
    if [ -f "$CONFIG_FILE" ]; then
        AUTO_SAVE=$("$MEMPAL_PYTHON_BIN" -c "
import json, sys
try:
    cfg = json.load(open(sys.argv[1]))
    print(str(cfg.get('hooks', {}).get('auto_save', True)).lower())
except Exception: print('true')
" "$CONFIG_FILE" 2>/dev/null)
        if [ "$AUTO_SAVE" = "false" ]; then
            echo "{}"
            exit 0
        fi
    fi
fi

# 从 stdin 读 JSON 输入
INPUT=$(cat)

# 一次性解析 session_id 和 transcript_path。先在 Python 里做清洗，再用
# ``sed -n 'Np'`` 把每行结果读进 shell 变量（避免对生成代码做 ``eval``，#1231 review）。
# 用 sed 而不是 bash 4 才有的 ``mapfile`` 是为了兼容 macOS /bin/bash 3.2.57
# （Apple 2006 年 GPLv3 冻结版本），在那个版本上 ``mapfile`` 会静默回退为默认值（#1440）。
#
# 头部 ``__MEMPAL_PARSE_OK__`` 哨兵让下面的防御性检查能区分
# "Python 顺利解析完" 与 "Python 崩溃没输出"。与 mempal_save_hook.sh 同契约。
# Python 的 stderr 被捕获到 last_python_err.log，让下面的检查区分
# "用户输入坏" 与 "解释器坏 / 本脚本未来回归"。诊断契约与 mempal_save_hook.sh 一致。
#
# 命令替换子 shell 内的 ``umask 077`` 让 ``2>$STATE_DIR/last_python_err.log``
# 在创建文件时直接是 0600 模式，关闭 "默认 umask 创建 → 再 chmod 600" 之间
# 的 TOCTOU 窗口。``printf '%s'`` 替代 ``echo`` 避免 echo 误把以
# ``-n``/``-e``/``-E`` 开头或含反斜杠的内容当作选项处理。
_mempal_parsed=$(
    umask 077
    printf '%s' "$INPUT" | "$MEMPAL_PYTHON_BIN" -c "
import sys, json, re
data = json.load(sys.stdin)
sid = data.get('session_id', '')
tp = data.get('transcript_path', '')
safe = lambda s: re.sub(r'[^a-zA-Z0-9_/.\-~]', '', str(s))
print('__MEMPAL_PARSE_OK__')
print(safe(sid))
print(safe(tp))
" 2>"$STATE_DIR/last_python_err.log"
)
# 成功时清掉空文件；失败时 chmod 600 与 last_input.log 的隐私契约保持一致。
if [ -s "$STATE_DIR/last_python_err.log" ]; then
    chmod 600 "$STATE_DIR/last_python_err.log" 2>/dev/null
else
    rm -f "$STATE_DIR/last_python_err.log"
fi
_MEMPAL_PARSE_MARKER=$(printf '%s\n' "$_mempal_parsed" | sed -n '1p')
SESSION_ID=$(printf '%s\n' "$_mempal_parsed" | sed -n '2p')
TRANSCRIPT_PATH=$(printf '%s\n' "$_mempal_parsed" | sed -n '3p')
SESSION_ID="${SESSION_ID:-unknown}"
TRANSCRIPT_PATH="${TRANSCRIPT_PATH:-}"

# 防御性检查：INPUT 非空但 Python 没走到 print()（哨兵缺失），
# 意味着解析悄无声息地失败了。把原始 payload 落盘，避免下一个调试者
# 浪费一天去查 hook.log 里只有 "Session unknown" 的问题。
# 限 4 KB；每次失败覆盖（而非追加），防止配置一直错把 ~/.mempalace/hook_state/ 撑爆。
# chmod 600 —— 该 dump 镜像 Claude Code 的 PreCompact payload（含
# transcript_path，会暴露用户 home + 项目布局），不能让其他用户可读。
if [ -n "$INPUT" ] && [ "$_MEMPAL_PARSE_MARKER" != "__MEMPAL_PARSE_OK__" ]; then
    echo "[$(date '+%H:%M:%S')] WARN: 输入解析失败（哨兵缺失），见 $STATE_DIR/last_input.log 和 $STATE_DIR/last_python_err.log" >> "$STATE_DIR/hook.log"
    # ``head -c 4096`` 是按字节截断，且与 locale 无关；``${INPUT:0:4096}``
    # 在 UTF-8 下按字符计数，可能让多字节内容溜过边界。本脚本没开
    # ``set -o pipefail``，所以 ``head`` 关 stdin 引起的 SIGPIPE 会被自然吸收。
    # 子 shell 里的 ``umask 077`` 让 last_input.log 创建即 0600，下面的
    # ``chmod 600`` 作为双保险保留。
    ( umask 077 && printf '%s' "$INPUT" | head -c 4096 > "$STATE_DIR/last_input.log" )
    chmod 600 "$STATE_DIR/last_input.log" 2>/dev/null
fi

# 展开路径里的 ~
TRANSCRIPT_PATH="${TRANSCRIPT_PATH/#\~/$HOME}"

# 校验 TRANSCRIPT_PATH 长得像个 transcript 文件。
# 与 mempalace.hooks_cli._validate_transcript_path 同契约，让 shell 钩子
# 拒掉 Python 钩子也会拒掉的形状（#1231 review）。
is_valid_transcript_path() {
    local path="$1"
    [ -n "$path" ] || return 1
    case "$path" in
        *.json|*.jsonl) ;;
        *) return 1 ;;
    esac
    case "/$path/" in
        */../*) return 1 ;;
    esac
    return 0
}

echo "[$(date '+%H:%M:%S')] PRE-COMPACT 触发 session=$SESSION_ID" >> "$STATE_DIR/hook.log"

# 同步执行入库，确保记忆在压缩前落地。两个独立目标，都设了就都跑：
#   1. TRANSCRIPT_PATH（来自 Claude Code）→ 父目录，--mode convos
#   2. MEMPAL_DIR → --mode projects
if is_valid_transcript_path "$TRANSCRIPT_PATH" && [ -f "$TRANSCRIPT_PATH" ]; then
    "$MEMPAL_PYTHON_BIN" -m mempalace mine "$(dirname "$TRANSCRIPT_PATH")" --mode convos \
        >> "$STATE_DIR/hook.log" 2>&1
elif [ -n "$TRANSCRIPT_PATH" ]; then
    echo "[$(date '+%H:%M:%S')] 跳过非法 transcript 路径: $TRANSCRIPT_PATH" \
        >> "$STATE_DIR/hook.log"
fi
if [ -n "$MEMPAL_DIR" ] && [ -d "$MEMPAL_DIR" ]; then
    "$MEMPAL_PYTHON_BIN" -m mempalace mine "$MEMPAL_DIR" --mode projects \
        >> "$STATE_DIR/hook.log" 2>&1
fi

# 静默：返回空 JSON，不阻塞压缩。"decision": "allow" 非法 ——
# 钩子协议只识别 "block" 或 {}。
echo '{}'
