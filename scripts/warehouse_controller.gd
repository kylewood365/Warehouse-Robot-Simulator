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
const MAX_PENDING_JOBS := 5
const INITIAL_STOCK_PER_SHELF := 3

@onready var navigation_region: NavigationRegion3D = $NavigationRegion3D
@onready var robot: RobotController = $Robot01
@onready var camera: Camera3D = $OverviewCamera
@onready var destination_marker: MeshInstance3D = $DestinationMarker
@onready var shelf_01_pickup: Marker3D = $JobTargets/Shelf01Pickup
@onready var shelf_02_pickup: Marker3D = $JobTargets/Shelf02Pickup
@onready var shelf_03_pickup: Marker3D = $JobTargets/Shelf03Pickup
@onready var shelf_04_pickup: Marker3D = $JobTargets/Shelf04Pickup
@onready var packing_dropoff: Marker3D = $JobTargets/PackingDropoff
@onready var shelf_01_source_package: MeshInstance3D = $Shelving/ShelfRow01/PackageD
@onready var shelf_02_source_package: MeshInstance3D = $Shelving/ShelfRow02/PackageD
@onready var shelf_03_source_package: MeshInstance3D = $Shelving/ShelfRow03/PackageD
@onready var shelf_04_source_package: MeshInstance3D = $Shelving/ShelfRow04/PackageD
@onready var shelf_01_stock_label: Label3D = $StockIndicators/Shelf01Stock
@onready var shelf_02_stock_label: Label3D = $StockIndicators/Shelf02Stock
@onready var shelf_03_stock_label: Label3D = $StockIndicators/Shelf03Stock
@onready var shelf_04_stock_label: Label3D = $StockIndicators/Shelf04Stock
@onready var carried_package: MeshInstance3D = $Robot01/CargoMount/CarriedPackage
@onready var delivered_package: MeshInstance3D = $JobVisuals/DeliveredPackage
@onready var movement_panel: PanelContainer = $MovementUI/Panel
@onready var status_label: Label = $MovementUI/Panel/Margin/Readout
@onready var job_panel: PanelContainer = $JobUI/Panel
@onready var job_status_label: Label = $JobUI/Panel/Margin/Readout
@onready var inventory_panel: PanelContainer = $InventoryUI/Panel
@onready var inventory_status_label: Label = $InventoryUI/Panel/Margin/Readout

var _navigation_ready := false
var _job_state := JobState.IDLE
var _next_job_id := 1
var _current_job_id := 0
var _current_pickup_marker: Marker3D
var _current_pickup_name := ""
var _current_source_package: MeshInstance3D
var _job_queue: Array[Dictionary] = []
var _queued_start_scheduled := false
var _delivery_flash_id := 0
var _available_stock: Dictionary = {}
var _current_stock_reserved := false


func _ready() -> void:
	_available_stock = {
		shelf_01_pickup: INITIAL_STOCK_PER_SHELF,
		shelf_02_pickup: INITIAL_STOCK_PER_SHELF,
		shelf_03_pickup: INITIAL_STOCK_PER_SHELF,
		shelf_04_pickup: INITIAL_STOCK_PER_SHELF,
	}
	_update_visible_stock()
	_update_inventory_ui()
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
	_update_job_ui("Ready")


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
		if key_event.pressed and not key_event.echo:
			var selected_pickup: Marker3D
			var selected_name := ""
			var is_restock := false
			match key_event.keycode:
				KEY_1:
					selected_pickup = shelf_01_pickup
					selected_name = "Shelf Row 01"
				KEY_2:
					selected_pickup = shelf_02_pickup
					selected_name = "Shelf Row 02"
				KEY_3:
					selected_pickup = shelf_03_pickup
					selected_name = "Shelf Row 03"
				KEY_4:
					selected_pickup = shelf_04_pickup
					selected_name = "Shelf Row 04"
				KEY_5:
					selected_pickup = shelf_01_pickup
					selected_name = "Shelf Row 01"
					is_restock = true
				KEY_6:
					selected_pickup = shelf_02_pickup
					selected_name = "Shelf Row 02"
					is_restock = true
				KEY_7:
					selected_pickup = shelf_03_pickup
					selected_name = "Shelf Row 03"
					is_restock = true
				KEY_8:
					selected_pickup = shelf_04_pickup
					selected_name = "Shelf Row 04"
					is_restock = true
			if selected_pickup != null:
				if is_restock:
					_request_restock(selected_pickup, selected_name)
				else:
					_request_job(selected_pickup, selected_name)
				get_viewport().set_input_as_handled()
		return

	if not _navigation_ready or not event is InputEventMouseButton:
		return
	var mouse_event := event as InputEventMouseButton
	if mouse_event.button_index != MOUSE_BUTTON_LEFT or not mouse_event.pressed:
		return
	print("Click received: (%.1f, %.1f)" % [mouse_event.position.x, mouse_event.position.y])
	if movement_panel.get_global_rect().has_point(mouse_event.position) \
			or job_panel.get_global_rect().has_point(mouse_event.position) \
			or inventory_panel.get_global_rect().has_point(mouse_event.position):
		print("Destination rejected: click is over the UI")
		get_viewport().set_input_as_handled()
		return
	if _has_autonomous_workload():
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


