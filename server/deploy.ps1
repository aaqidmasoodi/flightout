# Builds the Linux dedicated server and deploys it to the official server.
# Usage (PowerShell, from the project folder):  .\server\deploy.ps1
# Needs: Godot at $Godot, the server's SSH key at $Key.
# The server's login and key are not in the repository (it is public): put them in server/deploy.local.json, which
# git ignores, e.g.  { "server": "user@host", "key": "C:\\path\\to\\key" }
param(
    [string]$Godot = "$env:USERPROFILE\Desktop\Godot.exe",
    [string]$Key = "",
    [string]$Server = ""
)
$ErrorActionPreference = "Stop"
$localCfg = Join-Path $PSScriptRoot "deploy.local.json"
if (Test-Path $localCfg) {
    $cfg = Get-Content $localCfg -Raw | ConvertFrom-Json
    if (-not $Server -and $cfg.server) { $Server = $cfg.server }
    if (-not $Key -and $cfg.key) { $Key = $cfg.key }
}
if (-not $Server -or -not $Key) { throw "Set the server and key in server/deploy.local.json (or pass -Server and -Key)" }
$root = Split-Path -Parent $PSScriptRoot
$out = Join-Path $root "build\linux"
New-Item -ItemType Directory -Force $out | Out-Null

Write-Host "Building the Linux server..."
& $Godot --headless --path $root --export-release "Linux Server" (Join-Path $out "flightout_server.x86_64") | Out-Null
if ($LASTEXITCODE -ne 0) { throw "Export failed" }

# Map data: the server reads the Kashmir heights and land cover from /opt/flightout/kashmir (not packed into the
# server build: it is large and rarely changes). Only files that are missing or changed size are sent.
$map = Join-Path $root "assets\kashmir"
$mapFiles = @("terrain.json", "h0.bin", "i0.bin", "lc0.bin", "lci0.bin")
Write-Host "Checking the map data on the server..."
$have = @{}
$list = ssh -i $Key $Server "sudo mkdir -p /opt/flightout/kashmir; cd /opt/flightout/kashmir && stat -c '%n %s' * 2>/dev/null || true"
foreach ($line in $list) {
    $p = "$line".Trim() -split ' '
    if ($p.Count -eq 2) { $have[$p[0]] = [int64]$p[1] }
}
$send = @()
foreach ($f in $mapFiles) {
    $local = Join-Path $map $f
    if (-not (Test-Path $local)) { throw "Map file missing: $local" }
    if (-not $have.ContainsKey($f) -or $have[$f] -ne (Get-Item $local).Length) { $send += $local }
}
if ($send.Count -gt 0) {
    $mb = [math]::Round((($send | ForEach-Object { (Get-Item $_).Length }) | Measure-Object -Sum).Sum / 1MB)
    Write-Host "Uploading map data ($($send.Count) files, $mb MB, only needed once)..."
    ssh -i $Key $Server "mkdir -p ~/flightout_upload/kashmir"
    scp -i $Key $send "${Server}:flightout_upload/kashmir/"
    ssh -i $Key $Server "sudo install -m 644 ~/flightout_upload/kashmir/* /opt/flightout/kashmir/ && rm -rf ~/flightout_upload/kashmir"
} else {
    Write-Host "Map data is up to date."
}

Write-Host "Uploading..."
ssh -i $Key $Server "mkdir -p ~/flightout_upload"
scp -i $Key -C (Join-Path $out "flightout_server.x86_64") (Join-Path $out "flightout_server.pck") (Join-Path $PSScriptRoot "flightout.service") "${Server}:flightout_upload/"

Write-Host "Installing and restarting..."
$remote = @"
set -e
sudo install -m 755 ~/flightout_upload/flightout_server.x86_64 /opt/flightout/
sudo install -m 644 ~/flightout_upload/flightout_server.pck /opt/flightout/
sudo install -m 644 ~/flightout_upload/flightout.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl restart flightout
sleep 3
systemctl is-active flightout
"@ -replace "`r", ""
ssh -i $Key $Server $remote
Write-Host "Done. Logs: ssh -i $Key $Server 'journalctl -u flightout -f'"
