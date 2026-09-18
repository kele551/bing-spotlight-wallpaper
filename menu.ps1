# 微软壁纸助手 - 单层菜单 (by 海风 & 小腾)
. (Join-Path $PSScriptRoot 'core.ps1')

$global:BWVersion = '1.2.2'

# 把用户按键归一化: 去首尾空格 + 全角转半角 + 转小写。
# 中文输入法很容易把 o 打成全角 ｏ, 不归一化就变成"按了键没反应"。
function Normalize-BwKey([string]$s) {
  if (-not $s) { return '' }
  $out = foreach ($ch in $s.Trim().ToCharArray()) {
    $c = [int][char]$ch
    if ($c -eq 0x3000) { ' ' }
    elseif ($c -ge 0xFF01 -and $c -le 0xFF5E) { [char]($c - 0xFEE0) }
    else { $ch }
  }
  return ((-join $out).Trim()).ToLower()
}

function Pause-Bw { Write-Host ''; Read-Host '  按回车返回菜单' | Out-Null }
function Today-Str { return (Get-Date -Format 'yyyy-MM-dd') }
function Count-Jpg([string]$dir) { return (Get-ChildItem $dir -Recurse -Filter *.jpg -ErrorAction SilentlyContinue | Measure-Object).Count }
function Left-Queue($s) { return @($s.queue | Where-Object { $_ }).Count }

# ---------- 工具: 必须是绝对路径, 免得朋友输入相对路径后写到自己都不知道的地方 ----------
function Test-BwPathShape([string]$p) {
  if (-not $p) { return $false }
  if ($p -match '^[A-Za-z]:\\') { return $true }
  if ($p -match '^\\\\[^\\]+\\') { return $true }   # UNC \\server\share
  return $false
}
function Open-BwDir([string]$dir) {
  if (-not (Test-Path -LiteralPath $dir)) { $null = Ensure-BwDirs }
  if (Test-Path -LiteralPath $dir) {
    try { Start-Process -FilePath 'explorer.exe' -ArgumentList ('"{0}"' -f $dir) | Out-Null }
    catch { Write-Host ('  打不开文件夹: ' + $dir) }
  } else { Write-Host ('  文件夹还不存在: ' + $dir) }
}

# ---------- [5] 浏览两个库 (必应 + 聚焦, 按时间合并取最近 40 张) ----------
function Show-BrowseAll {
  $c = Get-BwConfig
  $files = @()
  foreach ($pair in @(@('必应', $c.bing_save_dir), @('聚焦', $c.spotlight_save_dir))) {
    $files += @(Get-ChildItem $pair[1] -Recurse -Filter *.jpg -ErrorAction SilentlyContinue |
      ForEach-Object { [psobject]@{ src = $pair[0]; file = $_ } })
  }
  $files = @($files | Sort-Object { $_.file.LastWriteTime } -Descending | Select-Object -First 40)
  if ($files.Count -eq 0) {
    Write-Host '  两个壁纸库都是空的 (菜单 [3] 可以补下载必应, [7] 可以抓聚焦)'
    Write-Host ('  位置: ' + $c.bing_save_dir)
    return
  }
  Write-Host ('  —— 壁纸库 (最近 ' + $files.Count + ' 张, [必应]/[聚焦] 标来源) ——')
  Write-Host ('  所在文件夹: ' + $c.bing_save_dir)
  $i = 0
  foreach ($f in $files) { Write-Host ("  [$i] [$($f.src)] $($f.file.Name)"); $i++ }
  $sel = Normalize-BwKey (Read-Host '  输入序号设为壁纸 (输入 o 打开文件夹, 回车返回)')
  if ($sel -eq '') { return }
  if ($sel -eq 'o') {
    Open-BwDir $c.bing_save_dir
    Open-BwDir $c.spotlight_save_dir
    return
  }
  try {
    $p = $files[[int]$sel].file.FullName
    $ok = Set-BwDesktopWallpaper $p
    Write-Host ('  已设为壁纸 (ok=' + $ok + '): ' + (Split-Path $p -Leaf))
    Log ('手动浏览设壁纸: ' + $p)
  } catch { Write-Host '  序号无效' }
}

