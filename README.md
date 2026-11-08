# phone-backup

DeepSeek Harness 技能：把安卓手机通过局域网 WiFi 备份到 Windows 电脑。

全程走 `adb over TCP`，不需要插数据线长跑，所以不会出现 MTP 那种「读写多了手机无响应」。
本机实测（小米 13 → WiFi 6 台式机）：峰值 45 MB/s，长时间稳定 12–13 MB/s，40 GB 约半小时。

## 为什么不用 `adb pull`

这台电脑上的 adb **创建不了任何非 ASCII 文件名**。碰到中文目录就：

```
adb: error: failed to create directory 'D:\...\Pictures\知�\': Illegal byte sequence
```

而且不是跳过单个文件，是**整个目录直接中断**（本来 8.8 GB 的 `Pictures` 只传了 126 MB 就停了）。

手机上的名字本身是标准 UTF-8，问题在 Windows 侧 adb 的路径转换。
所以本技能改用 `adb exec-out` 把目录打成 tar 原始字节流，再由 Python 按 UTF-8 解包。

**另一个坑**：不要用系统自带的 `tar.exe`（bsdtar）解包。它按 GBK 解释文件名，
`足迹` 会变成 `瓒宠抗`，而且不报任何错误——你会以为备份成功了。

## 安装

```powershell
git clone <this repo> "$env:USERPROFILE\.dsh\skills\phone-backup"
```

依赖：

- `adb`：`winget install --id Google.PlatformTools`
- Python 3（只用到标准库 `tarfile`）

装完技能会自动出现在 DSH 的技能目录里（设置 → 技能）。

## 用法

```powershell
$s = "$env:USERPROFILE\.dsh\skills\phone-backup\scripts\backup.ps1"

powershell -NoProfile -ExecutionPolicy Bypass -File $s setup        # 重建无线连接（需插一次线）
powershell -NoProfile -ExecutionPolicy Bypass -File $s full         # 全量备份
powershell -NoProfile -ExecutionPolicy Bypass -File $s dir Pictures # 只备份一个目录
powershell -NoProfile -ExecutionPolicy Bypass -File $s status       # 历史备份
```

可选参数：`-Dest D:\PhoneBackup\2026-11-08`、`-Dev 192.168.31.200:5555`、`-Exclude Android`。

> 注意：脚本必须用 `-ExecutionPolicy Bypass` 跑；文件是 UTF-8 **带 BOM** 保存的，
> 改成无 BOM 后 PowerShell 5.1 会按 GBK 读，中文字符串全乱。

## 备份不到的东西

- `/sdcard/Android`（约 35 GB）：App 私有目录，无 root 读不出来
- `/data` 里微信 / QQ 的聊天记录：同样需要 root，只能靠它们自己的「聊天记录迁移与备份」

手机总用量和备份体积差一大截是正常的。

## 校验

脚本跑完会逐个顶层目录比对**文件数**（手机 `find -type f | wc -l` vs 本地）。
不一致会退出码 1 并提示重跑哪个目录。体积对比没意义，`du` 有块对齐误差。
