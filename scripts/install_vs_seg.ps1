<#
.SYNOPSIS
  One-click installer for the "vs_seg" conda environment.
  Run via install_vs_seg.bat -- do not run this file directly.
#>

$ErrorActionPreference = "Continue"

$EnvName  = "vs_seg"
$RepoRoot = Split-Path -Parent $PSScriptRoot
$EnvYml   = Join-Path $RepoRoot "environment.yml"

# ── Helpers ──────────────────────────────────────────────────────────────
function Banner($text) {
    Write-Host ""
    Write-Host ("=" * 56) -ForegroundColor Cyan
    Write-Host "  $text" -ForegroundColor Cyan
    Write-Host ("=" * 56) -ForegroundColor Cyan
}
function OK($msg)   { Write-Host "  [OK]  $msg" -ForegroundColor Green  }
function WARN($msg) { Write-Host "  [!]   $msg" -ForegroundColor Yellow }
function INFO($msg) { Write-Host "        $msg" -ForegroundColor Gray   }
function FAIL($msg) {
    Write-Host ""
    Write-Host "  [FAIL]  $msg" -ForegroundColor Red
    Write-Host ""
    Write-Host "  Setup did not complete. Read the messages above." -ForegroundColor Red
    Write-Host ""
    Read-Host "  Press Enter to exit"
    exit 1
}

# Run a conda command showing live output in the window.
# Returns the process exit code.
function Run-Conda([string[]]$CArgs) {
    # Build the full command line with quoted conda bat path
    $args2 = $CArgs -join " "
    $proc  = Start-Process "cmd.exe" -ArgumentList "/c `"$script:CondaBat`" $args2" `
                           -NoNewWindow -Wait -PassThru
    return $proc.ExitCode
}

# Run a conda command silently and return its stdout lines.
function Get-CondaOutput([string[]]$CArgs) {
    $args2 = $CArgs -join " "
    $out   = & cmd.exe /c "`"$script:CondaBat`" $args2 2>&1"
    return $out
}

# ── Step 0: sanity ────────────────────────────────────────────────────────
Banner "Step 0 / 4  --  Checking system"

if (-not (Test-Path $EnvYml)) {
    FAIL "environment.yml not found at:`n        $EnvYml`n`n  Make sure the 'scripts' folder is still inside the repository."
}
OK "Found environment.yml at: $EnvYml"

# ── Step 1: locate (or install) conda ────────────────────────────────────
Banner "Step 1 / 4  --  Locating Python / conda"

function Find-CondaBat {
    # Check common install roots
    $roots = @(
        (Join-Path $env:USERPROFILE  "miniforge3"),
        (Join-Path $env:USERPROFILE  "Miniforge3"),
        (Join-Path $env:LOCALAPPDATA "miniforge3"),
        (Join-Path $env:USERPROFILE  "miniconda3"),
        (Join-Path $env:USERPROFILE  "Miniconda3"),
        (Join-Path $env:USERPROFILE  "anaconda3"),
        (Join-Path $env:USERPROFILE  "Anaconda3"),
        (Join-Path $env:ProgramData  "miniforge3"),
        (Join-Path $env:ProgramData  "Miniconda3"),
        (Join-Path $env:ProgramData  "Anaconda3")
    )
    foreach ($r in $roots) {
        $bat = Join-Path $r "condabin\conda.bat"
        if (Test-Path $bat) { return $bat }
    }
    # Fall back: look for conda on PATH
    $cmd = Get-Command conda -ErrorAction SilentlyContinue
    if ($cmd) {
        # Walk up from the conda.exe/bat to find the root containing condabin
        $p = $cmd.Source
        for ($i = 0; $i -lt 5; $i++) {
            $p = Split-Path $p -Parent
            $bat = Join-Path $p "condabin\conda.bat"
            if (Test-Path $bat) { return $bat }
        }
    }
    return $null
}

$script:CondaBat = Find-CondaBat

if (-not $script:CondaBat) {
    WARN "No conda/Miniforge found. Downloading Miniforge3 (~100 MB installer)..."
    $installDir = Join-Path $env:USERPROFILE "miniforge3"
    $installer  = Join-Path $env:TEMP "Miniforge3-setup.exe"
    $urls = @(
        "https://github.com/conda-forge/miniforge/releases/latest/download/Miniforge3-Windows-x86_64.exe",
        "https://mirror.nju.edu.cn/github-release/conda-forge/miniforge/LatestRelease/Miniforge3-Windows-x86_64.exe"
    )
    $downloaded = $false
    foreach ($url in $urls) {
        INFO "Trying: $url"
        try {
            Invoke-WebRequest -Uri $url -OutFile $installer -UseBasicParsing -TimeoutSec 180
            $downloaded = $true
            OK "Download complete"
            break
        } catch {
            WARN "That source failed, trying the next one..."
        }
    }
    if (-not $downloaded) {
        FAIL "Could not download Miniforge3. Check your internet connection and try again.`n  Or install manually from https://github.com/conda-forge/miniforge"
    }
    INFO "Installing Miniforge3 silently (current user only, no admin needed)..."
    $proc = Start-Process -FilePath $installer `
                          -ArgumentList "/InstallationType=JustMe /RegisterPython=0 /AddToPath=0 /S /D=$installDir" `
                          -Wait -PassThru
    Remove-Item $installer -Force -ErrorAction SilentlyContinue
    if ($proc.ExitCode -ne 0) {
        FAIL "Miniforge3 installer failed (exit code $($proc.ExitCode)).`n  Install manually from https://github.com/conda-forge/miniforge"
    }
    $script:CondaBat = Join-Path $installDir "condabin\conda.bat"
    if (-not (Test-Path $script:CondaBat)) {
        FAIL "Miniforge3 installation did not produce expected files.`n  Install manually from https://github.com/conda-forge/miniforge"
    }
    OK "Miniforge3 installed at: $installDir"
}
else {
    OK "Found conda at: $($script:CondaBat)"
}

