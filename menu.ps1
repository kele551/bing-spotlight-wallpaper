# 微软壁纸助手 - 单层菜单 (by 海风 & 小腾)
. (Join-Path $PSScriptRoot 'core.ps1')

function Pause-Bw { Write-Host ''; Read-Host '  按回车返回菜单' | Out-Null }
function Today-Str { return (Get-Date -Format 'yyyy-MM-dd') }
function Count-Jpg([string]$dir) { return (Get-ChildItem $dir -Recurse -Filter *.jpg -ErrorAction SilentlyContinue | Measure-Object).Count }
function Left-Queue($s) { return @($s.queue | Where-Object { $_ }).Count }

# ---------- [4] 浏览两个库 (必应 + 聚焦, 按时间合并取最近 40 张) ----------
function Show-BrowseAll {
  $c = Get-BwConfig
  $files = @()
  foreach ($pair in @(@('必应', $c.bing_save_dir), @('聚焦', $c.spotlight_save_dir))) {
    $files += @(Get-ChildItem $pair[1] -Recurse -Filter *.jpg -ErrorAction SilentlyContinue |
      ForEach-Object { [psobject]@{ src = $pair[0]; file = $_ } })
  }
  $files = @($files | Sort-Object { $_.file.LastWriteTime } -Descending | Select-Object -First 40)
  if ($files.Count -eq 0) { Write-Host '  两个壁纸库都是空的'; return }
  Write-Host ('  —— 壁纸库 (最近 ' + $files.Count + ' 张, [必应]/[聚焦] 标来源) ——')
  $i = 0
  foreach ($f in $files) { Write-Host ("  [$i] [$($f.src)] $($f.file.Name)"); $i++ }
  $sel = Read-Host '  输入序号设为壁纸 (回车返回)'
  if ($sel -eq '') { return }
  try {
    $p = $files[[int]$sel].file.FullName
    $ok = Set-BwDesktopWallpaper $p
    Write-Host ('  已设为壁纸 (ok=' + $ok + '): ' + (Split-Path $p -Leaf))
    Log ('手动浏览设壁纸: ' + $p)
  } catch { Write-Host '  序号无效' }
}

# ---------- [3] 下载往期必应归档 (niumoo/bing-wallpaper, 2021-02 至今 4K) ----------
function Show-Archive {
  Write-Host '  归档范围: 2021-02 至今 (开源仓库 niumoo/bing-wallpaper, 4K UHD)'
  $ym = Read-Host '  输入年-月 (如 2024-08), 回车返回'
  if ($ym -eq 'r' -or $ym -eq '') { return }
  $items = Get-BwMonthItems $ym
  if (-not $items -or $items.Count -eq 0) { Write-Host '  未取到清单或该月不存在'; Pause-Bw; return }
  $items | ForEach-Object { Write-Host ("    $($_.date)  $($_.code)") }
  Write-Host '  [1] 批量下载本月全部   [2] 单张设为壁纸   [3] 单张仅保存   [0] 返回'
  $k = Read-Host '  选择'
  if ($k -eq '1') { Invoke-BwArchiveBatch $ym; Pause-Bw }
  elseif ($k -eq '2' -or $k -eq '3') {
    $d = Read-Host '  输入日期 (如 2024-08-15)'
    Invoke-BwArchiveSingle $ym $d ($k -eq '2'); Pause-Bw
  }
}

# ---------- [1] 立即换一张聚焦 ----------
function Invoke-BwManualSwap {
  $s = Get-BwState
  if ($s.last_bing_date -ne (Today-Str)) {
    $s.last_bing_date = (Today-Str)
    Write-Host '  (顺手记下今天必应已切, 免得下次进桌面又插一张必应)'
  }
  Invoke-BwSwap $s (Get-Date) '手动: 立刻换一张' | Out-Null
  Save-BwState $s
  if ($s.last_wall) { Write-Host ('  已更换: ' + (Split-Path $s.last_wall -Leaf)) }
}

