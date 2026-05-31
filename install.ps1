<#
  install.ps1 —— 幂等安装 claude-session-keeper，可反复运行。
    1) PowerShell $PROFILE 加 ccr 别名(重启后敲 ccr 一键恢复)
    2) 桌面快捷方式(双击恢复)
    3) 定时快照：优先计划任务每 N 分钟跑 snapshot.ps1；无权限则退回登录启动项(VBS, 免管理员)
  用法: pwsh -NoProfile -ExecutionPolicy Bypass -File install.ps1 [-IntervalMinutes 2] [-NoTask] [-NoShortcut] [-NoAlias]
#>
[CmdletBinding()]
param(
  [string]$Dir = (Split-Path $PSCommandPath -Parent),
  [int]   $IntervalMinutes = 2,
  [switch]$NoAlias, [switch]$NoShortcut, [switch]$NoTask
)
$ErrorActionPreference = 'Stop'
$restore  = Join-Path $Dir 'restore.ps1'
$snapshot = Join-Path $Dir 'snapshot.ps1'
$pwsh = "$env:ProgramFiles\PowerShell\7\pwsh.exe"
foreach ($f in @($restore, $snapshot)) { if (-not (Test-Path -LiteralPath $f)) { throw "缺少文件: $f" } }
Write-Host "== 安装 claude-session-keeper ==  目录: $Dir" -ForegroundColor Cyan

# --- 环境预检(只警告，不阻断) ---
if (-not (Test-Path -LiteralPath $pwsh)) {
  $alt = (Get-Command pwsh -EA SilentlyContinue).Source
  if ($alt) { $pwsh = $alt; Write-Host "  [i] 用到的 pwsh7: $pwsh" -ForegroundColor DarkGray }
  else { Write-Warning "  没装 PowerShell 7(pwsh)！restore.ps1 用了 PS7 语法，ccr 会跑不起来。请先装：winget install Microsoft.PowerShell" }
}
if (-not (Get-Command wt -EA SilentlyContinue)) { Write-Warning "  没装 Windows Terminal(wt)：恢复时会退回成『每会话一个独立窗口』，功能不受影响。" }
$claudeCmd = @("$env:APPDATA\npm\claude.cmd") | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
if (-not $claudeCmd -and -not (Get-Command claude.cmd -EA SilentlyContinue)) { Write-Warning "  没找到 claude.cmd：这台机器似乎还没装 Claude Code CLI，恢复会失败。" }

