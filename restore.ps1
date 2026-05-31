<#
.SYNOPSIS  把关机/断电前还开着的 ClaudeCode 会话一键 resume 回来。
.DESCRIPTION
  数据源优先级：
    默认       读自己的快照(session-keeper\snapshots)里"本次开机之前最后一份"=断电前那批窗口。
    -Last      读最近一份快照(不管开机时间)——误关了窗口想立刻找回时用。
    -History N 连快照都没有时，从 transcript 历史列最近 N 个供手挑。
  启动前自动把涉及目录的"信任弹窗"答掉(写 ~/.claude.json 的 hasTrustDialogAccepted)。
  每个会话按 sessionId 精确 resume，默认开成一个 Windows Terminal 窗口的多个标签页。
  默认跳过"当前已经在跑"的会话(两个进程写同一 transcript 会冲突)。
  注意：大/老会话进去前会问"从摘要恢复 / 完整原样恢复"——这步无法自动，由你按键决定(完整=按 2)。
.EXAMPLE
  ccr            # 恢复断电前的窗口
  ccr -WhatIf    # 只预览
  ccr -Last      # 重开最近一份快照里的会话
  ccr -Pick      # 手动勾选
#>
[CmdletBinding(SupportsShouldProcess)]
param(
  [switch] $Last,
  [int]    $History = 0,
  [switch] $Pick,
  [int]    $Max = 12,
  [switch] $Force,
  [switch] $IncludeCurrent,
  [ValidateSet('tabs','windows')]
  [string] $Layout = 'tabs',
  [string] $ClaudeHome = (Join-Path $env:USERPROFILE '.claude')
)
$ErrorActionPreference = 'Stop'
$projectsDir = Join-Path $ClaudeHome 'projects'
$sessionsDir = Join-Path $ClaudeHome 'sessions'
$snapDir     = Join-Path $ClaudeHome 'session-keeper\snapshots'

function Get-BootMs { [DateTimeOffset]::new((Get-CimInstance Win32_OperatingSystem).LastBootUpTime).ToUnixTimeMilliseconds() }

function Get-LiveIds {
  $h = @{}
  if (Test-Path -LiteralPath $sessionsDir) {
    foreach ($f in Get-ChildItem -LiteralPath $sessionsDir -Filter *.json -File -EA SilentlyContinue) {
      try { $o = Get-Content -LiteralPath $f.FullName -Raw | ConvertFrom-Json } catch { continue }
      if ($o.kind -eq 'interactive' -and $o.sessionId) { $h[[string]$o.sessionId] = $true }
    }
  }
  $h
}

function Get-AncestorPids {
  $h = @{}; $cur = $PID
  for ($i = 0; $i -lt 8 -and $cur; $i++) {
    $p = Get-CimInstance Win32_Process -Filter "ProcessId=$cur" -EA SilentlyContinue
    if (-not $p) { break }
    $h[[int]$cur] = $true; $cur = [int]$p.ParentProcessId
  }
  $h
}

$script:txCache = $null
function Find-Transcript([string]$id) {
  if ($null -eq $script:txCache) {
    $script:txCache = @{}
    Get-ChildItem -Path (Join-Path $projectsDir '*\*.jsonl') -File -EA SilentlyContinue |
      ForEach-Object { $script:txCache[$_.BaseName] = $_.FullName }
  }
  $script:txCache[$id]
}

function Get-Label([string]$id, [string]$cwd) {
  $file = Find-Transcript $id
  if ($file) {
    try {
      foreach ($ln in Get-Content -LiteralPath $file -TotalCount 60 -EA Stop) {
        if ($ln -notmatch '"type"\s*:\s*"user"') { continue }
        try { $j = $ln | ConvertFrom-Json } catch { continue }
        $c = $j.message.content; $txt = $null
        if ($c -is [string]) { $txt = $c } elseif ($c) { $txt = ($c | Where-Object { $_.type -eq 'text' } | Select-Object -First 1).text }
        if (-not $txt) { continue }
        $txt = (($txt -replace '<[^>]+>', ' ') -replace 'Caveat:.*?asks you to\.', ' ') -replace '\s+', ' '
        $txt = $txt.Trim()
        if ($txt.Length -ge 4) { if ($txt.Length -gt 50) { $txt = $txt.Substring(0,47) + '...' }; return $txt }
      }
    } catch {}
  }
  $leaf = Split-Path $cwd -Leaf
  if ([string]::IsNullOrEmpty($leaf)) { $cwd } else { $leaf }
}

