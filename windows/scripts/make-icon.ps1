# Rewrites src\FastShot\Assets\AppIcon.ico from the logo, src\FastShot\Assets\AppIcon.png (see AppIcon.cs).
$ErrorActionPreference = "Stop"
$root = Split-Path $PSScriptRoot -Parent
dotnet build (Join-Path $root "src\FastShot\FastShot.csproj") -c Release -v q
$exe = Get-ChildItem (Join-Path $root "src\FastShot\bin\Release") -Recurse -Filter FastShot.exe | Select-Object -First 1
& $exe.FullName --make-icon (Join-Path $root "src\FastShot\Assets\AppIcon.ico")
Write-Host "AppIcon.ico güncellendi; simgeyi exe'ye gömmek için yeniden derleyin."
