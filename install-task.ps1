# install-task.ps1 - (re)register the MSWallpaperDaily scheduled task.
#
# The task starts run-hidden.vbs through wscript.exe.  wscript.exe is a GUI
# subsystem binary (no console is ever allocated), and the VBS launches
# powershell with window style 0, so the wallpaper cycle runs with NO black
# window flash.  (Verified: powershell.exe = CONSOLE subsystem -> flashes;
# wscript.exe = GUI subsystem -> cannot flash.)
#
# Usage (normal user works; run once from an ELEVATED terminal if you get
# "Access is denied" - the task itself still runs at least privilege):
#     powershell -ExecutionPolicy Bypass -File install-task.ps1
#
# Roll back to the old flashing action:
#     $a = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument '-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "D:\微软壁纸助手\core.ps1" -Cycle'
#     Set-ScheduledTask -TaskName MSWallpaperDaily -Action $a

$name = 'MSWallpaperDaily'
$dir  = Split-Path -Parent $MyInvocation.MyCommand.Path
$vbs  = Join-Path $dir 'run-hidden.vbs'
$core = Join-Path $dir 'core.ps1'

$fatal = $false
if (-not (Test-Path $vbs))  { Write-Host "MISSING: run-hidden.vbs next to this script ($dir)"; $fatal = $true }
if (-not (Test-Path $core)) { Write-Host "MISSING: core.ps1 next to this script ($dir)";          $fatal = $true }
if ($fatal) { exit 1 }

# show what we are replacing (rollback aid)
$old = (Get-ScheduledTask -TaskName $name -ErrorAction SilentlyContinue).Actions[0]
if ($old) { Write-Host ("Old action: {0} {1}" -f $old.Execute, $old.Arguments) }

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
  Write-Host ("FAILED: " + $_.Exception.Message)
  Write-Host "Tip: run this script once from an elevated terminal (Run as administrator)."
  exit 2
}

$t = Get-ScheduledTask -TaskName $name
Write-Host ("OK  task={0}  state={1}  triggers={2}" -f $t.TaskName, $t.State, @($t.Triggers).Count)
Write-Host ("    action: {0} {1}" -f $t.Actions[0].Execute, $t.Actions[0].Arguments)
Write-Host "    test now:  Start-ScheduledTask -TaskName $name"
Write-Host "    after moving this folder, run this script again to fix the path."
