#!/usr/bin/env python3
"""MemPalace 钩子专用 flock 替代品。

为什么自己写：MSYS2 的 flock.exe 在 Git Bash 下启动子进程时会把
HOME / USERPROFILE / TZ 等关键环境变量丢掉，导致 mempalace 进程
连 Path.home() 都跑不通。此脚本用 Python 实现等价的 `flock LOCKFILE CMD ARGS`
语义，关键改动是把完整 os.environ 透传给子进程。

用法：
    python mempalace-flock.py -w TIMEOUT LOCKFILE COMMAND [ARGS...]

参数：
    -w TIMEOUT      等锁超时秒数（必填）
    LOCKFILE        锁文件路径
    COMMAND [ARGS]  拿到锁之后要跑的命令

返回码：
    0           子进程正常退出（透传子进程 exit code）
    1           等锁超时
    2           参数错误
    其他        子进程的 exit code

实现说明：
    Windows: msvcrt.locking(fd, LK_NBLCK, n) 做非阻塞独占锁，配合
             100ms 轮询循环实现 timeout 语义。
    Linux/WSL: fcntl.flock(fd, LOCK_EX|LOCK_NB) 同样做轮询。
    锁生命周期 = 此 Python 进程生命周期。进程退出 OS 自动释放。
"""
from __future__ import annotations

import os
import shutil
import subprocess
import sys
import time


def parse_args(argv: list[str]) -> tuple[int, str, list[str]]:
    """解析参数。返回 (timeout, lockfile, command_args)。"""
    if len(argv) < 5 or argv[1] != "-w":
        sys.stderr.write(
            "用法: mempalace-flock.py -w TIMEOUT LOCKFILE COMMAND [ARGS...]\n"
        )
        sys.exit(2)
    try:
        timeout = int(argv[2])
    except ValueError:
        sys.stderr.write(f"timeout 必须是整数，收到: {argv[2]}\n")
        sys.exit(2)
    lockfile = argv[3]
    command = argv[4:]
    if not command:
        sys.stderr.write("COMMAND 不能为空\n")
        sys.exit(2)
    return timeout, lockfile, command


def acquire_lock_windows(fd: int, timeout: int) -> bool:
    """Windows: msvcrt.locking 非阻塞独占锁 + 轮询。"""
    import msvcrt

    deadline = time.monotonic() + timeout
    poll_interval = 0.1
    while True:
        try:
            # 锁文件第一个字节：足够防止并发写入同一文件
            msvcrt.locking(fd, msvcrt.LK_NBLCK, 1)
            return True
        except OSError:
            if time.monotonic() >= deadline:
                return False
            time.sleep(poll_interval)


def acquire_lock_posix(fd: int, timeout: int) -> bool:
    """Linux/WSL: fcntl.flock 非阻塞 + 轮询（保持和 Windows 路径行为一致）。"""
    import fcntl

    deadline = time.monotonic() + timeout
    poll_interval = 0.1
    while True:
        try:
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
            return True
        except BlockingIOError:
            if time.monotonic() >= deadline:
                return False
            time.sleep(poll_interval)


def main() -> int:
    timeout, lockfile, command = parse_args(sys.argv)

    # 确保锁文件存在（msvcrt.locking 需要打开后写一个字节才能锁；预先 touch）
    if not os.path.exists(lockfile):
        os.makedirs(os.path.dirname(lockfile) or ".", exist_ok=True)
        with open(lockfile, "a"):
            pass

    fd = os.open(lockfile, os.O_RDWR)
    try:
        # 保证有一个字节可锁
        if os.fstat(fd).st_size < 1:
            os.write(fd, b"\0")
            os.lseek(fd, 0, os.SEEK_SET)

        if sys.platform == "win32":
            ok = acquire_lock_windows(fd, timeout)
        else:
            ok = acquire_lock_posix(fd, timeout)

        if not ok:
            sys.stderr.write(f"等锁超时 ({timeout}s): {lockfile}\n")
            return 1

        # Windows 上 subprocess 直接 CreateProcess 不认 .sh（WinError 193）。
        # 检测 command[0] 是 .sh 时，用 shutil.which("bash") 包装。
        # POSIX 平台靠 shebang 自动识别，无需此处理。
        cmd = command
        if sys.platform == "win32" and cmd and cmd[0].lower().endswith(".sh"):
            bash = shutil.which("bash") or shutil.which("bash.exe")
            if not bash:
                sys.stderr.write("找不到 bash.exe，无法执行 .sh 子命令\n")
                return 127
            cmd = [bash] + cmd

        # 关键：完整透传当前环境给子进程（不像 MSYS2 flock 会丢 HOME 等）
        result = subprocess.run(cmd, env=os.environ.copy())
        return result.returncode
    finally:
        # 进程退出时 OS 自动释放锁；显式 close 是好习惯
        os.close(fd)


if __name__ == "__main__":
    sys.exit(main())