func _request_job(pickup_marker: Marker3D, pickup_name: String) -> void:
	if not _navigation_ready:
		print("Job start unavailable: navigation is not ready")
		return
	if (_is_job_active() or not _job_queue.is_empty()) \
			and _job_queue.size() >= MAX_PENDING_JOBS:
		print("Job queue full: request rejected")
		_update_job_ui(_job_status_text())
		return
	if not _has_available_stock(pickup_marker):
		print("Job rejected: %s out of stock" % pickup_name)
		return
	if not _reserve_stock(pickup_marker, pickup_name):
		return

	var job := {
		"id": _next_job_id,
		"pickup_marker": pickup_marker,
		"pickup_name": pickup_name,
	}
	_next_job_id += 1
	if not _is_job_active() and _job_queue.is_empty():
		_begin_job(job)
		return

	_job_queue.append(job)
	print("Job #%03d queued: %s" % [job.id, job.pickup_name])
	print("Pending jobs: %d/%d" % [_job_queue.size(), MAX_PENDING_JOBS])
	_update_job_ui(_job_status_text())
	if not _is_job_active():
		_schedule_next_queued_job()


func _begin_job(job: Dictionary) -> void:
	_current_job_id = job.id
	_current_pickup_marker = job.pickup_marker
	_current_pickup_name = job.pickup_name
	_current_stock_reserved = true
	carried_package.visible = false
	_current_source_package = _get_source_package_for_pickup(_current_pickup_marker)
	if _current_source_package != null:
		_current_source_package.visible = true
	_job_state = JobState.TRAVELLING_TO_PICKUP
	print("%s started" % _current_job_label())
	print("Pickup: %s" % _current_pickup_name)
	_update_job_ui("Travelling to %s" % _current_pickup_name)
	_command_job_target(_current_pickup_marker, _current_pickup_name)


func _schedule_next_queued_job() -> void:
	if _job_queue.is_empty() or _queued_start_scheduled:
		return
	_queued_start_scheduled = true
	call_deferred("_start_next_queued_job")


func _start_next_queued_job() -> void:
	_queued_start_scheduled = false
	if not _navigation_ready or _is_job_active() or _job_queue.is_empty():
		return
	var job: Dictionary = _job_queue.pop_front()
	print("Starting queued Job #%03d: %s" % [job.id, job.pickup_name])
	_begin_job(job)


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
			print("Robot arrived for %s pickup: %s" % [
				_current_job_label(), _current_pickup_name
			])
			_begin_pickup()
		JobState.TRAVELLING_TO_PACKING:
			print("Robot arrived at packing station for %s" % _current_job_label())
			_complete_job()


func _on_robot_navigation_target_failed(
		destination: Vector3, horizontal_remaining: float
) -> void:
	var failed_leg := ""
	match _job_state:
		JobState.TRAVELLING_TO_PICKUP:
			failed_leg = "%s pickup" % _current_pickup_name
		JobState.TRAVELLING_TO_PACKING:
			failed_leg = "Packing Station delivery"
		_:
			return
	print("%s leg failed: %s" % [_current_job_label(), failed_leg])
	print("Job failure destination: %s" % _format_vector3(destination))
	print("Job failure horizontal remaining: %.3f" % horizontal_remaining)
	_fail_job("%s navigation failed" % failed_leg)


