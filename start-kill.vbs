Set fso = CreateObject("Scripting.FileSystemObject")
Set sh = CreateObject("WScript.Shell")
d = fso.GetParentFolderName(WScript.ScriptFullName)
sh.Run "taskkill /F /FI ""PID eq 999999"" /FI ""IMAGENAME eq powershell.exe""", 0, True
sh.Run "powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File """ & d & "\relay.ps1"" """ & d & """", 0, False
