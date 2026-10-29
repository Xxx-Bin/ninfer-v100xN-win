<#
.SYNOPSIS
    Writes the GitHub release body for a Windows x64 media build.

.DESCRIPTION
    The body is produced as a file instead of a multiline `body: |` workflow input. A block scalar
    carrying a multi-row Markdown table went through YAML and env-file interpolation, and the table
    arrived as one table per row, so the text now never touches either.

    The archive name, its SHA256, the staged file list and the CI identity all come from the caller;
    the description of the build is fixed by the pipeline itself. No performance figure is written
    here: a hosted runner has no GPU, so numbers in a release body have to come from the acceptance
    run on the target hardware (pass them to promote-release.ps1 as -AcceptanceNote), never from the
    build machine.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string] $ZipName,
    [Parameter(Mandatory)][string] $Sha256,
    [Parameter(Mandatory)][string] $DistDirectory,
    [Parameter(Mandatory)][string] $OutFile,
    [switch] $Test
)

$ErrorActionPreference = 'Stop'

$rows = Get-ChildItem $DistDirectory -File | Sort-Object Name | ForEach-Object {
    "| ``$($_.Name)`` | $([math]::Round($_.Length / 1MB, 1)) MiB |"
}
$banner = if ($Test) {
    '> **TEST BUILD** - prefixed to distinguish it from a real release. The binaries are produced by the real pipeline; only the tag carries the test prefix.'
} else {
    ''
}
$runUrl = "$env:GITHUB_SERVER_URL/$env:GITHUB_REPOSITORY/actions/runs/$env:GITHUB_RUN_ID"

# Single-quoted here-string: backticks stay literal, which is what the Markdown code spans need.
$notes = @'
Windows x64 build for two Tesla V100-SXM2 16 GB (`sm_70`), tensor-parallel `--tp 2`, with the media
path enabled: `NINFER_STUB_MEDIA=OFF` - FFmpeg 8.1 image/video decode plus libcurl 8.11.1 URL
acquisition, so `--vision` and `image_url`/`video_url` prompts work.

| | |
|---|---|
| Toolchain | MSVC 19.x (Visual Studio 2022), CUDA 12.8.61 (portable redist), CMake + Ninja |
| Runtime | Static CRT and static cudart; no CUDA toolkit needed on the target machine |
| Runner | `windows-2022`, `NINFER_BUILD_JOBS=4` |
| Commit | `__COMMIT__` |
| Run | __RUN_URL__

## What this archive is

The tree is compiled and linked by the same `scripts\windows\configure-media.cmd` a local build
uses, so the CMake arguments are identical to a developer tree: `sm_70`, `NINFER_STUB_MEDIA=OFF`,
portable CUDA 12.8, FFmpeg 8.1, libcurl 8.11.1.

The hosted runner has no GPU, so this run proves the tree configures, compiles, links and packages.
It does **not** prove throughput or output: numerical checks, the `ctest` suite and the media
fixtures are run on the V100 host against the archive this run produces.

__BANNER__

Unzip the archive into one directory and run the executables from there: the media build loads
FFmpeg and libcurl from the executable directory, so the DLLs must stay beside `ninfer.exe` and
`ninfer-serve.exe`.

| Archive | SHA256 |
|---|---|
| `__ZIP__` | `__SHA__` |

`__ZIP__.sha256` is the sha256sum-style sidecar for the same archive.

| Contents | Size |
|---|---|
__CONTENTS__
'@

$notes = $notes.
    Replace('__COMMIT__', $env:GITHUB_SHA).
    Replace('__RUN_URL__', $runUrl).
    Replace('__BANNER__', $banner).
    Replace('__ZIP__', $ZipName).
    Replace('__SHA__', $Sha256).
    Replace('__CONTENTS__', ($rows -join "`n"))

# LF only: the release body is Markdown, and CRLF would leave stray carriage returns in it.
$text = (($notes -split "`r?`n") -join "`n").TrimEnd() + "`n"
[System.IO.File]::WriteAllText(
    (Join-Path (Get-Location) $OutFile),
    $text,
    (New-Object System.Text.UTF8Encoding($false))
)
Write-Output "release notes written to $OutFile ($($rows.Count) staged files)"
