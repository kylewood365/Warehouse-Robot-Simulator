class_name RobotController
extends CharacterBody3D

signal movement_changed(status: String, speed: float, destination: Vector3)

@export var move_speed := 3.5
@export var acceleration := 8.0
@export var turn_speed := 5.0

@onready var navigation_agent: NavigationAgent3D = $NavigationAgent3D

var _destination := Vector3.ZERO
var _has_target := false
var _path_diagnostics_pending := false


func _ready() -> void:
	navigation_agent.path_desired_distance = 0.25
	navigation_agent.target_desired_distance = 0.3
	movement_changed.emit("Idle", 0.0, Vector3.ZERO)


func set_navigation_target(target: Vector3) -> void:
	# Keep the CharacterBody3D on the physical floor while placing its navigation
	# query origin on the actual mesh. This offset is derived from the map rather
	# than assuming a particular navigation mesh height.
	var navigation_map := navigation_agent.get_navigation_map()
	var navigation_origin := NavigationServer3D.map_get_closest_point(
		navigation_map, global_position
	)
	navigation_agent.position.y = navigation_origin.y - global_position.y
	_destination = Vector3(target.x, global_position.y, target.z)
	_has_target = true
	_path_diagnostics_pending = true
	navigation_agent.target_position = target
	print("Robot navigation target: %s" % _format_vector3(target))
	print("Robot horizontal destination: %s" % _format_vector3(_destination))
	movement_changed.emit("Moving", velocity.length(), _destination)


func _physics_process(delta: float) -> void:
	if not _has_target:
		_stop_robot(delta)
		return

	var next_position := navigation_agent.get_next_path_position()
	if _path_diagnostics_pending:
		_path_diagnostics_pending = false
		print("Navigation final position: %s" % _format_vector3(navigation_agent.get_final_position()))
		print("Target reachable: %s" % _format_bool(navigation_agent.is_target_reachable()))
	if navigation_agent.is_navigation_finished():
		_print_finished_diagnostics()
		_has_target = false
		_stop_robot(delta)
		return

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
	velocity.x = move_toward(velocity.x, 0.0, acceleration * delta)
	velocity.z = move_toward(velocity.z, 0.0, acceleration * delta)
	velocity.y = 0.0
	if velocity.length_squared() > 0.0001:
		move_and_slide()
	movement_changed.emit("Idle", Vector2(velocity.x, velocity.z).length(), _destination)


func _print_finished_diagnostics() -> void:
	var horizontal_distance := Vector2(
		_destination.x - global_position.x,
		_destination.z - global_position.z
	).length()
	print("Navigation finished")
	print("Robot position: %s" % _format_vector3(global_position))
	print("Horizontal distance remaining: %.3f" % horizontal_distance)
	print("Target reached: %s" % _format_bool(navigation_agent.is_target_reached()))
	print("Target reachable: %s" % _format_bool(navigation_agent.is_target_reachable()))


func _format_vector3(value: Vector3) -> String:
	return "(%.3f, %.3f, %.3f)" % [value.x, value.y, value.z]


func _format_bool(value: bool) -> String:
	return "true" if value else "false"
