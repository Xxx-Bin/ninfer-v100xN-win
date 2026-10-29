@echo off
rem Configure the native Windows build without vcvars64.bat.
rem
rem vcvars64.bat shells out to reg.exe to locate Visual Studio and the Windows SDK, and this host
rem has reg.exe on the program blacklist, so configure.cmd cannot set its environment here. CMake
rem needs none of that: vcvars' whole output is PATH / INCLUDE / LIB / TMP, so set them directly.
rem
rem Usage: scripts\windows\configure-novcvars.cmd [extra cmake args]
rem
rem Overridable: NINFER_MSVC_VER, NINFER_SDK_VER, NINFER_BUILD_DIR, NINFER_TOOLCHAIN_ROOT,
rem NINFER_TOOLS_ROOT.
setlocal
set "ROOT=%~dp0..\.."
for %%I in ("%ROOT%") do set "ROOT=%%~fI"

rem --- toolchain roots -------------------------------------------------------------------------
rem A sibling checkout that already owns the portable toolchain is used verbatim. It must be the
rem real directory: pointing these roots at a junction or symlink makes nvcc and cmake fail to
rem create their own output files on this host, which surfaces as "Could not open output file" from
rem nvcc and "Unable to (re)create the private pkgRedirects directory" from cmake.
if defined NINFER_TOOLCHAIN_ROOT goto :tc_root_set
set "NINFER_TOOLCHAIN_ROOT=%ROOT%\_toolchain"
if exist "%NINFER_TOOLCHAIN_ROOT%\cuda-12.8\bin\nvcc.exe" goto :tc_root_set
if exist "%ROOT%\..\NInfer-V100-Duo-win\_toolchain\cuda-12.8\bin\nvcc.exe" (
  set "NINFER_TOOLCHAIN_ROOT=%ROOT%\..\NInfer-V100-Duo-win\_toolchain"
)
:tc_root_set
if defined NINFER_TOOLS_ROOT goto :tools_root_set
set "NINFER_TOOLS_ROOT=%ROOT%\.tools"
if exist "%NINFER_TOOLS_ROOT%\venv\Scripts\ninja.exe" goto :tools_root_set
if exist "%ROOT%\..\NInfer-V100-Duo-win\.tools\venv\Scripts\ninja.exe" (
  set "NINFER_TOOLS_ROOT=%ROOT%\..\NInfer-V100-Duo-win\.tools"
)
:tools_root_set

set "CUDA=%NINFER_TOOLCHAIN_ROOT%\cuda-12.8"
set "NINJA=%NINFER_TOOLS_ROOT%\venv\Scripts\ninja.exe"

