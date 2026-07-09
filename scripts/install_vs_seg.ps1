<#
.SYNOPSIS
  One-click installer for the "vs_seg" conda environment used by the
  VS Segmentation 3D Slicer extension.

.DESCRIPTION
  Designed for users with NO programming background. Double-click
  install_vs_seg.bat in the same folder instead of running this file
  directly -- that wrapper launches this script with the correct options
  and keeps the window open so you can read the results.

  What this script does, step by step:
    1. Looks for an existing conda/Miniforge/Anaconda installation.
    2. If none is found, downloads and silently installs Miniforge3
       (a minimal, free Python distribution) for the current user only
       -- no administrator rights required.
    3. Creates (or updates) a dedicated "vs_seg" environment from the
       environment.yml file included in this repository, with the exact
       package versions needed by the extension (PyTorch + CUDA + nnU-Net v2).
    4. Runs a GPU self-test and prints a clear pass/fail summary, along
       with the exact folder path to paste into the extension's
       "vs_seg env directory" field.

  Nothing outside this environment is modified: no system-wide PATH
  changes, no admin rights, no other Python installation is touched.
#>

[CmdletBinding()]
param(
    # Where to install Miniforge if no conda installation is found.
    [string]$MiniforgeInstallDir = (Join-Path $env:USERPROFILE "miniforge3")
)

$ErrorActionPreference = "Stop"
$RepoRoot   = Split-Path -Parent $PSScriptRoot
$EnvYmlPath = Join-Path $RepoRoot "environment.yml"
$EnvName    = "vs_seg"

# ---------------------------------------------------------------------------
# Small helpers (ASCII-only output: avoids garbled text on non-UTF8 consoles,
# the same class of issue that previously broke the extension's own logging)
# ---------------------------------------------------------------------------

function Write-Section($text) {
    Write-Host ""
    Write-Host "==== $text ====" -ForegroundColor Cyan
}

function Write-Info($text)  { Write-Host "  $text" -ForegroundColor Gray }
function Write-Ok($text)    { Write-Host "  [OK] $text" -ForegroundColor Green }
function Write-Warn($text)  { Write-Host "  [!]  $text" -ForegroundColor Yellow }

function Write-FailAndExit($text) {
    Write-Host ""
    Write-Host "  [FAILED] $text" -ForegroundColor Red
    Write-Host ""
    Write-Host "Setup did not complete. See the message above for details." -ForegroundColor Red
    exit 1
}

# ---------------------------------------------------------------------------
# Step 0: sanity checks
# ---------------------------------------------------------------------------

Write-Section "Checking system"

if (-not [Environment]::Is64BitOperatingSystem) {
    Write-FailAndExit "This installer requires 64-bit Windows. Your system appears to be 32-bit."
}
Write-Ok "64-bit Windows detected"

if (-not (Test-Path $EnvYmlPath)) {
    Write-FailAndExit "Could not find environment.yml at: $EnvYmlPath`nMake sure this script is still inside the cloned repository's scripts\ folder."
}
Write-Ok "Found environment.yml"

# ---------------------------------------------------------------------------
# Step 1: find or install conda
# ---------------------------------------------------------------------------

Write-Section "Looking for an existing Python/conda installation"

function Find-CondaRoot {
    # 1) Already on PATH?
    $cmd = Get-Command conda -ErrorAction SilentlyContinue
    if ($cmd) {
        # conda.exe/.bat typically lives in <root>\condabin or <root>\Scripts
        $binDir = Split-Path -Parent $cmd.Source
        $root   = Split-Path -Parent $binDir
        if (Test-Path (Join-Path $root "condabin")) { return $root }
    }
    # 2) Common install locations, user-level first (no admin required)
    $candidates = @(
        (Join-Path $env:USERPROFILE "miniforge3"),
        (Join-Path $env:USERPROFILE "Miniconda3"),
        (Join-Path $env:USERPROFILE "Anaconda3"),
        (Join-Path $env:LOCALAPPDATA "miniforge3"),
        (Join-Path $env:ProgramData "miniforge3"),
        (Join-Path $env:ProgramData "Anaconda3")
    )
    foreach ($c in $candidates) {
        if (Test-Path (Join-Path $c "condabin\conda.bat")) { return $c }
    }
    return $null
}

$CondaRoot = Find-CondaRoot

