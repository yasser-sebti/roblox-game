$ErrorActionPreference = "Stop"
$projectRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$buildDirectory = Join-Path $projectRoot "build"
$pluginDirectory = Join-Path $env:LOCALAPPDATA "Roblox\Plugins"
$builtPlugin = Join-Path $buildDirectory "R15PoseTuner.rbxm"
$installedPlugin = Join-Path $pluginDirectory "R15PoseTuner.rbxm"
$exportHelper = Join-Path $projectRoot "tools\PoseTunerExportHelper.ps1"
Set-Location -LiteralPath $projectRoot

$rojoCommand = Get-Command rojo -ErrorAction SilentlyContinue
if ($rojoCommand) {
    $rojoPath = $rojoCommand.Source
} elseif (Test-Path -LiteralPath "C:\Rojo\rojo.exe") {
    $rojoPath = "C:\Rojo\rojo.exe"
} else {
    throw "Rojo was not found. Install it or add rojo.exe to PATH."
}

New-Item -ItemType Directory -Force -Path $buildDirectory | Out-Null
New-Item -ItemType Directory -Force -Path $pluginDirectory | Out-Null

Write-Host "Building the local Edit-mode R15 Pose Tuner plugin..."
& $rojoPath build (Join-Path $projectRoot "pose-tuner.project.json") -o $builtPlugin
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

Copy-Item -LiteralPath $builtPlugin -Destination $installedPlugin -Force
$helperArguments = "-NoProfile -ExecutionPolicy Bypass -File `"$exportHelper`" -ProjectRoot `"$projectRoot`""
Start-Process -FilePath "powershell.exe" -ArgumentList $helperArguments -WindowStyle Hidden
Write-Host ""
Write-Host "Installed: $installedPlugin"
Write-Host "Local .txt/.luau export helper started. Files are saved to: $(Join-Path $projectRoot 'pose-exports')"
Write-Host "Restart Roblox Studio, then open Plugins > Pose Tuner."
Write-Host "The tuner runs in Edit mode: do not press Play. HTTP Requests are not required."
exit 0
