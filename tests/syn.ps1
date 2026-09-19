$p = 'F:\wp-src\tests\syn_out.txt'
Set-Content -LiteralPath $p -Value @('start') -Encoding UTF8
try {
  Add-Content -LiteralPath $p -Value ('PSVersion ' + $PSVersionTable.PSVersion.ToString()) -Encoding UTF8
  Add-Content -LiteralPath $p -Value ('LanguageMode ' + $ExecutionContext.SessionState.LanguageMode) -Encoding UTF8
  foreach ($f in @('F:\wp-src\core.ps1', 'F:\wp-src\menu.ps1')) {
    $t = $null
    $e = $null
    $null = [System.Management.Automation.Language.Parser]::ParseFile($f, [ref]$t, [ref]$e)
    if ($e -and ($e.Count -gt 0)) {
      Add-Content -LiteralPath $p -Value ('ERR ' + $f + ' count=' + $e.Count) -Encoding UTF8
      foreach ($x in $e) { Add-Content -LiteralPath $p -Value ('    ' + $x.Message) -Encoding UTF8 }
    } else {
      Add-Content -LiteralPath $p -Value ('OK  ' + $f) -Encoding UTF8
    }
  }
} catch {
  Add-Content -LiteralPath $p -Value ('EXC ' + $_.Exception.Message) -Encoding UTF8
}
