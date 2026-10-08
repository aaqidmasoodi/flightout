extends Resource
## AircraftSpec: every parameter that defines one aircraft. The simulation (scripts/sim/) is generic;
## an aircraft is one of these files plus a model that follows the node naming contract.

@export_group("Identity")
@export var id: String = "aircraft"   ## Short id used in code and network messages
@export var display_name: String = "Aircraft"
@export var model_scene: String = ""   ## glTF model following the FlightOut node naming contract
@export var cockpit_eye: Vector3 = Vector3(0, 1.3, -5)   ## pilot eye point, body frame
@export_group("Mass")
@export var empty_mass: float = 15000.0   ## kg
@export var misc_mass: float = 700.0   ## kg: pilot, oil, gun ammunition
@export var fuel_capacity: float = 8000.0   ## kg internal
@export var fuel_default: float = 5000.0   ## kg at spawn
@export var inertia: Vector3 = Vector3(250000, 280000, 40000)   ## kg m^2 about body X (pitch), Y (yaw), Z (roll)
@export var inertia_ref_mass: float = 22000.0   ## mass the inertia values refer to (scaled with mass)
@export_group("Geometry")
@export var wing_area: float = 60.0   ## m^2
@export var wing_span: float = 14.0   ## m
@export var mac: float = 4.5   ## m, mean aerodynamic chord
@export var aspect_ratio: float = 3.5
@export var oswald: float = 0.8
@export_group("Lift")
@export var cl_table: Array = []   ## [alpha_deg, CL] clean, low Mach
@export var alpha_crit_deg: float = 30.0   ## CLmax AoA at low Mach
@export var alpha_buffet_frac: float = 0.62   ## buffet onset as a fraction of the critical AoA
@export var slat_crit_bonus_deg: float = 3.0
@export var flap_cl: float = 0.3
@export var cl_de: float = -0.25   ## lift per rad of elevator (tail download when pulling)
@export_group("Drag")
@export var cd0: float = 0.024
@export var wave_drag_peak: float = 0.032
@export var flap_cd: float = 0.03
@export var airbrake_cd: float = 0.07
@export var gear_cd: float = 0.02
@export var cy_beta: float = -0.9   ## side force per rad of sideslip
@export var cy_dr: float = 0.15   ## side force per rad of rudder
@export_group("Moments")
@export var cm_table: Array = []   ## [alpha_deg, Cm] static pitching moment (+ nose up)
@export var cm_q: float = -5.5   ## pitch damping
@export var cm_de: float = 1.0   ## pitch control power per rad of elevator
@export var flap_cm: float = -0.03
@export var cl_beta: float = -0.06   ## dihedral effect
@export var cl_p: float = -0.28   ## roll damping
@export var cl_r: float = 0.05
@export var cl_da: float = 0.11   ## roll control power per rad
@export var cl_dr: float = 0.01
@export var cn_beta: float = 0.14   ## weathercock stability
@export var cn_r: float = -0.35   ## yaw damping
@export var cn_dr: float = 0.075   ## yaw control power per rad
@export var cn_da: float = -0.008   ## adverse yaw
@export_group("Controls")
@export var elevator_up_deg: float = 25.0   ## trailing edge up travel
@export var elevator_down_deg: float = 20.0
@export var aileron_deg: float = 20.0
@export var rudder_deg: float = 25.0
@export var actuator_rates: Vector3 = Vector3(60, 70, 90)   ## deg/s: elevator, rudder, aileron
@export_group("Fly-by-wire")
@export var g_max: float = 9.0
@export var g_min: float = -3.0
@export var alpha_limit_deg: float = 26.0   ## AoA limiter (K overrides)
@export var max_rates: Vector3 = Vector3(0.5, 0.25, 4.2)   ## rad/s demand at full stick: pitch, yaw, roll
@export var fbw_gains: Vector3 = Vector3(4.0, 2.5, 5.0)   ## 1/s rate-loop bandwidth: pitch, yaw, roll
@export_group("Engines")
@export var engine_count: int = 1
@export var engine_idle_n2: float = 68.0   ## % core speed at idle
@export var thrust_idle_n: float = 2000.0   ## per engine
@export var thrust_dry_n: float = 60000.0   ## per engine, military power
@export var thrust_ab_n: float = 100000.0   ## per engine, full afterburner
@export var ab_threshold: float = 0.85   ## throttle detent for afterburner
@export var ab_ignition_delay: float = 0.7   ## s
@export var ab_stage_rate: float = 0.9   ## stages per second
@export var spool_up_time: float = 3.5   ## s time constant near idle
@export var spool_down_time: float = 2.2
@export var tsfc_dry: float = 1.9e-05   ## kg per N per s
@export var tsfc_ab: float = 5.4e-05
@export_group("Ground")
@export var gear_height: float = 2.0   ## origin height above ground at rest
@export var wing_height_offset: float = 1.6
@export var tail_probe: Vector3 = Vector3(0, 0, 10)
@export var roll_friction: float = 0.02
@export var brake_friction: float = 0.5
@export var tyre_side_friction: float = 0.8
@export var max_steer_deg: float = 55.0
@export var gear_transit_time: float = 4.0   ## s to extend or retract
@export var static_stroke: float = 0.12   ## oleo compression at rest (visuals)
@export var max_stroke: float = 0.32
@export var gear_contacts: Array = []   ## nose, main L, main R (body frame, full extension)
@export var gear_k: Array = []   ## N/m
@export var gear_c: Array = []   ## N/(m/s)
@export var sink_smooth: float = 1.5
@export var sink_good: float = 3.0
@export var sink_firm: float = 4.5
@export var sink_hard: float = 7.0
@export var crash_probes: Array = []   ## airframe points that must not touch
