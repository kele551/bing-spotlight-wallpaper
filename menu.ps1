# 微软壁纸助手 - 菜单 (by 海风 & 小腾)
. (Join-Path $PSScriptRoot 'core.ps1')

$global:BWVersion = '1.3.0'

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
# 库的口径: 只数这一层的 .jpg, 不往子目录里钻。
# 用户会把图挪进子目录、删掉、或者搬到别处 —— 口径必须稳定可预期:
# "库里有几张" 就等于 "能轮换到几张", 两个数不会对不上。
function Count-Jpg([string]$dir) {
  return @(Get-ChildItem -LiteralPath $dir -File -Filter *.jpg -ErrorAction SilentlyContinue).Count
}
function Left-Queue($s) { return @($s.queue | Where-Object { $_ }).Count }

# 两个库通常放在同一个父目录下面 ("壁纸\必应" 和 "壁纸\聚焦"), 那就显示父目录;
# 万一被改成了两个分开的地方, 就分别显示, 不合并成一个看不出所以然的路径。
function Get-BwBaseOf($c) {
  $pb = ''
  $ps = ''
  try { $pb = Split-Path $c.bing_save_dir -Parent } catch {}
  try { $ps = Split-Path $c.spotlight_save_dir -Parent } catch {}
  if ($pb -and $ps -and ($pb -eq $ps)) { return $pb }
  return ''
}

# ---------- 工具: 必须是绝对路径, 免得用户输了相对路径后写到自己都不知道的地方 ----------
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

# ---------- 挑一个盘: 只排序, 不筛选 ----------
# 这个向导只**排序**, 不**筛选**。
#
# "某个盘现在能不能写"是每台机器各自的权限设置, 不是本程序的产品规则 ——
# 所以每一个盘都要出现在列表里、每一个都能被选中。默认值只是"排在最前面的那个",
# 它不剥夺任何人选别的盘的权利。
# (v1.2.2 把写不进去的盘从编号列表里剔了出去, 那等于用我这一台机器的权限去替
#  所有 GitHub 用户做决定: 用户看到自己的盘不在列表里, 会以为程序不支持那个盘,
#  而实际只是那台机器上少了一条 ACL。v1.2.3 改回全列出, 不能写的当场给一键修复。)
#
# 排列方式: 非系统盘在前 (能用的在前, 同档按可用空间从大到小), 系统盘固定放最后。
function Get-BwOrderedDrives {
  $all  = @(Get-BwDriveChoices)
  $data = @($all | Where-Object { -not $_.Sys })
  $sys  = @($all | Where-Object { $_.Sys })
  return @($data + $sys)
}