# 1) $PROFILE 别名(标记块幂等) —— 同时写 pwsh7 和 Windows PowerShell 5.1 两个 profile，
#    且 ccr 始终用 pwsh7 跑 restore.ps1(restore.ps1 用了 PS7 语法，不能在 5.1 里 in-process 跑)
if (-not $NoAlias) {
  $s = '# >>> claude-session-keeper >>>'; $e = '# <<< claude-session-keeper <<<'
  $body = @"
$s
function Resume-ClaudeSessions {
  param([Parameter(ValueFromRemainingArguments=`$true)] `$A)
  `$exe = "`$env:ProgramFiles\PowerShell\7\pwsh.exe"
  if (-not (Test-Path -LiteralPath `$exe)) { `$exe = (Get-Command pwsh -EA SilentlyContinue).Source }
  if (`$exe) { & `$exe -NoProfile -ExecutionPolicy Bypass -File '$restore' @A }
  else { & '$restore' @A }
}
Set-Alias ccr Resume-ClaudeSessions
$e
"@
  # pwsh7 的 $PROFILE 路径，以及把它换算成 5.1 的路径(对 Documents 重定向也稳)
  $targets = @($PROFILE)
  $p51 = $PROFILE -replace '\\PowerShell\\', '\WindowsPowerShell\'
  if ($p51 -ne $PROFILE) { $targets += $p51 }
  foreach ($pf in $targets) {
    $pdir = Split-Path $pf -Parent
    if (-not (Test-Path -LiteralPath $pdir)) { New-Item -ItemType Directory -Force -Path $pdir | Out-Null }
    if (-not (Test-Path -LiteralPath $pf)) { New-Item -ItemType File -Path $pf | Out-Null }
    $content = Get-Content -LiteralPath $pf -Raw -EA SilentlyContinue; if ($null -eq $content) { $content = '' }
    if ($content.Contains($s) -and $content.Contains($e)) {
      $content = $content.Substring(0, $content.IndexOf($s)) + $body.TrimEnd() + $content.Substring($content.IndexOf($e) + $e.Length)
    } else {
      if ($content -and -not $content.EndsWith("`n")) { $content += "`r`n" }
      $content += $body
    }
    Set-Content -LiteralPath $pf -Value $content -Encoding utf8
    Write-Host "  [OK] ccr 别名写入: $pf" -ForegroundColor Green
  }
}

# 2) 桌面快捷方式
if (-not $NoShortcut) {
  $lnk = Join-Path ([Environment]::GetFolderPath('Desktop')) '恢复Claude会话.lnk'
  $w = New-Object -ComObject WScript.Shell
  $sc = $w.CreateShortcut($lnk)
  $sc.TargetPath = $pwsh
  $sc.Arguments = '-NoProfile -ExecutionPolicy Bypass -File "' + $restore + '"'
  $sc.WorkingDirectory = $Dir
  $sc.IconLocation = "$env:LOCALAPPDATA\Microsoft\WindowsApps\wt.exe,0"
  $sc.Description = '重开关机/断电前还开着的 Claude Code 会话'
  $sc.Save()
  [Runtime.InteropServices.Marshal]::ReleaseComObject($w) | Out-Null
  Write-Host "  [OK] 桌面快捷方式: $lnk" -ForegroundColor Green
}

# 3) 定时快照
if (-not $NoTask) {
  $taskName = 'ClaudeSessionKeeper-Snapshot'; $taskOk = $false
  try {
    # 经 wscript 调 run-hidden.vbs 隐藏启动 pwsh —— 直接调 pwsh.exe(控制台程序)即使 Hidden 也会每次闪窗，
    # 用 vbs 的 WshShell.Run(...,0,...) 从源头不创建可见窗口，完全无感。
    $vbsRun = Join-Path $Dir 'run-hidden.vbs'
    $act = New-ScheduledTaskAction -Execute 'wscript.exe' -Argument ('"' + $vbsRun + '" "' + $pwsh + '" "' + $snapshot + '"')
    $repSpan = New-TimeSpan -Minutes $IntervalMinutes
    $durSpan = New-TimeSpan -Days 3650
    # 触发器1：每次登录后启动重复 —— 保证重启后续得上
    $trgLogon = New-ScheduledTaskTrigger -AtLogOn -User $env:USERNAME
    $trgLogon.Repetition = (New-ScheduledTaskTrigger -Once -At (Get-Date) -RepetitionInterval $repSpan -RepetitionDuration $durSpan).Repetition
    # 触发器2：时间触发锚定当天0点(明确的过去时刻)+重复 —— 不依赖登录，安装后立即稳定每N分钟跑，消除装好头几分钟的空档
    $trgTime = New-ScheduledTaskTrigger -Once -At (Get-Date).Date -RepetitionInterval $repSpan -RepetitionDuration $durSpan
    $set = New-ScheduledTaskSettingsSet -StartWhenAvailable -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Minutes 5) -Hidden
    $prin = New-ScheduledTaskPrincipal -UserId $env:USERNAME -LogonType Interactive -RunLevel Limited
    Register-ScheduledTask -TaskName $taskName -Action $act -Trigger @($trgLogon, $trgTime) -Settings $set -Principal $prin -Force | Out-Null
    Start-ScheduledTask -TaskName $taskName -EA SilentlyContinue
    $taskOk = $true
    Write-Host "  [OK] 计划任务 '$taskName'：每 $IntervalMinutes 分钟快照(隐藏运行)" -ForegroundColor Green
  } catch {
    Write-Warning "  计划任务注册失败：$($_.Exception.Message) → 退回登录启动项(免管理员)"
  }
  if (-not $taskOk) {
    $loop = Join-Path $Dir 'snapshot-loop.ps1'
    "param([int]`$IntervalMinutes = $IntervalMinutes)`r`n`$snap = Join-Path (Split-Path `$PSCommandPath -Parent) 'snapshot.ps1'`r`nwhile (`$true) { try { & `$snap } catch {}; Start-Sleep -Seconds (`$IntervalMinutes * 60) }" | Set-Content -LiteralPath $loop -Encoding utf8
    $vbs = Join-Path ([Environment]::GetFolderPath('Startup')) 'ClaudeSessionKeeper.vbs'
    $cmd = '"' + $pwsh + '" -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "' + $loop + '"'
    "Set sh = CreateObject(""WScript.Shell"")`r`nsh.Run ""$($cmd -replace '"','""')"", 0, False" | Set-Content -LiteralPath $vbs -Encoding ascii
    Start-Process -FilePath $pwsh -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-WindowStyle','Hidden','-File',$loop) -WindowStyle Hidden
    Write-Host "  [OK] 登录启动项: $vbs (本次已拉起，每 $IntervalMinutes 分钟快照)" -ForegroundColor Green
  }
}
Write-Host "`n完成。重启后 → 开任意终端敲 ccr (或双击桌面『恢复Claude会话』)。预览 ccr -WhatIf；手挑 ccr -Pick。" -ForegroundColor Cyan