# ── Helper: find env path via "conda info --envs" ─────────────────────────
# Works regardless of whether conda is a user or system install, because
# "conda info --envs" always lists the actual on-disk paths. Plain-text
# output avoids the ANSI/warning lines that corrupt the --json output.
function Get-EnvPath([string]$Name) {
    $lines = Get-CondaOutput @("info", "--envs")
    foreach ($line in $lines) {
        $line = $line.Trim()
        if ($line -match '^#' -or $line -eq '') { continue }
        # Each non-comment line: "  name   [*]   /path/to/env"
        # The path is the last space-separated token that looks like a path
        $parts = $line -split '\s+'
        foreach ($part in $parts) {
            if ($part -match '[:\\]' -or $part -match '^/') {
                if ((Split-Path $part -Leaf) -eq $Name) {
                    return $part
                }
            }
        }
    }
    return $null
}

# ── Step 2: mirror config ─────────────────────────────────────────────────
Banner "Step 2 / 4  --  Network / mirror"

Write-Host ""
Write-Host "  Type Y if pypi.org or download.pytorch.org is slow/blocked" -ForegroundColor Gray
Write-Host "  on your network (e.g. mainland China). Otherwise press Enter." -ForegroundColor Gray
Write-Host ""
$mirrorChoice = Read-Host "  Use a package mirror? [y/N]"

$EnvYmlToUse = $EnvYml
if ($mirrorChoice -match '^[Yy]') {
    $pipMirror = Read-Host "  Pip index URL (Enter = Aliyun default)"
    if ([string]::IsNullOrWhiteSpace($pipMirror)) {
        $pipMirror = "https://mirrors.aliyun.com/pypi/simple/"
    }
    $torchMirror = Read-Host "  PyTorch cu128 wheel URL (Enter = Aliyun default)"
    if ([string]::IsNullOrWhiteSpace($torchMirror)) {
        $torchMirror = "https://mirrors.aliyun.com/pytorch-wheels/cu128/"
    }
    $tmpYml  = Join-Path $env:TEMP "vs_seg_env_mirror.yml"
    $content = Get-Content $EnvYml -Raw -Encoding UTF8
    $content = $content -replace `
        '- --extra-index-url https://download\.pytorch\.org/whl/cu128', `
        "- --index-url $pipMirror`n      - --find-links $torchMirror"
    Set-Content -Path $tmpYml -Value $content -Encoding UTF8
    $EnvYmlToUse = $tmpYml
    OK "Mirror configuration written"
}
else {
    INFO "Using default sources (pypi.org / download.pytorch.org)"
}

# ── Step 3: create / update env ───────────────────────────────────────────
Banner "Step 3 / 4  --  Setting up the '$EnvName' environment"

# Check whether the env already exists
$existingPath = Get-EnvPath $EnvName
$envExists    = ($null -ne $existingPath)
$action       = "create"

if ($envExists) {
    Write-Host ""
    WARN "A '$EnvName' environment already exists at: $existingPath"
    Write-Host ""
    Write-Host "  [R]  Remove and re-create from scratch" -ForegroundColor Gray
    Write-Host "  [U]  Update packages in place  (default)" -ForegroundColor Gray
    Write-Host "  [S]  Skip -- just test the GPU" -ForegroundColor Gray
    Write-Host ""
    $choice = Read-Host "  Your choice [R/U/S, default U]"
    switch -Regex ($choice.Trim()) {
        '^[Rr]' { $action = "recreate" }
        '^[Ss]' { $action = "skip"     }
        default { $action = "update"   }
    }
}

Write-Host ""