func _begin_pickup() -> void:
	_job_state = JobState.PICKING
	print("%s picking package" % _current_job_label())
	_update_job_ui("Picking package...")
	await get_tree().create_timer(1.0).timeout
	if _job_state != JobState.PICKING:
		return
	if _current_source_package != null:
		_current_source_package.visible = false
	carried_package.visible = true
	print("%s package loaded" % _current_job_label())
	_begin_delivery()


func _begin_delivery() -> void:
	_job_state = JobState.TRAVELLING_TO_PACKING
	_update_job_ui("Delivering to Packing Station")
	_command_job_target(packing_dropoff, "Packing Station")


func _complete_job() -> void:
	carried_package.visible = false
	if _current_source_package != null:
		_current_source_package.visible = true
	print("%s package delivered" % _current_job_label())
	_current_stock_reserved = false
	print("Inventory consumed: %s — %d/%d available" % [
		_current_pickup_name,
		_get_available_stock(_current_pickup_marker),
		INITIAL_STOCK_PER_SHELF,
	])
	_show_delivered_package_briefly()
	_job_state = JobState.COMPLETE
	_update_job_ui("Complete")
	print("%s complete" % _current_job_label())
	_schedule_next_queued_job()


func _fail_job(reason: String) -> void:
	carried_package.visible = false
	if _current_source_package != null:
		_current_source_package.visible = true
	_delivery_flash_id += 1
	delivered_package.visible = false
	if _current_stock_reserved:
		_release_stock(_current_pickup_marker, _current_pickup_name)
		_current_stock_reserved = false
	_job_state = JobState.FAILED
	_update_job_ui("Failed")
	print("%s failed: %s" % [_current_job_label(), reason])
	_schedule_next_queued_job()


func _get_available_stock(pickup_marker: Marker3D) -> int:
	return int(_available_stock.get(pickup_marker, 0))


func _has_available_stock(pickup_marker: Marker3D) -> bool:
	return _get_available_stock(pickup_marker) > 0


func _request_restock(pickup_marker: Marker3D, pickup_name: String) -> void:
	if not _available_stock.has(pickup_marker):
		print("Restock rejected: unknown shelf")
		return
	if _has_reserved_jobs_for_shelf(pickup_marker):
		print("Restock unavailable: %s has reserved jobs" % pickup_name)
		return
	var available := _get_available_stock(pickup_marker)
	if available >= INITIAL_STOCK_PER_SHELF:
		print("Restock rejected: %s already full" % pickup_name)
		return
	available += 1
	_available_stock[pickup_marker] = available
	_refresh_stock_displays()
	print("Restocked: %s — %d" % [pickup_name, available])


func _has_reserved_jobs_for_shelf(pickup_marker: Marker3D) -> bool:
	if _current_stock_reserved and _current_pickup_marker == pickup_marker:
		return true
	for job in _job_queue:
		if job.pickup_marker == pickup_marker:
			return true
	return false


func _reserve_stock(pickup_marker: Marker3D, pickup_name: String) -> bool:
	var available := _get_available_stock(pickup_marker)
	if available <= 0:
		return false
	_available_stock[pickup_marker] = available - 1
	print("Inventory reserved: %s — %d/%d available" % [
		pickup_name, available - 1, INITIAL_STOCK_PER_SHELF
	])
	_refresh_stock_displays()
	return true


func _release_stock(pickup_marker: Marker3D, pickup_name: String) -> void:
	var available := mini(
		_get_available_stock(pickup_marker) + 1, INITIAL_STOCK_PER_SHELF
	)
	_available_stock[pickup_marker] = available
	print("Inventory reservation released: %s — %d/%d available" % [
		pickup_name, available, INITIAL_STOCK_PER_SHELF
	])
	_refresh_stock_displays()


func _refresh_stock_displays() -> void:
	_update_visible_stock()
	_update_inventory_ui()


