<#
.SYNOPSIS
  One-click installer for the "vs_seg" conda environment.
  Run via install_vs_seg.bat -- do not run this file directly.
#>

# ── Never stop silently. Every error is caught explicitly below. ──────────
$ErrorActionPreference = "Continue"

$EnvName  = "vs_seg"
$RepoRoot = Split-Path -Parent $PSScriptRoot        # …/3dSlicer_VS_Segmentation
$EnvYml   = Join-Path $RepoRoot "environment.yml"

# ── Helpers ──────────────────────────────────────────────────────────────
function Banner($text) {
    Write-Host ""
    Write-Host ("=" * 54) -ForegroundColor Cyan
    Write-Host "  $text" -ForegroundColor Cyan
    Write-Host ("=" * 54) -ForegroundColor Cyan
}
function OK($msg)   { Write-Host "  [OK]  $msg" -ForegroundColor Green  }
function WARN($msg) { Write-Host "  [!]   $msg" -ForegroundColor Yellow }
function INFO($msg) { Write-Host "        $msg" -ForegroundColor Gray   }
function FAIL($msg) {
    Write-Host ""
    Write-Host "  [FAIL] $msg" -ForegroundColor Red
    Write-Host ""
    Write-Host "  Setup did not complete. Read the messages above," -ForegroundColor Red
    Write-Host "  then close this window." -ForegroundColor Red
    Write-Host ""
    Read-Host "  Press Enter to exit"
    exit 1
}

# ── Step 0: sanity checks ─────────────────────────────────────────────────
Banner "Step 0 / 4  --  Checking system"

if (-not (Test-Path $EnvYml)) {
    FAIL "environment.yml not found at:`n        $EnvYml`n`n  Make sure the 'scripts' folder is still inside the repo."
}
OK "Found environment.yml"

# ── Step 1: locate (or install) conda ────────────────────────────────────
Banner "Step 1 / 4  --  Locating Python / conda"

function Find-CondaBat {
    # 1. Already on PATH?
    $cmd = Get-Command conda -ErrorAction SilentlyContinue
    if ($cmd) {
        # cmd.Path is conda.bat or conda.exe
        if ($cmd.Source -match '\\condabin\\') { return $cmd.Source }
        # Reconstruct condabin path from any conda entry
        $root = $cmd.Source
        for ($i = 0; $i -lt 4; $i++) { $root = Split-Path $root -Parent }
        $bat = Join-Path $root "condabin\conda.bat"
        if (Test-Path $bat) { return $bat }
    }
    # 2. Common install locations
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
    return $null
}

$CondaBat = Find-CondaBat

if (-not $CondaBat) {
    WARN "No conda / Miniforge found. Downloading Miniforge3 (one-time, ~100 MB installer)..."
    $installDir = Join-Path $env:USERPROFILE "miniforge3"
    $installer  = Join-Path $env:TEMP "Miniforge3-installer.exe"

    $urls = @(
        "https://github.com/conda-forge/miniforge/releases/latest/download/Miniforge3-Windows-x86_64.exe",
        "https://mirror.nju.edu.cn/github-release/conda-forge/miniforge/LatestRelease/Miniforge3-Windows-x86_64.exe"
    )
    $downloaded = $false
    foreach ($url in $urls) {
        INFO "Trying: $url"
        try {
            Invoke-WebRequest -Uri $url -OutFile $installer -UseBasicParsing -TimeoutSec 120
            $downloaded = $true
            OK "Download complete"
            break
        } catch {
            WARN "Could not reach that source. Trying the next one..."
        }
    }
    if (-not $downloaded) {
        FAIL "Could not download Miniforge. Check your internet connection and try again.`n`n  Manual alternative:`n  Download from https://github.com/conda-forge/miniforge`n  and re-run this installer."
    }

    INFO "Installing Miniforge3 silently (this may take a minute)..."
    $argList = "/InstallationType=JustMe /RegisterPython=0 /AddToPath=0 /S /D=$installDir"
    $proc = Start-Process -FilePath $installer -ArgumentList $argList -Wait -PassThru
    Remove-Item $installer -Force -ErrorAction SilentlyContinue

    $CondaBat = Join-Path $installDir "condabin\conda.bat"
    if ($proc.ExitCode -ne 0 -or -not (Test-Path $CondaBat)) {
        FAIL "Miniforge installation failed (exit code $($proc.ExitCode)).`n  Try installing manually from https://github.com/conda-forge/miniforge"
    }
    OK "Miniforge installed at: $installDir"
}
else {
    OK "Found conda at: $CondaBat"
}