# ---------- [4] 下载往期必应归档 (niumoo/bing-wallpaper, 2021-02 至今 4K) ----------
function Show-Archive {
  Write-Host '  归档范围: 2021-02 至今 (开源仓库 niumoo/bing-wallpaper, 4K UHD)'
  $ym = Read-Host '  输入年-月 (如 2024-08), 回车返回'
  if ((Normalize-BwKey $ym) -eq 'r' -or $ym -eq '') { return }
  $items = Get-BwMonthItems $ym
  if (-not $items -or $items.Count -eq 0) { Write-Host '  未取到清单或该月不存在'; Pause-Bw; return }
  $items | ForEach-Object { Write-Host ("    $($_.date)  $($_.code)") }
  Write-Host '  [1] 批量下载本月全部   [2] 单张设为壁纸   [3] 单张仅保存   [0] 返回'
  $k = Normalize-BwKey (Read-Host '  选择')
  if ($k -eq '1') { Invoke-BwArchiveBatch $ym; Pause-Bw }
  elseif ($k -eq '2' -or $k -eq '3') {
    $d = Read-Host '  输入日期 (如 2024-08-15)'
    Invoke-BwArchiveSingle $ym $d ($k -eq '2'); Pause-Bw
  }
}

# ---------- [1] 立即换一张聚焦 ----------
function Invoke-BwManualSwap {
  $null = Ensure-BwDirs
  $s = Get-BwState
  if ($s.last_bing_date -ne (Today-Str)) {
    $s.last_bing_date = (Today-Str)
    Write-Host '  (顺手记下今天必应已切, 免得下次进桌面又插一张必应)'
  }
  Invoke-BwSwap $s (Get-Date) '手动: 立刻换一张' | Out-Null
  Save-BwState $s
  if ($s.last_wall) { Write-Host ('  已更换: ' + (Split-Path $s.last_wall -Leaf)) }
}

# ---------- [7] 刷新下载一批新聚焦, 立刻排进队列 ----------
function Invoke-BwRefill {
  $c = Get-BwConfig
  $null = Ensure-BwDirs
  $s = Get-BwState
  $want = [int]$c.spotlight_per_cycle
  $new = @(Invoke-SpotlightFetch -count $want -Quiet)
  if ($new.Count -gt 0) {
    # 新下载的图立刻排进队列, 不用干等一整轮
    $s.queue = @(@($s.queue | Where-Object { $_ }) + $new)
    Save-BwState $s
  }
  Write-Host ('  聚焦库现在 ' + (Count-Jpg $c.spotlight_save_dir) + ' 张, 队列还剩 ' + (Left-Queue $s) + ' 张')
}

# ---------- [3] 手动补下错过的必应 ----------
function Invoke-BwBackfillManual {
  $null = Ensure-BwDirs
  $c = Get-BwConfig
  $before = (Get-ChildItem $c.bing_save_dir -Filter *.jpg -ErrorAction SilentlyContinue | Measure-Object).Count
  Write-Host '  正在检查缺口并补下载 (只下载, 不切壁纸)...'
  Invoke-BwBackfill
  $after = (Get-ChildItem $c.bing_save_dir -Filter *.jpg -ErrorAction SilentlyContinue | Measure-Object).Count
  Write-Host ('  必应库: ' + $before + ' -> ' + $after + ' 张 (本机断网时补不了, 联网后再来)')
}