# 启动前把"信任目录"弹窗答掉：只在确有未信任目录时才动 ~/.claude.json，备份+校验+失败回滚
function Approve-Trust([string[]]$cwds) {
  $cfgPath = Join-Path $env:USERPROFILE '.claude.json'
  if (-not (Test-Path -LiteralPath $cfgPath)) { return }
  $keys = $cwds | ForEach-Object { ($_ -replace '\\','/') } | Select-Object -Unique
  try { $cfg = Get-Content -LiteralPath $cfgPath -Raw | ConvertFrom-Json } catch { Write-Warning "读 .claude.json 失败，跳过信任设置"; return }
  if (-not $cfg.projects) { return }
  $changed = $false
  foreach ($k in $keys) {
    $proj = $cfg.projects.$k
    if ($proj) {
      if ($proj.hasTrustDialogAccepted -ne $true) {
        $proj | Add-Member -NotePropertyName hasTrustDialogAccepted -NotePropertyValue $true -Force
        $changed = $true
      }
    } else {
      $cfg.projects | Add-Member -NotePropertyName $k -NotePropertyValue ([pscustomobject]@{
        allowedTools = @(); hasTrustDialogAccepted = $true; hasCompletedProjectOnboarding = $true; projectOnboardingSeenCount = 0
      }) -Force
      $changed = $true
    }
  }
  if (-not $changed) { return }
  Copy-Item -LiteralPath $cfgPath -Destination "$cfgPath.skbak" -Force
  $new = $cfg | ConvertTo-Json -Depth 100
  try { $null = $new | ConvertFrom-Json; Set-Content -LiteralPath $cfgPath -Value $new -Encoding utf8 }
  catch { Write-Warning "信任写入校验失败，已保留原 .claude.json" }
}

function Resolve-ClaudeCmd {
  foreach ($p in @("$env:APPDATA\npm\claude.cmd", "$env:USERPROFILE\AppData\Roaming\npm\claude.cmd")) {
    if (Test-Path -LiteralPath $p) { return $p }
  }
  $g = Get-Command claude.cmd -EA SilentlyContinue; if ($g) { return $g.Source }
  return 'claude'
}

# -------- 取候选 --------
$source = ''
$raw = @()
if ($History -gt 0) {
  $source = "历史(最近 $History 个)"
  $seen = @{}; $picked = @()
  foreach ($f in (Get-ChildItem -Path (Join-Path $projectsDir '*\*.jsonl') -File -EA SilentlyContinue | Sort-Object LastWriteTime -Descending)) {
    if ($seen[$f.BaseName]) { continue }; $seen[$f.BaseName] = $true
    $cwd = $null
    try { foreach ($ln in Get-Content -LiteralPath $f.FullName -TotalCount 30 -EA Stop) { if ($ln -match '"cwd"') { try { $cwd = ($ln | ConvertFrom-Json).cwd } catch {}; if ($cwd) { break } } } } catch {}
    $picked += [pscustomobject]@{ SessionId = $f.BaseName; Cwd = ($cwd ?? '?'); UpdatedAt = [DateTimeOffset]::new($f.LastWriteTime).ToUnixTimeMilliseconds() }
    if ($picked.Count -ge $History) { break }
  }
  $raw = $picked; $Pick = $true
} else {
  $snaps = @()
  if (Test-Path -LiteralPath $snapDir) {
    $snaps = Get-ChildItem -LiteralPath $snapDir -Filter *.json -File -EA SilentlyContinue |
             ForEach-Object { try { Get-Content -LiteralPath $_.FullName -Raw | ConvertFrom-Json } catch {} }
  }
  $chosen = $null
  if ($Last) { $chosen = $snaps | Sort-Object capturedAt -Descending | Select-Object -First 1; $source = '最近快照' }
  else { $boot = Get-BootMs; $chosen = $snaps | Where-Object { $_.bootAt -and $_.bootAt -lt $boot } | Sort-Object capturedAt -Descending | Select-Object -First 1; $source = '断电前快照' }

  if ($chosen) {
    $raw = $chosen.sessions | ForEach-Object { [pscustomobject]@{ SessionId = [string]$_.sessionId; Cwd = [string]$_.cwd; UpdatedAt = [long]($_.updatedAt ?? $_.startedAt) } }
  } else {
    $source = '实时注册表(无可用快照)'
    if (Test-Path -LiteralPath $sessionsDir) {
      foreach ($f in Get-ChildItem -LiteralPath $sessionsDir -Filter *.json -File -EA SilentlyContinue) {
        try { $o = Get-Content -LiteralPath $f.FullName -Raw | ConvertFrom-Json } catch { continue }
        if ($o.kind -ne 'interactive' -or -not $o.sessionId -or -not $o.cwd) { continue }
        $raw += [pscustomobject]@{ SessionId = [string]$o.sessionId; Cwd = [string]$o.cwd; UpdatedAt = [long]($o.updatedAt ?? $o.startedAt) }
      }
    }
  }
}

