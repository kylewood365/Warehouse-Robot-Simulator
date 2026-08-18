extends Node3D

@onready var navigation_region: NavigationRegion3D = $NavigationRegion3D
@onready var robot: RobotController = $Robot01
@onready var camera: Camera3D = $OverviewCamera
@onready var destination_marker: MeshInstance3D = $DestinationMarker
@onready var movement_panel: PanelContainer = $MovementUI/Panel
@onready var status_label: Label = $MovementUI/Panel/Margin/Readout

var _navigation_ready := false


func _ready() -> void:
	robot.movement_changed.connect(_on_robot_movement_changed)
	destination_marker.visible = false
	status_label.text = "Robot01\nStatus: Preparing navigation...\nSpeed: 0.00 m/s\nDestination: —"
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


func _navigation_failed(stage: String, detail: String) -> void:
	push_error(
		"Navigation failed during %s: %s; click-to-move is disabled"
		% [stage, detail]
	)
	status_label.text = "Robot01\nStatus: Navigation unavailable\nSpeed: 0.00 m/s\nDestination: —"


func _input(event: InputEvent) -> void:
	if not _navigation_ready or not event is InputEventMouseButton:
		return
	var mouse_event := event as InputEventMouseButton
	if mouse_event.button_index != MOUSE_BUTTON_LEFT or not mouse_event.pressed:
		return
	print("Click received: (%.1f, %.1f)" % [mouse_event.position.x, mouse_event.position.y])
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
	if movement_panel.get_global_rect().has_point(mouse_event.position):
		print("Destination rejected: click is over the movement UI")
		return
	if not collider.is_in_group("warehouse_floor"):
		print("Destination rejected: collider is not warehouse floor")
		return
	var navigation_map := navigation_region.get_navigation_map()
	var valid_position := NavigationServer3D.map_get_closest_point(navigation_map, clicked_position)
	var snap_distance := valid_position.distance_to(clicked_position)
	print("Navigation closest point: %s" % _format_vector3(valid_position))
	print("Navigation snap distance: %.3f" % snap_distance)
	# A point far from the closest polygon lies under an obstacle or off the mesh.
	if snap_distance > 0.4:
		print("Destination rejected: navigation snap distance exceeds 0.4")
		return
	valid_position.y = 0.0
	print("Destination accepted: %s" % _format_vector3(valid_position))
	destination_marker.global_position = valid_position + Vector3.UP * 0.04
	destination_marker.visible = true
	robot.set_navigation_target(valid_position)
	get_viewport().set_input_as_handled()


func _format_vector3(value: Vector3) -> String:
	return "(%.3f, %.3f, %.3f)" % [value.x, value.y, value.z]


func _on_robot_movement_changed(status: String, speed: float, destination: Vector3) -> void:
	var destination_text := "—"
	if destination_marker.visible:
		destination_text = "(%.1f, %.1f)" % [destination.x, destination.z]
	status_label.text = "Robot01\nStatus: %s\nSpeed: %.2f m/s\nDestination: %s" % [
		status, speed, destination_text
	]
