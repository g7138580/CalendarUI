# Build CalendarUI and deploy the .dll into the MO2 mods folder.
#
# Usage:  .\build.ps1            # incremental release build
#         .\build.ps1 -Configure # re-run CMake configure first
#         .\build.ps1 -Clean     # wipe the build tree and start over

param(
    [switch]$Configure,
    [switch]$Clean
)

# Continue, not Stop: CMake and Ninja write ordinary progress to stderr, and
# PowerShell surfaces native-command stderr as NativeCommandError. Under 'Stop'
# that aborts a build that is actually succeeding. Real failures are caught by
# checking $LASTEXITCODE after each step instead.
$ErrorActionPreference = 'Continue'

# --- Environment -------------------------------------------------------------

$env:VCPKG_ROOT = 'C:\vcpkg'

# Where the built plugin is deployed. CMakeLists reads this and appends
# /CalendarUI/SKSE/Plugins.
$env:SKYRIM_MODS_FOLDER = 'e:\Skyrim Modlists\Winds of the North\mods'

# The mod's folder name, which is NOT always "CalendarUI" -- Winds of the North
# installs it as "[NoDelete] CalendarUI" (the Wabbajack prefix for a folder the
# installer must not remove). CMakeLists appends "/CalendarUI/SKSE/Plugins" to
# the mods folder, so without this the build would deploy into a folder MO2 has
# never heard of and the game would keep loading the previous .dll.
$env:CALENDARUI_MOD_FOLDER = '[NoDelete] CalendarUI'

Set-Location $PSScriptRoot

# Enter the MSVC developer environment. Enter-VsDevShell is required rather
# than just calling cl.exe: the vcpkg toolchain needs the full INCLUDE/LIB
# environment, not merely the compiler on PATH.
$vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
$vsPath = & $vswhere -latest -property installationPath
if (-not $vsPath) { throw 'Visual Studio not found via vswhere.' }

Import-Module "$vsPath\Common7\Tools\Microsoft.VisualStudio.DevShell.dll"
Enter-VsDevShell -VsInstallPath $vsPath -SkipAutomaticLocation `
    -DevCmdArguments '-arch=x64 -host_arch=x64' | Out-Null

# --- Build -------------------------------------------------------------------

if ($Clean -and (Test-Path 'build')) {
    Write-Host 'Removing build tree...' -ForegroundColor Yellow
    Remove-Item 'build' -Recurse -Force
}

if ($Configure -or $Clean -or -not (Test-Path 'build/release')) {
    Write-Host 'Configuring...' -ForegroundColor Cyan
    cmake --preset release
    if ($LASTEXITCODE -ne 0) { throw 'CMake configure failed.' }
}

# Every AS2 callback registered with GameDelegate.addCallBack must be pushed
# with FxDelegate::Invoke, never GFxMovieView::Invoke.
#
# GFxMovieView::Invoke resolves by movie path and simply finds nothing for a
# delegate callback -- it fails silently, so the menu just never receives the
# data. This has already been hit twice in this project (setCalendarData, then
# setKeys), which is why it is checked rather than remembered.
$menuSrc = Get-Content (Join-Path $PSScriptRoot 'src\CalendarMenu.cpp') -Raw
if ($menuSrc -match 'uiMovie->Invoke\(') {
    throw ("Build aborted: src/CalendarMenu.cpp calls uiMovie->Invoke(). The AS2 side " +
           "registers its callbacks with GameDelegate.addCallBack, which " +
           "GFxMovieView::Invoke cannot reach -- it fails silently. Use " +
           "RE::FxDelegate::Invoke(uiMovie.get(), name, args) instead.")
}

Write-Host 'Building...' -ForegroundColor Cyan
cmake --build build/release --config Release
if ($LASTEXITCODE -ne 0) { throw 'Build failed.' }

$dll = Join-Path $env:SKYRIM_MODS_FOLDER (Join-Path $env:CALENDARUI_MOD_FOLDER 'SKSE\Plugins\CalendarUI.dll')
# -LiteralPath, not the bare form: the Wabbajack folder name
# "[NoDelete] CalendarUI" contains square brackets, which Test-Path treats
# as a wildcard character class. Without -LiteralPath the check returns
# false for a file that is really there, and a good build reports a
# spurious "not at the expected path" warning.
if (Test-Path -LiteralPath $dll) {
    Write-Host "Deployed: $dll" -ForegroundColor Green
} else {
    Write-Warning "Build succeeded but the .dll is not at the expected path: $dll"
}