switch ($action) {
    "recreate" {
        INFO "Removing existing '$EnvName' environment..."
        Run-Conda @("env", "remove", "-n", $EnvName, "-y") | Out-Null
        INFO "Creating '$EnvName' from environment.yml (~4 GB download, please wait)..."
        $rc = Run-Conda @("env", "create", "-n", $EnvName, "-f", "`"$EnvYmlToUse`"")
        if ($rc -ne 0) { FAIL "Environment creation failed (exit code $rc).`n  See the output above for details." }
        OK "Environment created"
    }
    "update" {
        if ($envExists) {
            INFO "Updating packages in '$EnvName' environment..."
            $rc = Run-Conda @("env", "update", "-n", $EnvName, "-f", "`"$EnvYmlToUse`"", "--prune")
        } else {
            INFO "Creating '$EnvName' from environment.yml (~4 GB download, please wait)..."
            $rc = Run-Conda @("env", "create", "-n", $EnvName, "-f", "`"$EnvYmlToUse`"")
        }
        if ($rc -ne 0) { FAIL "Environment setup failed (exit code $rc).`n  See the output above for details." }
        OK "Environment ready"
    }
    "skip" { INFO "Skipping environment creation/update." }
}

if ($EnvYmlToUse -ne $EnvYml) {
    Remove-Item $EnvYmlToUse -Force -ErrorAction SilentlyContinue
}

# Find the environment path now that it definitely exists
$EnvPath = Get-EnvPath $EnvName
INFO "Searching for '$EnvName' in conda environment list..."

if (-not $EnvPath) {
    # Fallback: check the two most common locations directly
    $fallbacks = @(
        (Join-Path $env:USERPROFILE ".conda\envs\$EnvName"),
        (Join-Path (Split-Path (Split-Path $script:CondaBat -Parent) -Parent) "envs\$EnvName")
    )
    foreach ($fb in $fallbacks) {
        if (Test-Path (Join-Path $fb "python.exe")) {
            $EnvPath = $fb
            break
        }
    }
}

if (-not $EnvPath -or -not (Test-Path (Join-Path $EnvPath "python.exe"))) {
    # Print what conda info --envs actually returned to help diagnose
    Write-Host ""
    WARN "Could not locate the environment. Output of 'conda info --envs':"
    Get-CondaOutput @("info", "--envs") | ForEach-Object { INFO "  $_" }
    FAIL "python.exe not found in the '$EnvName' environment.`n  Try re-running and choosing [R] to recreate."
}

OK "Environment found at: $EnvPath"
$PythonExe = Join-Path $EnvPath "python.exe"

# ── Step 4: GPU self-test ─────────────────────────────────────────────────
Banner "Step 4 / 4  --  GPU self-test"

$gpuScript = Join-Path $env:TEMP "vs_seg_gpu_test.py"
@'
import torch
try:
    if torch.cuda.is_available():
        nm = torch.cuda.get_device_name(0)
        x  = torch.rand(4, 4, device="cuda")
        _  = (x @ x).sum().item()
        print("GPU_OK|" + torch.__version__ + "|" + nm)
    else:
        print("GPU_NONE|" + torch.__version__)
except Exception as e:
    print("GPU_ERR|" + str(e))
'@ | Set-Content -Path $gpuScript -Encoding UTF8

$result    = & $PythonExe $gpuScript 2>&1
$resultStr = ($result | Out-String).Trim()
Remove-Item $gpuScript -Force -ErrorAction SilentlyContinue

if ($resultStr -match "GPU_OK\|([^\|]+)\|(.+)") {
    OK "PyTorch $($Matches[1]) installed"
    OK "GPU detected: $($Matches[2])"
    Write-Host ""
    Write-Host "  Your GPU passed the test. You are ready to use" -ForegroundColor Green
    Write-Host "  the VS Segmentation extension in 3D Slicer." -ForegroundColor Green
}
elseif ($resultStr -match "GPU_NONE\|(.+)") {
    WARN "PyTorch $($Matches[1]) is installed but NO CUDA GPU was detected."
    WARN "The extension requires an NVIDIA GPU with CUDA support (>= 8 GB VRAM)."
    WARN "Make sure the latest NVIDIA driver is installed, then try again."
}
elseif ($resultStr -match "GPU_ERR\|(.+)") {
    WARN "GPU test error: $($Matches[1])"
}
else {
    WARN "Unexpected GPU test output (showing raw):"
    foreach ($line in $result) { INFO "  $line" }
}

# ── Summary ───────────────────────────────────────────────────────────────
Banner "Setup complete"

Write-Host ""
Write-Host "  Paste this path into the 'vs_seg env directory' field" -ForegroundColor White
Write-Host "  in the VS Segmentation panel inside 3D Slicer:" -ForegroundColor White
Write-Host ""
Write-Host "      $EnvPath" -ForegroundColor Green
Write-Host ""
Write-Host "  Next steps in 3D Slicer:" -ForegroundColor White
Write-Host "    1. Edit > Application Settings > Modules" -ForegroundColor White
Write-Host "    2. Additional module paths > Add > select:" -ForegroundColor White
Write-Host "         $RepoRoot\VSSegmentation" -ForegroundColor White
Write-Host "    3. Click OK, restart Slicer, open 'VS Segmentation'." -ForegroundColor White
Write-Host ""
Read-Host "  Press Enter to close this window"
