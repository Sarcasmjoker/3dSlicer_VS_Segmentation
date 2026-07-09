<#
.SYNOPSIS  One-click installer for the vs_seg conda environment.
           Run via install_vs_seg.bat -- do not run this file directly.
#>
$ErrorActionPreference = "Continue"
$EnvName  = "vs_seg"
$RepoRoot = Split-Path -Parent $PSScriptRoot
$EnvYml   = Join-Path $RepoRoot "environment.yml"

function Banner($t) {
    Write-Host ""; Write-Host ("=" * 56) -ForegroundColor Cyan
    Write-Host "  $t" -ForegroundColor Cyan
    Write-Host ("=" * 56) -ForegroundColor Cyan
}
function OK($m)   { Write-Host "  [OK]    $m" -ForegroundColor Green  }
function WARN($m) { Write-Host "  [WARN]  $m" -ForegroundColor Yellow }
function INFO($m) { Write-Host "          $m" -ForegroundColor Gray   }
function DBG($m)  { Write-Host "  [DBG]   $m" -ForegroundColor DarkCyan }
function FAIL($m) {
    Write-Host ""; Write-Host "  [FAIL]  $m" -ForegroundColor Red; Write-Host ""
    Read-Host "  Press Enter to exit"; exit 1
}

# Run a conda command with live streaming output.
# Uses & cmd.exe /c  so child stdout/stderr go directly to this window
# (Start-Process -NoNewWindow can buffer output on some Windows configs).
function Run-Conda([string[]]$CArgs) {
    $escaped = $CArgs | ForEach-Object {
        if ($_ -match '\s') { "`"$_`"" } else { $_ }
    }
    $line = $escaped -join " "
    DBG "Running: conda $line"
    & cmd.exe /c "`"$script:CondaBat`" $line"
    $rc = $LASTEXITCODE
    DBG "  -> exit code: $rc"
    return $rc
}

# --------------- Step 0: sanity ---------------
Banner "Step 0 / 4  --  Checking system"
DBG "PSScriptRoot : $PSScriptRoot"
DBG "RepoRoot     : $RepoRoot"
DBG "EnvYml       : $EnvYml"
if (-not (Test-Path $EnvYml)) {
    FAIL "environment.yml not found at: $EnvYml`n  Make sure the scripts folder is still inside the repo."
}
OK "Found environment.yml"

# --------------- Step 1: locate conda ---------------
Banner "Step 1 / 4  --  Locating Python / conda"

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

$script:CondaBat = $null
foreach ($r in $roots) {
    $bat = Join-Path $r "condabin\conda.bat"
    DBG "  checking: $bat  exists=$(Test-Path $bat)"
    if (Test-Path $bat) { $script:CondaBat = $bat; break }
}

if (-not $script:CondaBat) {
    $cmd = Get-Command conda -ErrorAction SilentlyContinue
    if ($cmd) {
        DBG "conda on PATH: $($cmd.Source)"
        $p = $cmd.Source
        for ($i = 0; $i -lt 5; $i++) {
            $p   = Split-Path $p -Parent
            $bat = Join-Path $p "condabin\conda.bat"
            DBG "  checking: $bat  exists=$(Test-Path $bat)"
            if (Test-Path $bat) { $script:CondaBat = $bat; break }
        }
    }
}

if (-not $script:CondaBat) {
    WARN "No conda/Miniforge found. Downloading Miniforge3..."
    $installDir = Join-Path $env:USERPROFILE "miniforge3"
    $installer  = Join-Path $env:TEMP "Miniforge3-setup.exe"
    $urls = @(
        "https://github.com/conda-forge/miniforge/releases/latest/download/Miniforge3-Windows-x86_64.exe",
        "https://mirror.nju.edu.cn/github-release/conda-forge/miniforge/LatestRelease/Miniforge3-Windows-x86_64.exe"
    )
    $ok = $false
    foreach ($url in $urls) {
        INFO "Trying: $url"
        try {
            Invoke-WebRequest -Uri $url -OutFile $installer -UseBasicParsing -TimeoutSec 180
            $ok = $true; OK "Download complete"; break
        } catch { WARN "Failed, trying next..." }
    }
    if (-not $ok) { FAIL "Could not download Miniforge3. Check internet connection." }
    INFO "Installing Miniforge3 silently..."
    & $installer /InstallationType=JustMe /RegisterPython=0 /AddToPath=0 /S /D=$installDir
    Remove-Item $installer -Force -ErrorAction SilentlyContinue
    $script:CondaBat = Join-Path $installDir "condabin\conda.bat"
    if (-not (Test-Path $script:CondaBat)) { FAIL "Miniforge3 install failed." }
    OK "Miniforge3 installed at: $installDir"
}
OK "Using conda: $($script:CondaBat)"

# --------------- Step 2: mirror ---------------
Banner "Step 2 / 4  --  Network / mirror"
Write-Host ""
Write-Host "  +---------------------------------------------------------+" -ForegroundColor Yellow
Write-Host "  |  ACTION REQUIRED: Please answer the question below.    |" -ForegroundColor Yellow
Write-Host "  |                                                         |" -ForegroundColor Yellow
Write-Host "  |  If you are in mainland China or pypi.org /            |" -ForegroundColor Yellow
Write-Host "  |  download.pytorch.org are slow, type  Y  then Enter.   |" -ForegroundColor Yellow
Write-Host "  |  Otherwise just press  Enter  to use the default.      |" -ForegroundColor Yellow
Write-Host "  +---------------------------------------------------------+" -ForegroundColor Yellow
Write-Host ""
$mir = Read-Host "  >>> Use a package mirror? [y/N]"
$EnvYmlToUse = $EnvYml
if ($mir -match "^[Yy]") {
    Write-Host ""
    Write-Host "  (Just press Enter to accept the Aliyun defaults below)" -ForegroundColor Gray
    $pipM   = Read-Host "  >>> Pip index URL   (Enter = Aliyun)"
    $torchM = Read-Host "  >>> PyTorch cu128   (Enter = Aliyun)"
    if ([string]::IsNullOrWhiteSpace($pipM))   { $pipM   = "https://mirrors.aliyun.com/pypi/simple/" }
    if ([string]::IsNullOrWhiteSpace($torchM)) { $torchM = "https://mirrors.aliyun.com/pytorch-wheels/cu128/" }
    $tmpYml  = Join-Path $env:TEMP "vs_seg_mirror.yml"
    $content = Get-Content $EnvYml -Raw -Encoding UTF8
    $content = $content -replace "- --extra-index-url https://download\.pytorch\.org/whl/cu128",
                                 ("- --index-url " + $pipM + "`n      - --find-links " + $torchM)
    Set-Content -Path $tmpYml -Value $content -Encoding UTF8
    $EnvYmlToUse = $tmpYml
    OK "Mirror config written"
} else {
    OK "Using default sources (pypi.org / download.pytorch.org)"
}
Write-Host "  Step 2 complete. Proceeding to Step 3..." -ForegroundColor Green

# --------------- Step 3: env setup ---------------
Banner "Step 3 / 4  --  Setting up the '$EnvName' environment"

# Detect env by checking python.exe in the two most common locations.
# We do NOT rely on JSON output from conda (it has ANSI/warning noise).
$condaBatDir  = Split-Path $script:CondaBat -Parent        # .../condabin
$condaRoot    = Split-Path $condaBatDir -Parent            # .../miniforge3
$candidatePaths = @(
    (Join-Path $env:USERPROFILE  ".conda\envs\$EnvName"),
    (Join-Path $env:LOCALAPPDATA ".conda\envs\$EnvName"),
    (Join-Path $condaRoot        "envs\$EnvName")
)
DBG "Candidate env paths:"
$existingEnvPath = $null
foreach ($c in $candidatePaths) {
    $py = Join-Path $c "python.exe"
    DBG "  $py  exists=$(Test-Path $py)"
    if (Test-Path $py) { $existingEnvPath = $c; break }
}
DBG "existingEnvPath = '$existingEnvPath'"

$doCreate = $true
if ($existingEnvPath) {
    Write-Host ""
    WARN "Found existing '$EnvName' at: $existingEnvPath"
    Write-Host "  [R] Remove and re-create   [U] Update (default)   [S] Skip" -ForegroundColor Gray
    $ch = Read-Host "  [R/U/S, default U]"
    if ($ch -match "^[Rr]") {
        DBG "User chose: recreate"
        INFO "Removing existing environment..."
        Run-Conda @("env", "remove", "-n", $EnvName, "-y") | Out-Null
    } elseif ($ch -match "^[Ss]") {
        DBG "User chose: skip"
        INFO "Skipping environment setup."
        $doCreate = $false
        $existingEnvPath = $existingEnvPath   # keep it
    } else {
        DBG "User chose: update"
        INFO "Updating '$EnvName' packages..."
        $rc = Run-Conda @("env", "update", "-n", $EnvName, "-f", $EnvYmlToUse, "--prune")
        if ($rc -ne 0) { FAIL "Environment update failed (rc=$rc). See output above." }
        OK "Environment updated"
        $doCreate = $false
    }
}

if ($doCreate) {
    DBG "Running conda env create..."
    Write-Host ""
    Write-Host "  +----------------------------------------------------------+" -ForegroundColor Yellow
    Write-Host "  |  DOWNLOADING AND INSTALLING PACKAGES                    |" -ForegroundColor Yellow
    Write-Host "  |  This step downloads ~4 GB and may take 10-30 minutes.  |" -ForegroundColor Yellow
    Write-Host "  |  The window is NOT frozen -- conda progress will appear  |" -ForegroundColor Yellow
    Write-Host "  |  below as packages are downloaded and installed.        |" -ForegroundColor Yellow
    Write-Host "  |  Please DO NOT close this window.                       |" -ForegroundColor Yellow
    Write-Host "  +----------------------------------------------------------+" -ForegroundColor Yellow
    Write-Host ""
    $rc = Run-Conda @("env", "create", "-n", $EnvName, "-f", $EnvYmlToUse)
    if ($rc -ne 0) { FAIL "Environment creation failed (rc=$rc). See output above." }
    OK "Environment created successfully"
}

if ($EnvYmlToUse -ne $EnvYml) {
    Remove-Item $EnvYmlToUse -Force -ErrorAction SilentlyContinue
}

# Re-scan for the env path now it should definitely exist
DBG "Re-scanning candidate paths after create/update:"
$EnvPath = $null
foreach ($c in $candidatePaths) {
    $py = Join-Path $c "python.exe"
    DBG "  $py  exists=$(Test-Path $py)"
    if (Test-Path $py) { $EnvPath = $c; break }
}

# Last resort: ask conda itself
if (-not $EnvPath) {
    DBG "Trying: conda run -n $EnvName python -c import sys;print(sys.prefix)"
    $prefix = & cmd.exe /c "`"$script:CondaBat`" run -n $EnvName python -c `"import sys; print(sys.prefix)`" 2>&1"
    DBG "  conda run output lines:"
    foreach ($line in $prefix) { DBG "    '$line'" }
    foreach ($line in $prefix) {
        $t = $line.Trim()
        if ($t -ne "" -and (Test-Path (Join-Path $t "python.exe"))) {
            $EnvPath = $t; break
        }
    }
}

DBG "Final EnvPath = '$EnvPath'"
if (-not $EnvPath) {
    Write-Host ""
    WARN "Could not find '$EnvName'. Dumping 'conda info --envs':"
    & cmd.exe /c "`"$script:CondaBat`" info --envs"
    FAIL "python.exe not found in '$EnvName'. Try re-running and choosing [R]."
}
OK "Environment path: $EnvPath"
$PythonExe = Join-Path $EnvPath "python.exe"

# --------------- Step 4: GPU test ---------------
Banner "Step 4 / 4  --  GPU self-test"
$gpu = Join-Path $env:TEMP "vs_gpu_test.py"
Set-Content -Path $gpu -Encoding UTF8 -Value @"
import torch
try:
    if torch.cuda.is_available():
        nm = torch.cuda.get_device_name(0)
        x  = torch.rand(4, 4, device='cuda')
        _  = (x @ x).sum().item()
        print('GPU_OK|' + torch.__version__ + '|' + nm)
    else:
        print('GPU_NONE|' + torch.__version__)
except Exception as e:
    print('GPU_ERR|' + str(e))
"@
$res = (& $PythonExe $gpu 2>&1 | Out-String).Trim()
Remove-Item $gpu -Force -ErrorAction SilentlyContinue
DBG "GPU test raw: $res"
if     ($res -match "GPU_OK\|([^\|]+)\|(.+)")  { OK "PyTorch $($Matches[1])"; OK "GPU: $($Matches[2])" }
elseif ($res -match "GPU_NONE\|(.+)")           { WARN "No CUDA GPU (PyTorch $($Matches[1])). Extension needs NVIDIA GPU >= 8 GB VRAM." }
elseif ($res -match "GPU_ERR\|(.+)")            { WARN "GPU test error: $($Matches[1])" }
else                                            { WARN "Unexpected GPU output: $res" }

# --------------- Summary ---------------
Banner "Setup complete"
Write-Host ""
Write-Host "  Paste this into 'vs_seg env directory' in Slicer:" -ForegroundColor White
Write-Host ""; Write-Host "      $EnvPath" -ForegroundColor Green; Write-Host ""
Write-Host "  Next steps in 3D Slicer:" -ForegroundColor White
Write-Host "    1. Edit > Application Settings > Modules" -ForegroundColor White
Write-Host "    2. Additional module paths > Add > select:" -ForegroundColor White
Write-Host "         $RepoRoot\VSSegmentation" -ForegroundColor White
Write-Host "    3. Click OK, restart Slicer, open VS Segmentation." -ForegroundColor White
Write-Host ""
Read-Host "  Press Enter to close"
