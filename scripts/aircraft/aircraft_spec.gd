extends Resource
## AircraftSpec: every parameter that defines how one aircraft flies.
## The flight model (scripts/aircraft/aircraft.gd) is generic; an aircraft is just one of these files.

@export_group("Identity")
@export var id: String = "aircraft"   ## Short id used in code and (later) network messages
@export var display_name: String = "Aircraft"
@export var model_scene: String = ""   ## glTF model following the FlightOut node naming contract
@export var cockpit_eye: Vector3 = Vector3(0, 1.3, -5)   ## Pilot eye point, aircraft frame (-Z forward)
@export_group("Airframe")
@export var mass_kg: float = 20000.0   ## Typical combat weight
@export var wing_area: float = 60.0   ## m^2, reference area
@export var wing_span: float = 14.0   ## m, used for ground effect
@export var aspect_ratio: float = 3.5
@export var oswald: float = 0.8   ## span efficiency for induced drag
@export_group("Lift")
@export var cl0: float = 0.05   ## lift at zero AoA
@export var cl_alpha: float = 4.0   ## low-AoA lift slope per radian (limiter estimate)
@export var cl_table: Array = []   ## [alpha_deg, CL] clean lift curve at low Mach, 0..90 deg
@export var alpha_crit_deg: float = 30.0   ## critical AoA (CLmax) at low Mach
@export var alpha_buffet_frac: float = 0.62   ## buffet begins at this fraction of the critical AoA
@export var slat_crit_bonus_deg: float = 3.0   ## leading-edge slats raise the critical AoA by this much
@export var flap_cl: float = 0.30   ## extra lift with flaps down
@export_group("Drag")
@export var cd0: float = 0.024   ## clean parasite drag
@export var wave_drag_peak: float = 0.032   ## transonic drag rise peak (near Mach 1.1)
@export var flap_cd: float = 0.03
@export var airbrake_cd: float = 0.07
@export var gear_cd: float = 0.02
@export var side_force: float = 0.6   ## side force per radian of sideslip
@export_group("Engines")
@export var engine_count: int = 1
@export var thrust_idle_n: float = 2500.0   ## per engine
@export var thrust_dry_n: float = 60000.0   ## per engine, military power
@export var thrust_ab_n: float = 100000.0   ## per engine, full afterburner (same as dry if none)
@export var ab_threshold: float = 0.85   ## throttle above this lights the afterburner
@export var spool_rate: float = 0.45   ## engine response, throttle fraction per second
@export_group("Fly-by-wire")
@export var g_max: float = 9.0
@export var g_min: float = -3.0
@export var alpha_limit_deg: float = 26.0   ## AoA limiter (overridable)
@export var max_rates: Vector3 = Vector3(0.65, 0.35, 3.8)   ## pitch, yaw, roll rate demand at full stick (rad/s)
@export var ang_accel: Vector3 = Vector3(2.5, 1.5, 9.0)   ## rate onset (rad/s^2)
@export var q_ref: float = 9000.0   ## dynamic pressure (Pa) for full pitch/yaw authority
@export var q_ref_roll: float = 14000.0   ## dynamic pressure (Pa) for full roll authority
@export_group("Ground")
@export var rotate_ias_start: float = 55.0   ## m/s IAS where the tail starts lifting the nose wheel
@export var rotate_ias_full: float = 72.0   ## m/s IAS for full rotation authority
@export var gear_height: float = 2.0   ## origin height above ground, level, gear down
@export var nose_contact: Vector3 = Vector3(0, -2, -5)
@export var main_contact: Vector3 = Vector3(0, -2, 1.8)
@export var tail_probe: Vector3 = Vector3(0, 0, 10)   ## tail stinger point for tail strikes
@export var wing_height_offset: float = 1.6   ## wing height below origin (ground effect)
@export var roll_friction: float = 0.025
@export var brake_friction: float = 0.45
@export var wheelbase: float = 7.0   ## m, nose wheel to main wheels
@export var max_steer_deg: float = 55.0   ## nose-wheel angle at taxi speed
@export var max_ground_pitch_deg: float = 13.0   ## tail touches the runway beyond this
@export_group("Gear")
@export var static_stroke: float = 0.12   ## oleo compression at rest
@export var max_stroke: float = 0.32   ## beyond this the gear bottoms out
@export var gear_contacts: Array = []   ## wheel contact points at full extension (nose, main L, main R)
@export var gear_k: Array = []   ## spring rate per wheel, N/m
@export var gear_c: Array = []   ## damping per wheel, N/(m/s)
@export var sink_smooth: float = 1.5   ## touchdown grades, m/s
@export var sink_good: float = 3.0
@export var sink_firm: float = 4.5
@export var sink_hard: float = 7.0   ## above this the gear collapses
@export var crash_probes: Array = []   ## airframe points that must not touch the ground
