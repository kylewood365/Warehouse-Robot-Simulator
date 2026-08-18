extends Node3D

enum JobState {
	IDLE,
	TRAVELLING_TO_PICKUP,
	PICKING,
	TRAVELLING_TO_PACKING,
	COMPLETE,
	FAILED,
}

const JOB_TARGET_MAX_HORIZONTAL_SNAP := 0.75

@onready var navigation_region: NavigationRegion3D = $NavigationRegion3D
@onready var robot: RobotController = $Robot01
@onready var camera: Camera3D = $OverviewCamera
@onready var destination_marker: MeshInstance3D = $DestinationMarker
@onready var shelf_pickup: Marker3D = $JobTargets/Shelf03Pickup
@onready var packing_dropoff: Marker3D = $JobTargets/PackingDropoff
@onready var movement_panel: PanelContainer = $MovementUI/Panel
@onready var status_label: Label = $MovementUI/Panel/Margin/Readout
@onready var job_panel: PanelContainer = $JobUI/Panel
@onready var job_status_label: Label = $JobUI/Panel/Margin/Readout

var _navigation_ready := false
var _job_state := JobState.IDLE


func _ready() -> void:
	robot.movement_changed.connect(_on_robot_movement_changed)
	robot.destination_reached.connect(_on_robot_destination_reached)
	robot.navigation_target_failed.connect(_on_robot_navigation_target_failed)
	destination_marker.visible = false
	status_label.text = "Robot01\nStatus: Preparing navigation...\nSpeed: 0.00 m/s\nDestination: —"
	_update_job_ui("Preparing navigation...")
	# Parsing touches the SceneTree, so wait until every child in the warehouse scene
	# has completed its ready step before collecting the grouped static colliders.
	call_deferred("_build_navigation")


func _build_navigation() -> void:
	var navigation_mesh := navigation_region.navigation_mesh
	if navigation_mesh == null:
		_navigation_failed("navigation mesh baking", "NavigationRegion3D has no NavigationMesh")
		return

	var source_nodes := get_tree().get_nodes_in_group("navigation_source")
	print("Navigation source group nodes: %d" % source_nodes.size())
	if source_nodes.is_empty():
		_navigation_failed("group discovery", "the navigation_source group is empty")
		return

	var source_geometry := NavigationMeshSourceGeometryData3D.new()
	# `self` is the Warehouse scene root. Group filtering on the NavigationMesh
	# selects Architecture, Shelving, and Stations and includes their children.
	NavigationServer3D.parse_source_geometry_data(navigation_mesh, source_geometry, self)
	var source_vertices := source_geometry.get_vertices()
	var source_indices := source_geometry.get_indices()
	print(
		"Navigation source data: %d vertices, %d indices"
		% [source_vertices.size(), source_indices.size()]
	)
	if not source_geometry.has_data():
		for source_node in source_nodes:
			print("Navigation source node: %s" % source_node.get_path())
		_navigation_failed("source geometry parsing", "group nodes produced no collider data")
		return

	NavigationServer3D.bake_from_source_geometry_data(navigation_mesh, source_geometry)
	if navigation_mesh.get_vertices().is_empty() or navigation_mesh.get_polygon_count() == 0:
		_navigation_failed("navigation mesh baking", "parsed data produced no usable polygons")
		return
	print("Navigation bake completed")
	print(
		"Navigation mesh: %d vertices, %d polygons"
		% [navigation_mesh.get_vertices().size(), navigation_mesh.get_polygon_count()]
	)

	# Keep both the scene node and its NavigationServer region synchronized with
	# the resource that was populated by the explicit bake.
	navigation_region.navigation_mesh = navigation_mesh
	NavigationServer3D.region_set_navigation_mesh(navigation_region.get_rid(), navigation_mesh)
	await get_tree().physics_frame
	var navigation_map := navigation_region.get_navigation_map()
	var map_regions := NavigationServer3D.map_get_regions(navigation_map)
	if not map_regions.has(navigation_region.get_rid()):
		_navigation_failed("region registration", "baked region is not registered on its navigation map")
		return
	_navigation_ready = true
	print("Navigation ready")
	_on_robot_movement_changed("Idle", 0.0, Vector3.ZERO)
	_update_job_ui("Ready — press J")


