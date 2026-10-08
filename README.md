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
All keys can be rebound in Settings → Controls (two keys per action; conflicts move the key, Delete clears). The HUD key caps and hints always show your current bindings. Defaults:
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

## Time of day, weather and clouds
Settings → Weather: time presets (night, dawn, morning, noon, afternoon, sunset, dusk), a time slider, time flow (frozen, real time, fast), and sky conditions (clear, scattered, broken, overcast, fog, rain), plus wind and turbulence. Settings → Display → Image: brightness, contrast, gamma, saturation.
- `scripts/world/sky_system.gd`: sun and moon positions from the hour at a 34°N latitude; light colour and strength, ambient light, fog, exposure and glow keyed to the sun's elevation; weather eases in smoothly; above an overcast deck the sky is clear; rain particles and rain sound.
- `shaders/sky.gdshader`: sky colour by sun elevation, sun disc and glow, moon, stars, high cirrus.
- Distant water fades into the horizon haze like the land.
- `scripts/world/volumetric_clouds.gd` + `shaders/clouds_march.glsl`, `clouds_resolve.glsl`, `clouds_composite.glsl`: raymarched volumetric clouds as a compositor effect in three GPU passes. March (half resolution): 3D Perlin-Worley density with detail erosion, a weather map and varied layer heights; adaptive stepping (large steps through empty air, small steps inside cloud); blue-noise ray offsets; Beer-Lambert self-shadowing, powder and multiple-scattering lighting; stores cloud start and end distances. Resolve: temporal accumulation with wind-aware reprojection and motion-adaptive neighbourhood clipping (no trails). Composite (full resolution): cubic B-spline upsampling with each sample trimmed against the pixel's exact depth, so clouds behind an object never cover it.

## Terrain and forests
- One forest density map is computed from the heightmap: dense woods on hillsides, groves in the lowlands, a treeline near 1,100 m, nothing on steep rock or beaches. The terrain shader paints forest floor from the same map.
- About 96,000 trees (conifers higher up, broadleaves lower), each with its own size, lean and tint, swaying in the wind. Per-tree level of detail: a detailed, shadow-casting pool around the camera refilled from a spatial grid, cheap batches beyond, with a dithered crossfade.
- Terrain, ocean and clouds use mipmapped noise textures, so they stay smooth at any distance.

## Weather
Settings → Weather: wind strength and direction (runway 36 points north, so a north wind is a headwind) and turbulence.

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
**Simulation (pure data, server-ready)** in `scripts/sim/`. No nodes, no rendering, seeded randomness, fixed tick (120 Hz physics, 2 substeps = 240 Hz), so the same code can run authoritatively on a server and predictively on clients.
- `flight_model.gd`: 6-DOF rigid body with an inertia tensor. Forces and moments from aerodynamic coefficients: lift from a CL(alpha) table scaled by Mach (compressibility, Mach-dependent critical AoA), induced/wave/flat-plate drag, side force; pitching moment table with pitch damping and elevator power; roll (dihedral, damping, aileron, rudder) and yaw (weathercock stability, damping, rudder, adverse yaw). Post-stall: buffet, wing rock, wing drop, loss of directional stability.
- Fly-by-wire by nonlinear dynamic inversion: stick commands g (pitch), roll rate about the velocity vector, and coordinated yaw; the inversion computes the surface deflections, which then move through rate-limited actuators with real travel limits. AoA and G protection; K overrides the AoA limiter while aft stick is held (Cobra). Neutral stick holds the flight path, including in turns.
- Landing gear: a spring-damper per strut at its real contact point, tyre rolling resistance, braking and side friction, nose-wheel steering. Rotation, wheelies, crosswind behaviour and taxi turns all come from these forces.
- `jet_engine.gd`: core spool (N2) dynamics, thrust curve, afterburner light-off delay and staging, fuel flow and flameout. Mass and inertia change as fuel burns.
- `atmosphere.gd`: International Standard Atmosphere (temperature, pressure, density, speed of sound), wind with a boundary-layer profile, deterministic turbulence.

**Aircraft are data**: `AircraftSpec` (`scripts/aircraft/aircraft_spec.gd`, 81 parameters) and one file per aircraft (`data/aircraft/su27.tres`). `scripts/aircraft/aircraft.gd` is a thin node that feeds controls in and drives visuals from the sim (actuator positions move the surfaces, gear transit drives the animation, strut compression moves the oleos).

**Services (autoloads)**: `Settings` (saved, applied live), `Game` (menu and flight flow), `Audio` (mix buses, cockpit muffling, interface sounds), `WorldData` (heightmap, runways, shared atmosphere).

**Sound**: `scripts/aircraft/aircraft_audio.gd` layers turbine whine, core roar, low rumble and afterburner (with a CC0 recording underneath) at the intakes and nozzles in 3D with distance, air absorption and Doppler; jet directivity makes the front whine and the rear roar. Wind follows dynamic pressure, buffet follows the stall model, tyre roll follows wheel speed, hydraulics follow the gear, canopy and airbrake. Touchdown, tyre chirp, gear locks, afterburner light-off, tail scrape and crash are event-driven. Cockpit warnings: pull up, stall, over-G, gear, low fuel. Credits in `assets/audio/CREDITS.md`.

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

## Graphics presets
Settings → Graphics → Preset: Low, Medium, High, Ultra, or Custom. A preset sets every option at once (render scale and FSR upscaling, anti-aliasing, anisotropic filtering, shadows and shadow quality, ambient occlusion, bloom, forest detail and density, draw distance, cloud quality); changing any option switches to Custom. Measured while flying on the development PC: Low about 310 fps, Medium 167, High 103, Ultra 71.

## Runway and forests at a distance
- The runway markings are procedural (`shaders/runway.gdshader`): ICAO-style edge lines, centreline, threshold stripes, designators "36" and "18", aiming points and touchdown zones, analytically anti-aliased so they stay sharp at any distance.
- Trees smaller than a few pixels on screen are thinned out and the terrain draws a forest canopy texture instead, so forests read correctly from altitude without speckle.
- The sky's lighting cubemap is only re-rendered when the sky actually changes.
