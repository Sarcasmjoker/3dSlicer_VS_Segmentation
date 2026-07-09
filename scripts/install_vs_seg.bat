@echo off
:: VS Segmentation -- One-click environment installer
:: Double-click this file to install Python and all required packages.
:: No programming knowledge required.

title VS Segmentation Installer

echo.
echo  =====================================================
echo   VS Segmentation -- Environment Installer
echo  =====================================================
echo.
echo  This will install the Python environment needed to run
echo  the VS Segmentation plugin in 3D Slicer.
echo.
echo  - If Python (Miniforge/conda) is NOT installed on this
echo    computer, it will be downloaded and installed automatically
echo    (current user only, no administrator rights required).
echo.
echo  - An isolated "vs_seg" environment will then be created
echo    with all required packages (PyTorch, nnU-Net v2, etc.).
echo.
echo  - Your GPU will be tested at the end.
echo.
echo  Expected time: 5-20 minutes depending on internet speed.
echo.
pause

:: --- Check PowerShell availability ---
where powershell >nul 2>&1
if errorlevel 1 (
    echo.
    echo  ERROR: PowerShell was not found on this computer.
    echo  PowerShell is required and should be available on
    echo  any supported version of Windows (7 SP1 or later).
    echo.
    pause
    exit /b 1
)

:: --- Run the PowerShell installer ---
:: ExecutionPolicy Bypass: allows running this script even if the
::   system policy blocks unsigned scripts (common on work computers).
:: -NoProfile: skips user profile to avoid interference.
:: -File: path to the actual installer logic.

powershell -NoProfile -ExecutionPolicy Bypass ^
  -File "%~dp0install_vs_seg.ps1"

if errorlevel 1 (
    echo.
    echo  Installation did not complete. See the messages above.
    echo  If you need help, please contact the extension maintainer
    echo  and share a screenshot of this window.
    echo.
) else (
    echo.
    echo  =====================================================
    echo   Installation finished. You can close this window.
    echo  =====================================================
    echo.
)

pause
