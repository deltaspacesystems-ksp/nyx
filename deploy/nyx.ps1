# Zarzadzanie Nyx na serwerku (https://nyx.deltatechksp.eu).
#
#   nyx.bat start        uruchamia serwer Nyx i przekaznik TURN (glos przez internet)
#   nyx.bat stop         zatrzymuje oba
#   nyx.bat restart
#   nyx.bat update       wgrywa nowa wersje z folderu update\ (zatrzymuje, podmienia pliki, uruchamia ponownie)
#   nyx.bat status       co dziala + test lokalny i z internetu
#   nyx.bat nginx        dodaje nyx.conf do nginx (kopia -> nginx -t -> przeladowanie; przy bledzie cofa)
#   nyx.bat firewall     otwiera porty TURN w Zaporze Windows (uruchom jako administrator)
#   nyx.bat autostart    uruchamia Nyx po starcie Windows (uruchom jako administrator)
#   nyx.bat invite       pokazuje kod pierwszego zaproszenia, jesli nie ma jeszcze zadnego konta
#   nyx.bat log [N]      ostatnie N linii logu serwera (domyslnie 40)

param([string]$Cmd = 'pomoc', [string]$Arg = '')
$ErrorActionPreference = 'Stop'

$Root    = Split-Path -Parent $MyInvocation.MyCommand.Path
$Server  = Join-Path $Root 'server\Nyx.Server.exe'
$Turn    = Join-Path $Root 'turn\nyx-turn.exe'
$Data    = Join-Path $Root 'data'
$Downloads = Join-Path $Root 'downloads'
$Logs    = Join-Path $Root 'logs'
$Secret  = Join-Path $Root 'config\turn.secret'
$NginxDir = Join-Path (Split-Path -Parent $Root) 'nginx-1.29.5'
$Nginx   = Join-Path $NginxDir 'nginx.exe'
$NginxConf = Join-Path $NginxDir 'conf\nginx.conf'
$Host_   = 'nyx.deltatechksp.eu'
$TurnHost = 'turn.deltatechksp.eu'

function Say($t, $c = 'Gray') { Write-Host $t -ForegroundColor $c }
function Running($name) { Get-Process $name -ErrorAction SilentlyContinue }

