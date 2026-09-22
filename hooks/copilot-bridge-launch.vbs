' Launches the Copilot bridge supervisor with no console window, ever.
'
' WScript.Shell.Run with intWindowStyle = 0 starts the process with its window
' hidden from creation, so there is never a visible (or briefly flashing) console
' the way "pwsh -WindowStyle Hidden" launched directly by Task Scheduler can show.
' The supervisor then launches the daemon itself, also hidden, and the daemon keeps
' a real console (required for AttachConsole reply injection) - unlike
' "conhost --headless", which gives a pseudoconsole that breaks injection.
Dim fso, shell, here
Set fso = CreateObject("Scripting.FileSystemObject")
Set shell = CreateObject("WScript.Shell")
here = fso.GetParentFolderName(WScript.ScriptFullName)
shell.Run "pwsh.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File """ & here & "\copilot-bridge-supervisor.ps1""", 0, False