# ---------- [6] 刷新下载一批新聚焦, 立刻排进队列 ----------
function Invoke-BwRefill {
  $c = Get-BwConfig
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

# ---------- [7] 设置 (间隔 / 每轮张数 / 两个库位置, 一次问完, 回车跳过) ----------
function Edit-BwSettings {
  $c = Get-BwConfig
  $m = Read-Host ('  换图间隔分钟 (现在 ' + $c.cycle_minutes + ', 回车不变)')
  if ($m -match '^\d+$' -and [int]$m -gt 0) { $c.cycle_minutes = [int]$m }
  $n = Read-Host ('  每轮下载张数 (现在 ' + $c.spotlight_per_cycle + ', 回车不变)')
  if ($n -match '^\d+$' -and [int]$n -gt 0) { $c.spotlight_per_cycle = [int]$n }
  $b = Read-Host ('  必应库位置 (现在 ' + $c.bing_save_dir + ', 回车不变)')
  if ($b -and ((Split-Path $b -Qualifier) -ne 'C:')) {
    New-Item $b -ItemType Directory -Force | Out-Null
    $c.bing_save_dir = $b
  } elseif ($b) { Write-Host '  必应库位置无效 (不能是 C 盘), 保持不变' }
  $d = Read-Host ('  聚焦库位置 (现在 ' + $c.spotlight_save_dir + ', 回车不变)')
  if ($d -and ((Split-Path $d -Qualifier) -ne 'C:')) {
    New-Item $d -ItemType Directory -Force | Out-Null
    $c.spotlight_save_dir = $d
  } elseif ($d) { Write-Host '  聚焦库位置无效 (不能是 C 盘), 保持不变' }
  Save-BwConfig $c
  $s = Get-BwState
  $s.queue = @(Get-BwFreshQueue $s)   # 位置或张数变了, 重洗队列
  Save-BwState $s
  Write-Host '  已保存'
}

# ---------- 主菜单 (单层, 8 项直达) ----------
do {
  $c0 = Get-BwConfig
  $s0 = Get-BwState
  Clear-Host
  Write-Host '========== 微软壁纸助手 v1.1.0 ==========' -ForegroundColor Cyan
  # 一行状态
  $bingDone = '待切'
  if ($s0.last_bing_date -eq (Today-Str)) { $bingDone = '已切' }
  $last = Get-BwTime $s0.last_swap
  $next = '首次运行后确定'
  if ($last) { $next = $last.AddMinutes([int]$c0.cycle_minutes).ToString('HH:mm') }
  $cur = ''
  if ($s0.last_wall) { $cur = ' · 当前: ' + (Split-Path $s0.last_wall -Leaf) }
  Write-Host (' 必应今日: ' + $bingDone + ' · 聚焦 ' + (Count-Jpg $c0.spotlight_save_dir) + ' 张 · 队列剩 ' + (Left-Queue $s0) + ' 张 · 下次自动换 ' + $next) -ForegroundColor DarkGray
  if ($cur) { Write-Host $cur -ForegroundColor DarkGray }
  Write-Host ''
  Write-Host ' [1] 立即换一张聚焦'
  Write-Host ' [2] 检测并更换今日必应图'
  Write-Host ' [3] 下载往期必应 (2021至今 4K)'
  Write-Host ' [4] 浏览壁纸库, 选一张设为壁纸'
  Write-Host ' [5] 随机回忆 (两个库随机一张)'
  Write-Host ' [6] 刷新下载一批新聚焦'
  Write-Host ' [7] 设置 (间隔/每轮张数/库位置)'
  Write-Host ' [8] 查看运行日志'
  Write-Host ' [0] 退出'
  $k = Read-Host '请选择'
  switch ($k) {
    '1' { Invoke-BwManualSwap; Pause-Bw }
    '2' { Invoke-BwUpdate; Pause-Bw }
    '3' { Show-Archive }
    '4' { Show-BrowseAll; Pause-Bw }
    '5' { Invoke-BwRandom; Pause-Bw }
    '6' { Invoke-BwRefill; Pause-Bw }
    '7' { Edit-BwSettings; Pause-Bw }
    '8' { Get-Content $global:BWLog -Tail 40 -Encoding UTF8 -ErrorAction SilentlyContinue; Pause-Bw }
  }
} while ($k -ne '0')
