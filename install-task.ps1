# install-task.ps1 - 注册 / 卸载「微软壁纸助手」的开机自启计划任务
#
# 任务 = 登录后延迟 45 秒跑一次 + 之后每 15 分钟跑一次, 动作是
#   wscript.exe "run-hidden.vbs"
# wscript.exe 是 GUI 子系统程序, 系统不会给它分配控制台窗口; VBS 再用
# 窗口样式 0 拉起 core.ps1 -Cycle —— 所以整个过程一个黑窗口都不会闪。
# (实测依据: powershell.exe 的 PE 子系统是 CONSOLE, Windows 一定先建控制台
# 再执行 -WindowStyle Hidden, 必然闪一下; wscript.exe 是 GUI 子系统, 闪不出来。)
#
# 用法:
#     装自启       powershell -ExecutionPolicy Bypass -File install-task.ps1
#     卸自启       powershell -ExecutionPolicy Bypass -File install-task.ps1 -Uninstall
#     看状态       powershell -ExecutionPolicy Bypass -File install-task.ps1 -Status
#     仅建快捷方式  powershell -ExecutionPolicy Bypass -File install-task.ps1 -ShortcutOnly
#
# 没提权也能跑; 遇到"拒绝访问"会自己弹 UAC 重新拉起自己。
# 普通朋友不用手敲这些 —— 双击「安装开机自启.cmd」和「卸载.cmd」就行。
[CmdletBinding()]
param(
  [switch]$Uninstall,
  [switch]$Status,
  [switch]$ShortcutOnly,
  [switch]$NoShortcut
)

$ErrorActionPreference = 'Stop'
$global:InstallTaskDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$dir  = $global:InstallTaskDir
$name = 'MSWallpaperDaily'
$vbs  = Join-Path $dir 'run-hidden.vbs'
$core = Join-Path $dir 'core.ps1'
$menu = Join-Path $dir 'menu.ps1'
$ico  = Join-Path $dir '微软壁纸助手.ico'
$lnk  = Join-Path ([Environment]::GetFolderPath('Desktop')) '微软壁纸助手.lnk'

# ---------------------------------------------------------------- 工具函数
function Test-BwAdmin {
  try {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    return (New-Object Security.Principal.WindowsPrincipal($id)).IsInRole(
      [Security.Principal.WindowsBuiltInRole]::Administrator)
  } catch { return $false }
}
function New-BwShortcut {
  if ($NoShortcut) { return }
  try {
    $sh = New-Object -ComObject WScript.Shell
    $sc = $sh.CreateShortcut($lnk)
    $sc.TargetPath       = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
    $sc.Arguments        = ('-NoProfile -ExecutionPolicy Bypass -File "{0}"' -f $menu)
    $sc.WorkingDirectory = $dir
    $sc.Description      = '微软壁纸助手 - 必应每日一图 + Windows 聚焦'
    if (Test-Path -LiteralPath $ico) { $sc.IconLocation = ('{0},0' -f $ico) }
    $sc.Save()
    Write-Host ('OK  桌面快捷方式: ' + $lnk)
  } catch { Write-Host ('桌面快捷方式没建成 (不影响换壁纸): ' + $_.Exception.Message) }
}
function Remove-BwShortcut {
  if (Test-Path -LiteralPath $lnk) {
    try { Remove-Item -LiteralPath $lnk -Force; Write-Host 'OK  已删桌面快捷方式' }
    catch { Write-Host ('桌面快捷方式删不掉: ' + $_.Exception.Message) }
  }
}
function Restart-BwElevated {
  $argLine = '-NoProfile -ExecutionPolicy Bypass -File "{0}"' -f $PSCommandPath
  if ($Uninstall)    { $argLine += ' -Uninstall' }
  if ($Status)       { $argLine += ' -Status' }
  if ($ShortcutOnly) { $argLine += ' -ShortcutOnly' }
  if ($NoShortcut)   { $argLine += ' -NoShortcut' }
  try {
    $p = Start-Process -FilePath 'powershell.exe' -ArgumentList $argLine -Verb RunAs -PassThru -Wait
    if ($p -and $p.ExitCode -ne 0) { Write-Host ('提权后的进程返回 ' + $p.ExitCode + ' (见上面输出)') }
    exit 0
  } catch {
    Write-Host '提权被取消, 什么都没改。'
    Write-Host '想手动来的话: 右键「开始」-> 终端(管理员), 然后跑 install-task.ps1'
    exit 3
  }
}

