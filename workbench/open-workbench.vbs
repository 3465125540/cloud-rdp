' GitHub 虚拟机管理工作台 —— 桌面快捷方式的真正目标。
' 逻辑与 9router 的 open-dashboard.vbs 一致：
'   已在运行（8787 在监听）→ 直接开浏览器；
'   没在运行 → 先隐藏启动服务，等端口起来（最多 20s）再开浏览器。
Option Explicit

Const PORT = 8787
Const URL  = "http://127.0.0.1:8787"

Dim oWS, fso, here
Set oWS = CreateObject("WScript.Shell")
Set fso = CreateObject("Scripting.FileSystemObject")

' 脚本所在目录 = workbench 目录
here = fso.GetParentFolderName(WScript.ScriptFullName)

If Not PortListening(PORT) Then
    If Not fso.FileExists(fso.BuildPath(here, "serve.cmd")) Then
        MsgBox "找不到 serve.cmd（应在 " & here & "）。", 16, "GitHub虚拟机管理工作台"
        WScript.Quit 1
    End If
    oWS.CurrentDirectory = here
    oWS.Run "cmd /c call """ & fso.BuildPath(here, "serve.cmd") & """", 0, False

    Dim waited
    waited = 0
    Do While (Not PortListening(PORT)) And (waited < 20)
        WScript.Sleep 1000
        waited = waited + 1
    Loop

    If Not PortListening(PORT) Then
        MsgBox "工作台启动超时（20 秒内没监听到 " & PORT & " 端口）。" & vbCrLf & _
               "可看日志：" & oWS.ExpandEnvironmentStrings("%USERPROFILE%") & "\cloud-rdp-workbench.log", _
               48, "GitHub虚拟机管理工作台"
    End If
End If

oWS.Run URL, 1, False

' 判断本机某端口是否在 LISTENING
Function PortListening(p)
    Dim rc
    PortListening = False
    rc = oWS.Run("cmd /c netstat -ano | findstr :" & p & " | findstr LISTENING", 0, True)
    If rc = 0 Then PortListening = True
End Function
