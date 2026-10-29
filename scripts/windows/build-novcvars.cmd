@echo off
rem Build an already configured tree without vcvars64.bat.
rem
rem Pairs with configure-novcvars.cmd, which writes the tree. Same reason for existing: vcvars64.bat
rem needs reg.exe to locate the toolchain, and reg.exe is on this host's program blacklist.
rem
rem Usage: scripts\windows\build-novcvars.cmd [-jN] [ninja target ...]
rem Unchanged behaviour with no arguments: full incremental build of build-win at -j2.
rem
rem Overridable: NINFER_MSVC_VER, NINFER_SDK_VER, NINFER_BUILD_DIR, NINFER_BUILD_JOBS,
rem NINFER_TOOLS_ROOT.
setlocal
set "ROOT=%~dp0..\.."
for %%I in ("%ROOT%") do set "ROOT=%%~fI"

if defined NINFER_TOOLS_ROOT goto :tools_root_set
set "NINFER_TOOLS_ROOT=%ROOT%\.tools"
if exist "%NINFER_TOOLS_ROOT%\venv\Scripts\ninja.exe" goto :tools_root_set
if exist "%ROOT%\..\NInfer-V100-Duo-win\.tools\venv\Scripts\ninja.exe" (
  set "NINFER_TOOLS_ROOT=%ROOT%\..\NInfer-V100-Duo-win\.tools"
)
:tools_root_set

set "NINJA=%NINFER_TOOLS_ROOT%\venv\Scripts\ninja.exe"
if not exist "%NINJA%" set "NINJA=ninja"

if not defined NINFER_MSVC_VER set "NINFER_MSVC_VER=14.38.33130"
if not defined NINFER_SDK_VER set "NINFER_SDK_VER=10.0.19041.0"
if not defined NINFER_BUILD_DIR set "NINFER_BUILD_DIR=%ROOT%\build-win"
rem 2 is the measured ceiling here: -j4 has twice driven this machine into an Infinity-Fabric WHEA
rem storm that ended in a hard reset. Raise it only with that history in mind.
if not defined NINFER_BUILD_JOBS set "NINFER_BUILD_JOBS=2"

set "MSCV=%ProgramFiles%\Microsoft Visual Studio\2022\Community\VC\Tools\MSVC\%NINFER_MSVC_VER%"
set "SDK=%ProgramFiles(x86)%\Windows Kits\10"

rem %ProgramFiles(x86)% carries parentheses, so goto is used instead of parenthesised if-blocks.
if not exist "%MSCV%\bin\Hostx64\x64\cl.exe" goto :no_toolset
if not exist "%SDK%\Include\%NINFER_SDK_VER%\ucrt" goto :no_sdk
if not exist "%NINFER_BUILD_DIR%\build.ninja" goto :not_configured

set "PATH=%MSCV%\bin\Hostx64\x64;%SDK%\bin\%NINFER_SDK_VER%\x64;%PATH%"
set "INCLUDE=%MSCV%\include;%SDK%\Include\%NINFER_SDK_VER%\ucrt;%SDK%\Include\%NINFER_SDK_VER%\um;%SDK%\Include\%NINFER_SDK_VER%\shared"
set "LIB=%MSCV%\lib\x64;%SDK%\Lib\%NINFER_SDK_VER%\ucrt\x64;%SDK%\Lib\%NINFER_SDK_VER%\um\x64"

rem Compiler children run at low integrity in this environment, so TMP must be a low-integrity
rem directory or nvcc fails to create its tmpxft_* files. configure-novcvars.cmd sets that up.
set "NINFER_BUILD_TMP=%NINFER_BUILD_DIR%-tmp"
if not exist "%NINFER_BUILD_TMP%" mkdir "%NINFER_BUILD_TMP%"
icacls "%NINFER_BUILD_TMP%" /setintegritylevel (OI)(CI)low >nul 2>&1
set "TMP=%NINFER_BUILD_TMP%"
set "TEMP=%NINFER_BUILD_TMP%"
set "VSLANG=1033"
set "VSCMD_SKIP_SENDTELEMETRY=1"

if "%~1"=="" (
  "%NINJA%" -C "%NINFER_BUILD_DIR%" -j %NINFER_BUILD_JOBS%
  exit /b %errorlevel%
)
"%NINJA%" -C "%NINFER_BUILD_DIR%" %*
exit /b %errorlevel%

:no_toolset
echo Cannot find cl.exe under "%MSCV%". Set NINFER_MSVC_VER to the installed toolset.
exit /b 1

:no_sdk
echo Cannot find Windows SDK %NINFER_SDK_VER% under "%SDK%". Set NINFER_SDK_VER.
exit /b 1

:not_configured
echo No build.ninja under "%NINFER_BUILD_DIR%".
echo Run: scripts\windows\configure-novcvars.cmd
exit /b 1
