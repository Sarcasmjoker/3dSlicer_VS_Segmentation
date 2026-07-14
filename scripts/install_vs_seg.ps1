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

# Quote one argument using the Windows CommandLineToArgvW rules.
function Quote-NativeArgument([AllowEmptyString()][string]$Value) {
    if ($null -eq $Value) { $Value = "" }
    if ($Value.IndexOf([char]0) -ge 0) {
        throw "A native-process argument contains a NUL character."
    }

    $result = New-Object System.Text.StringBuilder
    [void]$result.Append('"')
    $slashes = 0
    foreach ($ch in $Value.ToCharArray()) {
        if ($ch -eq '\') {
            $slashes++
            continue
        }
        if ($ch -eq '"') {
            if ($slashes -gt 0) { [void]$result.Append(('\' * ($slashes * 2))) }
            [void]$result.Append('\"')
        } else {
            if ($slashes -gt 0) { [void]$result.Append(('\' * $slashes)) }
            [void]$result.Append($ch)
        }
        $slashes = 0
    }
    if ($slashes -gt 0) { [void]$result.Append(('\' * ($slashes * 2))) }
    [void]$result.Append('"')
    return $result.ToString()
}

# Run conda.exe with its stdout/stderr attached directly to this console.
# Do not add a PowerShell pipeline here: conda uses carriage returns to redraw
# download bars and spinners, and a pipeline converts that stream into lines.
function Run-Conda([string[]]$CArgs) {
    if (-not $script:CondaExe -or -not (Test-Path -LiteralPath $script:CondaExe)) {
        WARN "conda.exe was not found at: $($script:CondaExe)"
        return 1
    }

    $argumentLine = (($CArgs | ForEach-Object { Quote-NativeArgument $_ }) -join " ")
    DBG "Running: conda $argumentLine"

    $process = $null
    $rc = 1
    try {
        $startInfo = New-Object System.Diagnostics.ProcessStartInfo
        $startInfo.FileName = $script:CondaExe
        $startInfo.Arguments = $argumentLine
        $startInfo.WorkingDirectory = $RepoRoot
        $startInfo.UseShellExecute = $false
        $startInfo.CreateNoWindow = $false
        $startInfo.RedirectStandardOutput = $false
        $startInfo.RedirectStandardError = $false

        $process = [System.Diagnostics.Process]::Start($startInfo)
        if ($null -eq $process) { throw "conda.exe did not start." }
        $process.WaitForExit()
        $rc = $process.ExitCode
    } catch {
        WARN "Could not run conda: $($_.Exception.Message)"
    } finally {
        if ($process) { $process.Dispose() }
    }

    DBG "  -> exit code: $rc"
    return [int]$rc
}

function Format-ByteSize([double]$Bytes) {
    if ($Bytes -ge 1GB) { return ("{0:N1} GB" -f ($Bytes / 1GB)) }
    if ($Bytes -ge 1MB) { return ("{0:N1} MB" -f ($Bytes / 1MB)) }
    if ($Bytes -ge 1KB) { return ("{0:N1} KB" -f ($Bytes / 1KB)) }
    return ("{0:N0} B" -f $Bytes)
}

# Invoke-WebRequest progress is host/version dependent. Stream the response
# ourselves so first-time Miniforge downloads always show bytes, speed, and
# percentage when the server supplies Content-Length.
function Download-FileWithProgress(
    [string]$Url,
    [string]$Destination,
    [int]$TimeoutSec = 180
) {
    $request = $null
    $response = $null
    $inputStream = $null
    $outputStream = $null
    $lineVisible = $false
    $completed = $false

    try {
        $request = [System.Net.HttpWebRequest]([System.Net.WebRequest]::Create($Url))
        $request.Method = "GET"
        $request.AllowAutoRedirect = $true
        $request.Timeout = $TimeoutSec * 1000
        $request.ReadWriteTimeout = $TimeoutSec * 1000
        $request.UserAgent = "SlicerVS-Installer/1.0"

        $response = [System.Net.HttpWebResponse]$request.GetResponse()
        $total = [long]$response.ContentLength
        $inputStream = $response.GetResponseStream()
        $outputStream = [System.IO.File]::Open(
            $Destination,
            [System.IO.FileMode]::Create,
            [System.IO.FileAccess]::Write,
            [System.IO.FileShare]::None
        )

        $buffer = New-Object byte[] (64KB)
        $downloaded = [long]0
        $timer = [System.Diagnostics.Stopwatch]::StartNew()
        $lastDraw = [System.Diagnostics.Stopwatch]::StartNew()

        while (($read = $inputStream.Read($buffer, 0, $buffer.Length)) -gt 0) {
            $outputStream.Write($buffer, 0, $read)
            $downloaded += $read

            if ($lastDraw.ElapsedMilliseconds -ge 200 -or ($total -gt 0 -and $downloaded -ge $total)) {
                $seconds = [Math]::Max($timer.Elapsed.TotalSeconds, 0.001)
                $speed = Format-ByteSize ($downloaded / $seconds)
                if ($total -gt 0) {
                    $percent = [Math]::Min(100, (100.0 * $downloaded / $total))
                    $status = "  Downloading: {0,6:N1}%  {1} / {2}  {3}/s" -f `
                        $percent, (Format-ByteSize $downloaded), (Format-ByteSize $total), $speed
                } else {
                    $status = "  Downloading: {0}  {1}/s" -f (Format-ByteSize $downloaded), $speed
                }
                Write-Host ("`r{0,-88}" -f $status) -NoNewline -ForegroundColor Cyan
                $lineVisible = $true
                $lastDraw.Restart()
            }
        }

        if ($total -gt 0 -and $downloaded -ne $total) {
            throw "Download ended early ($downloaded of $total bytes)."
        }
        if ($downloaded -le 0) { throw "The server returned an empty file." }

        if (-not $lineVisible) {
            Write-Host ("  Downloaded {0}" -f (Format-ByteSize $downloaded)) -ForegroundColor Cyan
        } else {
            Write-Host ""
            $lineVisible = $false
        }
        $completed = $true
    } finally {
        if ($outputStream) { $outputStream.Dispose() }
        if ($inputStream)  { $inputStream.Dispose() }
        if ($response)     { $response.Dispose() }
        if ($lineVisible)  { Write-Host "" }
        if (-not $completed) {
            Remove-Item -LiteralPath $Destination -Force -ErrorAction SilentlyContinue
        }
    }
}

function Run-MiniforgeInstaller([string]$Installer, [string]$InstallDir) {
    $startInfo = New-Object System.Diagnostics.ProcessStartInfo
    $startInfo.FileName = $Installer
    # NSIS requires /D to be the final argument and consumes the rest of the line.
    $startInfo.Arguments = "/InstallationType=JustMe /RegisterPython=0 /AddToPath=0 /S /D=$InstallDir"
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true

    $process = $null
    try {
        $process = [System.Diagnostics.Process]::Start($startInfo)
        if ($null -eq $process) { throw "The Miniforge installer did not start." }
        $timer = [System.Diagnostics.Stopwatch]::StartNew()
        while (-not $process.WaitForExit(500)) {
            $elapsed = "{0:00}:{1:00}" -f [Math]::Floor($timer.Elapsed.TotalMinutes), $timer.Elapsed.Seconds
            $status = "  Installing Miniforge3... elapsed $elapsed"
            Write-Host ("`r{0,-72}" -f $status) -NoNewline -ForegroundColor Cyan
        }
        Write-Host ("`r{0,-72}" -f "  Miniforge3 installer finished.") -ForegroundColor Cyan
        return [int]$process.ExitCode
    } finally {
        if ($process) { $process.Dispose() }
    }
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
            # GitHub requires TLS 1.2 on older Windows/.NET installations.
            [System.Net.ServicePointManager]::SecurityProtocol =
                [System.Net.ServicePointManager]::SecurityProtocol -bor [System.Net.SecurityProtocolType]::Tls12
            Download-FileWithProgress -Url $url -Destination $installer -TimeoutSec 180
            $ok = $true; OK "Download complete"; break
        } catch { WARN "Download failed: $($_.Exception.Message)" }
    }
    if (-not $ok) { FAIL "Could not download Miniforge3. Check internet connection." }
    INFO "Installing Miniforge3 silently (elapsed time will update below)..."
    try {
        $installRc = Run-MiniforgeInstaller -Installer $installer -InstallDir $installDir
    } catch {
        Remove-Item -LiteralPath $installer -Force -ErrorAction SilentlyContinue
        FAIL "Could not start the Miniforge3 installer: $($_.Exception.Message)"
    }
    Remove-Item $installer -Force -ErrorAction SilentlyContinue
    if ($installRc -ne 0) { FAIL "Miniforge3 installer failed (rc=$installRc)." }
    $script:CondaBat = Join-Path $installDir "condabin\conda.bat"
    if (-not (Test-Path $script:CondaBat)) { FAIL "Miniforge3 install failed." }
    OK "Miniforge3 installed at: $installDir"
}
OK "Using conda: $($script:CondaBat)"
$condaBatDir = Split-Path $script:CondaBat -Parent
$condaRoot = Split-Path $condaBatDir -Parent
$script:CondaExe = Join-Path $condaRoot "Scripts\conda.exe"
if (-not (Test-Path -LiteralPath $script:CondaExe)) {
    FAIL "conda.exe not found at: $($script:CondaExe)"
}
DBG "Using conda executable: $($script:CondaExe)"

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
Write-Host "         $RepoRoot\SlicerVS" -ForegroundColor White
Write-Host "    3. Click OK, restart Slicer, open SlicerVS." -ForegroundColor White
Write-Host ""
Read-Host "  Press Enter to close"
