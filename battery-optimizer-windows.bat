@echo off
rem Battery Optimizer for Windows. Double-click this file.
rem It runs the same script as Linux (battery-optimizer-linux.sh), with the same menus.
rem The first start downloads the tools it needs (about 130 MB) into %LOCALAPPDATA%\battery-optimizer:
rem   bash (portable Git for Windows), Python, fzf (the menus) and adb (talks to the phone).
rem Nothing is installed system-wide and nothing is done to the phone until you choose it in the menu.
setlocal
chcp 65001 >nul
title Battery Optimizer
set "TOOLS=%LOCALAPPDATA%\battery-optimizer"
set "CURL=%SystemRoot%\System32\curl.exe"
set "TAR=%SystemRoot%\System32\tar.exe"
rem Pinned versions, so every computer gets the same tools.
set "GIT_URL=https://github.com/git-for-windows/git/releases/download/v2.47.1.windows.1/PortableGit-2.47.1-64-bit.7z.exe"
set "PY_URL=https://www.python.org/ftp/python/3.13.1/python-3.13.1-embed-amd64.zip"
set "FZF_URL=https://github.com/junegunn/fzf/releases/download/v0.56.3/fzf-0.56.3-windows_amd64.zip"
set "ADB_URL=https://dl.google.com/android/repository/platform-tools-latest-windows.zip"
set "SCRIPT_URL=https://raw.githubusercontent.com/AZP3001/battery-optimizer/main/battery-optimizer-linux.sh"

rem curl and tar come with Windows 10 (1803) and newer.
if not exist "%CURL%" goto :oldwindows
if not exist "%TAR%" goto :oldwindows
if not exist "%TOOLS%" mkdir "%TOOLS%"

if exist "%TOOLS%\git\bin\bash.exe" goto :havegit
echo Downloading bash (portable Git for Windows, about 60 MB)...
"%CURL%" -fL --progress-bar -o "%TOOLS%\git.7z.exe" "%GIT_URL%" || goto :fail
rem Self-extracting archive: -o = where to, -y = no questions.
"%TOOLS%\git.7z.exe" -o"%TOOLS%\git" -y || goto :fail
del "%TOOLS%\git.7z.exe"
:havegit

if exist "%TOOLS%\python\python.exe" goto :havepython
echo Downloading Python...
"%CURL%" -fL --progress-bar -o "%TOOLS%\python.zip" "%PY_URL%" || goto :fail
mkdir "%TOOLS%\python" 2>nul
"%TAR%" -xf "%TOOLS%\python.zip" -C "%TOOLS%\python" || goto :fail
del "%TOOLS%\python.zip"
:havepython

if exist "%TOOLS%\fzf\fzf.exe" goto :havefzf
echo Downloading fzf...
"%CURL%" -fL --progress-bar -o "%TOOLS%\fzf.zip" "%FZF_URL%" || goto :fail
mkdir "%TOOLS%\fzf" 2>nul
"%TAR%" -xf "%TOOLS%\fzf.zip" -C "%TOOLS%\fzf" || goto :fail
del "%TOOLS%\fzf.zip"
:havefzf

if exist "%TOOLS%\platform-tools\adb.exe" goto :haveadb
echo Downloading adb (Android platform tools)...
"%CURL%" -fL --progress-bar -o "%TOOLS%\adb.zip" "%ADB_URL%" || goto :fail
"%TAR%" -xf "%TOOLS%\adb.zip" -C "%TOOLS%" || goto :fail
del "%TOOLS%\adb.zip"
:haveadb

rem Use the script next to this file. If there is none, use the latest one from GitHub
rem (kept from the last download when offline).
set "SCRIPT=%~dp0battery-optimizer-linux.sh"
if exist "%SCRIPT%" goto :run
set "SCRIPT=%TOOLS%\battery-optimizer-linux.sh"
"%CURL%" -fsSL -o "%SCRIPT%.new" "%SCRIPT_URL%" && move /y "%SCRIPT%.new" "%SCRIPT%" >nul
if not exist "%SCRIPT%" goto :fail

:run
set "PATH=%TOOLS%\python;%TOOLS%\fzf;%TOOLS%\platform-tools;%TOOLS%\git\usr\bin;%TOOLS%\git\bin;%PATH%"
rem The script starts Python with this name (on Linux it is python3).
set "PYTHON=python"
rem On Windows fzf runs its key bindings with cmd.exe unless told to use bash.
set "FZF_DEFAULT_OPTS=--with-shell 'bash -c'"
if not defined TERM set "TERM=cygwin"
"%TOOLS%\git\bin\bash.exe" "%SCRIPT%" %*
exit /b %errorlevel%

:oldwindows
echo This needs Windows 10 (version 1803) or newer.
pause
exit /b 1

:fail
echo.
echo Something went wrong while downloading the tools. Check the internet connection and try again.
echo If it keeps failing, delete the folder %TOOLS% and start this file again.
pause
exit /b 1
