' ===========================================================================
'  ATK Battery Tray - 完全无窗口启动器
'
'  为什么需要这个：
'    直接用 powershell.exe -WindowStyle Hidden 启动时，控制台窗口会先闪
'    一下才隐藏（Windows 的已知行为）。用 WScript.Shell.Run 的 windowStyle=0
'    可以做到完全无窗口、零闪烁。
'
'  用法：
'    双击本文件即可启动插件（无任何窗口弹出）。
'    想做成快捷方式：右键 → 发送到 → 桌面快捷方式
' ===========================================================================

Option Explicit

Dim fso, sh, scriptDir, ps1, cmd

Set fso = CreateObject("Scripting.FileSystemObject")
Set sh  = CreateObject("WScript.Shell")

' 本文件所在目录
scriptDir = fso.GetParentFolderName(WScript.ScriptFullName)
ps1 = scriptDir & "\atk-tray.ps1"

' 检查插件本体是否存在
If Not fso.FileExists(ps1) Then
    MsgBox "找不到 atk-tray.ps1" & vbCrLf & vbCrLf & _
           "请确保本文件与 atk-tray.ps1 在同一目录。" & vbCrLf & _
           "当前目录: " & scriptDir, _
           vbCritical, "ATK 电量插件"
    WScript.Quit 1
End If

' 构造命令：-WindowStyle Hidden 双保险，Run(...,0,...) 保证不闪窗
cmd = "powershell.exe -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass" & _
      " -File """ & ps1 & """ -LauncherMode"

' windowStyle=0 -> 隐藏窗口; bWaitOnReturn=False -> 不等待
sh.Run cmd, 0, False
