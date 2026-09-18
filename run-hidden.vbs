' run-hidden.vbs - launch core.ps1 with NO console window flash.
' The scheduled task runs this via wscript.exe (which has no console),
' so powershell.exe stays hidden from the very first millisecond.
' Path is derived from this script's own location - pure ASCII, no hardcoded paths.
Dim fso, sh, dir, cmd
Set fso = CreateObject("Scripting.FileSystemObject")
Set sh = CreateObject("WScript.Shell")
dir = fso.GetParentFolderName(WScript.ScriptFullName)
cmd = "powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File """ & dir & "\core.ps1"" -Cycle"
sh.Run cmd, 0, False
