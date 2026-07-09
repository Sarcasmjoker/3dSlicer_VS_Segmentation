@echo off
:: VS Segmentation -- One-click environment installer
:: Double-click this file.  No terminal or programming experience needed.
::
:: Uses "cmd /k" so the window stays open on ANY exit (success or error).
:: The user can read the results and close the window manually.

title VS Segmentation -- Environment Setup

echo.
echo  =====================================================
echo   VS Segmentation  --  Environment Installer
echo  =====================================================
echo.
echo  This window will install the Python environment needed
echo  to run the VS Segmentation plugin in 3D Slicer.
echo.
echo  What will happen:
echo    - If Miniforge (free Python) is not installed, it will
echo      be downloaded and installed for your user account
echo      (no administrator rights needed).
echo    - A "vs_seg" environment will be created with all
echo      required packages (PyTorch, nnU-Net v2, etc.).
echo    - Your GPU will be tested at the end.
echo.
echo  Expected time: 5-20 minutes (first run, downloads ~4 GB).
echo  The window will NOT close automatically -- you can read
echo  all messages before closing it yourself.
echo.
echo  Press any key to start ...
pause >nul

:: Locate PowerShell (should always exist on Windows 7+)
where powershell >nul 2>&1
if errorlevel 1 (
    echo.
    echo  ERROR: powershell.exe was not found.
    echo  Please install PowerShell from https://aka.ms/powershell
    echo.
    goto :END
)

:: Build the absolute path to the PS1 file (handles spaces in path).
:: %~dp0 = directory of this .bat (always has trailing backslash).
set "PS1=%~dp0install_vs_seg.ps1"

if not exist "%PS1%" (
    echo.
    echo  ERROR: install_vs_seg.ps1 was not found at:
    echo    %PS1%
    echo.
    echo  Make sure both files are in the same "scripts" folder
    echo  inside the repository.
    echo.
    goto :END
)

:: Run the PowerShell installer.
::   -ExecutionPolicy Bypass  : allows running unsigned scripts
::   -NoProfile               : skip user profile (faster, no interference)
::   -File "..."              : run the PS1 as a script file
::
:: IMPORTANT: we do NOT use "cmd /k" here because the PS1 already
:: prompts the user.  The outer "cmd /k" at the CALL instruction
:: below (see last line) keeps this window alive after PS1 finishes.
powershell -NoProfile -ExecutionPolicy Bypass -File "%PS1%"

:END
echo.
echo  -------------------------------------------------------
echo   Done.  You can now close this window.
echo  -------------------------------------------------------
echo.
pause
