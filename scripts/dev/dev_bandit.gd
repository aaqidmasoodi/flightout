extends Node3D
## Development: a simple target for the sensor displays (--dev-bandits). Flies a straight line or a slow
## circle; carries the fields the sensors read (velocity, team, callsign). No mesh, no physics.

var velocity := Vector3.ZERO
var team := "red"
var callsign := "BANDIT"
var turn_rate := 0.0            # rad/s, + right


func _ready() -> void:
	add_to_group("ai_aircraft")


func _physics_process(delta: float) -> void:
	if turn_rate != 0.0:
		velocity = velocity.rotated(Vector3.UP, -turn_rate * delta)
	global_position += velocity * delta
