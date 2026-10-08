# Builds the Linux dedicated server and deploys it to the official server.
# Usage (PowerShell, from the project folder):  .\server\deploy.ps1
# Needs: Godot at $Godot, the server's SSH key at $Key.
param(
    [string]$Godot = "$env:USERPROFILE\Desktop\Godot.exe",
    [string]$Key = "$env:USERPROFILE\.ssh\flightout_server_key",
    [string]$Server = "ubuntu@play.flightout.app"
)
$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot
$out = Join-Path $root "build\linux"
New-Item -ItemType Directory -Force $out | Out-Null

Write-Host "Building the Linux server..."
& $Godot --headless --path $root --export-release "Linux Server" (Join-Path $out "flightout_server.x86_64") | Out-Null
if ($LASTEXITCODE -ne 0) { throw "Export failed" }

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
