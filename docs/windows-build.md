# Building on Windows

Native MSVC build of NInfer V100X2. Targets `sm_70` with CUDA 12.8, one build tree per media
configuration. This document records the settings that were actually required on the porting host,
including the ones that are environment-specific.

## 1. Entry points

```bat
scripts\windows\configure-novcvars.cmd          :: write build-win
scripts\windows\build-novcvars.cmd              :: full incremental build, -j2
scripts\windows\build-novcvars.cmd -j2 ninfer_ops   :: one target
```

`configure.cmd` / `build.cmd` are the vcvars-based variants and only work on hosts where
`vcvars64.bat` can run; see §3 for why they fail on the porting host.

Both novcvars scripts take the toolchain from, in order:

| Root | Variable | Default |
|---|---|---|
| CUDA 12.8 + CUTLASS | `NINFER_TOOLCHAIN_ROOT` | `%ROOT%\_toolchain`, else `..\NInfer-V100-Duo-win\_toolchain` |
| cmake / ninja / python venv | `NINFER_TOOLS_ROOT` | `%ROOT%\.tools`, else `..\NInfer-V100-Duo-win\.tools` |

The sibling checkout is read in place through a plain path string — **do not** point these roots at a
junction or symlink. When the roots resolve through a link, nvcc fails to create its output files
(`Could not open output file`) and cmake fails to create its build tree, even though the same
binaries work when invoked from their real path.

Overridable: `NINFER_MSVC_VER` (default `14.38.33130`), `NINFER_SDK_VER` (default `10.0.19041.0`),
`NINFER_BUILD_DIR`, `NINFER_BUILD_JOBS` (default 2), `NINFER_CMAKE`.

## 2. What the configure step produces

```bat
cmake -S . -B build-win -G Ninja ^
  -DCMAKE_BUILD_TYPE=Release ^
  -DCMAKE_CUDA_ARCHITECTURES=70 ^
  -DCMAKE_CUDA_COMPILER=<toolchain>\cuda-12.8\bin\nvcc.exe ^
  -DCUDAToolkit_ROOT=<toolchain>\cuda-12.8 ^
  -DNINFER_STUB_MEDIA=ON ^
  -DFETCHCONTENT_SOURCE_DIR_CUTLASS=<toolchain>\cutlass
```

`NINFER_STUB_MEDIA=ON` removes the FFmpeg and libcurl dependencies: image and video input throw at
runtime instead of decoding, and libcurl URL acquisition throws as well. That keeps the whole
product link graph buildable without a media toolchain. `-DFETCHCONTENT_SOURCE_DIR_CUTLASS` points
CUTLASS at a pre-cloned checkout; without it, configure clones CUTLASS over the network.

## 3. Host constraints that shaped the scripts

**`reg.exe` is on the program blacklist.** `vcvars64.bat` reads the VS and SDK locations from the
registry, so it cannot run. Its entire output is `PATH` / `INCLUDE` / `LIB` / `TMP`, which the
scripts set directly. The sandbox policy that blacklists `reg.exe` is independent of the tool
sandbox; a shell with full permissions does not lift it.

**cmake 3.31.6 cannot create its build tree here.** It fails with

```
CMake Error: Unable to (re)create the private pkgRedirects directory: .../CMakeFiles/pkgRedirects
```

cmake 3.30.5 configures the same tree cleanly, so `_toolchain\cmake-3.30\bin\cmake.exe` is the
default when present. Note that `venv\Scripts\cmake.exe` is a python launcher, not the compiler
driver; the native binary it wraps lives at
`venv\Lib\site-packages\cmake\data\bin\cmake.exe`.

**Compiler children run at low integrity.** Windows gives a new directory the integrity level of
its parent, so a build tree created under a medium-integrity checkout stays medium and the
low-integrity compiler children cannot write into it. nvcc then reports

```
nvcc fatal : Could not open output file '<tmp>/tmpxft_0000xxxx_00000000'
```

Both scripts therefore run `icacls <dir> /setintegritylevel (OI)(CI)low` on the build tree and on
its `-tmp` directory as soon as those exist. This is the single most confusing failure on this host:
the file cannot be created, yet any shell can write to the directory by hand.

**`-j2` is the measured ceiling.** `-j4` has twice driven this machine into an Infinity-Fabric WHEA
storm that ended in a hard reset with no BugCheck. The default stays at 2; raising it is a hardware
decision, not a build one.

## 4. Portability changes this port needed

