# 微软壁纸助手 · Bing + Windows 聚焦 双图源自动换壁纸

Windows 桌面壁纸自动轮换工具。两个官方图源：**必应每日一图** + **Windows 聚焦**（微软官方 4K）。
装完不用管，纯 PowerShell，无第三方依赖。

## 功能

| 能力 | 说明 |
|---|---|
| 必应每日图 | 每天第一次进入桌面，下载并切换到必应当前官方图 |
| 离线补漏 | 几天没开机，**错过的每一天必应壁纸自动补下载**，一张不少（≤7 天走官方接口，更早走归档源） |
| 聚焦轮换 | 每 30 分钟自动换一张聚焦壁纸；每次重启电脑立刻换一张；同库内不重复 |
| 队列机制 | 库内图片洗牌成队列依次发放，发完自动再下载 6 张重洗一轮，不会"挑不出图卡死" |
| 往期归档 | 可按年月批量下载 2021-02 至今的必应 4K 原图（来源 niumoo/bing-wallpaper） |
| 无黑窗 | 计划任务通过 wscript 拉起，**一个像素都不会闪**（原理见下） |
| 无重复下载 | 文件名即去重依据，重复运行完全幂等 |

## 安装

1. 把本目录放到任意位置（例如 `D:\微软壁纸助手`），保证 `core.ps1` 与 `run-hidden.vbs` 同目录。
2. 首次使用：复制 `config.example.json` 为 `config.json`，按需修改两个壁纸库路径（**不要放 C 盘**）。
3. 注册计划任务（**以管理员身份运行 PowerShell**，普通身份通常会被拒绝访问）：

```powershell
powershell -ExecutionPolicy Bypass -File install-task.ps1
```

4. 立即测试一次：

```powershell
Start-ScheduledTask -TaskName MSWallpaperDaily
```

日常使用直接运行菜单：

```powershell
powershell -ExecutionPolicy Bypass -File menu.ps1
```

## 菜单（单层，8 项直达）

```
========== 微软壁纸助手 v1.1.0 ==========
 必应今日: 已切 · 聚焦 124 张 · 队列剩 122 张 · 下次自动换 09:56
 [1] 立即换一张聚焦          [2] 检测并更换今日必应图
 [3] 下载往期必应 (2021至今4K) [4] 浏览壁纸库, 选一张设为壁纸
 [5] 随机回忆 (两个库随机一张)  [6] 刷新下载一批新聚焦
 [7] 设置 (间隔/每轮张数/库位置) [8] 查看运行日志
 [0] 退出
```

## 黑窗口为什么不会再闪

计划任务原先直接启动 `powershell.exe`，`-WindowStyle Hidden` 救不了它——因为
powershell.exe 的 PE 子系统是 **CONSOLE**，Windows 会**先创建控制台窗口、再执行隐藏**，
所以每次都闪一下。

本项目的做法：计划任务启动 `wscript.exe`（PE 子系统为 **GUI**，根本不会分配控制台），
再由 `run-hidden.vbs` 以窗口样式 0 拉起 powershell。

| 宿主 | PE 子系统 | 结果 |
|---|---|---|
| powershell.exe | CONSOLE | 会分配控制台 → 闪窗 |
| **wscript.exe** | **GUI** | 不可能闪 |

## 配置项（config.json）

| 字段 | 含义 | 默认 |
|---|---|---|
| `bing_save_dir` | 必应壁纸库目录 | `D:\Bing壁纸` |
| `spotlight_save_dir` | 聚焦壁纸库目录 | `D:\聚焦壁纸` |
| `resolution_mode` | 必应下载分辨率：`auto` 跟随屏幕 / `uhd` 固定 4K | `uhd` |
| `cycle_minutes` | 聚焦换图间隔（分钟） | `30` |
| `spotlight_per_cycle` | 队列发完后每轮补货张数 | `6` |

## 目录结构

```
core.ps1              核心库：下载 / 轮换 / 补漏 / 归档
menu.ps1              单层交互菜单
run-hidden.vbs        无窗口启动器（wscript 调用）
install-task.ps1      (重新)注册计划任务
config.example.json   配置模板
config.json           你的实际配置（已 gitignore）
state.json            运行进度（已 gitignore）
wallpaper.log         运行日志（已 gitignore）
```

## 常见问题

- **改了目录/移动了文件夹**：重新跑一次 `install-task.ps1`，任务里写的是 `run-hidden.vbs` 的绝对路径。
- **想回到旧行为**：见 `install-task.ps1` 顶部注释里的回退命令。
- **杀软拦截**：脚本会用 wscript 拉起 powershell，部分安全软件会提示，允许即可。
- **未来兼容性**：微软已宣布逐步弃用 VBScript。若某天 `run-hidden.vbs` 失效，可把计划任务
  改为指向一个无控制台的 WinExe 启动器（创建进程时带 `CREATE_NO_WINDOW`），效果相同。
- **日志**：`wallpaper.log` 超过 256 KB 自动裁剪，只留最近 200 行。

## 许可

MIT
