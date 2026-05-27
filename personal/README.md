# Personal MemPalace 自动化层

[MemPalace](https://github.com/MemPalace/mempalace) 的个人自动化层 —— Claude Code 钩子 + 每日备份脚本。

这些文件单独放在 `personal/` 下，避免和上游同步冲突。它们是**用来 `cp` 到 `~/.claude/`** （以及备份目录）的，不要在仓库里就地运行。

## 目录内容

| 文件 | 用途 |
|------|------|
| `hooks/mempalace-mine-hook.sh` | **SessionEnd** 钩子。会话关闭时自动入库 transcript + 项目代码/文档。后台执行，全局 flock 排队，每项目 files mine 每天最多一次。 |
| `hooks/mempalace-precompact-hook.sh` | **PreCompact** 钩子。压缩前同步入库 transcript，保证压缩不丢内容。上游的本地化分支，调用 `python3 -m mempalace`，无须 `mempalace` 在 PATH 上。 |
| `scripts/mempalace-backup.sh` | 每日备份脚本。把 `~/.mempalace/` + `~/.claude/projects/` 整个 copy 一份，保留 N 天。会试探 mine 锁，避开 mine 进行中复制半写状态。 |
| `claude-settings.json.example` | 要合并进 `~/.claude/settings.json` 的钩子片段示例。 |

## 为什么需要这些

vanilla mempalace 在实际用起来有三个盲区：

1. **压缩盲区** —— Claude Code 在对话过长时会自动压缩，用摘要替换原文。如果没有 PreCompact 钩子，那些内容在 mempalace 看到之前就已经丢失。这违背了 mempalace 的"原文召回"承诺。
2. **没有自动备份** —— mempalace 自身不做快照。ChromaDB 有已知的损坏模式（例如 `dimensionality=None` 的元数据损坏），唯一记录的恢复路径就是"从备份还原"。repair 流程的错误信息原文就是：*"Restore from your most recent palace backup, then re-mine."*
3. **每项目 mine 很烦** —— 新项目要 init + 全量 mine，老项目还得增量。如果有十几个项目，手动跑根本跑不过来。SessionEnd 钩子把这件事自动化了。

## SessionEnd 钩子设计

`hooks/mempalace-mine-hook.sh` 的关键设计点：

- **不阻塞会话关闭** —— 钩子立即返回，所有 mine 工作放进 `nohup` 后台子 shell。
- **全局 flock 排队** —— 多个项目、多个会话可能同时触发 SessionEnd。mempalace 在 palace 级别强制单写者（`mine_palace_<key>.lock`，非阻塞 `LOCK_EX|LOCK_NB`），并发会立即失败。所以钩子层用一把全局 `flock`，让所有 mine 任务串行排队，互不抢锁。
- **convos → files 串行** —— 单个子 shell 内先跑 convos mine（会话归档），再跑 files mine（项目代码/文档）。避免两个 mempalace 进程争同一把 palace 锁。
- **每项目 files mine 每天一次** —— 用状态文件 `$STATE_DIR/proj_<sha256(cwd)[:16]>` 的 mtime 判断；同一天已成功过就跳过，失败时不刷新状态文件以便下次重试。首次见到的项目自动全量。
- **cwd 不靠 slug 反解** —— `~/.claude/projects/` 下的目录名（slug）把 `\`/`/`/`:` 全都替换成了 `-`，无法可靠反解。改成从 transcript jsonl 第一条带 `cwd` 字段的记录里读真实路径。

## 安装

### 1. 钩子

```bash
cp personal/hooks/mempalace-mine-hook.sh       ~/.claude/
cp personal/hooks/mempalace-precompact-hook.sh ~/.claude/
chmod +x ~/.claude/mempalace-*.sh
```

把 `claude-settings.json.example` 的内容合并进 `~/.claude/settings.json`。**别覆盖整个文件** —— 里面还有 permissions / model / theme 等其他配置。

重启 Claude Code。钩子只在会话启动时加载一次。

### 2. 每日备份

```bash
cp personal/scripts/mempalace-backup.sh ~/.claude/
chmod +x ~/.claude/mempalace-backup.sh
```

选一个备份目的地 —— **强烈建议是与 palace 不同的物理盘**。例：

```bash
export MEMPALACE_BACKUP_ROOT="/path/to/external/backups/mempalace"
# 加进 ~/.bashrc，或在计划任务里直接 inline 传入
```

#### Linux/macOS (cron)

```cron
0 3 * * * MEMPALACE_BACKUP_ROOT=/path/to/backups /bin/bash $HOME/.claude/mempalace-backup.sh
```

#### Windows（用 Git Bash + 计划任务）

```powershell
schtasks /Create /TN "MemPalace Daily Backup" `
  /TR "C:\Program Files\Git\usr\bin\bash.exe -lc '$HOME/.claude/mempalace-backup.sh'" `
  /SC DAILY /ST 03:00 /RL HIGHEST /F
```

bash 路径按你机器上 Git Bash 的实际位置调整。`MEMPALACE_BACKUP_ROOT` 在用户环境变量里设好，或者直接在脚本里改默认值。

验证：

```bash
# 立刻触发一次
schtasks /Run /TN "MemPalace Daily Backup"
# 看日志
tail -20 "$MEMPALACE_BACKUP_ROOT/backup.log"
```

## 可调环境变量

`mempalace-mine-hook.sh`：

| 变量 | 默认 | 用途 |
|------|------|------|
| `MEMPALACE_HOOK_STATE` | `$HOME/.mempalace/hook_state` | 状态文件目录（含日志、锁、proj_* 时间戳） |
| `MEMPALACE_HOOK_LOG` | `$MEMPALACE_HOOK_STATE/hook.log` | 钩子日志路径 |
| `MEMPALACE_HOOK_LOCK` | `$MEMPALACE_HOOK_STATE/hook_mine.lock` | 全局排队锁文件 |
| `MEMPALACE_HOOK_TIMEOUT` | `1800` | 等全局锁的超时秒数（30 分钟） |
| `MEMPAL_PYTHON_BIN` | `python3` | Python 解释器路径 |

`mempalace-precompact-hook.sh`：

| 变量 | 默认 | 用途 |
|------|------|------|
| `MEMPAL_PYTHON` | `command -v python3` | Python 解释器显式覆盖 |
| `MEMPAL_DIR` | 空 | 可选：每次 PreCompact 都同时入库的项目目录（`--mode projects`） |
| `MEMPALACE_HOOKS_AUTO_SAVE` | true | 设 `false`/`0`/`no` 可完全关闭自动保存 |

`mempalace-backup.sh`：

| 变量 | 默认 | 用途 |
|------|------|------|
| `MEMPALACE_BACKUP_ROOT` | `$HOME/.mempalace-backups` | 备份根目录 |
| `MEMPALACE_KEEP_DAYS`   | `7` | 保留多少天的每日快照 |
| `MEMPALACE_DIR`         | `$HOME/.mempalace` | palace 源目录 |
| `CLAUDE_PROJECTS_DIR`   | `$HOME/.claude/projects` | Claude Code transcript 源目录 |

## 故障与恢复

### palace 损坏

```bash
# 1. 停掉所有正在写 mempalace 的进程
# 2. 把坏的 palace 挪开（别 rm，留着做尸检）
mv ~/.mempalace ~/.mempalace.crashed-$(date +%Y%m%d)

# 3. 从最近的好快照恢复
cp -a "$MEMPALACE_BACKUP_ROOT/daily-YYYYMMDD/mempalace" ~/.mempalace

# 4. 验证
python3 -m mempalace status
```

### 某项目卡在"今天已 mine"需要强制重跑

```bash
# 算对应的 proj_key（cwd 的 sha256 前 16 位）
python3 -c "import hashlib; print(hashlib.sha256(b'D:\\\\aiproject\\\\extractor').hexdigest()[:16])"
# 删掉状态文件即可，下次 SessionEnd 会重新跑 files mine
rm "$MEMPALACE_HOOK_STATE/proj_<proj_key>"
```

### 钩子卡了 / 全局锁被孤儿进程占着

```bash
# 看后台 mine 进程
tail -50 "$MEMPALACE_HOOK_LOG"
ps -ef | grep "mempalace mine"

# 如果确认没人在用，可以直接删全局锁
rm "$MEMPALACE_HOOK_LOCK"
```

## 设计取舍说明

- **SessionEnd 钩子不传 `--wing`**。mempalace 3.3+ 会自动识别 Claude Code 路径（`.claude/projects/`），统一归到 `wing_api`。传 `--wing` 反而会覆盖这个识别、把同一项目的记忆分散到不同 wing。
- **统一用 `python3 -m mempalace`**。避免依赖 `mempalace` 这个 CLI shim 在 PATH 上 —— Windows Store Python / pyenv-shim 上经常装不上。
- **备份脚本试探 mine 锁**。ChromaDB 的写不是跨文件原子的，mine 进行中直接 `cp -a` 可能拷到半写状态。`flock -n` 是非阻塞的，拿不到锁就跳过这次备份，不阻塞备份计划。
- **PreCompact 同步、SessionEnd 后台**。压缩是会丢内容的不可逆操作，必须同步阻塞到入库完成；会话关闭只是清理，没必要让用户等。
- **全局 flock 而不是 palace lock**。mempalace 内部已经有 palace lock，但那是非阻塞 + 立刻失败的，并发会丢任务。钩子层多加一把阻塞锁，让任务排队而不是丢任务。
