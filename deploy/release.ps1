<#
  Publishes a Windows build as an update:
    - zips client\build\windows\x64\runner\Release as Nyx-windows-<version>.zip
    - copies it to the downloads folder and prepends the release (with its changelog) to releases.json
  Apps that are already installed then offer "Update now / Later / Skip" with these notes.

  Usage (after `flutter build windows --release`, with pubspec.yaml's version matching -Version):
    .\release.ps1 -Version 1.1.0 -Notes "Friends list","Fixed screen share sometimes staying black"
#>
param(
    [Parameter(Mandatory)] [string] $Version,
    [Parameter(Mandatory)] [string[]] $Notes,
    [string] $Downloads = 'E:\Users\brzoz\Documents\nyx\downloads',
    [string] $Build = 'C:\Projects\nyx\client\build\windows\x64\runner\Release',
    [string] $Apk = 'C:\Projects\nyx\client\build\app\outputs\flutter-apk\app-release.apk' # optional: published for Android when it exists
)
$ErrorActionPreference = 'Stop'
if (-not (Test-Path (Join-Path $Build 'nyx.exe'))) { throw "nyx.exe not found in $Build. Run flutter build windows --release first." }
New-Item -ItemType Directory -Force $Downloads | Out-Null

$name = "Nyx-windows-$Version.zip"
$zip = Join-Path $Downloads $name
if (Test-Path $zip) { Remove-Item $zip -Force }
Compress-Archive -Path (Join-Path $Build '*') -DestinationPath $zip -CompressionLevel Optimal

# Per-user installer (no admin): needs the WiX tool (dotnet tool install -g wix --version 6.0.2)
$msiName = "Nyx-windows-$Version.msi"
$msi = Join-Path $Downloads $msiName
if (Test-Path $msi) { Remove-Item $msi -Force }
$wix = Get-Command wix -ErrorAction SilentlyContinue
if ($wix) {
    $icon = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../client/windows/runner/resources/app_icon.ico'))
    $art = Join-Path $PSScriptRoot 'installer'
    & wix build -pdbtype none -arch x64 -ext WixToolset.UI.wixext -ext WixToolset.Util.wixext -d "Version=$Version" -d "Src=$Build" -d "Icon=$icon" -d "Art=$art" (Join-Path $PSScriptRoot "nyx.wxs") -o $msi
    if ($LASTEXITCODE) { throw 'msi build failed' }
} else { Write-Warning 'wix not found: skipping the .msi installer' }

$manifestPath = Join-Path $Downloads 'releases.json'
$releases = @()
if (Test-Path $manifestPath) {
    $old = Get-Content $manifestPath -Raw | ConvertFrom-Json
    if ($old.releases) { $releases = @($old.releases | Where-Object { $_.version -ne $Version }) }
}
$entry = [ordered]@{
    version  = $Version
    released = (Get-Date).ToString('yyyy-MM-dd')
    notes    = @($Notes)
    files    = [ordered]@{ windows = $name }
}
if (Test-Path $Apk) {
    $apkName = "Nyx-android-$Version.apk"
    Copy-Item $Apk (Join-Path $Downloads $apkName) -Force
    $entry.files['android'] = $apkName
    Write-Host "Published $apkName"
}
$manifest = [ordered]@{ releases = @($entry) + $releases }
$manifest | ConvertTo-Json -Depth 6 | Set-Content $manifestPath -Encoding utf8
Write-Host "Published $name ($([math]::Round((Get-Item $zip).Length / 1MB, 1)) MB) and updated releases.json"
