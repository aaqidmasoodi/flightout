# Flightout

A flight game built in Godot 4, starring a fully animated Su-27 Flanker.

## Features
- Su-27 model built at real scale in Blender, with animated landing gear, canopy, airbrake, radome, radar dish, flaperons, slats, stabilators and rudders
- Physics-based flight model: lift and induced drag from angle of attack, transonic wave drag, thrust with afterburner and altitude lapse, gravity, air density, fly-by-wire rate commands with AoA and G limiting
- Nose-wheel steering, wheel brakes and judged landings
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
- `project.godot`, `scenes/`, `scripts/` : Godot project
- `assets/su27.glb` : exported aircraft model used by the game
- `blender/su27.blend` : Blender source for the aircraft (ignored by Godot)

## Running
Open the folder in Godot 4.7 (Import in the Project Manager) and press Play.
