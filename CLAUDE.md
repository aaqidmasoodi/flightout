# FlightOut: rules for working on this project

- **Netcode is DCS / military flight-sim style, always.** This is a flight simulator: aircraft, missiles, flares and
  chaff move predictably. Other players' objects are predicted to the present (dead reckoning) and corrections are
  blended in smoothly, never snapped. Smoothness in close formation comes first. Read `docs/NETCODE.md` before
  changing anything in `scripts/net/`, or adding anything that moves and is seen by other players.
- Kashmir is the only map.
- On-screen flight data, status, warnings and ILS are development-only (`Game.dev_hud`); players get the cockpit
  instruments and the FPS counter.
- Test performance and netcode by flying real manoeuvres (turns, rolls, formation, different camera views), not
  just straight and level.
- Never commit keys or credentials (the project is open source).