rem CMake selection, in order:
rem   1. NINFER_CMAKE, when the caller pins one;
rem   2. a 3.30.x portable tree outside this checkout -- the pip launcher under venv\Scripts is a
rem      python shim that cannot create its own build directories here, and the 3.31.6 build
rem      shipped in the venv fails the same way ("Unable to (re)create the private pkgRedirects
rem      directory"), while 3.30.5 configures cleanly;
rem   3. the native binary the venv shim wraps;
rem   4. whatever is on PATH.
if defined NINFER_CMAKE set "CMAKE=%NINFER_CMAKE%"
if defined NINFER_CMAKE goto :cmake_set
set "CMAKE=%ROOT%\_toolchain\cmake-3.30\bin\cmake.exe"
if exist "%CMAKE%" goto :cmake_set
set "CMAKE=%NINFER_TOOLCHAIN_ROOT%\cmake-3.30\bin\cmake.exe"
if exist "%CMAKE%" goto :cmake_set
set "CMAKE=%NINFER_TOOLS_ROOT%\cmake-3.30\bin\cmake.exe"
if exist "%CMAKE%" goto :cmake_set
set "CMAKE=%NINFER_TOOLS_ROOT%\venv\Lib\site-packages\cmake\data\bin\cmake.exe"
if exist "%CMAKE%" goto :cmake_set
set "CMAKE=cmake"
:cmake_set
if not exist "%NINJA%" set "NINJA=ninja"
if not exist "%CUDA%\bin\nvcc.exe" (
  echo Missing portable CUDA toolkit at "%CUDA%"
  echo Run: python scripts\windows\fetch_cuda_toolkit.py
  exit /b 1
)

if not defined NINFER_MSVC_VER set "NINFER_MSVC_VER=14.38.33130"
if not defined NINFER_SDK_VER set "NINFER_SDK_VER=10.0.19041.0"
if not defined NINFER_BUILD_DIR set "NINFER_BUILD_DIR=%ROOT%\build-win"

set "MSCV=%ProgramFiles%\Microsoft Visual Studio\2022\Community\VC\Tools\MSVC\%NINFER_MSVC_VER%"
set "SDK=%ProgramFiles(x86)%\Windows Kits\10"

rem %ProgramFiles(x86)% carries parentheses, so the checks below use goto rather than parenthesised
rem if-blocks -- an expanded ")" inside a block breaks cmd's parsing.
if not exist "%MSCV%\bin\Hostx64\x64\cl.exe" goto :no_toolset
if not exist "%SDK%\Include\%NINFER_SDK_VER%\ucrt" goto :no_sdk

set "PATH=%MSCV%\bin\Hostx64\x64;%SDK%\bin\%NINFER_SDK_VER%\x64;%PATH%"
set "INCLUDE=%MSCV%\include;%SDK%\Include\%NINFER_SDK_VER%\ucrt;%SDK%\Include\%NINFER_SDK_VER%\um;%SDK%\Include\%NINFER_SDK_VER%\shared"
set "LIB=%MSCV%\lib\x64;%SDK%\Lib\%NINFER_SDK_VER%\ucrt\x64;%SDK%\Lib\%NINFER_SDK_VER%\um\x64"

rem nvcc and cl write intermediate files through TMP/TEMP. Two constraints on this host: the
rem default per-session temp directory is not writable for compiler children, and the directory has
rem to be created by a normal process -- a tree pre-created from a restricted shell leaves the wrong
rem ACL, after which nvcc fails with "Could not open output file".
rem This host runs builds inside a low-integrity sandbox. Windows applies the parent directory's
rem integrity level to newly created children, so a tree created under a medium-integrity checkout
rem stays medium and the low-integrity compiler children cannot write into it: nvcc then dies with
rem "Could not open output file <tmp>/tmpxft_*". Drop both trees to low as soon as they exist.
set "NINFER_BUILD_TMP=%NINFER_BUILD_DIR%-tmp"
if not exist "%NINFER_BUILD_TMP%" mkdir "%NINFER_BUILD_TMP%"
if not exist "%NINFER_BUILD_DIR%" mkdir "%NINFER_BUILD_DIR%"
icacls "%NINFER_BUILD_TMP%" /setintegritylevel (OI)(CI)low >nul 2>&1
icacls "%NINFER_BUILD_DIR%" /setintegritylevel (OI)(CI)low >nul 2>&1
set "TMP=%NINFER_BUILD_TMP%"
set "TEMP=%NINFER_BUILD_TMP%"
set "VSLANG=1033"
set "VSCMD_SKIP_SENDTELEMETRY=1"

rem FetchContent clones CUTLASS and then asks git to update its (empty) submodule list. Git for
rem Windows runs that through MSYS sh, which cannot always create its shared-memory object. A
rem pre-cloned checkout lets FetchContent use the source in place instead of going to the network.
set "CUTLASS_SOURCE="
if exist "%NINFER_TOOLCHAIN_ROOT%\cutlass\CMakeLists.txt" (
  set "CUTLASS_SOURCE=-DFETCHCONTENT_SOURCE_DIR_CUTLASS=%NINFER_TOOLCHAIN_ROOT%\cutlass"
)

echo cmake   : "%CMAKE%"
echo cuda    : "%CUDA%"
echo build   : "%NINFER_BUILD_DIR%"

"%CMAKE%" -S "%ROOT%" -B "%NINFER_BUILD_DIR%" -G Ninja ^
  -DCMAKE_MAKE_PROGRAM="%NINJA%" ^
  -DCMAKE_BUILD_TYPE=Release ^
  -DCMAKE_CUDA_ARCHITECTURES=70 ^
  -DCMAKE_CUDA_COMPILER="%CUDA%\bin\nvcc.exe" ^
  -DCUDAToolkit_ROOT="%CUDA%" ^
  -DNINFER_STUB_MEDIA=ON ^
  %CUTLASS_SOURCE% ^
  %*
exit /b %errorlevel%

:no_toolset
echo Cannot find cl.exe under "%MSCV%". Set NINFER_MSVC_VER to the installed toolset.
exit /b 1

:no_sdk
echo Cannot find Windows SDK %NINFER_SDK_VER% under "%SDK%". Set NINFER_SDK_VER.
exit /b 1