if ($raw.Count -eq 0) {
  Write-Host "没有可恢复的会话(来源：$source)。" -ForegroundColor Yellow
  Write-Host "刚装好还没攒下快照的话，可用  ccr -History 15  从历史里手挑。" -ForegroundColor DarkGray
  return
}

# 去重 + 排除已在跑(含当前)
$raw = $raw | Sort-Object SessionId, @{Expression='UpdatedAt';Descending=$true} | Group-Object SessionId | ForEach-Object { $_.Group[0] }
$liveIds = Get-LiveIds
$cands = @($raw | Where-Object { $IncludeCurrent -or -not $liveIds.ContainsKey($_.SessionId) })

if ($cands.Count -eq 0) {
  Write-Host "来源[$source]里的会话当前都已经在跑了，无需恢复。" -ForegroundColor Green
  return
}

# 标注 + cwd 解析
foreach ($c in $cands) {
  $c | Add-Member Label (Get-Label $c.SessionId $c.Cwd) -Force
  $c | Add-Member Running ([bool]$liveIds.ContainsKey($c.SessionId)) -Force
  if (Test-Path -LiteralPath $c.Cwd -PathType Container) { $c | Add-Member LaunchDir $c.Cwd -Force }
  else { Write-Warning "目录不存在：$($c.Cwd) → 改在家目录开"; $c | Add-Member LaunchDir $env:USERPROFILE -Force }
}
$cands = @($cands | Sort-Object UpdatedAt -Descending)

if ($Pick) {
  Write-Host "`n来源：$source —— 可恢复：" -ForegroundColor Cyan
  for ($i=0; $i -lt $cands.Count; $i++) { $c=$cands[$i]; "{0,3}] {1}  [{2}]  {3}" -f $i,$c.Label.PadRight(34).Substring(0,34),$c.SessionId.Substring(0,8),$c.LaunchDir | Write-Host }
  $sel = Read-Host "输入编号(逗号/空格分隔，回车=全部，q=退出)"
  if ($sel -match '^\s*q') { Write-Host "已取消。"; return }
  if (-not [string]::IsNullOrWhiteSpace($sel)) {
    $idx = $sel -split '[,\s]+' | Where-Object { $_ -match '^\d+$' } | ForEach-Object { [int]$_ }
    $cands = @($idx | Where-Object { $_ -ge 0 -and $_ -lt $cands.Count } | ForEach-Object { $cands[$_] })
  }
}
if ($cands.Count -eq 0) { Write-Host "没选任何会话。"; return }

Write-Host "`n将恢复 $($cands.Count) 个(来源：$source)：" -ForegroundColor Green
$cands | ForEach-Object { $r = if($_.Running){' [已在跑]'}else{''}; "  • {0}  [{1}]  {2}{3}" -f $_.Label,$_.SessionId.Substring(0,8),$_.LaunchDir,$r | Write-Host }

if ($WhatIfPreference) { Write-Host "`n[-WhatIf] 仅预览，未实际打开。" -ForegroundColor Yellow; return }
if ($cands.Count -gt $Max -and -not $Force) {
  $a = Read-Host "`n要打开 $($cands.Count) 个，确认？[y/N]"
  if ($a -notmatch '^(y|yes)$') { Write-Host "已取消。"; return }
}

# 启动前答掉信任弹窗
Approve-Trust ($cands.LaunchDir)

$claude = Resolve-ClaudeCmd
function Get-Inner([string]$id) { if ($claude -match '\s') { "& `"$claude`" --resume $id" } else { "$claude --resume $id" } }
$hasWt = [bool](Get-Command wt -EA SilentlyContinue)

if ($Layout -eq 'tabs' -and $hasWt) {
  $wtArgs = [System.Collections.Generic.List[string]]::new(); $first = $true
  foreach ($c in $cands) {
    if (-not $first) { $wtArgs.Add(';') }; $first = $false
    $wtArgs.AddRange([string[]]@('new-tab','--title',$c.Label,'-d',$c.LaunchDir,'pwsh.exe','-NoExit','-Command',(Get-Inner $c.SessionId)))
  }
  & wt @wtArgs
} else {
  if ($Layout -eq 'tabs') { Write-Warning "没找到 wt，改用独立窗口。" }
  foreach ($c in $cands) { Start-Process -FilePath "$env:ProgramFiles\PowerShell\7\pwsh.exe" -WorkingDirectory $c.LaunchDir -ArgumentList @('-NoExit','-Command',(Get-Inner $c.SessionId)) }
}
Write-Host "`n已开 $($cands.Count) 个标签。大/老会话进去前会问『摘要 / 完整原样』——要完整就按 2 回车。" -ForegroundColor Green
