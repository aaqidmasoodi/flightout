@echo off
rem Builds FlightOut for Windows and packages the installer.
rem Needs: Godot 4.7.2 with export templates, and Inno Setup 6 (ISCC on PATH or in the default install folder).
rem Usage:  installer\build_windows.bat [path\to\Godot.exe]
setlocal
set ROOT=%~dp0..
set GODOT=%~1
if "%GODOT%"=="" set GODOT=%USERPROFILE%\Desktop\Godot.exe
set ISCC=ISCC.exe
where ISCC.exe >nul 2>nul || set ISCC=%LOCALAPPDATA%\Programs\Inno Setup 6\ISCC.exe
if not exist "%ISCC%" if exist "%ProgramFiles(x86)%\Inno Setup 6\ISCC.exe" set ISCC=%ProgramFiles(x86)%\Inno Setup 6\ISCC.exe

echo [1/2] Exporting the game...
if not exist "%ROOT%\build\windows" mkdir "%ROOT%\build\windows"
"%GODOT%" --headless --path "%ROOT%" --export-release "Windows Desktop" "%ROOT%\build\windows\FlightOut.exe" || goto :fail

echo [2/2] Building the installer...
"%ISCC%" /Q "%ROOT%\installer\flightout.iss" || goto :fail

echo Done: build\installer
exit /b 0
:fail
echo Build failed.
exit /b 1