if ($CondaRoot) {
    Write-Ok "Found existing conda installation at: $CondaRoot"
}
else {
    Write-Info "No conda installation found. Installing Miniforge3 (this only affects your user account)."
    Write-Info "Install location: $MiniforgeInstallDir"

    $installerPath = Join-Path $env:TEMP "Miniforge3-installer.exe"
    $downloadUrls = @(
        "https://github.com/conda-forge/miniforge/releases/latest/download/Miniforge3-Windows-x86_64.exe",
        "https://mirror.nju.edu.cn/github-release/conda-forge/miniforge/LatestRelease/Miniforge3-Windows-x86_64.exe"
    )

    $downloaded = $false
    foreach ($url in $downloadUrls) {
        Write-Info "Downloading from: $url"
        try {
            Invoke-WebRequest -Uri $url -OutFile $installerPath -UseBasicParsing
            $downloaded = $true
            break
        }
        catch {
            Write-Warn "Download failed from this source, trying the next one if available..."
        }
    }
    if (-not $downloaded) {
        Write-FailAndExit "Could not download the Miniforge installer from any source. Check your internet connection and try again, or install Miniforge manually from https://github.com/conda-forge/miniforge and re-run this script."
    }
    Write-Ok "Download complete"

    Write-Info "Installing (silent, current user only, no PATH changes)..."
    $installArgs = @(
        "/InstallationType=JustMe",
        "/RegisterPython=0",
        "/AddToPath=0",
        "/S",
        "/D=$MiniforgeInstallDir"
    )
    $proc = Start-Process -FilePath $installerPath -ArgumentList $installArgs -Wait -PassThru
    Remove-Item $installerPath -ErrorAction SilentlyContinue

    if ($proc.ExitCode -ne 0 -or -not (Test-Path (Join-Path $MiniforgeInstallDir "condabin\conda.bat"))) {
        Write-FailAndExit "Miniforge installation did not complete successfully (exit code $($proc.ExitCode))."
    }
    Write-Ok "Miniforge installed at: $MiniforgeInstallDir"
    $CondaRoot = $MiniforgeInstallDir
}

$CondaBat = Join-Path $CondaRoot "condabin\conda.bat"

# ---------------------------------------------------------------------------
# Step 2: optional mirror for users with restricted access to
# pypi.org / download.pytorch.org (e.g. mainland China networks)
# ---------------------------------------------------------------------------

Write-Section "Network configuration"

Write-Host "  If pypi.org or download.pytorch.org are slow or unreachable from" -ForegroundColor Gray
Write-Host "  your network, you can use a mirror instead." -ForegroundColor Gray
$useMirror = Read-Host "  Use a package mirror? [y/N]"

$EnvYmlToUse = $EnvYmlPath
if ($useMirror -match '^[Yy]') {
    $pipMirror  = Read-Host "  Pip index URL [default: https://mirrors.aliyun.com/pypi/simple/]"
    if ([string]::IsNullOrWhiteSpace($pipMirror)) { $pipMirror = "https://mirrors.aliyun.com/pypi/simple/" }
    $torchMirror = Read-Host "  PyTorch (cu128) wheel URL [default: https://mirrors.aliyun.com/pytorch-wheels/cu128/]"
    if ([string]::IsNullOrWhiteSpace($torchMirror)) { $torchMirror = "https://mirrors.aliyun.com/pytorch-wheels/cu128/" }

    $tmpEnvYml = Join-Path $env:TEMP "vs_seg_environment.mirror.yml"
    $content = Get-Content $EnvYmlPath -Raw
    $content = $content -replace '--extra-index-url https://download\.pytorch\.org/whl/cu128', "--index-url $pipMirror`n      - --find-links $torchMirror"
    Set-Content -Path $tmpEnvYml -Value $content -Encoding UTF8
    $EnvYmlToUse = $tmpEnvYml
    Write-Ok "Using mirror configuration for this install"
}
else {
    Write-Info "Using default package sources (pypi.org / download.pytorch.org)"
}

# ---------------------------------------------------------------------------
# Step 3: create or update the vs_seg environment
# ---------------------------------------------------------------------------

Write-Section "Setting up the '$EnvName' environment"

function Get-CondaEnvPath($name) {
    $json = & $CondaBat env list --json 2>$null | Out-String
    if (-not $json) { return $null }
    $data = $json | ConvertFrom-Json
    foreach ($p in $data.envs) {
        if ((Split-Path -Leaf $p) -eq $name) { return $p }
    }
    return $null
}

$existingEnvPath = Get-CondaEnvPath $EnvName
$action = "create"