# 用户挑了一个这台机器上写不进去的位置 -> 解释清楚 + 给两条路,
# 绝不静默退回默认位置 (那正是"用户以为程序不支持他的盘"的来源)。
# 返回修好之后的路径; 用户不修、或修不成, 返回空串。
function Resolve-BwUnwritableBase([string]$base) {
  $drive = ''
  if ($base -match '^([A-Za-z]):\\') { $drive = $Matches[1] + '\' }
  Write-Host ''
  Write-Host ('  ' + $base + ' 现在写不进去。') -ForegroundColor Yellow
  if ($drive) {
    Write-Host ('  最常见的原因: ' + $drive + ' 的根目录没给普通用户"新建文件夹"的权限。') -ForegroundColor DarkGray
    Write-Host '  那是这台机器的权限设置, 不是本程序不支持这个盘 —— 盘上别的目录也可能照样能写。' -ForegroundColor DarkGray
  } else {
    Write-Host '  可能原因: 路径不存在、没有权限, 或者网络盘没连上。' -ForegroundColor DarkGray
  }
  Write-Host ''
  Write-Host ('   [1] 现在就修好它 —— 用一次管理员权限建出 ' + $base) -ForegroundColor Gray
  Write-Host '       并只给这一个文件夹授权 (不动盘根, 不动盘上别的目录;' -ForegroundColor DarkGray
  Write-Host '       删掉这个文件夹就等于完全回退, 不留任何权限改动)' -ForegroundColor DarkGray
  Write-Host '   [2] 我自己换一个位置'
  Write-Host '   回车 = 返回'
  $k = Normalize-BwKey (Read-Host '  怎么处理')
  if ($k -eq '1') {
    if (-not $drive) {
      Write-Host '  非本地盘符的位置没法自动创建, 请先自己把文件夹建好。' -ForegroundColor Yellow
      Pause-Bw
      return ''
    }
    Write-Host '  正在修复, 会弹一次管理员授权框...' -ForegroundColor DarkGray
    if (Repair-BwBaseDir $base) {
      Write-Host ('  修好了: ' + $base) -ForegroundColor Green
      Pause-Bw
      return $base
    }
    Write-Host '  没修成 —— 可能是授权被取消了, 或者这个位置不允许自动创建。' -ForegroundColor Yellow
    Pause-Bw
    return ''
  }
  return ''
}

# ---------- 选择壁纸文件夹 (首次运行向导和「设置」共用) ----------
# 返回选中的路径; 返回空串表示"这轮没选出来, 重新问一遍"。
function Select-BwBase([string]$suggest, [string]$suggestReason) {
  $cands = @()
  # 第一项固定是系统「图片」文件夹 —— 用户要的就是"图片库里的壁纸文件夹"。
  # 顺带把那个盘的剩余空间也印上, 跟下面各盘那一列对齐, 好看也好比。
  $picPath = Join-Path (Get-BwPicturesDir) '壁纸'
  $picExtra = '系统「图片」文件夹'
  $pd = ''
  if ($picPath -match '^([A-Za-z]):') { $pd = $Matches[1].ToUpper() + ':' }
  $drives = @(Get-BwOrderedDrives)
  if ($pd) {
    foreach ($ch in $drives) {
      if (([string]$ch.Name).ToUpper() -eq $pd) { $picExtra = '系统「图片」文件夹    可用 ' + [math]::Round($ch.Free / 1GB, 1) + ' GB'; break }
    }
  }
  $cands += [PSCustomObject]@{ Path = $picPath; Extra = $picExtra }
  foreach ($ch in $drives) {
    $tags = @()
    if (-not $ch.Writable) { $tags += '这台机器上还没给写入权限, 选中可一键修' }
    if ($ch.Sys) { $tags += '系统盘, 不推荐' }
    $extra = '可用 ' + [math]::Round($ch.Free / 1GB, 1) + ' GB'
    if ($tags.Count -gt 0) { $extra += '   (' + ($tags -join '; ') + ')' }
    $cands += [PSCustomObject]@{ Path = ($ch.Name + '\图片\壁纸'); Extra = $extra }
  }
  $manual = $cands.Count + 1
  $i = 0
  foreach ($cd in $cands) {
    $i++
    $mark = ''
    if ($suggest -and ($cd.Path -eq $suggest)) { $mark = '   <-- 建议' }
    Write-Host ('   [' + $i + '] ' + $cd.Path + '     ' + $cd.Extra + $mark)
  }
  Write-Host ('   [' + $manual + '] 我自己输入完整路径')
  Write-Host ''
  if ($suggest) {
    Write-Host ('   建议: ' + $suggest) -ForegroundColor Green
    if ($suggestReason) { Write-Host ('         ' + $suggestReason) -ForegroundColor DarkGray }
    Write-Host '   回车 = 用建议位置 · 也可以输入序号 · 或直接粘贴完整路径'
  } else {
    Write-Host '   输入序号, 或直接粘贴完整路径'
  }
  $in = Read-Host '  壁纸存哪'
  $t = ''
  if ($in) { $t = $in.Trim().Trim('"') }
  if (-not $t) { return $suggest }
  if ($t -match '^\d+$') {
    $idx = [int]$t
    if (($idx -lt 1) -or ($idx -gt $manual)) {
      Write-Host ('  没有 [' + $idx + '] 这一项 (共 ' + $manual + ' 个), 请重新选。') -ForegroundColor Yellow
      Pause-Bw
      return ''
    }
    if ($idx -eq $manual) {
      $p = Read-Host '  输入完整路径 (比如 D:\我的壁纸, 网络盘写 \\服务器\共享\目录)'
      if (-not $p) { return '' }
      return $p.Trim().Trim('"').TrimEnd('\')
    }
    return $cands[$idx - 1].Path
  }
  if (-not (Test-BwPathShape $t)) {
    Write-Host ''
    Write-Host ('  「' + $t + '」不是完整路径。要写成像 D:\壁纸 这样。') -ForegroundColor Yellow
    Pause-Bw
    return ''
  }
  return $t.TrimEnd('\')
}

# 把壁纸文件夹定下来并写进 config。下面的「必应」「聚焦」两个子目录顺手建好。
# 返回是否成功。
function Set-BwBase([string]$base) {
  $b = $base.TrimEnd('\')
  if (-not (Test-BwPathShape $b)) {
    Write-Host ('  要写完整路径, 比如 D:\壁纸 —— 已保持不变')
    return $false
  }
  $bing = Join-Path $b '必应'
  $spot = Join-Path $b '聚焦'
  if (-not ((Test-BwWritable $bing) -and (Test-BwWritable $spot))) {
    $fixed = Resolve-BwUnwritableBase $b
    if (-not $fixed) { Write-Host '  已保持不变。'; return $false }
    $b = $fixed
    $bing = Join-Path $b '必应'
    $spot = Join-Path $b '聚焦'
  }
  $c = Get-BwConfig
  $c.bing_save_dir = $bing
  $c.spotlight_save_dir = $spot
  Save-BwConfig $c
  # 位置换了, 老队列里的文件名已经对不上新目录, 重洗一次
  $s = Get-BwState
  $s.queue = @(Get-BwFreshQueue $s)
  Save-BwState $s
  Log ('保存位置: ' + $b)
  Write-Host ('  已设为 ' + $b)
  return $true
}

# ---------- [4] 从库里挑一张 ----------
function Show-BrowseAll {
  $c = Get-BwConfig
  $files = @()
  foreach ($pair in @(@('必应', $c.bing_save_dir), @('聚焦', $c.spotlight_save_dir))) {
    $files += @(Get-ChildItem -LiteralPath $pair[1] -File -Filter *.jpg -ErrorAction SilentlyContinue |
      ForEach-Object { [PSCustomObject]@{ src = $pair[0]; file = $_ } })
  }
  $files = @($files | Sort-Object { $_.file.LastWriteTime } -Descending | Select-Object -First 40)
  if ($files.Count -eq 0) {
    Write-Host '  两个壁纸库现在都是空的。'
    Write-Host ('  位置: ' + $c.bing_save_dir)
    Write-Host '  菜单 [1] 会顺手抓图, [7] 补必应, 开着自动换也会自己攒起来。'
    return
  }
  Write-Host ('  —— 壁纸库 (最近 ' + $files.Count + ' 张, [必应]/[聚焦] 标来源) ——')
  Write-Host ('  所在文件夹: ' + $c.bing_save_dir)
  $i = 0
  foreach ($f in $files) { Write-Host ("  [$i] [$($f.src)] $($f.file.Name)"); $i++ }
  Write-Host '  [o] 打开文件夹    [q] 返回'
  $sel = Normalize-BwKey (Read-Host '  输入序号设为壁纸')
  if ($sel -eq '' -or $sel -eq 'q') { return }
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

# ---------- [8] 下载往期必应 (niumoo/bing-wallpaper, 2021-02 至今 4K) ----------
function Show-Archive {
  Write-Host '  归档范围: 2021-02 至今 (开源仓库 niumoo/bing-wallpaper, 4K)'
  $ym = Read-Host '  输入年-月 (如 2024-08), 回车返回'
  if (-not $ym) { return }
  if ((Normalize-BwKey $ym) -eq 'q') { return }
  $items = Get-BwMonthItems $ym
  if (-not $items -or $items.Count -eq 0) { Write-Host '  没取到清单 (检查网络, 或这个月不存在)'; Pause-Bw; return }
  $items | ForEach-Object { Write-Host ("    $($_.date)  $($_.code)") }
  Write-Host '  [1] 把这一个月全下下来   [2] 只下一张并设成壁纸   [3] 只下一张存着   [q] 返回'
  $k = Normalize-BwKey (Read-Host '  选择')
  if ($k -eq '1') { Invoke-BwArchiveBatch $ym; Pause-Bw }
  elseif ($k -eq '2' -or $k -eq '3') {
    $d = Read-Host '  输入日期 (如 2024-08-15)'
    if ($d) { Invoke-BwArchiveSingle $ym $d ($k -eq '2'); Pause-Bw }
  }
}

# ---------- [1] 立刻换一张 ----------
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

# ---------- [3] 再抓一批新聚焦 ----------
function Invoke-BwRefill {
  $c = Get-BwConfig
  $null = Ensure-BwDirs
  $s = Get-BwState
  $want = [int]$c.spotlight_per_cycle
  $new = @(Invoke-SpotlightFetch -count $want -Quiet)
  if ($new.Count -gt 0) {
    # 新下的图立刻排进队列, 不用干等一整轮
    $s.queue = @(@($s.queue | Where-Object { $_ }) + $new)
    Save-BwState $s
  }
  Write-Host ('  聚焦库现在 ' + (Count-Jpg $c.spotlight_save_dir) + ' 张, 待换队列还剩 ' + (Left-Queue $s) + ' 张')
}

# ---------- [7] 补下最近错过的必应 ----------
function Invoke-BwBackfillManual {
  $null = Ensure-BwDirs
  $c = Get-BwConfig
  $before = (Count-Jpg $c.bing_save_dir)
  Write-Host '  正在检查缺口并补下载 (只下载, 不切壁纸)...'
  Invoke-BwBackfill (Get-BwState)
  $after = (Count-Jpg $c.bing_save_dir)
  Write-Host ('  必应库: ' + $before + ' -> ' + $after + ' 张 (断网时补不了, 联网后再来)')
  Write-Host '  删掉或移走的旧图不会被补回来 —— 补的只是真正错过的那些天。'
}

# ---------- 设置 ----------
function Show-BwSettings {
  $back = $false
  do {
    $c = Get-BwConfig
    Clear-Host
    Write-Host '========== 设置 ==========' -ForegroundColor Cyan
    Write-Host ''
    Write-Host ('  [1] 换图间隔        每 ' + $c.cycle_minutes + ' 分钟换一张')
    Write-Host ('  [2] 每轮抓几张      一次抓 ' + $c.spotlight_per_cycle + ' 张聚焦备用')
    $base = Get-BwBaseOf $c
    if ($base) { Write-Host ('  [3] 壁纸保存位置    ' + $base) }
    else {
      Write-Host ('  [3] 壁纸保存位置    必应: ' + $c.bing_save_dir)
      Write-Host ('                      聚焦: ' + $c.spotlight_save_dir)
    }
    Write-Host ''
    Write-Host '  [q] 返回'
    Write-Host ''
    $k = Normalize-BwKey (Read-Host '  要改哪一项')
    switch ($k) {
      '1' {
        Write-Host ''
        $m = Read-Host ('  多少分钟换一次? (现在 ' + $c.cycle_minutes + ', 回车不改)')
        if ($m -and ((Normalize-BwKey $m) -match '^\d+$') -and ([int]$m -gt 0)) {
          $c.cycle_minutes = [int]$m
          Save-BwConfig $c
          Write-Host ('  好了, 每 ' + $m + ' 分钟换一张。')
        } elseif ($m) { Write-Host '  要填一个大于 0 的数字, 没改。' }
        Pause-Bw
      }
      '2' {
        Write-Host ''
        $n = Read-Host ('  一次抓几张? (现在 ' + $c.spotlight_per_cycle + ', 回车不改)')
        if ($n -and ((Normalize-BwKey $n) -match '^\d+$') -and ([int]$n -gt 0)) {
          $c.spotlight_per_cycle = [int]$n
          Save-BwConfig $c
          Write-Host ('  好了, 一次抓 ' + $n + ' 张。')
        } elseif ($n) { Write-Host '  要填一个大于 0 的数字, 没改。' }
        Pause-Bw
      }
      '3' {
        Clear-Host
        Write-Host '========== 壁纸保存位置 ==========' -ForegroundColor Cyan
        Write-Host ''
        if ($base) { Write-Host ('  现在: ' + $base) }
        else {
          Write-Host ('  现在: 必应 ' + $c.bing_save_dir)
          Write-Host ('        聚焦 ' + $c.spotlight_save_dir)
        }
        Write-Host '  壁纸会放在这个文件夹下面的「必应」和「聚焦」两个子目录里。'
        Write-Host '  换位置不影响已经存好的图, 只是以后往新地方存。'
        Write-Host ''
        $sel = Select-BwBase '' ''
        if (-not $sel) { Write-Host '  没改。' }
        else { [void](Set-BwBase $sel) }
        Pause-Bw
      }
      'q' { $back = $true }
      default { }
    }
  } while (-not $back)
}

# ---------- 首次运行向导 ----------
function Invoke-BwFirstRun {
  $d = Get-BwDefaults
  $base = ''
  while (-not $base) {
    Clear-Host
    Write-Host ('========== 微软壁纸助手 v' + $global:BWVersion + ' · 首次运行 ==========') -ForegroundColor Cyan
    Write-Host ''
    Write-Host '  它做三件事:'
    Write-Host '    1. 每天把「必应每日一图」存下来, 并设成桌面壁纸'
    Write-Host '    2. 每半小时换一张「Windows 聚焦」壁纸, 不重复'
    Write-Host '    3. 几天没开机也不漏图, 错过的必应壁纸会自动补齐'
    Write-Host ''
    Write-Host '  图片全部存在你自己电脑上, 不会上传到任何服务器。'
    Write-Host '  壁纸你随时可以自己删、自己挪到别处, 删了不影响它继续换图。'
    Write-Host ''
    Write-Host '  壁纸存到哪? 下面这些都能选:'
    Write-Host ''
    $sel = Select-BwBase $d.base $d.reason
    if (-not $sel) { continue }
    $base = $sel
    # 位置定了, 但"能写"才是真定了。不能写就地解释 + 给一键修复。
    if ((Test-BwWritable (Join-Path $base '必应')) -and (Test-BwWritable (Join-Path $base '聚焦'))) { break }
    $fixed = Resolve-BwUnwritableBase $base
    if ($fixed) { $base = $fixed; break }
    $base = ''    # 没修成 -> 回到列表重来, 而不是偷偷换到别的地方
  }

  $bing = Join-Path $base '必应'
  $spot = Join-Path $base '聚焦'
  [void](Set-BwBase $base)

  $c = Get-BwConfig
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
  Write-Host ''
  Write-Host '  想让它在后台自动换, 回到菜单按 [A] 打开「开机自动换壁纸」,'
  Write-Host '  不需要管理员权限, 也不装计划任务; 再按一次 [A] 就关掉。'
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

# ---------- 主菜单 ----------
if (-not (Test-Path -LiteralPath $global:CfgPath)) { Invoke-BwFirstRun }

do {
  $c0 = Get-BwConfig
  $s0 = Get-BwState
  $bingN = Count-Jpg $c0.bing_save_dir
  $spotN = Count-Jpg $c0.spotlight_save_dir
  Clear-Host
  Write-Host ('========== 微软壁纸助手 v' + $global:BWVersion + ' ==========') -ForegroundColor Cyan
  $bingDone = '待切'
  if ($s0.last_bing_date -eq (Today-Str)) { $bingDone = '已切' }
  $last = Get-BwTime $s0.last_swap
  $next = '还没换过'
  if ($last) { $next = $last.AddMinutes([int]$c0.cycle_minutes).ToString('HH:mm') }
  $auto = '关'
  if (Test-BwAutoStart) { $auto = '开' }
  Write-Host (' 今日必应: ' + $bingDone + '    下次自动换: ' + $next + '    开机自动换: ' + $auto) -ForegroundColor DarkGray
  Write-Host (' 壁纸库: 必应 ' + $bingN + ' 张 · 聚焦 ' + $spotN + ' 张 · 待换队列剩 ' + (Left-Queue $s0) + ' 张') -ForegroundColor DarkGray
  $base0 = Get-BwBaseOf $c0
  if ($base0) { Write-Host (' 保存位置: ' + $base0) -ForegroundColor DarkGray }
  else {
    Write-Host (' 必应库: ' + $c0.bing_save_dir) -ForegroundColor DarkGray
    Write-Host (' 聚焦库: ' + $c0.spotlight_save_dir) -ForegroundColor DarkGray
  }
  if ($s0.last_wall) {
    $leaf = Split-Path $s0.last_wall -Leaf
    if (Test-Path -LiteralPath $s0.last_wall) {
      Write-Host (' 当前壁纸: ' + $leaf) -ForegroundColor DarkGray
    } else {
      # 图被用户删掉或挪走了 —— 这是正常操作, 如实说清楚, 不报错也不假装还在
      Write-Host (' 当前壁纸: ' + $leaf) -ForegroundColor DarkGray
      Write-Host '           这张已经不在库里了 (桌面还显示着它, 换一张就会更新)' -ForegroundColor DarkYellow
    }
  }
  if ((($bingN + $spotN) -eq 0) -and ([int]$s0.shown -gt 0)) {
    Write-Host ''
    Write-Host ' 注意: 库里现在一张图都没有, 但程序已经换过壁纸。' -ForegroundColor Yellow
    Write-Host '       图是不是被删掉或移到别处了? 想接着用那些图, 按 [S] 把保存位置指到新地方;' -ForegroundColor DarkGray
    Write-Host '       不管的话, 它会自动重新下载新图。' -ForegroundColor DarkGray
  }
  Write-Host ''
  Write-Host ' —— 换图 ——'
  Write-Host '  [1] 立刻换一张 (聚焦)'
  Write-Host '  [2] 换上今天的必应每日一图'
  Write-Host '  [3] 再抓一批新聚焦'
  Write-Host ' —— 壁纸库 ——'
  Write-Host '  [4] 从库里挑一张'
  Write-Host '  [5] 随便来一张'
  Write-Host '  [6] 打开壁纸文件夹'
  Write-Host ' —— 补图 ——'
  Write-Host '  [7] 补下最近错过的必应 (几天没开机)'
  Write-Host '  [8] 下载往期必应 (2021 年至今, 4K)'
  Write-Host ' —— 其他 ——'
  Write-Host '  [S] 设置'
  Write-Host '  [A] 开机自动换壁纸  开 / 关'
  Write-Host '  [L] 查看运行日志'
  Write-Host '  [Q] 退出'
  $k = Normalize-BwKey (Read-Host '请选择')
  $quit = $false
  # 注意: PowerShell 的 switch 对字符串大小写不敏感, 且匹配到的子句"每个都会执行"。
  # 所以这里每个键只写一条小写子句 —— 写 'a' 和 'A' 两条会让开关被切两次 (等于没切)。
  switch ($k) {
    '1' { Invoke-BwManualSwap; Pause-Bw }
    '2' { Invoke-BwUpdate; Pause-Bw }
    '3' { Invoke-BwRefill; Pause-Bw }
    '4' { Show-BrowseAll; Pause-Bw }
    '5' { Invoke-BwRandom; Pause-Bw }
    '6' { Open-BwDir $c0.bing_save_dir; Open-BwDir $c0.spotlight_save_dir }
    '7' { Invoke-BwBackfillManual; Pause-Bw }
    '8' { Show-Archive }
    's' { Show-BwSettings }
    'a' { Toggle-BwAutoStart; Pause-Bw }
    'l' { Get-Content -LiteralPath $global:BWLog -Tail 40 -Encoding UTF8 -ErrorAction SilentlyContinue; Pause-Bw }
    # 退出: 主标识是 Q; 0 和 o 也认 —— 老菜单里那个 [0] 常被看成字母 O, 习惯不改
    'q' { $quit = $true }
    '0' { $quit = $true }
    'o' { $quit = $true }
    default {
      Write-Host ('  「' + $k + '」不是菜单里的选项, 请输入方括号里的数字或字母')
      Start-Sleep -Milliseconds 900
    }
  }
} while (-not $quit)
