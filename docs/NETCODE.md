# FlightOut netcode: design rules

## The rule

FlightOut is a flight simulator, not a shooter. Aircraft, missiles, flares and chaff move predictably: they have
mass, momentum and limited turn rates, and they cannot stop or reverse in an instant. Multiplayer is therefore done
the way DCS and military flight simulators (the DIS standard) do it:

- **Every moving object from another player is drawn at the present moment, predicted forward** from its latest
  update (dead reckoning: position, velocity, acceleration, turn rates). It is not drawn in the past.
- **New updates are blended in smoothly, never snapped.** When an update arrives, the object keeps moving along the
  path it was shown on, and its velocity and position slide onto the new prediction over a fraction of a second
  (projective velocity blending). Snapping, jumping, stepping or shaking is a bug.
- **Smoothness comes first.** Close formation flight at 100 m or less must look real: a 30 cm jump at 100 m is
  visible, and any difference in timing between two jets flying together at 170 m/s shows as one shaking against
  the other.
- **Everything is placed on the simulation clock.** Remote objects are placed every simulation tick, exactly like
  our own jet, and the engine's physics interpolation draws them all between ticks with the same fraction. Never
  position things by the wall clock or per rendered frame.
- **The same applies to everything added later**: missiles, flares, chaff, ground vehicles, ships. Send their state,
  predict them to the present on every client, and blend corrections.

Shooter techniques (drawing other players in the past between snapshots, rewinding hit boxes) exist because people
in shooters start, stop and turn instantly. That is not this game.

## How it is built now

- **Your own jet:** client prediction with the server in charge. Each tick the input is applied at once; the server's
  state for that tick is compared when it comes back, and on a mismatch the jet rewinds and replays the inputs since,
  with the difference blended out of the view (`scripts/net/client.gd`, `Aircraft.rewind`).
- **Other jets:** `scripts/net/client.gd`, `_predict` and `_reckon`.
  - Each jet keeps its own clock (its simulation tick = our tick + offset, smoothed over about ten snapshots). The
    drawing clock follows it at most 1% fast or slow, so network jitter never shows; it is only set outright when
    far out while the jet stands or rolls slowly (a player joining while loading), or after a long outage.
  - A blend always starts from the state as it was shown, at the time it was shown (the previous tick): starting it
    at the current tick freezes the jet for a tick at every snapshot, a 30 Hz shake.
  - The jet is predicted to the present (its clock plus the trip from the server) from the newest snapshot, using
    the acceleration measured between snapshots and the body turn rates.
  - Each newer snapshot starts a blend of `BLEND_TIME` (0.25 s) from the state as shown towards the new prediction.
  - If updates stop, prediction carries on (acceleration for 0.5 s, velocity up to 2 s) instead of freezing.

## Measuring it

`scripts/dev/formation.gd` flies a scripted two-ship (lead and wingman) between Srinagar and Awantipora with two
clients on a local server, and `tools/formation_report.py` reports, per client, how much the other jet wobbles on
screen relative to ours, frame to frame. Close formation should stay under 1 mrad (about 1.5 px at 1080p) in
almost every frame.

```
Godot --headless -- --server --server-stats=server.csv
Godot -- --connect=127.0.0.1 --callsign=Lead --dev-formation=lead --formation-log=lead.csv --formation-time=300
Godot -- --connect=127.0.0.1 --callsign=Wing --dev-formation=wing --formation-log=wing.csv --formation-time=300
python tools/formation_report.py lead.csv wing.csv server.csv
```

Add `--formation-weapons` to fire the weapons demo (F5) from both jets once airborne.

## Sources

- Eagle Dynamics developer (c0ff) on DCS netcode: extrapolation built for Lock On "allows for close formation flying
  over internet"; input low-pass filtered to avoid the stroboscopic effect in speed and turn rate.
  https://forum.dcs.world/topic/74397-dcs-world-and-netcode/page/2/
- DCS multiplayer structure (each client flies its own aircraft, the server relays, remote objects are extrapolated
  between updates): https://forum.dcs.world/topic/264294-understanding-multiplayer-netcode-and-requirements/
- Dead reckoning in DIS (military simulation standard): https://www.gamedeveloper.com/programming/dead-reckoning-latency-hiding-for-networked-games
- Projective velocity blending: C. Murphy, "Believable Dead Reckoning for Networked Games", Game Engine Gems 2.
- Why shooters interpolate in the past instead: https://www.gabrielgambetta.com/entity-interpolation.html
