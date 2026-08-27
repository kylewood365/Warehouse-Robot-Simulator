class_name RobotController
extends CharacterBody3D

signal movement_changed(status: String, speed: float, destination: Vector3)
signal destination_reached(destination: Vector3)
signal navigation_target_failed(destination: Vector3, horizontal_remaining: float)

@export var move_speed := 3.5
@export var acceleration := 8.0
@export var turn_speed := 5.0

const ROBOT_01_AVOIDANCE_PRIORITY := 1.0
const ROBOT_02_AVOIDANCE_PRIORITY := 0.5

@onready var navigation_agent: NavigationAgent3D = $NavigationAgent3D

var _destination := Vector3.ZERO
var _has_target := false
var _path_diagnostics_pending := false


func _ready() -> void:
	navigation_agent.path_desired_distance = 0.25
	navigation_agent.target_desired_distance = 0.3
	navigation_agent.max_speed = move_speed
	# Robot02 makes the larger correction in an otherwise symmetrical encounter.
	navigation_agent.avoidance_priority = (
		ROBOT_01_AVOIDANCE_PRIORITY if name == &"Robot01" else ROBOT_02_AVOIDANCE_PRIORITY
	)
	navigation_agent.velocity_computed.connect(_on_safe_velocity_computed)
	movement_changed.emit("Idle", 0.0, Vector3.ZERO)


func set_navigation_target(target: Vector3) -> void:
	print("Robot set_navigation_target called: %s" % _format_vector3(target))
	var navigation_map := navigation_agent.get_navigation_map()
	var navigation_origin := NavigationServer3D.map_get_closest_point(
		navigation_map,
		global_position
	)
	var height_offset := navigation_origin.y - global_position.y
	navigation_agent.path_height_offset = height_offset
	print("Navigation origin: %s" % _format_vector3(navigation_origin))
	print("Navigation path height offset: %.3f" % height_offset)
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
		var initial_horizontal_waypoint_distance := Vector2(
			next_position.x - global_position.x,
			next_position.z - global_position.z
		).length()
		print("Next path position: %s" % _format_vector3(next_position))
		print("Robot position at path start: %s" % _format_vector3(global_position))
		print("Initial horizontal waypoint distance: %.3f" % initial_horizontal_waypoint_distance)
		print("Navigation final position: %s" % _format_vector3(navigation_agent.get_final_position()))
		print("Target reachable: %s" % _format_bool(navigation_agent.is_target_reachable()))
		if initial_horizontal_waypoint_distance <= 0.0001:
			_print_zero_horizontal_waypoint_diagnostics()

	var horizontal_remaining := _get_horizontal_remaining()
	if horizontal_remaining <= navigation_agent.target_desired_distance:
		_print_arrival_diagnostics(horizontal_remaining)
		_has_target = false
		_stop_robot(delta)
		destination_reached.emit(_destination)
		return

	if navigation_agent.is_navigation_finished():
		_print_finished_early_diagnostics(horizontal_remaining)
		_has_target = false
		_stop_robot(delta)
		navigation_target_failed.emit(_destination, horizontal_remaining)
		return

	var direction := next_position - global_position
	direction.y = 0.0
	if direction.length_squared() > 0.0001:
		direction = direction.normalized()
		var desired_velocity := direction * move_speed
		_submit_avoidance_velocity(desired_velocity, delta)
		var target_angle := atan2(direction.x, direction.z)
		rotation.y = lerp_angle(rotation.y, target_angle, turn_speed * delta)
	else:
		_submit_avoidance_velocity(Vector3.ZERO, delta)


func _stop_robot(delta: float) -> void:
	_submit_avoidance_velocity(Vector3.ZERO, delta)


func _submit_avoidance_velocity(desired_velocity: Vector3, delta: float) -> void:
	var intended_velocity := Vector3(
		move_toward(velocity.x, desired_velocity.x, acceleration * delta),
		0.0,
		move_toward(velocity.z, desired_velocity.z, acceleration * delta)
	)
	# NavigationServer emits velocity_computed once for this request. Movement is
	# performed only in that callback so the unadjusted and safe velocities can
	# never both move the body in the same physics frame.
	navigation_agent.velocity = intended_velocity


func _on_safe_velocity_computed(safe_velocity: Vector3) -> void:
	# A targetless agent remains registered with avoidance as a stationary
	# neighbor, but avoidance must never displace a robot performing an action at
	# its destination (pickup, packing, or charging).
	if not _has_target:
		velocity = Vector3.ZERO
		movement_changed.emit("Idle", 0.0, _destination)
		return

	velocity = Vector3(safe_velocity.x, 0.0, safe_velocity.z)
	if velocity.length_squared() > 0.0001:
		move_and_slide()
	movement_changed.emit("Moving", Vector2(velocity.x, velocity.z).length(), _destination)


func _get_horizontal_remaining() -> float:
	return Vector2(
		_destination.x - global_position.x,
		_destination.z - global_position.z
	).length()


func _print_arrival_diagnostics(horizontal_remaining: float) -> void:
	print("Robot destination reached")
	print("Robot position: %s" % _format_vector3(global_position))
	print("Horizontal distance remaining: %.3f" % horizontal_remaining)


func _print_finished_early_diagnostics(horizontal_remaining: float) -> void:
	print("Navigation finished before horizontal destination")
	print("Robot position: %s" % _format_vector3(global_position))
	print("Navigation final position: %s" % _format_vector3(navigation_agent.get_final_position()))
	print("Horizontal distance remaining: %.3f" % horizontal_remaining)
	print("Target reachable: %s" % _format_bool(navigation_agent.is_target_reachable()))


func _print_zero_horizontal_waypoint_diagnostics() -> void:
	var current_path := navigation_agent.get_current_navigation_path()
	print("Initial waypoint has zero horizontal distance")
	print("Navigation path index: %d" % navigation_agent.get_current_navigation_path_index())
	print("Navigation path point count: %d" % current_path.size())
	for point_index in current_path.size():
		print("Navigation path point %d: %s" % [point_index, _format_vector3(current_path[point_index])])


func _format_vector3(value: Vector3) -> String:
	return "(%.3f, %.3f, %.3f)" % [value.x, value.y, value.z]


func _format_bool(value: bool) -> String:
	return "true" if value else "false"
