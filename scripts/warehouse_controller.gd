extends Node3D

@onready var navigation_region: NavigationRegion3D = $NavigationRegion3D
@onready var floor_body: StaticBody3D = $Architecture/Floor
@onready var robot: RobotController = $Robot01
@onready var camera: Camera3D = $OverviewCamera
@onready var destination_marker: MeshInstance3D = $DestinationMarker
@onready var status_label: Label = $MovementUI/Panel/Margin/Readout

var _navigation_ready := false


func _ready() -> void:
	robot.movement_changed.connect(_on_robot_movement_changed)
	destination_marker.visible = false
	status_label.text = "Robot01\nStatus: Preparing navigation...\nSpeed: 0.00 m/s\nDestination: —"
	# This synchronous bake runs once. STATIC_COLLIDERS includes the floor, walls,
	# shelves, and stations while excluding the movable CharacterBody3D robot.
	navigation_region.bake_navigation_mesh(false)
	await get_tree().physics_frame
	_navigation_ready = true
	_on_robot_movement_changed("Idle", 0.0, Vector3.ZERO)


func _unhandled_input(event: InputEvent) -> void:
	if not _navigation_ready or not event is InputEventMouseButton:
		return
	var mouse_event := event as InputEventMouseButton
	if mouse_event.button_index != MOUSE_BUTTON_LEFT or not mouse_event.pressed:
		return
	var ray_origin := camera.project_ray_origin(mouse_event.position)
	var ray_end := ray_origin + camera.project_ray_normal(mouse_event.position) * 100.0
	var query := PhysicsRayQueryParameters3D.create(ray_origin, ray_end)
	query.collide_with_areas = false
	var hit := get_world_3d().direct_space_state.intersect_ray(query)
	if hit.is_empty() or hit["collider"] != floor_body:
		return
	var clicked_position: Vector3 = hit["position"]
	var navigation_map := navigation_region.get_navigation_map()
	var valid_position := NavigationServer3D.map_get_closest_point(navigation_map, clicked_position)
	# A point far from the closest polygon lies under an obstacle or off the mesh.
	if valid_position.distance_to(clicked_position) > 0.4:
		return
	valid_position.y = 0.0
	destination_marker.global_position = valid_position + Vector3.UP * 0.04
	destination_marker.visible = true
	robot.set_navigation_target(valid_position)
	get_viewport().set_input_as_handled()


func _on_robot_movement_changed(status: String, speed: float, destination: Vector3) -> void:
	var destination_text := "—"
	if destination_marker.visible:
		destination_text = "(%.1f, %.1f)" % [destination.x, destination.z]
	status_label.text = "Robot01\nStatus: %s\nSpeed: %.2f m/s\nDestination: %s" % [
		status, speed, destination_text
	]
