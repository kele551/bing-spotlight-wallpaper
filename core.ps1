# 微软壁纸助手 - 核心库 (by 海风 & Cindy)
param([switch]$Update, [switch]$Cycle, [switch]$DryRun)
$global:BWRoot = $PSScriptRoot
$global:CfgPath = Join-Path $global:BWRoot 'config.json'
$global:BWLog = Join-Path $global:BWRoot 'wallpaper.log'
$global:BWState = Join-Path $global:BWRoot 'state.json'
$global:BWDry = [bool]$DryRun
$ProgressPreference = 'SilentlyContinue'
function Log([string]$m) {
  Add-Content -Path $global:BWLog -Value ('{0}  {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $m) -Encoding UTF8
  $fi = Get-Item $global:BWLog -ErrorAction SilentlyContinue
  if ($fi -and $fi.Length -gt 256KB) { Set-Content -Path $global:BWLog -Value (Get-Content $global:BWLog -Tail 200 -Encoding UTF8) -Encoding UTF8 }
}
function Get-BwConfig {
  $c = $null
  if (Test-Path $global:CfgPath) { try { $c = Get-Content $global:CfgPath -Raw -Encoding UTF8 | ConvertFrom-Json } catch {} }
  if (-not $c) {
    $c = New-Object PSObject
    Add-Member -InputObject $c NoteProperty bing_save_dir 'D:\Bing壁纸' -Force
    Add-Member -InputObject $c NoteProperty spotlight_save_dir 'D:\聚焦壁纸' -Force
    Add-Member -InputObject $c NoteProperty resolution_mode 'uhd' -Force
  }
  if (-not $c.spotlight_save_dir) {
    $q = if ($c.bing_save_dir) { Split-Path $c.bing_save_dir -Qualifier } else { 'D:' }
    Add-Member -InputObject $c NoteProperty spotlight_save_dir "$q\聚焦壁纸" -Force
  }
  if (-not $c.resolution_mode) { Add-Member -InputObject $c NoteProperty resolution_mode 'uhd' -Force }
  if (-not $c.spotlight_per_cycle) { Add-Member -InputObject $c NoteProperty spotlight_per_cycle 6 -Force }
  if (-not $c.cycle_minutes) { Add-Member -InputObject $c NoteProperty cycle_minutes 30 -Force }
  return $c
}
function Save-BwConfig([psobject]$c) {
  [System.IO.File]::WriteAllText($global:CfgPath, ($c | ConvertTo-Json), (New-Object System.Text.UTF8Encoding($false)))
}
# ---- 自动轮换进度 (state.json): 计划任务每次是独立进程, 靠这个文件把节奏串起来 ----
# 只记三件事: 今天切过必应没有 / 上次换壁纸是什么时候 / 上次开机时间。
# 聚焦的"不重复"靠 queue —— 把库里所有图洗一次牌按顺序发, 发完再下载 6 张重洗一轮。
function Get-BwState {
  $existed = Test-Path -LiteralPath $global:BWState
  $s = $null
  if ($existed) {
    try { $s = Get-Content $global:BWState -Raw -Encoding UTF8 | ConvertFrom-Json } catch {}
  }
  $ver = 0
  if ($s) { try { $ver = [int]$s.schema } catch { $ver = 0 } }
  if ($ver -ne 3) {
    if ($existed) { Log ('节奏进度文件版本 ' + $ver + ' -> 3, 已重置 (下一次运行会重新切一次必应当日图)') }
    $s = New-Object PSObject
  }
  $def = [ordered]@{
    schema = 3; last_bing_date = ''; last_swap = ''; last_boot = ''
    queue = @(); refills = 0; shown = 0; last_wall = ''
  }
  foreach ($k in $def.Keys) {
    $p = $s.PSObject.Properties[$k]
    if ((-not $p) -or ($null -eq $p.Value)) { Add-Member -InputObject $s NoteProperty $k $def[$k] -Force }
  }
  return $s
}
function Save-BwState($s) {
  $s.queue = @($s.queue | Where-Object { $_ })
  [System.IO.File]::WriteAllText($global:BWState, ($s | ConvertTo-Json -Depth 5), (New-Object System.Text.UTF8Encoding($false)))
}
function Get-BwTime([string]$t) {
  try { return [DateTime]::ParseExact($t, 'yyyy-MM-dd HH:mm:ss', [System.Globalization.CultureInfo]::InvariantCulture) } catch { return $null }
}
function Set-BwWall([string]$path) {
  # 已经是这张就不重复调 API, 少一次桌面重绘
  if (-not (Test-Path -LiteralPath $path)) { return $false }
  if ($global:BWDry) { Log ('试运行: 本应设为壁纸 -> ' + $path); return $true }
  $cur = (Get-ItemProperty 'HKCU:\Control Panel\Desktop' -ErrorAction SilentlyContinue).Wallpaper
  if ($cur -and ($cur -eq $path)) { return $true }
  return (Set-BwDesktopWallpaper $path)
}
# ---- 聚焦库 ----
# 一律返回"普通数组"。不要写 `return ,@(...)` —— 它在 @(f).Count / f | Where-Object
# 下会把整个数组当成一个元素, 导致"库里有 60 张"被看成"1 张"、过滤整个失效。
function Get-BwSpotlightAll {
  $c = Get-BwConfig
  return @(Get-ChildItem $c.spotlight_save_dir -Filter *.jpg -ErrorAction SilentlyContinue)
}
function Get-BwSpotlightWant {
  $c = Get-BwConfig
  if ($c.spotlight_per_cycle) { return [int]$c.spotlight_per_cycle }
  return 6
}
# 把库里所有图洗一次牌。"不重复"由此天然成立, 不必另存一份"已看过"名单。
function Get-BwFreshQueue {
  $names = @()
  foreach ($f in @(Get-BwSpotlightAll)) { $names += [string]$f.Name }
  if ($names.Count -eq 0) { return @() }
  return @($names | Sort-Object { Get-Random })
}
# 取队列里下一张。队列空了(或剩下的图被手动删了) -> 下载一批新的重洗。
# 好处: 洗牌后的队列总有图可取, 所以不需要"抓不到新图就清空历史"那种兜底分支,
# 也就不会有"挑不出图 -> 永远不换壁纸"的死局。
function Get-BwNextWall($s) {
  $c = Get-BwConfig
  for ($round = 1; $round -le 2; $round++) {
    $q = @($s.queue | Where-Object { $_ })
    while ($q.Count -gt 0) {
      $name = [string]$q[0]
      $q = @($q | Select-Object -Skip 1)
      $p = Join-Path $c.spotlight_save_dir $name
      if (Test-Path -LiteralPath $p) { $s.queue = $q; return (Get-Item -LiteralPath $p) }
      # 这张被删了, 丢掉接着取下一张
    }
    $s.queue = @()
    $want = Get-BwSpotlightWant
    Log ('队列已空 (库中现有 ' + @(Get-BwSpotlightAll).Count + ' 张), 刷新下载 ' + $want + ' 张后重洗')
    if ($global:BWDry) { Log ('试运行: 本应刷新下载 ' + $want + ' 张聚焦壁纸') }
    else { Invoke-SpotlightFetch -count $want -Quiet | Out-Null }
    $s.refills = [int]$s.refills + 1
    $s.queue = @(Get-BwFreshQueue $s)
    if (@($s.queue).Count -eq 0) { return $null }
  }
  return $null
}
# 换一张聚焦壁纸并记账。返回是否成功。
function Invoke-BwSwap($s, [DateTime]$now, [string]$why) {
  $f = Get-BwNextWall $s
  if (-not $f) { Log ($why + ': 取不到聚焦图 (库是空的且下载失败), 稍后重试'); return $false }
  $ok = Set-BwWall $f.FullName
  $s.last_wall = $f.FullName
  $s.shown = [int]$s.shown + 1
  $s.last_swap = $now.ToString('yyyy-MM-dd HH:mm:ss')
  Log ($why + ' -> ' + $f.Name + ' (ok=' + $ok + '; 队列还剩 ' + @($s.queue | Where-Object { $_ }).Count + ' 张)')
  return $true
}
function Get-BwMeta([int]$idx) {
  [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
  for ($i = 1; $i -le 3; $i++) {
    try { return (Invoke-RestMethod -Uri "https://cn.bing.com/HPImageArchive.aspx?format=js&idx=$idx&n=1&mkt=zh-cn" -TimeoutSec 20 -UseBasicParsing).images[0] }
    catch { Start-Sleep -Seconds 5 }
  }
  return $null
}
function Get-BwDisplayDate($meta) {
  # 官方字段: enddate=这张图展示到哪天 (就是"今天是哪张"), startdate=开始展示的日期。
  # 别用 fullstartdate: 接口给的是 12 位 yyyyMMddHHmm (没有秒), 老代码按 14 位
  # yyyyMMddHHmmss 去 ParseExact, 每次必然抛异常 -> 掉进兜底分支返回"今天"。
  # 结果就是日期永远等于下载当天, 补漏时永远对不上目标日期。
  # 只取前 8 位当 yyyyMMdd, 稳。
  foreach ($cand in @($meta.enddate, $meta.startdate)) {
    $s = [string]$cand
    if ($s.Length -lt 8) { continue }
    $d = $null
    try { $d = [DateTime]::ParseExact($s.Substring(0, 8), 'yyyyMMdd', [System.Globalization.CultureInfo]::InvariantCulture) } catch {}
    if ($d) { return $d.ToString('yyyy-MM-dd') }
  }
  return (Get-Date -Format 'yyyy-MM-dd')
}
function Get-BwName($meta) {
  $titlePart = ($meta.copyright -replace '\s*[(（]©.*$','') -replace '[，,]','_'
  $n = ('{0}_{1}_{2}.jpg' -f (Get-BwDisplayDate $meta), $meta.title, $titlePart)
  return ($n -replace '[\\/:*?\"<>| ]','')
}
function Get-BwCandidates($meta, $mode) {
  $ub = "https://cn.bing.com$($meta.urlbase)"
  $suf = @()
  if ($mode -eq 'auto') {
    try {
      Add-Type -AssemblyName System.Windows.Forms
      $b = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds
      if ($b.Width -ge 3840) { $suf += '_UHD' }
      elseif ($b.Height -ge 1200) { $suf += '_1920x1200'; $suf += '_UHD' }
      elseif ($b.Width -ge 1920) { $suf += '_1920x1080'; $suf += '_1920x1200'; $suf += '_UHD' }
      else { $suf += '_1366x768'; $suf += '_1920x1080'; $suf += '_UHD' }
    } catch { $suf = @('_UHD') }
  } else { $suf = @('_UHD') }
  $suf += '_1920x1080'
  $urls = @($suf | Select-Object -Unique | ForEach-Object { "$ub$_.jpg" })
  $urls += "$ub.jpg"
  return ,$urls
}
function Get-BwTargetPath([string]$date, [string]$name) {
  $c = Get-BwConfig
  return (Join-Path $c.bing_save_dir $name)
}
function Set-BwDesktopWallpaper([string]$path) {
  if (-not ('WinWall' -as [type])) {
    Add-Type -TypeDefinition 'using System; using System.Runtime.InteropServices; public class WinWall { [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern bool SystemParametersInfo(uint a, uint p, string v, uint f); }'
  }
  Set-ItemProperty 'HKCU:\Control Panel\Desktop' -Name WallpaperStyle -Value 10
  Set-ItemProperty 'HKCU:\Control Panel\Desktop' -Name TileWallpaper -Value 0
  return [WinWall]::SystemParametersInfo(0x0014, 0, $path, 3)
}
function Save-BwFile([string[]]$urls, [string]$path) {
  foreach ($u in $urls) {
    try {
      Invoke-WebRequest -Uri $u -OutFile $path -TimeoutSec 300 -UseBasicParsing
      if ((Get-Item $path -ErrorAction SilentlyContinue).Length -gt 100KB) {
        Add-Type -AssemblyName System.Drawing
        $im = [System.Drawing.Image]::FromFile($path); $dim = "$($im.Width)x$($im.Height)"; $im.Dispose()
        Log "下载成功: $(Split-Path $path -Leaf) ($dim)"
        return $true
      }
      if (Test-Path $path) { Remove-Item $path -Force }
    } catch { Log ('下载失败: ' + $_.Exception.Message) }
  }
  return $false
}# ---- 归档源: niumoo/bing-wallpaper (2021-02 至今, 4K UHD, 用户要求批量下载近几年壁纸) ----
function Get-BwRawUrls([string]$rawPath) {
  $p = "https://raw.githubusercontent.com/$rawPath"
  return @("https://ghfast.top/$p", "https://gh-proxy.com/$p", $p)
}
function Get-BwMonthItems([string]$ym) {
  $items = @(); $md = $null
  foreach ($u in (Get-BwRawUrls "niumoo/bing-wallpaper/master/picture/$ym/README.md")) {
    try { $md = (Invoke-WebRequest -Uri $u -TimeoutSec 60 -UseBasicParsing).Content; if ($md) { break } } catch {}
  }
  if (-not $md) { return $null }
  foreach ($m in [regex]::Matches($md, '(\d{4}-\d{2}-\d{2}) \[download 4k\]\((https://cn\.bing\.com/th\?id=[^)]+)\)')) {
    $code = [regex]::Match($m.Groups[2].Value, 'OHR\.([A-Za-z0-9]+)_').Groups[1].Value
    $items += [psobject]@{ date = $m.Groups[1].Value; code = $code; url = $m.Groups[2].Value }
  }
  return $items
}
function Get-BwMonthName($item) { '{0}_{1}.jpg' -f $item.date, $item.code }
function Invoke-BwArchiveBatch([string]$ym) {
  $items = Get-BwMonthItems $ym
  if (-not $items -or $items.Count -eq 0) { Write-Host ('  未取到 ' + $ym + ' 的清单(检查网络)'); return }
  Write-Host ('  共 ' + $items.Count + ' 张, 开始批量下载(跳过已有)...')
  $ok = 0; $skip = 0; $fail = 0
  foreach ($it in $items) {
    $path = Get-BwTargetPath $it.date (Get-BwMonthName $it)
    if (Test-Path $path) { $skip++; continue }
    $dir = Split-Path $path -Parent
    if (-not (Test-Path $dir)) { New-Item $dir -ItemType Directory -Force | Out-Null }
    if (Save-BwFile @($it.url) $path) { $ok++ } else { $fail++ }
    Start-Sleep -Milliseconds 400
  }
  Write-Host ('  完成: 成功 ' + $ok + ', 跳过 ' + $skip + ', 失败 ' + $fail)
  Log ("归档批量 $ym : 成功$ok 跳过$skip 失败$fail")
}
function Invoke-BwArchiveSingle([string]$ym, [string]$date, [switch]$SetWall) {
  $items = Get-BwMonthItems $ym
  $it = $items | Where-Object { $_.date -eq $date } | Select-Object -First 1
  if (-not $it) { Write-Host '  该日期不存在于当月清单'; return }
  $path = Get-BwTargetPath $it.date (Get-BwMonthName $it)
  $dir = Split-Path $path -Parent
  if (-not (Test-Path $dir)) { New-Item $dir -ItemType Directory -Force | Out-Null }
  if (-not (Test-Path $path)) { if (-not (Save-BwFile @($it.url) $path)) { Write-Host '  下载失败'; return } }
  if ($SetWall) { $ok = Set-BwDesktopWallpaper $path; Write-Host ("  已设为壁纸: ok=$ok") } else { Write-Host ("  已保存: $path") }
}
function Invoke-BwRandom {
  $c = Get-BwConfig
  $all = @(Get-ChildItem $c.bing_save_dir -Recurse -Filter *.jpg -ErrorAction SilentlyContinue) +
         @(Get-ChildItem $c.spotlight_save_dir -Recurse -Filter *.jpg -ErrorAction SilentlyContinue)
  if ($all.Count -eq 0) { Write-Host '  两个壁纸库都是空的'; return }
  $f = $all | Get-Random -Count 1
  $ok = Set-BwDesktopWallpaper $f.FullName
  Write-Host ("  已随机设置: $($f.Name) (ok=$ok)")
  Log "随机回忆: $($f.FullName)"
}
# ---- 补漏: 几天没开机, 错过的必应壁纸一张不少 ----
# 原理: 必应库文件名都以日期开头。找出库里最新的日期, 它和昨天之间缺的日子全部补下载。
# 近 7 天的缺口走必应官方接口 (idx=相差天数); 更早的走 niumoo 归档源。
# 只下载不切壁纸; 文件在就跳过, 幂等, 补完之后每次自检秒过。
function Get-BwLatestDate([string]$dir) {
  $latest = $null
  foreach ($f in @(Get-ChildItem $dir -Filter *.jpg -ErrorAction SilentlyContinue)) {
    if ($f.Name -match '^(\d{4}-\d{2}-\d{2})') {
      $d = $null
      try { $d = [DateTime]::ParseExact($Matches[1], 'yyyy-MM-dd', [System.Globalization.CultureInfo]::InvariantCulture) } catch {}
      if ($d -and (($null -eq $latest) -or ($d -gt $latest))) { $latest = $d }
    }
  }
  return $latest
}
function Invoke-BwBackfill {
  $c = Get-BwConfig
  $today = Get-Date
  $latest = Get-BwLatestDate $c.bing_save_dir
  if (-not $latest) { return }
  $first = $latest.AddDays(1)
  $yesterday = $today.AddDays(-1)
  $missing = @()
  for ($d = $first; $d.Date -le $yesterday.Date; $d = $d.AddDays(1)) { $missing += $d.Date }
  if ($missing.Count -eq 0) { return }
  $monthCache = @{}
  $ok = 0; $skip = 0; $fail = 0
  foreach ($day in $missing) {
    $daysAgo = ($today.Date - $day).Days
    $path = $null; $urls = $null
    if ($daysAgo -le 7) {
      $meta = Get-BwMeta $daysAgo
      $bday = ''
      if ($meta) { $bday = Get-BwDisplayDate $meta }
      if ($bday -ne $day.ToString('yyyy-MM-dd')) { $fail++; continue }
      $path = Get-BwTargetPath $bday (Get-BwName $meta)
      $urls = Get-BwCandidates $meta ($c.resolution_mode)
    } else {
      $ym = $day.ToString('yyyy-MM')
      if (-not $monthCache.ContainsKey($ym)) { $monthCache[$ym] = (Get-BwMonthItems $ym) }
      $it = $null
      $items = $monthCache[$ym]
      if ($items) { $it = @($items | Where-Object { $_.date -eq $day.ToString('yyyy-MM-dd') })[0] }
      if (-not $it) { $fail++; continue }
      $path = Get-BwTargetPath $it.date (Get-BwMonthName $it)
      $urls = @($it.url)
    }
    if (Test-Path -LiteralPath $path) { $skip++; continue }
    if (Save-BwFile $urls $path) { $ok++ } else { $fail++ }
    Start-Sleep -Milliseconds 400
  }
  if (($ok + $skip + $fail) -gt 0) {
    Log ('补漏 ' + $missing[0].ToString('yyyy-MM-dd') + ' ~ ' + $missing[$missing.Count - 1].ToString('yyyy-MM-dd') + ': 新增 ' + $ok + ' 已有 ' + $skip + ' 失败 ' + $fail)
  }
}
# ---- Windows 聚焦图源 (微软官方桌面聚焦, 3840x2160, 与 Bing 壁纸同一壁纸团队) ----
function Get-SpotlightOne {
  # 单次请求 -> @{title,url,copyright,slug,id}; 失败返回 $null
  [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
  $ua = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36'
  $u = 'https://fd.api.iris.microsoft.com/v4/api/selection?placement=88000820&aid=1195280&country=cn&locale=zh-CN&fmt=json'
  try { $j = Invoke-RestMethod -Uri $u -UserAgent $ua -TimeoutSec 20 -UseBasicParsing } catch { return $null }
  $ad = $j.ad
  if (-not $ad) { return $null }
  $img = $ad.landscapeImage.asset
  if (-not $img) { return $null }
  $parts = (($img -split '/')[-1]) -split '_'
  $id = $parts[0]
  $slug = ''
  for ($i = 0; $i -lt ($parts.Count - 1); $i++) {
    if ($parts[$i] -eq 'ds') { $slug = $parts[$i + 1]; break }
  }
  if (-not $slug) { $slug = $id.Substring(0, 8) }
  $title = $ad.title
  if (-not $title) { $title = 'Spotlight' }
  return [psobject]@{ title = $title; url = $img; copyright = $ad.copyright; slug = $slug; id = $id }
}
function Get-SpotlightName($it) {
  $t = ($it.title -replace '[\\/:*?"<>|\s？：＊＜＞｜]', '')
  if ($t.Length -gt 28) { $t = $t.Substring(0, 28) }
  return ('{0}_{1}_{2}.jpg' -f (Get-Date -Format 'yyyy-MM-dd'), $t, $it.slug)
}
function Test-SpotlightDup([string]$dir, $it) {
  if (-not (Test-Path $dir)) { return $false }
  if ($it.slug) {
    $hit = Get-ChildItem $dir -Filter "*_$($it.slug).jpg" -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($hit) { return $true }
  }
  return $false
}
function Invoke-SpotlightFetch([int]$count, [switch]$SetWall, [switch]$Quiet) {
  # 聚焦接口每次请求几乎都返回一张不同的图(实测 40 次 / 39 张唯一), 因此可批量刷。
  # 返回本次新增的文件全名数组, 调用方可以立刻把它们排进轮换队列。
  $c = Get-BwConfig
  $dir = $c.spotlight_save_dir
  if (-not (Test-Path $dir)) { New-Item $dir -ItemType Directory -Force | Out-Null }
  $ok = 0; $skip = 0; $fail = 0; $first = $null
  $newFiles = @()
  $tries = 0
  $maxTries = [Math]::Max($count * 5, 20)
  while ((($ok + $skip) -lt $count) -and ($tries -lt $maxTries)) {
    $tries++
    $it = Get-SpotlightOne
    if (-not $it) { Start-Sleep -Milliseconds 800; continue }
    if (Test-SpotlightDup $dir $it) {
      $skip++
      if (-not $first) { $first = (Get-ChildItem $dir -Filter "*_$($it.slug).jpg" -ErrorAction SilentlyContinue | Select-Object -First 1).FullName }
      Start-Sleep -Milliseconds 400
      continue
    }
    $path = Join-Path $dir (Get-SpotlightName $it)
    if (Save-BwFile @($it.url) $path) {
      $ok++
      $newFiles += $path
      if (-not $first) { $first = $path }
      if (-not $Quiet) { Write-Host ('    OK  ' + (Split-Path $path -Leaf)) }
    } else { $fail++ }
    Start-Sleep -Milliseconds 600
  }
  Write-Host ("  完成: 新增 $ok, 已存在 $skip, 失败 $fail")
  Log ("聚焦抓取: 新增$ok 跳过$skip 失败$fail")
  if ($SetWall -and $first) {
    $r = Set-BwDesktopWallpaper $first
    Write-Host ("  已设为壁纸 (ok=$r): " + (Split-Path $first -Leaf))
  }
  return $newFiles
}
# 浏览任意一个库, 选一张设为壁纸 (必应库 / 聚焦库共用)
function Show-Browse([string]$dir, [string]$title) {
  $files = @(Get-ChildItem $dir -Recurse -Filter *.jpg -ErrorAction SilentlyContinue | Sort-Object Name -Descending | Select-Object -First 40)
  if ($files.Count -eq 0) { Write-Host ('  ' + $title + '还是空的'); return }
  Write-Host ('  —— ' + $title + ' (最近 40 张) ——')
  $i = 0
  foreach ($f in $files) { Write-Host ("  [$i] $($f.Name)"); $i++ }
  $sel = Read-Host '  输入序号设为壁纸 (回车返回)'
  if ($sel -eq '') { return }
  try {
    $p = $files[[int]$sel].FullName
    $ok = Set-BwDesktopWallpaper $p
    Write-Host ("  已设为壁纸 (ok=$ok): " + (Split-Path $p -Leaf))
    Log ('手动浏览设壁纸: ' + $p)
  } catch { Write-Host '  序号无效' }
}
# ---- 巡检: 跟随官方更新节奏 (官方出了新图就下载并切换; 没出则秒退, 完全幂等) ----
function Invoke-BwUpdate {
  try {
    $c = Get-BwConfig
    $meta = $null
    for ($i = 1; $i -le 4; $i++) {
      $meta = Get-BwMeta 0
      if ($meta) { break }
      Log ("巡检: 网络未就绪, 第${i}次等待..."); Start-Sleep -Seconds 10
    }
    if (-not $meta) { Log '巡检: 元数据失败, 退出'; return }
    $name = Get-BwName $meta
    $path = Get-BwTargetPath (Get-BwDisplayDate $meta) $name
    $dir = Split-Path $path -Parent
    if (-not (Test-Path $dir)) { New-Item $dir -ItemType Directory -Force | Out-Null }
    if (-not (Test-Path $path)) {
      if (-not (Save-BwFile (Get-BwCandidates $meta ($c.resolution_mode)) $path)) { Log '巡检: 下载失败, 下次再试'; return }
      Log ('巡检: 官方已更新 -> ' + $name)
    }
    $cur = (Get-ItemProperty 'HKCU:\Control Panel\Desktop' -ErrorAction SilentlyContinue).Wallpaper
    if ($cur -eq $path) { return }
    $ok = Set-BwDesktopWallpaper $path
    Log ('巡检: 切换壁纸 ok=' + $ok + ' -> ' + $name)
  } catch { Log ('巡检异常: ' + $_.Exception.Message) }
}

# ==================== 自动轮换 ====================
# 三条规则 + 一个补漏, 装完不用管:
#   0) 补漏: 几天没开机, 错过的必应壁纸全部补下载 (只下载, 不切壁纸)
#   1) 每天第一次进入桌面 -> 换【必应当前官方图】, 顺手确认它在库里
#   2) 每次重启电脑       -> 立刻换一张【聚焦】(不重复)
#   3) 每 30 分钟         -> 换一张【聚焦】(不重复)
# 聚焦的"不重复"靠 queue: 库里所有图洗一次牌按顺序发, 发完自动再下载 6 张重洗一轮。
# 必应只在"每天第一次"出现, 所以手动换的壁纸不会被必应抢回去。
function Invoke-BwCycle {
  try {
    $c = Get-BwConfig
    $s = Get-BwState
    $now = Get-Date
    $today = $now.ToString('yyyy-MM-dd')
    $gap = 30
    if ($c.cycle_minutes) { $gap = [int]$c.cycle_minutes }

    $boot = ''
    try { $boot = (Get-CimInstance Win32_OperatingSystem -ErrorAction Stop).LastBootUpTime.ToString('yyyy-MM-dd HH:mm:ss') } catch {}
    $rebooted = [bool]($boot -and $s.last_boot -and ($s.last_boot -ne $boot))
    if ($boot) { $s.last_boot = $boot }
    $last = Get-BwTime $s.last_swap
    $due = $true
    if ($last) { $due = ((($now - $last).TotalMinutes) -ge $gap) }

    # ---- 补漏: 错过日子的必应壁纸 (只下载, 不切壁纸) ----
    Invoke-BwBackfill

    # ---- 规则 1: 每天第一次 -> 必应当日壁纸 ----
    # 拿不到元数据就不记账, 让下面的规则照常走, 15 分钟后自然再试一次 ——
    # 不会把整条节奏卡死在这一步, 也不会漏下载。
    if ($s.last_bing_date -ne $today) {
      $meta = $null
      for ($i = 1; $i -le 4; $i++) {
        $meta = Get-BwMeta 0
        if ($meta) { break }
        Log ("必应: 网络未就绪, 第${i}次等待..."); Start-Sleep -Seconds 10
      }
      $bday = ''
      if ($meta) { $bday = Get-BwDisplayDate $meta }
      # 不再要求"接口日期 == 今天": 必应下午 16:00 才发新图, 卡这个闸门会整天不切也不下载。
      # 现在只要拿到"官方当前这张"就入库并切换, 一张不漏。
      if ($meta) {
        $name = Get-BwName $meta
        $path = Get-BwTargetPath $bday $name
        $dir = Split-Path $path -Parent
        if (-not (Test-Path $dir)) { New-Item $dir -ItemType Directory -Force | Out-Null }
        if ($global:BWDry) {
          Log ('试运行: 本应换必应当日壁纸 -> ' + $name + ' (库中已存在=' + (Test-Path -LiteralPath $path) + ')')
        } else {
          if (-not (Test-Path -LiteralPath $path)) {
            if (-not (Save-BwFile (Get-BwCandidates $meta ($c.resolution_mode)) $path)) { $path = $null }
          }
          if ($path) {
            $ok = Set-BwWall $path
            $s.last_wall = $path
            Log ('今日首次 -> 必应当日壁纸 ' + $name + ' (ok=' + $ok + ')')
          } else { Log '必应当日壁纸下载失败, 15 分钟后再试' }
        }
        $s.last_bing_date = $today
        # 用"此刻"而不是进入本轮的时刻: 下载当天必应图可能花几分钟,
        # 时间戳要是记成开始时间, 下一次轮换就会提前触发。
        $s.last_swap = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
        Save-BwState $s
        return
      }
      Log '必应元数据取不到, 15 分钟后再试'
      # 故意不 return: 继续往下走, 免得整条节奏卡在这里
    }

    # ---- 规则 2: 重启电脑 -> 立刻换一张聚焦 ----
    if ($rebooted) {
      Invoke-BwSwap $s (Get-Date) '重启电脑进入桌面' | Out-Null
      Save-BwState $s
      return
    }

    # ---- 规则 3: 半小时到点 -> 换一张聚焦 ----
    if ($due) {
      Invoke-BwSwap $s (Get-Date) '半小时到点' | Out-Null
      Save-BwState $s
      return
    }

    # 未到点: 静默, 只把开机时间存下来
    Save-BwState $s
  } catch { Log ('轮换异常: ' + $_.Exception.Message) }
}
# 注意: -Update 与 -Cycle 走同一套逻辑。
# 老计划任务的动作是 -Update, 而改任务参数需要管理员权限; 让 -Update 也进新节奏,
# 就能零提权立刻生效。将来用 install-task.ps1 重装会写成 -Cycle。
if ($Cycle -or $Update) { Invoke-BwCycle }
