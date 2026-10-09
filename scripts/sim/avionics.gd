extends RefCounted
## Avionics data layer shared by every fighter: master modes and the warning system.
##
## The master mode lives in the flight model state (server-owned, predicted like any switch), so the jet always
## knows what it is doing: the HUD picks its symbology from it, weapons will check it before they fire, and the
## warning system uses it to mute the alerts that are noise in combat. Terrain and stall protection never mute.

enum Mode { NAV, BVR, WVR, GND }
const MODE_NAMES := ["NAV", "BVR", "WVR", "GND"]
const MODE_TITLES := ["Navigation", "Beyond visual range", "Within visual range", "Ground attack"]

## Warnings in priority order (highest first).
enum W { PULL_UP, STALL, OVER_G, SINK_RATE, GEAR, BUFFET, LOW_FUEL }

## id -> [title, subtitle, level (0 warning red, 1 caution amber), voice clip or ""]
const INFO := {
	W.PULL_UP: ["PULL UP", "TERRAIN", 0, "warn_pullup"],
	W.STALL: ["STALL", "LOWER THE NOSE", 0, "warn_stall"],
	W.OVER_G: ["OVER G", "EASE THE PULL", 0, "warn_overg"],
	W.SINK_RATE: ["SINK RATE", "DESCENT TOO FAST", 0, ""],
	W.GEAR: ["GEAR", "GEAR NOT DOWN", 1, "warn_gear"],
	W.BUFFET: ["BUFFET", "NEAR THE STALL", 1, ""],
	W.LOW_FUEL: ["FUEL", "LOW FUEL", 1, ""],
}

## Warnings each master mode mutes. Combat flying is low, fast, steep and slow on purpose: approach and landing
## alerts are noise there. PULL UP, STALL and OVER G are never in this table.
const INHIBIT := {
	Mode.NAV: [],
	Mode.BVR: [W.SINK_RATE, W.GEAR],
	Mode.WVR: [W.SINK_RATE, W.GEAR, W.BUFFET],
	Mode.GND: [W.SINK_RATE, W.GEAR],
}

const LOW_FUEL_KG := 800.0


static func mode_name(mode: int) -> String:
	return MODE_NAMES[clampi(mode, 0, MODE_NAMES.size() - 1)]


## Every warning that applies right now, highest priority first, after the master mode's inhibits.
## `ac` is an aircraft node (scripts/aircraft/aircraft.gd).
static func active(ac) -> Array:
	var out: Array = []
	if ac.crashed:
		return out
	var agl: float = ac.altitude_agl
	var vs: float = ac.vertical_speed
	if not ac.wow:
		if vs < -5.0 and agl / -vs < 6.0 and agl < 900.0:
			out.append(W.PULL_UP)
		if ac.stall_frac > 0.55:
			out.append(W.STALL)
		if ac.g_load > ac.spec.g_max - 0.4:
			out.append(W.OVER_G)
		if (agl < 400.0 and vs < -10.0) or (agl < 60.0 and vs < -5.0):
			out.append(W.SINK_RATE)
		if not ac.gear_down and agl < 300.0 and vs < -1.5 and ac.ias < 110.0:
			out.append(W.GEAR)
		if ac.stall_frac > 0.05 and ac.stall_frac <= 0.55:
			out.append(W.BUFFET)
	if ac.fuel_kg < LOW_FUEL_KG:
		out.append(W.LOW_FUEL)
	var muted: Array = INHIBIT.get(int(ac.master_mode), [])
	if muted.is_empty():
		return out
	return out.filter(func(w): return not muted.has(w))