func _update_visible_stock() -> void:
	var stock_labels: Dictionary = {
		shelf_01_pickup: shelf_01_stock_label,
		shelf_02_pickup: shelf_02_stock_label,
		shelf_03_pickup: shelf_03_stock_label,
		shelf_04_pickup: shelf_04_stock_label,
	}
	for pickup_marker in stock_labels:
		var stock_label: Label3D = stock_labels[pickup_marker]
		stock_label.text = "AVAILABLE: %d/%d" % [
			_get_available_stock(pickup_marker), INITIAL_STOCK_PER_SHELF
		]


func _update_inventory_ui() -> void:
	inventory_status_label.text = "Available Stock / Restock\nShelf 01: %d   [5] +1\nShelf 02: %d   [6] +1\nShelf 03: %d   [7] +1\nShelf 04: %d   [8] +1" % [
		_get_available_stock(shelf_01_pickup),
		_get_available_stock(shelf_02_pickup),
		_get_available_stock(shelf_03_pickup),
		_get_available_stock(shelf_04_pickup),
	]


func _get_source_package_for_pickup(marker: Marker3D) -> MeshInstance3D:
	if marker == shelf_01_pickup:
		return shelf_01_source_package
	if marker == shelf_02_pickup:
		return shelf_02_source_package
	if marker == shelf_03_pickup:
		return shelf_03_source_package
	if marker == shelf_04_pickup:
		return shelf_04_source_package
	return null


func _show_delivered_package_briefly() -> void:
	_delivery_flash_id += 1
	var flash_id := _delivery_flash_id
	delivered_package.visible = true
	await get_tree().create_timer(0.75).timeout
	if flash_id == _delivery_flash_id:
		delivered_package.visible = false


func _is_job_active() -> bool:
	return _job_state in [
		JobState.TRAVELLING_TO_PICKUP,
		JobState.PICKING,
		JobState.TRAVELLING_TO_PACKING,
	]


func _has_autonomous_workload() -> bool:
	return _is_job_active() \
			or not _job_queue.is_empty() \
			or _queued_start_scheduled


func _update_job_ui(status: String) -> void:
	var queue_text := _queue_ui_text()
	if _current_job_id == 0:
		job_status_label.text = "Warehouse Jobs\nPress 1: Shelf Row 01\nPress 2: Shelf Row 02\nPress 3: Shelf Row 03\nPress 4: Shelf Row 04\nStatus: %s\n%s" % [status, queue_text]
		return
	job_status_label.text = "%s\nPick: %s\nDrop: Packing Station\nStatus: %s\n%s" % [
		_current_job_label(), _current_pickup_name, status, queue_text
	]


func _queue_ui_text() -> String:
	var lines: Array[String] = [
		"Pending: %d/%d" % [_job_queue.size(), MAX_PENDING_JOBS]
	]
	if _job_queue.size() >= 1:
		lines.append("Next: #%03d %s" % [_job_queue[0].id, _job_queue[0].pickup_name])
	if _job_queue.size() >= 2:
		lines.append("Then: #%03d %s" % [_job_queue[1].id, _job_queue[1].pickup_name])
	if _job_queue.size() > 2:
		lines.append("+%d more" % (_job_queue.size() - 2))
	return "\n".join(lines)


func _job_status_text() -> String:
	match _job_state:
		JobState.TRAVELLING_TO_PICKUP:
			return "Travelling to %s" % _current_pickup_name
		JobState.PICKING:
			return "Picking package..."
		JobState.TRAVELLING_TO_PACKING:
			return "Delivering to Packing Station"
		JobState.COMPLETE:
			return "Complete"
		JobState.FAILED:
			return "Failed"
		_:
			return "Ready" if _navigation_ready else "Preparing navigation..."


func _current_job_label() -> String:
	return "Job #%03d" % _current_job_id


func _format_vector3(value: Vector3) -> String:
	return "(%.3f, %.3f, %.3f)" % [value.x, value.y, value.z]


func _on_robot_movement_changed(status: String, speed: float, destination: Vector3) -> void:
	var destination_text := "—"
	if destination_marker.visible:
		destination_text = "(%.1f, %.1f)" % [destination.x, destination.z]
	status_label.text = "Robot01\nStatus: %s\nSpeed: %.2f m/s\nDestination: %s" % [
		status, speed, destination_text
	]
