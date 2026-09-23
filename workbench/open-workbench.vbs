' GitHub RDP workbench - launcher target of the desktop shortcut.
' Logic mirrors 9router's open-dashboard.vbs:
'   already running (port 8899 listening) -> just open the browser;
'   not running -> start the server hidden, wait for the port (max 20s), then open browser.
'
' NOTE: this file MUST stay pure ASCII. Windows Script Host reads .vbs as ANSI
' (GBK on zh-CN Windows); UTF-8 Chinese here gets mis-decoded and swallows a
' quote character -> "Statement expected" (0x800A0401). Keep it ASCII-only.
Option Explicit

Const PORT = 8899
Const URL  = "http://127.0.0.1:8899"

Dim oWS, fso, here
Set oWS = CreateObject("WScript.Shell")
Set fso = CreateObject("Scripting.FileSystemObject")

' script folder = workbench folder
here = fso.GetParentFolderName(WScript.ScriptFullName)

If Not PortListening(PORT) Then
    If Not fso.FileExists(fso.BuildPath(here, "serve.cmd")) Then
        MsgBox "serve.cmd not found (expected in " & here & ").", 16, "GitHub RDP Workbench"
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
        MsgBox "Workbench did not start within 20s (port " & PORT & " not listening)." & vbCrLf & _
               "See log: " & oWS.ExpandEnvironmentStrings("%USERPROFILE%") & "\cloud-rdp-workbench.log", _
               48, "GitHub RDP Workbench"
    End If
End If

oWS.Run URL, 1, False

' True if local port p is LISTENING
Function PortListening(p)
    Dim rc
    PortListening = False
    rc = oWS.Run("cmd /c netstat -ano | findstr :" & p & " | findstr LISTENING", 0, True)
    If rc = 0 Then PortListening = True
End Function