# ---------- [8] 设置 (间隔 / 每轮张数 / 两个库位置, 一次问完, 回车跳过) ----------
function Edit-BwSettings {
  $c = Get-BwConfig
  Write-Host ('  必应库: ' + $c.bing_save_dir)
  Write-Host ('  聚焦库: ' + $c.spotlight_save_dir)
  Write-Host ''
  $m = Normalize-BwKey (Read-Host ('  换图间隔分钟 (现在 ' + $c.cycle_minutes + ', 回车不变)'))
  if ($m -match '^\d+$' -and [int]$m -gt 0) { $c.cycle_minutes = [int]$m }
  $n = Normalize-BwKey (Read-Host ('  每轮下载张数 (现在 ' + $c.spotlight_per_cycle + ', 回车不变)'))
  if ($n -match '^\d+$' -and [int]$n -gt 0) { $c.spotlight_per_cycle = [int]$n }

  $b = Read-Host '  必应库位置 (回车不变, 输入 o 打开文件夹)'
  if ((Normalize-BwKey $b) -eq 'o') { Open-BwDir $c.bing_save_dir }
  elseif ($b) {
    if (-not (Test-BwPathShape $b)) { Write-Host '  要写完整路径, 比如 D:\壁纸\必应 —— 已保持不变' }
    elseif (Test-BwWritable $b) { $c.bing_save_dir = $b; Write-Host ('  已设为 ' + $b) }
    else { Write-Host '  这个位置写不进去 (权限或盘不存在), 已保持不变' }
  }

  $d = Read-Host '  聚焦库位置 (回车不变, 输入 o 打开文件夹)'
  if ((Normalize-BwKey $d) -eq 'o') { Open-BwDir $c.spotlight_save_dir }
  elseif ($d) {
    if (-not (Test-BwPathShape $d)) { Write-Host '  要写完整路径, 比如 D:\壁纸\聚焦 —— 已保持不变' }
    elseif (Test-BwWritable $d) { $c.spotlight_save_dir = $d; Write-Host ('  已设为 ' + $d) }
    else { Write-Host '  这个位置写不进去 (权限或盘不存在), 已保持不变' }
  }

  Save-BwConfig $c
  $s = Get-BwState
  $s.queue = @(Get-BwFreshQueue $s)   # 位置或张数变了, 重洗队列
  Save-BwState $s
  Write-Host '  已保存'
}

