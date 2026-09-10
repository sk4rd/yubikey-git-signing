@echo off
rem Double-click launcher for setup-yubikey-git-signing.ps1.
rem Arguments are passed through, e.g.:
rem     setup-yubikey-git-signing.cmd -GitName "Jane Doe" -GitEmail jane@example.com
rem     setup-yubikey-git-signing.cmd -Test
rem The output stays on screen afterwards so it can be read.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0setup-yubikey-git-signing.ps1" %*
echo.
echo (press any key to close)
pause >nul
