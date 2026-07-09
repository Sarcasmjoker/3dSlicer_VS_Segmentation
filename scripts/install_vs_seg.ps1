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

# Run a conda sub-command and stream output directly to the console.
# Returns the process exit code.
function Run-Conda {
    param([string[]]$CArgs)
    $cmdLine = "`"$script:CondaExe`" " + ($CArgs -join " ")
    $proc = Start-Process -FilePath "cmd.exe" `
                          -ArgumentList "/c $cmdLine" `
                          -NoNewWindow -Wait -PassThru
    return $proc.ExitCode
}

# ── Step 0: sanity ────────────────────────────────────────────────────────
Banner "Step 0 / 4  --  Checking system"

if (-not (Test-Path $EnvYml)) {
    FAIL "environment.yml not found at:`n        $EnvYml`n`n  Make sure 'scripts' is still inside the repository folder."
}
OK "Found environment.yml"

# ── Step 1: locate (or install) Miniforge ────────────────────────────────
Banner "Step 1 / 4  --  Locating Python / conda"

# Search order: common install locations, then PATH
function Find-CondaRoot {
    $candidates = @(
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
    foreach ($r in $candidates) {
        if (Test-Path (Join-Path $r "condabin\conda.bat")) { return $r }
    }
    # Last resort: conda on PATH
    $cmd = Get-Command conda -ErrorAction SilentlyContinue
    if ($cmd) {
        # Walk up from the conda executable to find the root that has condabin\
        $p = $cmd.Source
        for ($i = 0; $i -lt 5; $i++) {
            $p = Split-Path $p -Parent
            if (Test-Path (Join-Path $p "condabin\conda.bat")) { return $p }
        }
    }
    return $null
}

$CondaRoot = Find-CondaRoot

if (-not $CondaRoot) {
    WARN "No conda / Miniforge found.  Downloading Miniforge3 (~100 MB)..."
    $installDir = Join-Path $env:USERPROFILE "miniforge3"
    $installer  = Join-Path $env:TEMP "Miniforge3-setup.exe"
    $urls = @(
        "https://github.com/conda-forge/miniforge/releases/latest/download/Miniforge3-Windows-x86_64.exe",
        "https://mirror.nju.edu.cn/github-release/conda-forge/miniforge/LatestRelease/Miniforge3-Windows-x86_64.exe"
    )
    $ok = $false
    foreach ($url in $urls) {
        INFO "Downloading from: $url"
        try {
            Invoke-WebRequest -Uri $url -OutFile $installer -UseBasicParsing -TimeoutSec 180
            $ok = $true
            OK "Download complete"
            break
        } catch {
            WARN "That source failed, trying next..."
        }
    }
    if (-not $ok) {
        FAIL "Could not download Miniforge3.`n  Check your internet connection, then try again.`n  Or install manually from https://github.com/conda-forge/miniforge"
    }
    INFO "Installing Miniforge3 (silent, current user only, no admin needed)..."
    $proc = Start-Process -FilePath $installer `
                          -ArgumentList "/InstallationType=JustMe /RegisterPython=0 /AddToPath=0 /S /D=$installDir" `
                          -Wait -PassThru
    Remove-Item $installer -Force -ErrorAction SilentlyContinue
    if ($proc.ExitCode -ne 0) {
        FAIL "Miniforge3 installer exited with code $($proc.ExitCode).`n  Try installing manually from https://github.com/conda-forge/miniforge"
    }
    if (-not (Test-Path (Join-Path $installDir "condabin\conda.bat"))) {
        FAIL "Miniforge3 did not install correctly (condabin\conda.bat not found)."
    }
    OK "Miniforge3 installed at: $installDir"
    $CondaRoot = $installDir
}
else {
    OK "Found conda root at: $CondaRoot"
}

# The executable we will use for all conda calls
$script:CondaExe = Join-Path $CondaRoot "condabin\conda.bat"

# The environment will always live here -- we do NOT rely on JSON parsing
$EnvPath = Join-Path $CondaRoot "envs\$EnvName"
OK "Environment will be at: $EnvPath"

# ── Step 2: mirror config ─────────────────────────────────────────────────
Banner "Step 2 / 4  --  Network / mirror"

Write-Host ""
Write-Host "  Type Y if pypi.org or download.pytorch.org is slow or blocked" -ForegroundColor Gray
Write-Host "  from your network (e.g. mainland China). Otherwise press Enter." -ForegroundColor Gray
Write-Host ""
$mirrorChoice = Read-Host "  Use a package mirror? [y/N]"

$EnvYmlToUse = $EnvYml
if ($mirrorChoice -match '^[Yy]') {
    $pipMirror = Read-Host "  Pip index URL (Enter = Aliyun)"
    if ([string]::IsNullOrWhiteSpace($pipMirror)) {
        $pipMirror = "https://mirrors.aliyun.com/pypi/simple/"
    }
    $torchMirror = Read-Host "  PyTorch cu128 wheel URL (Enter = Aliyun)"
    if ([string]::IsNullOrWhiteSpace($torchMirror)) {
        $torchMirror = "https://mirrors.aliyun.com/pytorch-wheels/cu128/"
    }
    $tmpYml = Join-Path $env:TEMP "vs_seg_env_mirror.yml"
    $content = Get-Content $EnvYml -Raw -Encoding UTF8
    $content = $content -replace `
        '- --extra-index-url https://download\.pytorch\.org/whl/cu128', `
        "- --index-url $pipMirror`n      - --find-links $torchMirror"
    Set-Content -Path $tmpYml -Value $content -Encoding UTF8
    $EnvYmlToUse = $tmpYml
    OK "Using mirror configuration"
}
else {
    INFO "Using default sources (pypi.org / download.pytorch.org)"
}

# ── Step 3: create / update env ───────────────────────────────────────────
Banner "Step 3 / 4  --  Setting up the '$EnvName' environment"

$envExists = Test-Path (Join-Path $EnvPath "python.exe")
$action    = "create"

if ($envExists) {
    Write-Host ""
    WARN "A '$EnvName' environment already exists at: $EnvPath"
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
        $rc = Run-Conda @("env", "remove", "-n", $EnvName, "-y")
        INFO "Creating '$EnvName' environment from environment.yml."
        INFO "(This downloads ~4 GB of packages. Please be patient.)"
        $rc = Run-Conda @("env", "create", "-n", $EnvName, "-f", "`"$EnvYmlToUse`"")
        if ($rc -ne 0) { FAIL "Environment creation failed (exit code $rc).`n  Check the messages above for details." }
        OK "Environment created"
    }
    "update" {
        if ($envExists) {
            INFO "Updating packages in '$EnvName' environment..."
            $rc = Run-Conda @("env", "update", "-n", $EnvName, "-f", "`"$EnvYmlToUse`"", "--prune")
        } else {
            INFO "Creating '$EnvName' environment from environment.yml."
            INFO "(This downloads ~4 GB of packages. Please be patient.)"
            $rc = Run-Conda @("env", "create", "-n", $EnvName, "-f", "`"$EnvYmlToUse`"")
        }
        if ($rc -ne 0) { FAIL "Environment setup failed (exit code $rc).`n  Check the messages above for details." }
        OK "Environment ready"
    }
    "skip" {
        INFO "Skipping environment creation/update."
    }
}

if ($EnvYmlToUse -ne $EnvYml) {
    Remove-Item $EnvYmlToUse -Force -ErrorAction SilentlyContinue
}

# Verify python.exe is now present
$PythonExe = Join-Path $EnvPath "python.exe"
if (-not (Test-Path $PythonExe)) {
    FAIL "python.exe not found at: $PythonExe`n`n  The environment may not have been created correctly.`n  Try re-running and choosing [R] to recreate from scratch."
}
OK "python.exe confirmed at: $PythonExe"

# ── Step 4: GPU self-test ─────────────────────────────────────────────────
Banner "Step 4 / 4  --  GPU self-test"

$gpuScript = Join-Path $env:TEMP "vs_seg_gpu_test.py"
@'
import torch, sys
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

$result = & $PythonExe $gpuScript 2>&1
Remove-Item $gpuScript -Force -ErrorAction SilentlyContinue

$resultStr = ($result | Out-String).Trim()

if ($resultStr -match "GPU_OK\|([^\|]+)\|(.+)") {
    OK "PyTorch $($Matches[1]) installed"
    OK "GPU detected: $($Matches[2])"
    Write-Host ""
    Write-Host "  Your GPU passed the test.  You are ready to use the" -ForegroundColor Green
    Write-Host "  VS Segmentation extension in 3D Slicer." -ForegroundColor Green
}
elseif ($resultStr -match "GPU_NONE\|(.+)") {
    WARN "PyTorch $($Matches[1]) is installed but NO CUDA GPU was found."
    WARN "The extension requires an NVIDIA GPU with CUDA support (>= 8 GB VRAM)."
    WARN "Make sure the latest NVIDIA driver is installed, then re-run this test."
}
elseif ($resultStr -match "GPU_ERR\|(.+)") {
    WARN "GPU test raised an error: $($Matches[1])"
}
else {
    WARN "Unexpected GPU test output:"
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