func _navigation_failed(stage: String, detail: String) -> void:
	push_error(
		"Navigation failed during %s: %s; click-to-move is disabled"
		% [stage, detail]
	)
	status_label.text = "Robot01\nStatus: Navigation unavailable\nSpeed: 0.00 m/s\nDestination: —"
	_update_job_ui("Failed — navigation unavailable")


func _input(event: InputEvent) -> void:
	if event is InputEventKey:
		var key_event := event as InputEventKey
		if key_event.pressed and not key_event.echo and key_event.keycode == KEY_J:
			if _navigation_ready:
				_start_test_job()
			else:
				print("Job #001 unavailable: navigation is not ready")
			get_viewport().set_input_as_handled()
		return

	if not _navigation_ready or not event is InputEventMouseButton:
		return
	var mouse_event := event as InputEventMouseButton
	if mouse_event.button_index != MOUSE_BUTTON_LEFT or not mouse_event.pressed:
		return
	print("Click received: (%.1f, %.1f)" % [mouse_event.position.x, mouse_event.position.y])
	if movement_panel.get_global_rect().has_point(mouse_event.position) \
			or job_panel.get_global_rect().has_point(mouse_event.position):
		print("Destination rejected: click is over the UI")
		get_viewport().set_input_as_handled()
		return
	if _is_job_active():
		print("Manual destination rejected: autonomous job active")
		get_viewport().set_input_as_handled()
		return
	var ray_origin := camera.project_ray_origin(mouse_event.position)
	var ray_end := ray_origin + camera.project_ray_normal(mouse_event.position) * 100.0
	var query := PhysicsRayQueryParameters3D.create(ray_origin, ray_end)
	query.collide_with_areas = false
	var hit := get_world_3d().direct_space_state.intersect_ray(query)
	if hit.is_empty():
		print("Raycast missed")
		return
	var collider := hit["collider"] as CollisionObject3D
	print("Raycast hit: %s" % collider.get_path())
	var clicked_position: Vector3 = hit["position"]
	print("Clicked world position: %s" % _format_vector3(clicked_position))
	if not collider.is_in_group("warehouse_floor"):
		print("Destination rejected: collider is not warehouse floor")
		return
	var navigation_map := navigation_region.get_navigation_map()
	var valid_position := NavigationServer3D.map_get_closest_point(navigation_map, clicked_position)
	var snap_distance := Vector2(
		valid_position.x - clicked_position.x,
		valid_position.z - clicked_position.z
	).length()
	print("Navigation closest point: %s" % _format_vector3(valid_position))
	print("Navigation horizontal snap distance: %.3f" % snap_distance)
	# A point far from the closest polygon lies under an obstacle or off the mesh.
	if snap_distance > 0.4:
		print("Destination rejected: navigation snap distance exceeds 0.4")
		return
	print("Destination accepted: %s" % _format_vector3(valid_position))
	# The agent needs the point on the navigation surface, but the marker belongs
	# on the physical floor that was clicked.
	destination_marker.global_position = Vector3(
		valid_position.x, clicked_position.y + 0.04, valid_position.z
	)
	destination_marker.visible = true
	robot.set_navigation_target(valid_position)
	get_viewport().set_input_as_handled()


func _start_test_job() -> void:
	if _is_job_active():
		print("Job #001 start ignored: autonomous job already active")
		return
	_job_state = JobState.TRAVELLING_TO_PICKUP
	print("Job #001 started")
	_update_job_ui("Travelling to Shelf Row 03")
	_command_job_target(shelf_pickup, "Shelf Row 03")


