#!/usr/bin/env python3
"""删除碎片 wing 脚本

背景：
    早期版本钩子 / 旧 init 把整个 cwd（含盘符 + 路径分隔符）展平成 wing 名，
    产生了 d__aiproject_*、f__wslshare_* 这种碎片。当前 mempalace 用项目目录
    `.name` 做 wing，新增内容已经统一到正确的 wing（如 extractor、analyze），
    碎片 wing 里要么是同一项目的旧数据（删掉不丢内容），要么是孤儿项目（删掉
    后下次 SessionEnd 会按新规则重新 mine）。

使用：
    # 1. 先 dry-run 看会删什么
    python3 personal/scripts/delete_orphan_wings.py --dry-run

    # 2. 看完没问题真删
    python3 personal/scripts/delete_orphan_wings.py --yes

依赖：mempalace 模块可导入，palace 路径默认 ~/.mempalace/palace。

安全：
    - 仅删除目标 wing 的 drawer，不动其他 wing
    - 删除前打印总数 + 按 room 拆分让你二次确认
    - 真删要么带 --yes，要么交互式输 "YES"
    - 强烈建议运行前先 backup（personal/scripts/mempalace-backup.sh）
"""
from __future__ import annotations

import argparse
import os
import sys
from collections import Counter
from pathlib import Path

# 明确写死要删的碎片 wing
ORPHAN_WINGS = [
    "d__aiproject_due_diligence_processor",
    "d__aiproject_extractor",
    "f__wslshare_analyze",
]


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--palace", default=os.path.expanduser("~/.mempalace/palace"),
                    help="palace 目录 (默认 ~/.mempalace/palace)")
    ap.add_argument("--dry-run", action="store_true",
                    help="只看不删")
    ap.add_argument("--yes", action="store_true",
                    help="跳过交互确认，直接删")
    args = ap.parse_args()

    palace = Path(args.palace).expanduser().resolve()
    if not palace.exists():
        print(f"错误：palace 不存在: {palace}", file=sys.stderr)
        return 2

    try:
        import chromadb
    except ImportError:
        print("错误：chromadb 未安装", file=sys.stderr)
        return 2

    client = chromadb.PersistentClient(path=str(palace))
    collection_names = [c.name for c in client.list_collections()]
    print(f"palace: {palace}")
    print(f"collections: {collection_names}")
    print()

    # mempalace 主 collection 是 mempalace_drawers（存 drawer 原文 + metadata）
    # mempalace_closets 是次要 sidecar，drawer 数据不在这
    DRAWERS_COL = "mempalace_drawers"
    if DRAWERS_COL not in collection_names:
        print(f"错误：找不到主 collection {DRAWERS_COL}", file=sys.stderr)
        return 2
    target_collection = client.get_collection(DRAWERS_COL)
    print(f"目标 collection: {target_collection.name} (总 drawer={target_collection.count()})")
    print()

    # 统计每个 orphan wing 的 drawer + 按 room 拆分
    plan = {}
    for wing in ORPHAN_WINGS:
        result = target_collection.get(where={"wing": wing}, include=["metadatas"])
        ids = result.get("ids", []) or []
        metas = result.get("metadatas", []) or []
        if not ids:
            print(f"  WING={wing:50s}  0 drawer  (跳过)")
            continue
        rooms = Counter((m or {}).get("room", "?") for m in metas)
        plan[wing] = ids
        print(f"  WING={wing}")
        print(f"    drawer 数: {len(ids)}")
        for room, cnt in rooms.most_common():
            print(f"    ROOM: {room:30s} {cnt} drawer")

    if not plan:
        print()
        print("没有 orphan wing drawer 要删，退出。")
        return 0

    total = sum(len(ids) for ids in plan.values())
    print()
    print(f"合计待删 drawer: {total}")
    print()

    if args.dry_run:
        print("--dry-run 模式，未真删，退出。")
        return 0

    if not args.yes:
        ans = input(f"输入 YES 确认删除以上 {total} 个 drawer： ").strip()
        if ans != "YES":
            print("已取消。")
            return 1

    # 真删
    print()
    for wing, ids in plan.items():
        print(f"删除 {wing} 的 {len(ids)} 个 drawer ...", end=" ", flush=True)
        # chromadb delete 不限制 ids 数量，但稳妥起见分批
        BATCH = 1000
        for i in range(0, len(ids), BATCH):
            target_collection.delete(ids=ids[i:i + BATCH])
        print("ok")

    print()
    print("完成。建议运行 `python3 -m mempalace status` 验证。")
    return 0


if __name__ == "__main__":
    sys.exit(main())
