# FlightOut dedicated server

The server is the same game build, run headless: `flightout_server.x86_64 --headless -- --server [--port=27015] [--name="..."]`.
It is authoritative for up to 16 pilots and needs **UDP 27015** open (cloud firewall and the machine's own).

## Official server

- Host: Oracle Cloud, London (`play.flightout.app`), Ubuntu 22.04
- Installed in `/opt/flightout`, runs as the unprivileged `flightout` user via systemd (`flightout.service`):
  starts at boot, restarts within 3 s if it stops.
- Settings and logs of the game live in `/var/lib/flightout`.

## Everyday commands (on the server)

```
sudo systemctl status flightout      # is it running
journalctl -u flightout -f           # live log: joins, leaves
sudo systemctl restart flightout     # restart
```

## Deploying a new version

From the project folder on Windows: `.\server\deploy.ps1` (builds the Linux export, uploads it, restarts the service).

The Kashmir map data the server needs (`terrain.json`, `h0.bin`, `i0.bin`, `lc0.bin`, `lci0.bin` from
`assets/kashmir`, about 875 MB) is not packed into the server build: it lives in `/opt/flightout/kashmir` and the
service passes `--terrain=/opt/flightout/kashmir`. `deploy.ps1` uploads only the files that are missing or have
changed, so the first deploy after a map change is slow and the rest are quick.

Clients and server must run the same protocol version (`scripts/net/protocol.gd`, `VERSION`), so deploy the server
whenever the netcode or the flight model changes.
