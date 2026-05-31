' run-hidden.vbs —— 真正无窗口地跑 pwsh 快照。
' 计划任务直接调 pwsh.exe(控制台程序)即使 -WindowStyle Hidden 也会先建控制台再隐藏，
' 于是每次闪一下。改由 wscript 调本脚本，用 WshShell.Run(..., 0, False) 以隐藏窗口方式
' 启动 pwsh —— 0=隐藏，从源头不创建可见窗口，完全无感。
' 用法: wscript.exe run-hidden.vbs "<pwsh完整路径>" "<snapshot.ps1完整路径>"
Dim sh, pwsh, script, cmd
Set sh = CreateObject("WScript.Shell")
If WScript.Arguments.Count >= 2 Then
  pwsh = WScript.Arguments(0)
  script = WScript.Arguments(1)
Else
  ' 兜底：参数缺失时按同目录约定推断
  pwsh = sh.ExpandEnvironmentStrings("%ProgramFiles%") & "\PowerShell\7\pwsh.exe"
  script = Left(WScript.ScriptFullName, InStrRev(WScript.ScriptFullName, "\")) & "snapshot.ps1"
End If
cmd = """" & pwsh & """ -NoProfile -ExecutionPolicy Bypass -File """ & script & """"
sh.Run cmd, 0, False   ' 0 = 隐藏窗口；False = 不等待
Set sh = Nothing
