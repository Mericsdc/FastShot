# Builds FastShot for Windows into build\FastShot.exe.
#   scripts\build.ps1                 needs the .NET 10 Desktop Runtime on the target PC (small exe)
#   scripts\build.ps1 -SelfContained  runs on any Windows 10/11 x64 PC without installing .NET (larger exe)
#   scripts\build.ps1 -Runtime win-arm64
param(
    [switch]$SelfContained,
    [string]$Runtime = "win-x64"
)
$ErrorActionPreference = "Stop"
$root = Split-Path $PSScriptRoot -Parent
$out = Join-Path $root "build"
$self = if ($SelfContained) { "true" } else { "false" }
dotnet publish (Join-Path $root "src\FastShot\FastShot.csproj") -c Release -r $Runtime --self-contained $self `
    -p:PublishSingleFile=true -p:IncludeNativeLibrariesForSelfExtract=true -p:DebugType=none -o $out
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
Write-Host "Hazır: $(Join-Path $out 'FastShot.exe')"