if ($existingEnvPath) {
    Write-Warn "An environment named '$EnvName' already exists at: $existingEnvPath"
    Write-Host "  [R]ecreate from scratch  [U]pdate in place  [S]kip and just test it" -ForegroundColor Gray
    $choice = Read-Host "  Choose R/U/S [default: U]"
    switch -Regex ($choice) {
        '^[Rr]' { $action = "recreate" }
        '^[Ss]' { $action = "skip" }
        default { $action = "update" }
    }
}

switch ($action) {
    "recreate" {
        Write-Info "Removing existing environment..."
        & $CondaBat env remove -n $EnvName -y | Out-Null
        Write-Info "Creating environment from environment.yml (this can take several minutes)..."
        & $CondaBat env create -n $EnvName -f $EnvYmlToUse
        if ($LASTEXITCODE -ne 0) { Write-FailAndExit "Environment creation failed. See the output above for details." }
    }
    "update" {
        if ($existingEnvPath) {
            Write-Info "Updating existing environment (this can take several minutes)..."
            & $CondaBat env update -n $EnvName -f $EnvYmlToUse --prune
        }
        else {
            Write-Info "Creating environment from environment.yml (this can take several minutes)..."
            & $CondaBat env create -n $EnvName -f $EnvYmlToUse
        }
        if ($LASTEXITCODE -ne 0) { Write-FailAndExit "Environment setup failed. See the output above for details." }
    }
    "skip" {
        Write-Info "Skipping environment creation/update as requested."
    }
}

if ($EnvYmlToUse -ne $EnvYmlPath) {
    Remove-Item $EnvYmlToUse -ErrorAction SilentlyContinue
}

$EnvPath = Get-CondaEnvPath $EnvName
if (-not $EnvPath) {
    Write-FailAndExit "Could not locate the '$EnvName' environment after setup. Something went wrong."
}
Write-Ok "Environment ready at: $EnvPath"

# ---------------------------------------------------------------------------
# Step 4: GPU self-test
# ---------------------------------------------------------------------------

Write-Section "Testing GPU access"

$envPython = Join-Path $EnvPath "python.exe"
if (-not (Test-Path $envPython)) {
    Write-FailAndExit "Could not find python.exe inside the environment at: $EnvPath"
}

$testScript = @'
import torch
if torch.cuda.is_available():
    name = torch.cuda.get_device_name(0)
    x = torch.rand(3, 3, device="cuda")
    _ = (x @ x).sum().item()
    print("GPU_OK|" + torch.__version__ + "|" + name)
else:
    print("GPU_MISSING|" + torch.__version__)
'@
$testScriptPath = Join-Path $env:TEMP "vs_seg_gpu_test.py"
Set-Content -Path $testScriptPath -Value $testScript -Encoding UTF8

$result = & $envPython $testScriptPath 2>&1
Remove-Item $testScriptPath -ErrorAction SilentlyContinue

if ($result -match '^GPU_OK\|([^\|]+)\|(.+)$') {
    Write-Ok "PyTorch $($Matches[1]) detected GPU: $($Matches[2])"
}
elseif ($result -match '^GPU_MISSING\|(.+)$') {
    Write-Warn "PyTorch $($Matches[1]) installed, but no CUDA GPU was detected."
    Write-Warn "The extension will not run without a CUDA-capable NVIDIA GPU."
    Write-Warn "See the 'Minimum hardware requirements' section of the README."
}
else {
    Write-Warn "Could not run the GPU self-test. Raw output:"
    Write-Host "  $result" -ForegroundColor Gray
}

# ---------------------------------------------------------------------------
# Done
# ---------------------------------------------------------------------------

Write-Section "Setup complete"
Write-Host ""
Write-Host "  Next steps in 3D Slicer:" -ForegroundColor White
Write-Host "  1. Open 3D Slicer, then Edit > Application Settings > Modules." -ForegroundColor White
Write-Host "  2. Under 'Additional module paths', add:" -ForegroundColor White
Write-Host "       $RepoRoot\VSSegmentation" -ForegroundColor White
Write-Host "  3. Restart Slicer, then open the 'VS Segmentation' module." -ForegroundColor White
Write-Host "  4. In the 'vs_seg env directory' field, paste this exact path:" -ForegroundColor White
Write-Host ""
Write-Host "       $EnvPath" -ForegroundColor Green
Write-Host ""
Write-Host "  (The 'nnUNet_results directory' field is auto-detected if the" -ForegroundColor White
Write-Host "   model weights were downloaded into the models\ folder.)" -ForegroundColor White
Write-Host ""