| Area | Change |
|---|---|
| Artifact reader | `CreateFileW` + `CreateFileMappingW`/`MapViewOfFile` plus positional `ReadFile`/`GetOverlappedResult` on a `FILE_FLAG_OVERLAPPED` handle, replacing `open`/`mmap`/`pread`. Paths render as UTF-8 for diagnostics. |
| Host KV archive | `VirtualAlloc`/`VirtualFree` in place of anonymous `mmap`. |
| Terminal detection | `_isatty(_fileno(stderr))` instead of `isatty(STDERR_FILENO)`. |
| Timestamps | `localtime_s(&tm, &t)` — MSVC reverses the POSIX argument order. |
| Process id | `_getpid`. |
| utf8proc | `UTF8PROC_STATIC=1`, otherwise the vendored header declares `dllimport` and the definition is rejected with C2491. |
| BLAS | Optional. When `find_package(BLAS)` misses, `src/ops/host/sgemm_fallback.cpp` provides `sgemm_` for the CPU vision tower. It is single threaded: correctness is unaffected, CPU vision time is worse than with a tuned BLAS. |
| Media | `decode_stub_win.cpp` / `acquire_stub_win.cpp` under `NINFER_STUB_MEDIA`. |
| Source charset | `/utf-8` for every language, not only tests. MSVC reads sources as the ANSI code page, which spams C4819 and, in `gqa_attention_volta_splitd.cu`, turns a Chinese comment line into invalid tokens ("expected an expression"). All 717 sources under `src`/`include`/`apps` verify as UTF-8. |
| NVTX v3 | `<cstdlib>` before `nvtx3/nvToolsExt.h` in `core/nvtx.h` and `core/nvtx_range.h`; the v3 init path calls `_wgetenv`, which MSVC declares in `<cstdlib>`. Without it, `ops/wrapper/sparse_moe.cpp` fails with C3861. |
| `M_LOG2E` | The MSVC CRT only declares it under `_USE_MATH_DEFINES`; `gqa_attention_volta_splitd.cu` defines the same value itself. |
| Plan move operations | `targets/qwen3_6/impl/runtime/api_impl.h` spells out the four plan types' move constructor and move assignment. MSVC does not emit an out-of-line defaulted specialization the defining translation unit never odr-uses, so `= default` leaves them undefined at link time; GCC emits weak definitions and hides the problem. |
| CuTe conformance | `ops/launcher/gqa_attention_volta_splitd.cu` compiles with `-Xcompiler=/permissive`. Its layout helpers are accepted by GCC but rejected by MSVC's conforming two-phase lookup ("Layout: template argument for template parameter T must be a type"). Scoped to that one file. |
| Host memory admission | `check_host_memory` uses `GlobalMemoryStatusEx().ullAvailPhys` instead of `/proc/meminfo`'s `MemAvailable`; the 1 GiB headroom threshold is unchanged. |

## 5. Smoke test

```bat
scripts\windows\smoke.cmd          :: usage banner + host-only test subset
scripts\windows\smoke.cmd --gpu    :: additionally enumerates the devices
```

Three stages, each fatal, exit code = number of failed stages:

1. `ninfer.exe` with no arguments must print its usage banner **and** exit non-zero. That single
   check proves the binary starts, the static CRT and static cudart are linked consistently, and
   the argument path rejects an empty request.
2. A host-only test subset through ctest: `public_api`, `artifact_reader`, `tensor_slice`,
   `kv_capacity`, `request_log`, `runtime_mechanisms`, `admission_policy`,
   `sharded_materialization`. Each of these touches neither a GPU nor an artifact, so the result
   is meaningful on a machine whose cards are busy.
3. `--gpu` only: `ninfer_device_test`, which enumerates devices without allocating.

The script sets `TMP`/`TEMP` into the build tree and drops that directory to low integrity. Skip
that step and the artifact tests fail with `failed to write artifact fixture` while
`ninfer_request_log_test` dies with 0xC0000409 — both are the unwritable temp directory, not a
product defect.

## 6. Verified state

Full build succeeds with MSVC 14.38 / CUDA 12.8 / Windows SDK 10.0.19041 in `build-win-32`:

- `apps/ninfer.exe` (392 MB) and `apps/ninfer-serve.exe` (393 MB) link.
- 145 executables produced in total, including the whole host test suite.
- `ninfer.exe` starts and prints its usage banner, so the static CRT + static cudart link is sound.

Nothing has been executed on the GPU yet. Load, decode, prefill, serving, TP2/TP4 collectives and
the vision path are unverified on Windows — that is the next gate, and it needs an artifact plus
two V100s in TCC mode.

Notes on the build itself:

- `scripts\windows\smoke.cmd` returns PASS: usage banner, 9 host tests (8 pass, 1 skipped by
  design), and `--gpu` device enumeration.
- `BUILD_TESTING` ends up `ON` even though this tree defaults it to `OFF`: CUTLASS's
  `FetchContent_MakeAvailable` pulls in `CTest`, which sets it. Configure with
  `-DBUILD_TESTING=OFF` to skip the test tree.
- Link every target through `${NINFER_CUDART_TARGET}`, never `CUDA::cudart` directly. On Windows
  the former is the static runtime, and mixing the two aborts the link with LNK2005 for every
  runtime symbol.
- Expect a `warning D9002: ignoring unknown option '/NODEFAULTLIB:LIBCMT'` per C compile; the flag
  is a link option reaching cl. Harmless, and it does apply at link time.

Known gaps:

- Media is stubbed in this tree; a media-enabled tree needs FFmpeg 8.1 and libcurl dev libraries
  plus `-DNINFER_STUB_MEDIA=OFF`.
- TP4 has no Windows precedent (the sibling port validated TP2 only).
- The CPU vision tower runs on the portable sgemm, so vision latency will not match Linux numbers.
- `tests/test_model_residency_real.cpp` uses `create_symlink`, which needs Developer Mode or an
  elevated shell on Windows.
