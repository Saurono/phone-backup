#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""解包 adb exec-out tar 流，按 UTF-8 还原文件名。

为什么需要它：Windows 侧 adb 处理不了非 ASCII 路径（adb pull 会报 Illegal byte sequence），
而系统自带 tar.exe（bsdtar）解包时会按 GBK 解释名字，中文变乱码且不报错。

用法: python extract_tar.py <tar文件> <目标目录>
"""
import os
import sys
import tarfile


def main() -> int:
    if len(sys.argv) != 3:
        print("usage: extract_tar.py <tar> <dest>", file=sys.stderr)
        return 2
    src, dst = sys.argv[1], sys.argv[2]
    dst = os.path.abspath(dst)
    total = 0
    failed = 0

    with tarfile.open(src, "r:") as tf:
        for member in tf:
            name = member.name
            name = name.lstrip("./")
            target = os.path.normpath(os.path.join(dst, name.replace("/", os.sep)))
            if not (target == dst or target.startswith(dst + os.sep)):
                print("skip unsafe path:", name)
                continue
            if member.isdir():
                os.makedirs(target, exist_ok=True)
                continue
            if not member.isfile():
                continue  # 符号链接等一律跳过
            os.makedirs(os.path.dirname(target), exist_ok=True)
            f = tf.extractfile(member)
            if f is None:
                continue
            try:
                with open(target, "wb") as out:
                    while True:
                        chunk = f.read(1024 * 1024)
                        if not chunk:
                            break
                        out.write(chunk)
                total += 1
            except OSError as e:
                failed += 1
                print("ERROR", target, e)

    print(f"extracted {total} files -> {dst}" + (f" ({failed} failed)" if failed else ""))
    return 0 if failed == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
