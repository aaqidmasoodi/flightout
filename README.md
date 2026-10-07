# Flightout

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
| V | Cycle camera (close, far, cockpit) |
| Right mouse drag | Look around |
| Mouse wheel | Zoom |
| Backspace | Reset |

## Project layout
- `project.godot`, `scenes/`, `scripts/`, `shaders/` : Godot project
- `scripts/world/world_data.gd` : autoload with the authoritative heightmap (ground height, sea, spawns). Render-free so a future dedicated server can share it
- `scripts/world/world.gd` : visual world (terrain chunks, terrain and ocean shaders, forests)
- `assets/su27.glb` : exported aircraft
- `assets/world/world.glb`, `heightmap.r32`, `world_meta.json` : exported map, height data and metadata
- `blender/su27.blend` : aircraft source; `blender/world.blend` : map source; `blender/textures/` : baked textures (Godot ignores this folder)

## Running
Open the folder in Godot 4.7 (Import in the Project Manager) and press Play.