# ---------------------------------------------------------------- 不需要管理员的入口
if ($ShortcutOnly) {
  New-BwShortcut
  exit 0
}

if ($Status) {
  $t = Get-ScheduledTask -TaskName $name -ErrorAction SilentlyContinue
  if (-not $t) { Write-Host ('没装: 计划任务 ' + $name + ' 不存在'); }
  else {
    Write-Host ('任务 {0}  状态={1}  触发器={2} 个' -f $t.TaskName, $t.State, @($t.Triggers).Count)
    Write-Host ('动作: {0} {1}' -f $t.Actions[0].Execute, $t.Actions[0].Arguments)
    $inf = Get-ScheduledTaskInfo -TaskName $name -ErrorAction SilentlyContinue
    if ($inf) { Write-Host ('上次运行: {0}  结果={1}  下次: {2}' -f $inf.LastRunTime, $inf.LastTaskResult, $inf.NextRunTime) }
  }
  Write-Host ('桌面快捷方式: ' + (Test-Path -LiteralPath $lnk))
  exit 0
}

# ---------------------------------------------------------------- 卸载(要管理员)
if ($Uninstall) {
  if (-not (Test-BwAdmin)) { Restart-BwElevated }
  $t = Get-ScheduledTask -TaskName $name -ErrorAction SilentlyContinue
  if ($t) {
    try { Unregister-ScheduledTask -TaskName $name -Confirm:$false; Write-Host ('OK  已删除计划任务 ' + $name) }
    catch { Write-Host ('删计划任务失败: ' + $_.Exception.Message); exit 2 }
  } else { Write-Host '本来就没装这个计划任务' }
  Remove-BwShortcut
  Write-Host ''
  Write-Host '已停用自动换壁纸。壁纸图片和程序文件都还在原地, 没动过。'
  Write-Host ('想彻底清掉, 直接删掉这个文件夹就行: ' + $dir)
  exit 0
}

# ---------------------------------------------------------------- 安装(要管理员)
if (-not (Test-BwAdmin)) { Restart-BwElevated }

$fatal = $false
foreach ($f in @($vbs, $core)) {
  if (-not (Test-Path -LiteralPath $f)) { Write-Host ('缺文件: ' + $f); $fatal = $true }
}
if ($fatal) { Write-Host '程序文件不全, 没法装。请重新解压一份完整的。'; exit 1 }

$old = (Get-ScheduledTask -TaskName $name -ErrorAction SilentlyContinue).Actions[0]
if ($old) { Write-Host ('将被替换的旧动作: {0} {1}' -f $old.Execute, $old.Arguments) }

$action = New-ScheduledTaskAction -Execute 'wscript.exe' -Argument ('"{0}"' -f $vbs)

$every15 = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(1) `
  -RepetitionInterval (New-TimeSpan -Minutes 15) `
  -RepetitionDuration  (New-TimeSpan -Days 3650)
$atLogon = New-ScheduledTaskTrigger -AtLogOn -User $env:USERNAME
$atLogon.Delay = 'PT45S'

$settings  = New-ScheduledTaskSettingsSet -MultipleInstances IgnoreNew `
  -StartWhenAvailable -ExecutionTimeLimit (New-TimeSpan -Minutes 30)
$principal = New-ScheduledTaskPrincipal -UserId $env:USERNAME -LogonType Interactive -RunLevel Limited

try {
  Register-ScheduledTask -TaskName $name -Action $action -Trigger $every15, $atLogon `
    -Settings $settings -Principal $principal -Force -ErrorAction Stop | Out-Null
} catch {
  Write-Host ('注册失败: ' + $_.Exception.Message)
  Write-Host '提示: 需要在管理员终端里跑这个脚本。'
  exit 2
}

$t = Get-ScheduledTask -TaskName $name
Write-Host ('OK  计划任务 {0}  状态={1}  触发器={2} 个' -f $t.TaskName, $t.State, @($t.Triggers).Count)
Write-Host ('    动作: {0} {1}' -f $t.Actions[0].Execute, $t.Actions[0].Arguments)
New-BwShortcut
Write-Host ''
Write-Host '装好了。开机登录后 45 秒开始自动换, 之后每 15 分钟一次。'
Write-Host ('  立刻试一次:  Start-ScheduledTask -TaskName ' + $name)
Write-Host '  以后搬动这个文件夹, 重新双击一次「安装开机自启.cmd」修路径就行。'
exit 0
