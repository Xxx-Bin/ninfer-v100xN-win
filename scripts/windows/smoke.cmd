@echo off
rem Smoke test for a built Windows tree: proves the binaries run, without a GPU or an artifact.
rem
rem Usage: scripts\windows\smoke.cmd [--gpu]
rem
rem   default   usage banner + the host-only test subset
rem   --gpu     additionally run ninfer_device_test (needs an idle V100; it fails with
rem             cudaErrorMemoryAllocation when another process holds the card)
rem
rem Every stage is fatal: the script exits with the number of failed stages, so it can gate a
rem release. Set NINFER_BUILD_DIR to test a tree other than build-win.
setlocal enabledelayedexpansion
set "ROOT=%~dp0..\.."
for %%I in ("%ROOT%") do set "ROOT=%%~fI"
set "STAGES_FAILED=0"
set "WANT_GPU=0"
if /i "%~1"=="--gpu" set "WANT_GPU=1"

if defined NINFER_TOOLS_ROOT goto :tools_root_set
set "NINFER_TOOLS_ROOT=%ROOT%\.tools"
if exist "%NINFER_TOOLS_ROOT%\venv\Scripts\ninja.exe" goto :tools_root_set
if exist "%ROOT%\..\NInfer-V100-Duo-win\.tools\venv\Scripts\ninja.exe" (
  set "NINFER_TOOLS_ROOT=%ROOT%\..\NInfer-V100-Duo-win\.tools"
)
:tools_root_set

if not defined NINFER_BUILD_DIR set "NINFER_BUILD_DIR=%ROOT%\build-win"
rem ctest ships with the same cmake distribution.
set "CTEST=%NINFER_TOOLS_ROOT%\venv\Lib\site-packages\cmake\data\bin\ctest.exe"
if not exist "%CTEST%" set "CTEST=ctest"

if not exist "%NINFER_BUILD_DIR%\apps\ninfer.exe" goto :no_build

rem A low-integrity directory is required: the test fixtures and every nvcc temporary go to TMP,
rem and a medium-integrity temp directory is not writable for these processes.
set "SMOKE_TMP=%NINFER_BUILD_DIR%-tmp"
if not exist "%SMOKE_TMP%" mkdir "%SMOKE_TMP%"
icacls "%SMOKE_TMP%" /setintegritylevel (OI)(CI)low >nul 2>&1
set "TMP=%SMOKE_TMP%"
set "TEMP=%SMOKE_TMP%"

echo [1/3] ninfer.exe usage banner
"%NINFER_BUILD_DIR%\apps\ninfer.exe" > "%SMOKE_TMP%\usage.txt" 2>&1
if not errorlevel 1 goto :usage_no_failure
rem A bare invocation with no model must fail; that failure is the expected outcome.
rem The banner names the executable by its full path, so match the model argument instead.
findstr /c:"model.ninfer" "%SMOKE_TMP%\usage.txt" >nul
if errorlevel 1 goto :usage_no_banner
echo       ok: usage banner printed, exit code rejected the empty request
goto :host_tests
:usage_no_failure
echo       FAIL: ninfer.exe accepted an invocation with no model
set /a STAGES_FAILED+=1
goto :host_tests
:usage_no_banner
echo       FAIL: no usage banner in the output
type "%SMOKE_TMP%\usage.txt"
set /a STAGES_FAILED+=1

:host_tests
echo [2/3] host test subset
rem Tests that touch neither a GPU nor an artifact. A device test here would fail on a busy card,
rem and an artifact test would need a .ninfer file, so both are deliberate exclusions.
"%CTEST%" --test-dir "%NINFER_BUILD_DIR%" --output-on-failure ^
  -R "public_api|artifact_reader|tensor_slice|kv_capacity|request_log|runtime_mechanisms|admission_policy|sharded_materialization"
if errorlevel 1 (
  echo       FAIL: host test subset
  set /a STAGES_FAILED+=1
) else (
  echo       ok: host test subset
)

:device_test
if "%WANT_GPU%"=="0" (
  echo [3/3] device test skipped; pass --gpu to include it
  goto :done
)
echo [3/3] ninfer_device_test
"%NINFER_BUILD_DIR%\tests\ninfer_device_test.exe"
if errorlevel 1 (
  echo       FAIL: device test ^(a card held by another process reports cudaErrorMemoryAllocation^)
  set /a STAGES_FAILED+=1
) else (
  echo       ok: device test
)

:done
echo.
if "%STAGES_FAILED%"=="0" (
  echo smoke: PASS
  exit /b 0
)
echo smoke: FAIL ^(%STAGES_FAILED% stage^(s^)^)
exit /b %STAGES_FAILED%

:no_build
echo No ninfer.exe under "%NINFER_BUILD_DIR%\apps".
echo Run: scripts\windows\configure-novcvars.cmd then scripts\windows\build-novcvars.cmd
exit /b 1