function Start-Nyx {
    New-Item -ItemType Directory -Force $Data, $Logs, $Downloads | Out-Null
    if (-not (Running 'Nyx.Server')) {
        $env:ASPNETCORE_ENVIRONMENT = 'Production'
        Start-Process $Server -WorkingDirectory (Split-Path $Server) -WindowStyle Hidden `
            -ArgumentList '--Data:Path', "`"$Data`"", '--Downloads:Path', "`"$Downloads`"" `
            -RedirectStandardOutput (Join-Path $Logs 'nyx.log') -RedirectStandardError (Join-Path $Logs 'nyx.err.log')
        Say 'Serwer Nyx uruchomiony.' 'Green'
    } else { Say 'Serwer Nyx juz dziala.' 'Yellow' }

    if (-not (Running 'nyx-turn')) {
        # Sekret idzie zmienna srodowiskowa, a nie argumentem - nie widac go na liscie procesow.
        $env:NYX_TURN_SECRET = (Get-Content $Secret -Raw).Trim()
        Start-Process $Turn -WorkingDirectory (Split-Path $Turn) -WindowStyle Hidden `
            -ArgumentList '-public-host', $TurnHost, '-port', '3478', '-min-port', '49160', '-max-port', '49200' `
            -RedirectStandardOutput (Join-Path $Logs 'turn.log') -RedirectStandardError (Join-Path $Logs 'turn.err.log')
        Remove-Item Env:NYX_TURN_SECRET
        Say 'Przekaznik TURN uruchomiony.' 'Green'
    } else { Say 'Przekaznik TURN juz dziala.' 'Yellow' }
}

function Stop-Nyx {
    foreach ($n in 'Nyx.Server', 'nyx-turn') {
        $p = Running $n
        if ($p) { $p | Stop-Process -Force; Say "$n zatrzymany." 'Green' } else { Say "$n nie dzialal." 'Yellow' }
    }
}

function Test-Nginx {
    Push-Location $NginxDir
    try { $out = cmd /c "`"$Nginx`" -t 2>&1"; $ok = ($LASTEXITCODE -eq 0) } finally { Pop-Location }
    if (-not $ok) { $out | ForEach-Object { Say "  $_" 'Red' } }
    return $ok
}

function Reload-Nginx {
    Push-Location $NginxDir
    try {
        if (Running 'nginx') { cmd /c "`"$Nginx`" -s reload 2>&1" | Out-Null; Say 'nginx przeladowany.' 'Green' }
        else { Start-Process $Nginx -WorkingDirectory $NginxDir -WindowStyle Hidden; Say 'nginx nie dzialal - uruchomiony.' 'Yellow' }
    } finally { Pop-Location }
}

function Install-NginxConf {
    Copy-Item (Join-Path $Root 'nyx.conf') (Join-Path $NginxDir 'conf\nyx.conf') -Force
    # Login do strony pobierania: kopiowany tylko gdy go jeszcze nie ma (zmieniony przez Ciebie plik zostaje).
    $htp = Join-Path $NginxDir 'conf\nyx_download.htpasswd'
    if (-not (Test-Path $htp) -and (Test-Path (Join-Path $Root 'nyx_download.htpasswd'))) { Copy-Item (Join-Path $Root 'nyx_download.htpasswd') $htp }
    $text = Get-Content $NginxConf -Raw
    if ($text -match '(?m)^\s*include\s+nyx\.conf;') {
        Say 'nginx.conf juz zawiera nyx.conf - odswiezam tylko plik.' 'Yellow'
        if (Test-Nginx) { Reload-Nginx } else { Say 'Test nginx nie przeszedl (nic nie zmieniono w nginx.conf).' 'Red' }
        return
    }
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $backup = "$NginxConf.bak-$stamp"
    Copy-Item $NginxConf $backup -Force
    # Wstawiamy include tuz przed ostatnim nawiasem zamykajacym blok http (koniec pliku).
    $idx = $text.LastIndexOf('}')
    $new = $text.Substring(0, $idx) + "`r`n    # Nyx - prywatny czat`r`n    include nyx.conf;`r`n" + $text.Substring($idx)
    [IO.File]::WriteAllText($NginxConf, $new, (New-Object Text.UTF8Encoding($false)))
    if (Test-Nginx) { Reload-Nginx; Say "Gotowe. Kopia poprzedniej konfiguracji: $backup" 'Green' }
    else {
        Copy-Item $backup $NginxConf -Force
        Say 'Test nginx nie przeszedl - przywrocono poprzednia konfiguracje, nic nie zmieniono.' 'Red'
    }
}

switch ($Cmd) {
    'start'   { Start-Nyx }
    'stop'    { Stop-Nyx }
    'restart' { Stop-Nyx; Start-Sleep 2; Start-Nyx }
    'nginx'   { Install-NginxConf }
    'update' {
        $u = Join-Path $Root 'update'
        if (-not (Test-Path (Join-Path $u 'server'))) { Say 'Brak folderu update\server - nie ma czego wgrywac.' 'Yellow'; break }
        Stop-Nyx
        Start-Sleep 2
        # /XF: konfiguracja produkcyjna z sekretem zostaje nietknieta. Kody robocopy ponizej 8 oznaczaja sukces.
        robocopy (Join-Path $u 'server') (Join-Path $Root 'server') /E /XF appsettings.Production.json /NFL /NDL /NJH /NJS /NP | Out-Null
        if ($LASTEXITCODE -ge 8) { Say 'Kopiowanie serwera nie powiodlo sie.' 'Red'; break }
        if (Test-Path (Join-Path $u 'turn')) { robocopy (Join-Path $u 'turn') (Join-Path $Root 'turn') /E /NFL /NDL /NJH /NJS /NP | Out-Null }
        if (Test-Path (Join-Path $u 'nyx.conf')) { Copy-Item (Join-Path $u 'nyx.conf') (Join-Path $Root 'nyx.conf') -Force }
        cmd /c "rmdir /s /q `"$u`""
        Say 'Nowa wersja wgrana.' 'Green'
        Start-Nyx
        if (Test-Path (Join-Path $Root 'nyx.conf')) { Install-NginxConf }
    }
    'status' {
        foreach ($n in 'Nyx.Server', 'nyx-turn', 'nginx') { Say ("{0,-12} {1}" -f $n, $(if (Running $n) { 'dziala' } else { 'NIE dziala' })) $(if (Running $n) { 'Green' } else { 'Red' }) }
        try { $r = Invoke-RestMethod 'http://127.0.0.1:5200/health' -TimeoutSec 5; Say "lokalnie:    $r" 'Green' } catch { Say 'lokalnie:    brak odpowiedzi z 127.0.0.1:5200' 'Red' }
        try { $r = Invoke-RestMethod "https://$Host_/health" -TimeoutSec 10; Say "z internetu: $r" 'Green' } catch { Say "z internetu: brak odpowiedzi z https://$Host_ (DNS w Cloudflare? nginx.conf? router?)" 'Red' }
    }
    'firewall' {
        netsh advfirewall firewall add rule name="Nyx TURN udp" dir=in action=allow protocol=UDP localport=3478 | Out-Null
        netsh advfirewall firewall add rule name="Nyx TURN tcp" dir=in action=allow protocol=TCP localport=3478 | Out-Null
        netsh advfirewall firewall add rule name="Nyx TURN relay" dir=in action=allow protocol=UDP localport=49160-49200 | Out-Null
        Say 'Porty TURN otwarte w Zaporze: 3478 udp+tcp, 49160-49200 udp.' 'Green'
    }
    'autostart' {
        $cmd = "powershell -NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`" start"
        schtasks /Create /TN 'Nyx' /TR $cmd /SC ONSTART /RU SYSTEM /RL HIGHEST /F | Out-Null
        Say 'Nyx wystartuje razem z Windows (zadanie "Nyx" w Harmonogramie zadan).' 'Green'
    }
    'invite' {
        $f = Join-Path $Logs 'nyx.log'
        if (Test-Path $f) { Select-String -Path $f -Pattern 'invite code' | Select-Object -Last 1 | ForEach-Object { Say $_.Line 'Cyan' } }
        Say '(Kod pojawia sie w logu tylko dopoki nie ma zadnego konta. Kolejne zaproszenia: przycisk "Invite someone" w aplikacji.)'
    }
    'log' {
        $n = if ($Arg) { [int]$Arg } else { 40 }
        foreach ($f in 'nyx.log', 'nyx.err.log') { $p = Join-Path $Logs $f; if (Test-Path $p) { Say "--- $f" 'Cyan'; Get-Content $p -Tail $n } }
    }
    default { Get-Content $PSCommandPath -TotalCount 14 | ForEach-Object { Write-Host ($_ -replace '^#\s?', '') } }
}
