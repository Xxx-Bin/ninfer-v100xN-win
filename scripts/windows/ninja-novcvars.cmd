@echo off
rem Build the existing build-win tree without vcvars64.bat.
rem
rem vcvars64.bat shells out to reg.exe to locate Visual Studio and the Windows SDK, and this host
rem has reg.exe on the program blacklist, so build.cmd cannot set its environment here. Compiling
rem needs none of that: vcvars' whole output is PATH / INCLUDE / LIB / TMP. Set them directly.
rem
rem Usage (defaults to build-win, -j2):
rem   scripts\windows\ninja-novcvars.cmd                      full incremental build
rem   scripts\windows\ninja-novcvars.cmd -j1 <ninja target>   one edge, serially
rem
rem Override the SDK if the OS is not Windows 10 19045; see BUILD-LOCAL.md section 2.
setlocal
set "ROOT=%~dp0..\.."
for %%I in ("%ROOT%") do set "ROOT=%%~fI"

if not defined NINFER_MSVC_VER set "NINFER_MSVC_VER=14.38.33130"
if not defined NINFER_SDK_VER set "NINFER_SDK_VER=10.0.19041.0"
if not defined NINFER_BUILD_DIR set "NINFER_BUILD_DIR=%ROOT%\build-win"
if not defined NINFER_BUILD_JOBS set "NINFER_BUILD_JOBS=2"

set "MSCV=%ProgramFiles%\Microsoft Visual Studio\2022\Community\VC\Tools\MSVC\%NINFER_MSVC_VER%"
set "SDK=%ProgramFiles(x86)%\Windows Kits\10"

rem Note: %ProgramFiles(x86)% carries parentheses, so the checks below use goto rather than
rem parenthesised if-blocks -- an expanded ")" inside a block breaks cmd's parsing.
if not exist "%MSCV%\bin\Hostx64\x64\cl.exe" goto :no_toolset
if not exist "%SDK%\Include\%NINFER_SDK_VER%\ucrt" goto :no_sdk

set "PATH=%MSCV%\bin\Hostx64\x64;%SDK%\bin\%NINFER_SDK_VER%\x64;%PATH%"
set "INCLUDE=%MSCV%\include;%SDK%\Include\%NINFER_SDK_VER%\ucrt;%SDK%\Include\%NINFER_SDK_VER%\um;%SDK%\Include\%NINFER_SDK_VER%\shared"
set "LIB=%MSCV%\lib\x64;%SDK%\Lib\%NINFER_SDK_VER%\ucrt\x64;%SDK%\Lib\%NINFER_SDK_VER%\um\x64"

rem nvcc creates its temporaries through TMP/TEMP; keep them inside the tree.
set "NINFER_BUILD_TMP=%ROOT%\build-win-tmp"
if not exist "%NINFER_BUILD_TMP%" mkdir "%NINFER_BUILD_TMP%"
set "TMP=%NINFER_BUILD_TMP%"
set "TEMP=%NINFER_BUILD_TMP%"
set "VSLANG=1033"
set "VSCMD_SKIP_SENDTELEMETRY=1"

if "%~1"=="" goto :full
"%ROOT%\.tools\venv\Scripts\ninja.exe" -C "%NINFER_BUILD_DIR%" %*
exit /b %errorlevel%

:full
"%ROOT%\.tools\venv\Scripts\ninja.exe" -C "%NINFER_BUILD_DIR%" -j %NINFER_BUILD_JOBS%
exit /b %errorlevel%

:no_toolset
echo Cannot find cl.exe under "%MSCV%". Set NINFER_MSVC_VER to the installed toolset.
exit /b 1

:no_sdk
echo Cannot find Windows SDK %NINFER_SDK_VER% under "%SDK%". Set NINFER_SDK_VER.
exit /b 1
