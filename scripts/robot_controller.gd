class_name RobotController
extends CharacterBody3D

signal movement_changed(status: String, speed: float, destination: Vector3)

@export var move_speed := 3.5
@export var acceleration := 8.0
@export var turn_speed := 5.0

@onready var navigation_agent: NavigationAgent3D = $NavigationAgent3D

var _destination := Vector3.ZERO
var _has_target := false


func _ready() -> void:
	navigation_agent.path_desired_distance = 0.25
	navigation_agent.target_desired_distance = 0.3
	movement_changed.emit("Idle", 0.0, Vector3.ZERO)


func set_navigation_target(target: Vector3) -> void:
	_destination = target
	_has_target = true
	navigation_agent.target_position = target
	movement_changed.emit("Moving", velocity.length(), _destination)


func _physics_process(delta: float) -> void:
	if not _has_target or navigation_agent.is_navigation_finished():
		_stop_robot(delta)
		return

	var next_position := navigation_agent.get_next_path_position()
	var direction := next_position - global_position
	direction.y = 0.0
	if direction.length_squared() > 0.0001:
		direction = direction.normalized()
		var desired_velocity := direction * move_speed
		velocity.x = move_toward(velocity.x, desired_velocity.x, acceleration * delta)
		velocity.z = move_toward(velocity.z, desired_velocity.z, acceleration * delta)
		var target_angle := atan2(direction.x, direction.z)
		rotation.y = lerp_angle(rotation.y, target_angle, turn_speed * delta)
	else:
		velocity.x = move_toward(velocity.x, 0.0, acceleration * delta)
		velocity.z = move_toward(velocity.z, 0.0, acceleration * delta)
	velocity.y = 0.0
	move_and_slide()
	movement_changed.emit("Moving", Vector2(velocity.x, velocity.z).length(), _destination)


func _stop_robot(delta: float) -> void:
	if _has_target and navigation_agent.is_navigation_finished():
		_has_target = false
	velocity.x = move_toward(velocity.x, 0.0, acceleration * delta)
	velocity.z = move_toward(velocity.z, 0.0, acceleration * delta)
	velocity.y = 0.0
	if velocity.length_squared() > 0.0001:
		move_and_slide()
	movement_changed.emit("Idle", Vector2(velocity.x, velocity.z).length(), _destination)
