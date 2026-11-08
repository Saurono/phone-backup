---
name: phone-backup
argument-hint: "[setup | full | dir <目录名> | status]"
description: >-
  把安卓手机（小米 13 / 2211133C）的数据通过局域网 WiFi 备份到电脑 D:\PhoneBackup\。
  走 adb over TCP + tar 原始字节流，不插数据线、不走 MTP，因此不会出现长时间有线读写导致手机无响应。
  用户说「备份手机」「把手机照片存过来」「手机数据同步到电脑」「再跑一次备份」时用这个技能。
  支持全量（/sdcard 排除 Android）、单个目录、以及查看历史备份。
---

# 手机备份（adb over WiFi + tar）

## 什么时候用

用户要把手机里的照片、视频、下载、文档搬到这台电脑。**不要**建议他插数据线用 MTP——那正是他要避开的东西。

## 先决条件

- 手机和电脑在同一个局域网（这台电脑走 WLAN，5GHz，实测 12–45 MB/s）
- 手机开着 USB 调试；无线连接已配对过一次（`adb tcpip 5555`）
- 目标盘建议 `D:`（默认 `D:\PhoneBackup\<日期>\`）

## 三步用法

```
# ① 手机重启过 / 连不上时，先重建无线连接（这一步需要插一下数据线）
powershell -NoProfile -ExecutionPolicy Bypass -File "$SKILL\scripts\backup.ps1" setup

# ② 全量备份
powershell -NoProfile -ExecutionPolicy Bypass -File "$SKILL\scripts\backup.ps1" full

# 只要某个目录
powershell -NoProfile -ExecutionPolicy Bypass -File "$SKILL\scripts\backup.ps1" dir Pictures

# 看历史备份
powershell -NoProfile -ExecutionPolicy Bypass -File "$SKILL\scripts\backup.ps1" status
```

`$SKILL` 就是本文件所在的目录。跑之前先 `adb devices` 确认有个带 `:` 的无线条目；
脚本自己会做保底（找不到无线条目时用 USB 重新 `tcpip` + `connect`）。

## 两个必须知道的坑

**1. `adb pull` 在这台电脑上建不了任何非 ASCII 文件名。**
一碰到中文目录就 `adb: error: failed to create directory ... : Illegal byte sequence`，
并且**整个目录直接中断**（不是跳过单个文件）。手机上的名字本身是标准 UTF-8，是 Windows 侧 adb 的路径转换坏了。
所以本技能一律用 `adb exec-out` 把目录打成 tar 流，再用 Python 按 UTF-8 解包。

**2. 绝对不要用系统的 `tar.exe`（bsdtar）解包。**
它按 GBK 解释名字，`足迹` 会变成 `瓒宠抗`，而且不报错——你会以为备份好了。
解包只用技能里的 `scripts/extract_tar.py`。

## 备份不到的东西（要主动告诉用户，别让他以为全备了）

- `/sdcard/Android`（约 35 GB）：各 App 私有目录，无 root 读不出来
- `/data` 里的微信 / QQ 聊天记录：同样需要 root；只能靠它们自己的「聊天记录迁移与备份」
- 手机总用量和备份体积差一大截是正常的

## 跑完之后必须做的校验

逐个目录比对**文件数**（不是体积，`du` 有块对齐误差）：

```
adb -s <dev> shell "find '/sdcard/Pictures' -type f 2>/dev/null | wc -l"
```

和本地 `Get-ChildItem -Recurse -File | Measure-Object` 的 Count 对齐才算成功。
不一致就重跑那个目录，别含糊过去。

## 回复用户时给什么

一句话结论 + 路径 + 总文件数/体积 + 每个目录的「手机/电脑」文件数对照 + 没备到的部分。
不要把传输日志贴给他。