func _command_job_target(marker: Marker3D, target_name: String) -> void:
	print("Job leg: %s" % target_name)
	var target_result := _get_navigation_target_for_job(marker, target_name)
	if not target_result.valid:
		return
	var navigation_target: Vector3 = target_result.position
	destination_marker.global_position = Vector3(
		navigation_target.x, marker.global_position.y + 0.04, navigation_target.z
	)
	destination_marker.visible = true
	robot.set_navigation_target(navigation_target)


func _get_navigation_target_for_job(marker: Marker3D, target_name: String) -> Dictionary:
	var authored_position := marker.global_position
	var navigation_map := navigation_region.get_navigation_map()
	var navigation_position := NavigationServer3D.map_get_closest_point(
		navigation_map, authored_position
	)
	var horizontal_snap_distance := Vector2(
		navigation_position.x - authored_position.x,
		navigation_position.z - authored_position.z
	).length()
	print("Job target authored position: %s" % _format_vector3(authored_position))
	print("Job target navigation position: %s" % _format_vector3(navigation_position))
	print("Job target horizontal snap distance: %.3f" % horizontal_snap_distance)
	if horizontal_snap_distance > JOB_TARGET_MAX_HORIZONTAL_SNAP:
		_fail_job(
			"%s target is %.3f m from the NavigationMesh" % [
				target_name, horizontal_snap_distance
			]
		)
		return {"valid": false}
	return {"valid": true, "position": navigation_position}


func _on_robot_destination_reached(_destination: Vector3) -> void:
	match _job_state:
		JobState.TRAVELLING_TO_PICKUP:
			print("Robot arrived for Job #001 pickup")
			_begin_pickup()
		JobState.TRAVELLING_TO_PACKING:
			print("Robot arrived at packing station")
			_complete_job()


func _on_robot_navigation_target_failed(
		destination: Vector3, horizontal_remaining: float
) -> void:
	var failed_leg := ""
	match _job_state:
		JobState.TRAVELLING_TO_PICKUP:
			failed_leg = "Shelf Row 03 pickup"
		JobState.TRAVELLING_TO_PACKING:
			failed_leg = "Packing Station delivery"
		_:
			return
	print("Job #001 leg failed: %s" % failed_leg)
	print("Job failure destination: %s" % _format_vector3(destination))
	print("Job failure horizontal remaining: %.3f" % horizontal_remaining)
	_fail_job("%s navigation failed" % failed_leg)


func _begin_pickup() -> void:
	_job_state = JobState.PICKING
	print("Job #001 picking package")
	_update_job_ui("Picking package...")
	await get_tree().create_timer(1.0).timeout
	if _job_state != JobState.PICKING:
		return
	_begin_delivery()


func _begin_delivery() -> void:
	_job_state = JobState.TRAVELLING_TO_PACKING
	_update_job_ui("Delivering to Packing Station")
	_command_job_target(packing_dropoff, "Packing Station")


func _complete_job() -> void:
	_job_state = JobState.COMPLETE
	_update_job_ui("Complete")
	print("Job #001 complete")


func _fail_job(reason: String) -> void:
	_job_state = JobState.FAILED
	_update_job_ui("Failed")
	print("Job #001 failed: %s" % reason)


func _is_job_active() -> bool:
	return _job_state in [
		JobState.TRAVELLING_TO_PICKUP,
		JobState.PICKING,
		JobState.TRAVELLING_TO_PACKING,
	]


func _update_job_ui(status: String) -> void:
	job_status_label.text = "Job #001\nPick: Shelf Row 03\nDrop: Packing Station\nStatus: %s" % status


func _format_vector3(value: Vector3) -> String:
	return "(%.3f, %.3f, %.3f)" % [value.x, value.y, value.z]


func _on_robot_movement_changed(status: String, speed: float, destination: Vector3) -> void:
	var destination_text := "—"
	if destination_marker.visible:
		destination_text = "(%.1f, %.1f)" % [destination.x, destination.z]
	status_label.text = "Robot01\nStatus: %s\nSpeed: %.2f m/s\nDestination: %s" % [
		status, speed, destination_text
	]