# ---------- 首次运行向导 ----------
function Invoke-BwFirstRun {
  $d = Get-BwDefaults
  Clear-Host
  Write-Host '========== 微软壁纸助手 · 首次运行 ==========' -ForegroundColor Cyan
  Write-Host ''
  Write-Host '  它会做三件事:'
  Write-Host '    1. 每天把「必应每日一图」存到本机并设为壁纸'
  Write-Host '    2. 每半小时换一张「Windows 聚焦」壁纸 (不重复)'
  Write-Host '    3. 几天没开机也不漏图, 错过的必应壁纸会自动补齐'
  Write-Host ''
  Write-Host '  图片全部存在你自己电脑上, 不往任何服务器上传东西。'
  Write-Host ''
  $choices = @(Get-BwDriveChoices)
  $usable = @($choices | Where-Object { $_.Writable })
  $blocked = @($choices | Where-Object { -not $_.Writable })
  if ($usable.Count -gt 0) {
    Write-Host '  可以放壁纸的盘 (非系统盘优先, 按可用空间从大到小):'
    Write-Host ''
    $ci = 0
    foreach ($ch in $usable) {
      $mark = ''
      if ($ch.Sys) { $mark = '  (系统盘, 不推荐)' }
      elseif ($ci -eq 0) { $mark = '  <-- 推荐' }
      Write-Host ('   [{0}] {1}\微软壁纸助手   可用 {2} GB{3}' -f ($ci + 1), $ch.Name, [math]::Round($ch.Free / 1GB, 1), $mark)
      $ci++
    }
    Write-Host ''
  }
  if ($blocked.Count -gt 0) {
    foreach ($ch in $blocked) {
      Write-Host ('   ' + $ch.Name + '\ 用不了: 这个盘的根目录没给普通用户"新建文件夹"的权限 (它还有 ' + [math]::Round($ch.Free / 1GB, 1) + ' GB 空闲)') -ForegroundColor DarkGray
    }
    Write-Host '   (要让该盘能用, 得由管理员给它根目录加"修改"权限)' -ForegroundColor DarkGray
    Write-Host ''
  }
  Write-Host ('  建议保存到: ' + $d.base) -ForegroundColor Green
  $in = Read-Host '  回车 = 接受推荐位置, 也可直接输入上面的序号或一个完整路径'
  $base = $d.base
  if ($in) {
    $t = $in.Trim().Trim('"')
    if (($t -match '^\d+$') -and ([int]$t -ge 1) -and ([int]$t -le $usable.Count)) {
      $base = Join-Path (($usable[[int]$t - 1].Name) + '\') '微软壁纸助手'
    } else {
      $base = $t
    }
  }

  if (-not (Test-BwPathShape $base)) {
    Write-Host ''
    Write-Host ('  这不是个完整的盘符路径, 改用默认位置: ' + $d.base) -ForegroundColor Yellow
    $base = $d.base
  }
  $bing = Join-Path $base '必应'
  $spot = Join-Path $base '聚焦'
  if (-not (Test-BwWritable $bing) -or -not (Test-BwWritable $spot)) {
    Write-Host ''
    Write-Host ('  这个位置写不进去, 改用默认位置: ' + $d.base) -ForegroundColor Yellow
    Write-Host '  常见原因: 该盘根目录没给普通用户"新建文件夹"的权限; 也可能目录只读或盘不在。' -ForegroundColor DarkGray
    $base = $d.base
    $bing = Join-Path $base '必应'
    $spot = Join-Path $base '聚焦'
    $null = Test-BwWritable $bing
  }

  $c = Get-BwConfig
  $c.bing_save_dir = $bing
  $c.spotlight_save_dir = $spot
  Save-BwConfig $c
  Log ('首次运行: 保存位置 = ' + $base)

  Write-Host ''
  Write-Host '  正在下载今天的必应壁纸...' -ForegroundColor DarkGray
  Invoke-BwUpdate
  Write-Host ('  必应库: ' + (Count-Jpg $bing) + ' 张') -ForegroundColor DarkGray

  Write-Host '  正在抓几张聚焦壁纸备用...' -ForegroundColor DarkGray
  $null = Invoke-SpotlightFetch -count ([int]$c.spotlight_per_cycle) -Quiet
  Write-Host ('  聚焦库: ' + (Count-Jpg $spot) + ' 张') -ForegroundColor DarkGray

  $s = Get-BwState
  $s.last_bing_date = (Today-Str)
  $s.queue = @(Get-BwFreshQueue $s)
  $s.last_swap = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
  Save-BwState $s

  Write-Host ''
  Write-Host ('  好了。壁纸保存在: ' + $base) -ForegroundColor Green
  Write-Host '  想让它在后台自动换, 回到菜单按 [A] 打开「开机自动换壁纸」即可,' -ForegroundColor Green
  Write-Host '  不需要管理员权限, 也不装计划任务; 再按一次 [A] 就关掉。' -ForegroundColor Green
  Pause-Bw
}

# ---------- 开机自动换壁纸 (绿色做法: 往「启动」文件夹放个快捷方式, 不需要管理员) ----------
# 快捷方式指向 微软壁纸助手.exe --daemon。exe 是 GUI 子系统程序, 后台模式
# 一个控制台都不建, 所以开机拉起时不会闪任何窗口。
function Get-BwStartupLnk {
  return (Join-Path ([Environment]::GetFolderPath('Startup')) '微软壁纸助手.lnk')
}
function Get-BwLauncherPath {
  $p = Join-Path $global:BWRoot 'launcher.txt'
  if (Test-Path -LiteralPath $p) { return (Get-Content -LiteralPath $p -Raw -Encoding UTF8).Trim() }
  return ''
}
function Test-BwAutoStart { return (Test-Path -LiteralPath (Get-BwStartupLnk)) }
function Toggle-BwAutoStart {
  $lnk = Get-BwStartupLnk
  if (Test-BwAutoStart) {
    try { Remove-Item -LiteralPath $lnk -Force } catch {}
    # 告诉还在后台跑的 daemon 收工
    try { Set-Content -LiteralPath (Join-Path $global:BWRoot 'daemon.stop') -Value 'stop' -Encoding ASCII } catch {}
    Write-Host '  已关闭开机自动换壁纸。'
  } else {
    $exe = Get-BwLauncherPath
    if ((-not $exe) -or (-not (Test-Path -LiteralPath $exe))) {
      Write-Host '  找不到主程序「微软壁纸助手.exe」。'
      Write-Host '  请直接双击那个 exe 打开本菜单, 再来开这个开关。'
      return
    }
    try {
      # 清掉可能残留的 daemon.stop —— 不清的话刚拉起来的后台会立刻自己退掉
      $sf = Join-Path $global:BWRoot 'daemon.stop'
      if (Test-Path -LiteralPath $sf) { Remove-Item -LiteralPath $sf -Force -ErrorAction SilentlyContinue }
      $sh = New-Object -ComObject WScript.Shell
      $sc = $sh.CreateShortcut($lnk)
      $sc.TargetPath       = $exe
      $sc.Arguments        = '--daemon'
      $sc.WorkingDirectory = (Split-Path $exe -Parent)
      $sc.Description      = '微软壁纸助手 - 开机自动换壁纸'
      $sc.IconLocation     = ('{0},0' -f $exe)
      $sc.Save()
      Write-Host '  已开启。下次登录后会在后台自动换壁纸, 一个窗口都不会闪。'
      Write-Host ('  启动项位置: ' + $lnk)
    } catch { Write-Host ('  开启失败: ' + $_.Exception.Message) }
  }
}

# ---------- 主菜单 (单层, 一键直达) ----------
if (-not (Test-Path $global:CfgPath)) { Invoke-BwFirstRun }

do {
  $c0 = Get-BwConfig
  $s0 = Get-BwState
  Clear-Host
  Write-Host ('========== 微软壁纸助手 v' + $global:BWVersion + ' ==========') -ForegroundColor Cyan
  # 一行状态
  $bingDone = '待切'
  if ($s0.last_bing_date -eq (Today-Str)) { $bingDone = '已切' }
  $last = Get-BwTime $s0.last_swap
  $next = '首次运行后确定'
  if ($last) { $next = $last.AddMinutes([int]$c0.cycle_minutes).ToString('HH:mm') }
  Write-Host (' 必应今日: ' + $bingDone + ' · 必应库 ' + (Count-Jpg $c0.bing_save_dir) + ' 张 · 聚焦 ' + (Count-Jpg $c0.spotlight_save_dir) + ' 张 · 队列剩 ' + (Left-Queue $s0) + ' 张 · 下次自动换 ' + $next) -ForegroundColor DarkGray
  Write-Host (' 保存位置: ' + $c0.bing_save_dir) -ForegroundColor DarkGray
  if ($s0.last_wall) { Write-Host (' 当前壁纸: ' + (Split-Path $s0.last_wall -Leaf)) -ForegroundColor DarkGray }
  $auto = '关'
  if (Test-BwAutoStart) { $auto = '开' }
  Write-Host (' 开机自动换壁纸: ' + $auto) -ForegroundColor DarkGray
  Write-Host ''
  Write-Host ' [1] 立即换一张聚焦'
  Write-Host ' [2] 检测并更换今日必应图'
  Write-Host ' [3] 补下错过的必应 (几天没开机)'
  Write-Host ' [4] 下载往期必应 (2021至今 4K)'
  Write-Host ' [5] 浏览壁纸库, 选一张设为壁纸'
  Write-Host ' [6] 随机回忆 (两个库随机一张)'
  Write-Host ' [7] 刷新下载一批新聚焦'
  Write-Host ' [8] 设置 (间隔 / 张数 / 保存位置)'
  Write-Host ' [9] 打开保存壁纸的文件夹'
  Write-Host ' [A] 开机自动换壁纸  开 / 关'
  Write-Host ' [L] 查看运行日志'
  Write-Host ' [Q] 退出   (按 0 或 o 也一样)'
  $k = Normalize-BwKey (Read-Host '请选择')
  $quit = $false
  # 注意: PowerShell 的 switch 对字符串大小写不敏感, 且匹配到的子句"每个都会执行"。
  # 所以这里每个键只写一条小写子句 —— 写 'a' 和 'A' 两条会让开关被切两次 (等于没切)。
  switch ($k) {
    '1' { Invoke-BwManualSwap; Pause-Bw }
    '2' { Invoke-BwUpdate; Pause-Bw }
    '3' { Invoke-BwBackfillManual; Pause-Bw }
    '4' { Show-Archive }
    '5' { Show-BrowseAll; Pause-Bw }
    '6' { Invoke-BwRandom; Pause-Bw }
    '7' { Invoke-BwRefill; Pause-Bw }
    '8' { Edit-BwSettings; Pause-Bw }
    '9' { Open-BwDir (Get-BwConfig).bing_save_dir; Open-BwDir (Get-BwConfig).spotlight_save_dir }
    'a' { Toggle-BwAutoStart; Pause-Bw }
    'l' { Get-Content $global:BWLog -Tail 40 -Encoding UTF8 -ErrorAction SilentlyContinue; Pause-Bw }
    # 退出: 主标识是 Q, 但 0 和 o 也认 —— 菜单里那个 [0] 老被看成字母 O
    'q' { $quit = $true }
    '0' { $quit = $true }
    'o' { $quit = $true }
    default {
      Write-Host ('  「' + $k + '」不是菜单里的选项, 请输入方括号里的数字或字母')
      Start-Sleep -Milliseconds 900
    }
  }
} while (-not $quit)
