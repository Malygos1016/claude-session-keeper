<#
  snapshot.ps1 —— 把 Claude Code 自带的"在跑会话"注册表，定时复制到我们自己的、
  Claude 不会去清理的目录。这样即使 Claude 在下次启动时清掉了 ~/.claude/sessions 里
  的死进程记录，我们仍保留着「断电那一刻还开着哪些窗口」的证据，供 restore.ps1 恢复。

  由计划任务每 ~2 分钟跑一次（外加登录时跑一次）。只读 + 写自己的快照，无 GUI，
  在沙箱/无人值守下都能跑。
#>
param(
  [string]$ClaudeHome = "$env:USERPROFILE\.claude",
  [int]   $Keep = 400          # 保留最近多少份快照（约 400×2min ≈ 13 小时滚动 + 跨开机历史）
)
$ErrorActionPreference = 'Stop'

$sessionsDir = Join-Path $ClaudeHome 'sessions'
$snapDir     = Join-Path $ClaudeHome 'session-keeper\snapshots'
if (-not (Test-Path -LiteralPath $snapDir)) { New-Item -ItemType Directory -Force -Path $snapDir | Out-Null }

# 读当前在跑的交互会话
$list = @()
if (Test-Path -LiteralPath $sessionsDir) {
  foreach ($f in Get-ChildItem -LiteralPath $sessionsDir -Filter *.json -File -ErrorAction SilentlyContinue) {
    try { $o = Get-Content -LiteralPath $f.FullName -Raw | ConvertFrom-Json } catch { continue }
    if ($o.kind -ne 'interactive') { continue }
    if (-not $o.sessionId -or -not $o.cwd) { continue }
    $list += [pscustomobject]@{
      sessionId = [string]$o.sessionId
      cwd       = [string]$o.cwd
      pid       = [int]$o.pid
      status    = [string]$o.status
      startedAt = [long]$o.startedAt
      updatedAt = if ($o.updatedAt) { [long]$o.updatedAt } else { [long]$o.startedAt }
    }
  }
}

# 没有在跑的会话就不写：避免「开机瞬间还没开 Claude」时写一份空快照，污染历史。
if ($list.Count -eq 0) { return }

$nowMs  = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
$bootMs = [DateTimeOffset]::new((Get-CimInstance Win32_OperatingSystem).LastBootUpTime).ToUnixTimeMilliseconds()

$snap = [pscustomobject]@{
  capturedAt = $nowMs        # 本快照拍摄时刻
  bootAt     = $bootMs       # 拍摄时的本次开机时刻（用来区分"哪一次开机期间开着的"）
  count      = $list.Count
  sessions   = $list
}
$json = $snap | ConvertTo-Json -Depth 6

# 原子写：先写临时文件再改名
$file = Join-Path $snapDir ("{0}.json" -f $nowMs)
$tmp  = "$file.tmp"
$json | Set-Content -LiteralPath $tmp -Encoding utf8
Move-Item -LiteralPath $tmp -Destination $file -Force
# 顺便维护一个 latest.json 方便人工查看
$json | Set-Content -LiteralPath (Join-Path $snapDir '..\latest.json') -Encoding utf8

# 修剪旧快照（文件名是毫秒时间戳，按名字降序即按时间降序）
$all = Get-ChildItem -LiteralPath $snapDir -Filter *.json -File | Sort-Object Name -Descending
if ($all.Count -gt $Keep) { $all | Select-Object -Skip $Keep | Remove-Item -Force -ErrorAction SilentlyContinue }
