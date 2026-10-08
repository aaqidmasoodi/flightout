# FlightOut

**Yembera FlightOut**, a combat flight game by Yembera.

A flight game built in Godot 4, starring a fully animated Su-27 Flanker.

## Features
- 41 x 41 km island map surrounded by sea: hills, forests, a northern mountain range with snow, and an airbase with a 3 km runway, taxiways, apron, hardened shelters, hangar, tower and fuel farm
- Su-27 model built at real scale in Blender, with animated landing gear, canopy, airbrake, radome, radar dish, flaperons, slats, stabilators and rudders
- Physics-based flight model: lift and induced drag from angle of attack, transonic wave drag, thrust with afterburner and altitude lapse, gravity, air density, fly-by-wire rate commands with AoA and G limiting
- Nose-wheel steering (tiller works even when stopped), wheel brakes, judged landings, terrain and sea collisions
- Textured Su-27: three-tone camo, panel lines, weathering, national markings
- Close, far and cockpit cameras with free look

## Controls
| Key | Action |
|---|---|
| Shift / Ctrl | Throttle up / down (above 85% = afterburner) |
| W / S | Nose down / pull up |
| A / D | Roll |
| Q / E | Yaw, nose-wheel steering on the ground |
| G | Landing gear |
| F | Flaps |
| B | Airbrake |
| Space | Wheel brakes |
| C | Canopy |
| R | Radar scan |
| T | Radome |
| V | Cycle camera (close, far, orbit, cockpit). Orbit is DCS-style: follows position only, horizon stays level |
| Right mouse drag | Look around |
| Mouse wheel | Zoom |
| L | Exterior lights |
| Z | Auto-throttle (holds current speed) |
| P | Practice approach: 7 km final to runway 36, configured to land |
| H | Show / hide the flight data panel |
| K | AoA limiter off / on (allows the Cobra; you can stall and depart) |
| Esc | Pause menu (settings, restart, main menu) |
| Backspace | Reset |

## Menus
The game starts on a lightweight main menu (live Su-27 backdrop, nothing else loaded). **Play** streams the island in on a loading screen.
**Settings** (also in the Esc pause menu during flight) cover display, graphics, HUD, controls and audio; every change applies instantly and is saved to `user://settings.cfg`.
The flight path marker and ILS guidance appear in the cockpit view only.

## Landing
Press **P** for a practice approach. Follow the ILS box (bottom right): keep both needles centred, about 270-300 km/h, gear down, flaps on.
The PAPI lights left of the touchdown zone show two white and two red on the correct 3 degree glide (all white = high, all red = low).
Flare gently a few metres above the runway and close the throttle. Touchdowns are graded: smooth (<1.5 m/s), good (<3), firm (<4.5), hard (<7), and above 7 m/s the gear collapses.
Runway 36 (approach from the south over the sea) is the instrument runway; runway 18 is visual only because of the mountains to the north.

## Architecture
- Aircraft are data: `scripts/aircraft/aircraft.gd` is one generic flight model; each aircraft is an `AircraftSpec` resource (`data/aircraft/su27.tres`, 57 parameters: mass, wing, lift curve, critical AoA, drag, engines, fly-by-wire limits, rates, gear, suspension, cockpit eye, model). A new jet is a new `.tres` plus a model that follows the node naming contract.
- Aerodynamics run on air-relative velocity (wind-ready). The HUD shows IAS, TAS, ground speed, Mach and heading.
- `Settings` autoload: every option, saved and applied live; scenes listen for changes
- `Game` autoload: menu and flight flow, preloaded asset cache (multiplayer session state will live here)
- `WorldData` autoload: authoritative heightmap and runways, loaded only when a flight starts
- UI built from one theme (`scripts/ui/ui_theme.gd`): Rajdhani type, frosted glass panels, afterburner-orange accent

## Project layout
- `project.godot`, `scenes/`, `scripts/`, `shaders/` : Godot project
- `scripts/world/world_data.gd` : autoload with the authoritative heightmap (ground height, sea, spawns). Render-free so a future dedicated server can share it
- `scripts/world/world.gd` : visual world (terrain chunks, terrain and ocean shaders, forests)
- `scenes/menu.tscn`, `scripts/ui/` : main menu, settings, about, pause menu
- `assets/ui/` : FlightOut emblem, app icon, boot splash, Yembera mark; `assets/fonts/` : Rajdhani (SIL OFL)
- `assets/su27.glb` : exported aircraft
- `assets/world/world.glb`, `heightmap.r32`, `world_meta.json` : exported map, height data and metadata
- `blender/su27.blend` : aircraft source; `blender/world.blend` : map source; `blender/textures/` : baked textures (Godot ignores this folder)

## Running
Open the folder in Godot 4.7 (Import in the Project Manager) and press Play.
