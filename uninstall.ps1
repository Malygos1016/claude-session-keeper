<#
  uninstall.ps1 —— 卸载 claude-session-keeper（与 install 对应）。
    - 从 pwsh7 和 5.1 两个 $PROFILE 移除 ccr 标记块
    - 删桌面快捷方式
    - 注销计划任务 + 删登录启动项 VBS
    - -Purge：连脚本目录和存档一起删
  用法: pwsh -NoProfile -ExecutionPolicy Bypass -File uninstall.ps1 [-Purge]
#>
[CmdletBinding()]
param([switch]$Purge, [string]$Dir = (Split-Path $PSCommandPath -Parent))
$ErrorActionPreference = 'Continue'
Write-Host "== 卸载 claude-session-keeper ==" -ForegroundColor Cyan

# 1) 两个 profile 的标记块
$s = '# >>> claude-session-keeper >>>'; $e = '# <<< claude-session-keeper <<<'
$profiles = @($PROFILE, ($PROFILE -replace '\\PowerShell\\', '\WindowsPowerShell\')) | Select-Object -Unique
foreach ($pf in $profiles) {
  if (Test-Path -LiteralPath $pf) {
    $c = Get-Content -LiteralPath $pf -Raw
    if ($c.Contains($s) -and $c.Contains($e)) {
      $c = ($c.Substring(0, $c.IndexOf($s)) + $c.Substring($c.IndexOf($e) + $e.Length)).TrimEnd() + "`r`n"
      Set-Content -LiteralPath $pf -Value $c -Encoding utf8
      Write-Host "  [OK] 移除 ccr 别名: $pf" -ForegroundColor Green
    }
  }
}

# 2) 桌面快捷方式
$lnk = Join-Path ([Environment]::GetFolderPath('Desktop')) '恢复Claude会话.lnk'
if (Test-Path -LiteralPath $lnk) { Remove-Item -LiteralPath $lnk -Force; Write-Host "  [OK] 删快捷方式" -ForegroundColor Green }

# 3) 计划任务 + 启动项
if (Get-ScheduledTask -TaskName 'ClaudeSessionKeeper-Snapshot' -EA SilentlyContinue) {
  Unregister-ScheduledTask -TaskName 'ClaudeSessionKeeper-Snapshot' -Confirm:$false
  Write-Host "  [OK] 注销计划任务" -ForegroundColor Green
}
$vbs = Join-Path ([Environment]::GetFolderPath('Startup')) 'ClaudeSessionKeeper.vbs'
if (Test-Path -LiteralPath $vbs) { Remove-Item -LiteralPath $vbs -Force; Write-Host "  [OK] 删登录启动项" -ForegroundColor Green }
Get-CimInstance Win32_Process -Filter "Name='pwsh.exe'" -EA SilentlyContinue |
  Where-Object { $_.CommandLine -match 'snapshot-loop\.ps1' } |
  ForEach-Object { Stop-Process -Id $_.ProcessId -Force -EA SilentlyContinue }

# 4) -Purge 删目录
if ($Purge) {
  Write-Host "  [!] -Purge：删除脚本目录与存档 $Dir" -ForegroundColor Yellow
  Set-Location $env:USERPROFILE
  Remove-Item -LiteralPath $Dir -Recurse -Force -EA SilentlyContinue
}
Write-Host "`n完成。已开着的窗口不受影响（ccr 别名要重开终端才失效）。" -ForegroundColor Cyan
