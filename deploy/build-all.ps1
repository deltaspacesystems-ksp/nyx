<#
  Builds everything from source on C: and stages it for the server on E: (see nyx.bat update there).
  Usage: .\build-all.ps1 -Version 1.1.0 -Notes "..." ,"..."
#>
param(
    [Parameter(Mandatory)] [string] $Version,
    [Parameter(Mandatory)] [string[]] $Notes,
    [string] $Stage = 'E:\Users\brzoz\Documents\nyx\update'
)
$ErrorActionPreference = 'Continue' # native tools write warnings to stderr; failures are caught via exit codes
$env:Path += ';C:\dev\flutter\bin'
$root = 'C:\Projects\nyx'

Push-Location "$root\client"
flutter build web --release --no-wasm-dry-run --pwa-strategy=none --no-web-resources-cdn
if ($LASTEXITCODE) { throw 'web build failed' }
flutter build windows --release
if ($LASTEXITCODE) { throw 'windows build failed' }
Pop-Location

$www = "$root\server\Nyx.Server\wwwroot"
robocopy "$root\client\build\web" $www /MIR /NFL /NDL /NJH /NJS /NP | Out-Null

dotnet publish "$root\server\Nyx.Server" -c Release -r win-x64 --self-contained -o "$root\deploy\server"
if ($LASTEXITCODE) { throw 'server publish failed' }

New-Item -ItemType Directory -Force "$Stage\server" | Out-Null
robocopy "$root\deploy\server" "$Stage\server" /MIR /XF appsettings.Production.json /NFL /NDL /NJH /NJS /NP | Out-Null
Copy-Item "$root\deploy\nyx.conf" "$Stage\nyx.conf" -Force
Copy-Item "$root\deploy\nyx.ps1", "$root\deploy\nyx.bat" $Stage -Force -ErrorAction SilentlyContinue

& "$root\deploy\release.ps1" -Version $Version -Notes $Notes
Write-Host 'Done. On the server run: nyx.bat update'