# Helper: run a conda command and return stdout
function Invoke-Conda {
    param([string[]]$Args)
    $out = & cmd /c "`"$CondaBat`" $($Args -join ' ') 2>&1"
    return $out
}

# ── Step 2: network / mirror config ──────────────────────────────────────
Banner "Step 2 / 4  --  Network configuration"

Write-Host ""
Write-Host "  If pypi.org or download.pytorch.org is slow or blocked" -ForegroundColor Gray
Write-Host "  from your network (e.g. mainland China), type Y and" -ForegroundColor Gray
Write-Host "  press Enter to use a mirror. Otherwise press Enter to skip." -ForegroundColor Gray
Write-Host ""
$mirrorChoice = Read-Host "  Use a mirror? [y/N]"

$EnvYmlToUse = $EnvYml

if ($mirrorChoice -match '^[Yy]') {
    Write-Host ""
    $pipMirror = Read-Host "  Pip index URL`n  [default: https://mirrors.aliyun.com/pypi/simple/]`n  > "
    if ([string]::IsNullOrWhiteSpace($pipMirror)) {
        $pipMirror = "https://mirrors.aliyun.com/pypi/simple/"
    }
    $torchMirror = Read-Host "  PyTorch (cu128) wheel URL`n  [default: https://mirrors.aliyun.com/pytorch-wheels/cu128/]`n  > "
    if ([string]::IsNullOrWhiteSpace($torchMirror)) {
        $torchMirror = "https://mirrors.aliyun.com/pytorch-wheels/cu128/"
    }

    $tmpYml = Join-Path $env:TEMP "vs_seg_env_mirror.yml"
    $content = Get-Content $EnvYml -Raw -Encoding UTF8
    # Replace extra-index-url line with mirror config
    $content = $content -replace '- --extra-index-url https://download\.pytorch\.org/whl/cu128',
                                  "- --index-url $pipMirror`n      - --find-links $torchMirror"
    Set-Content -Path $tmpYml -Value $content -Encoding UTF8
    $EnvYmlToUse = $tmpYml
    OK "Mirror configuration written to temp file"
}
else {
    INFO "Using default sources (pypi.org / download.pytorch.org)"
}

# ── Step 3: create / update the environment ───────────────────────────────
Banner "Step 3 / 4  --  Creating the 'vs_seg' environment"

# Check whether the environment already exists
INFO "Checking for existing environments..."
$envList = Invoke-Conda @("env", "list", "--json")
$envExists = $false
$existingPath = ""

try {
    # envList may contain warnings before the JSON -- grab the JSON part
    $jsonPart = ($envList | Where-Object { $_ -match '^\s*\{' -or $_ -match '^\s*"' }) -join "`n"
    if (-not $jsonPart) { $jsonPart = $envList -join "`n" }
    $parsed = $jsonPart | ConvertFrom-Json
    foreach ($p in $parsed.envs) {
        if ((Split-Path $p -Leaf) -eq $EnvName) {
            $envExists    = $true
            $existingPath = $p
        }
    }
} catch {
    # JSON parse failed -- fall back to a simple string search
    foreach ($line in $envList) {
        if ($line -match "\\$EnvName\b" -or $line -match "/$EnvName\b") {
            $envExists    = $true
            $existingPath = ($line -split '\s+')[0]
        }
    }
}

$action = "create"
if ($envExists) {
    Write-Host ""
    WARN "An environment named '$EnvName' already exists at:"
    INFO "  $existingPath"
    Write-Host ""
    Write-Host "  Choose an option:" -ForegroundColor Gray
    Write-Host "    [R] Remove and re-create from scratch" -ForegroundColor Gray
    Write-Host "    [U] Update in place (default)" -ForegroundColor Gray
    Write-Host "    [S] Skip environment changes, just test the GPU" -ForegroundColor Gray
    Write-Host ""
    $choice = Read-Host "  R / U / S  [default: U]"
    switch -Regex ($choice.Trim()) {
        '^[Rr]' { $action = "recreate" }
        '^[Ss]' { $action = "skip"     }
        default { $action = "update"   }
    }
}

switch ($action) {
    "recreate" {
        INFO "Removing existing environment..."
        Invoke-Conda @("env", "remove", "-n", $EnvName, "-y") | Out-Null
        INFO "Creating environment (downloading packages, ~4 GB -- please be patient)..."
        Invoke-Conda @("env", "create", "-n", $EnvName, "-f", "`"$EnvYmlToUse`"")
        if ($LASTEXITCODE -ne 0) { FAIL "Environment creation failed. See above." }
        OK "Environment created"
    }
    "update" {
        if ($envExists) {
            INFO "Updating environment (downloading any new packages)..."
            Invoke-Conda @("env", "update", "-n", $EnvName, "-f", "`"$EnvYmlToUse`"", "--prune")
        } else {
            INFO "Creating environment (downloading packages, ~4 GB -- please be patient)..."
            Invoke-Conda @("env", "create", "-n", $EnvName, "-f", "`"$EnvYmlToUse`"")
        }
        if ($LASTEXITCODE -ne 0) { FAIL "Environment setup failed. See above." }
        OK "Environment ready"
    }
    "skip" { INFO "Skipping environment setup." }
}

if ($EnvYmlToUse -ne $EnvYml) {
    Remove-Item $EnvYmlToUse -Force -ErrorAction SilentlyContinue
}

# Re-locate the environment path (may have just been created)
$EnvPath = $existingPath
if ($action -ne "skip") {
    $envList2 = Invoke-Conda @("env", "list", "--json")
    try {
        $jsonPart2 = ($envList2 | Where-Object { $_ -match '^\s*[\{\[]' }) -join "`n"
        if (-not $jsonPart2) { $jsonPart2 = $envList2 -join "`n" }
        $parsed2 = $jsonPart2 | ConvertFrom-Json
        foreach ($p in $parsed2.envs) {
            if ((Split-Path $p -Leaf) -eq $EnvName) { $EnvPath = $p }
        }
    } catch {
        foreach ($line in $envList2) {
            if ($line -match "\\$EnvName\b" -or $line -match "/$EnvName\b") {
                $EnvPath = ($line -split '\s+')[0]
            }
        }
    }
}

if (-not $EnvPath -or -not (Test-Path $EnvPath)) {
    FAIL "Could not locate the '$EnvName' environment after setup."
}

# ── Step 4: GPU self-test ─────────────────────────────────────────────────
Banner "Step 4 / 4  --  GPU self-test"

$pythonExe = Join-Path $EnvPath "python.exe"
if (-not (Test-Path $pythonExe)) {
    WARN "python.exe not found at: $pythonExe"
    WARN "The environment may be incomplete. Try re-running and choosing [R] to recreate."
}
else {
    $gpuScript = Join-Path $env:TEMP "vs_seg_gpu_test.py"
    Set-Content -Path $gpuScript -Encoding UTF8 -Value @'
import sys, torch
try:
    if torch.cuda.is_available():
        name = torch.cuda.get_device_name(0)
        x = torch.rand(4, 4, device="cuda")
        _ = (x @ x).sum().item()
        print("GPU_OK|" + torch.__version__ + "|" + name)
    else:
        print("GPU_NONE|" + torch.__version__)
except Exception as e:
    print("GPU_ERR|" + str(e))
'@
    $result = & $pythonExe $gpuScript 2>&1
    Remove-Item $gpuScript -Force -ErrorAction SilentlyContinue

    if ($result -match "GPU_OK\|([^\|]+)\|(.+)") {
        OK "PyTorch $($Matches[1])"
        OK "GPU detected: $($Matches[2])"
    }
    elseif ($result -match "GPU_NONE\|(.+)") {
        WARN "PyTorch $($Matches[1]) is installed, but NO CUDA GPU was found."
        WARN "Inference requires an NVIDIA GPU with >= 8 GB VRAM."
        WARN "Check that the NVIDIA driver is installed and that the GPU is recognised"
        WARN "in Device Manager."
    }
    elseif ($result -match "GPU_ERR\|(.+)") {
        WARN "GPU test raised an exception: $($Matches[1])"
    }
    else {
        WARN "GPU test produced unexpected output:"
        foreach ($line in $result) { INFO "  $line" }
    }
}

# ── Summary ───────────────────────────────────────────────────────────────
Banner "Setup complete"

Write-Host ""
Write-Host "  Copy the path below into the 'vs_seg env directory'" -ForegroundColor White
Write-Host "  field in the VS Segmentation extension panel in Slicer:" -ForegroundColor White
Write-Host ""
Write-Host "      $EnvPath" -ForegroundColor Green
Write-Host ""
Write-Host "  Next steps:" -ForegroundColor White
Write-Host "    1. Open 3D Slicer" -ForegroundColor White
Write-Host "    2. Edit > Application Settings > Modules" -ForegroundColor White
Write-Host "    3. Additional module paths > Add >" -ForegroundColor White
Write-Host "         $RepoRoot\VSSegmentation" -ForegroundColor White
Write-Host "    4. Restart Slicer, then open 'VS Segmentation'" -ForegroundColor White
Write-Host ""
Read-Host "  Press Enter to close this window"
