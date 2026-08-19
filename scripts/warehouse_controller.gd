extends Node3D

enum JobState {
	IDLE,
	TRAVELLING_TO_PICKUP,
	PICKING,
	TRAVELLING_TO_PACKING,
	COMPLETE,
	FAILED,
}

enum JobPriority {
	NORMAL,
	HIGH,
}

enum ChargeState {
	NONE,
	TRAVELLING,
	CHARGING,
}

const JOB_TARGET_MAX_HORIZONTAL_SNAP := 0.75
const MAX_PENDING_JOBS := 5
const INITIAL_STOCK_PER_SHELF := 3
const MAX_RECENT_JOB_HISTORY := 5
const NORMAL_SLA_SECONDS := 20.0
const HIGH_SLA_SECONDS := 12.0
const BATTERY_MAX_PERCENT := 100.0
const BATTERY_LOW_PERCENT := 25.0
const BATTERY_DRAIN_PER_METER := 1.0
const CHARGE_DURATION_SECONDS := 4.0
const CHARGE_TARGET_MAX_HORIZONTAL_SNAP := 0.75

@onready var navigation_region: NavigationRegion3D = $NavigationRegion3D
@onready var robot: RobotController = $Robot01
@onready var camera: Camera3D = $OverviewCamera
@onready var destination_marker: MeshInstance3D = $DestinationMarker
@onready var shelf_01_pickup: Marker3D = $JobTargets/Shelf01Pickup
@onready var shelf_02_pickup: Marker3D = $JobTargets/Shelf02Pickup
@onready var shelf_03_pickup: Marker3D = $JobTargets/Shelf03Pickup
@onready var shelf_04_pickup: Marker3D = $JobTargets/Shelf04Pickup
@onready var packing_dropoff: Marker3D = $JobTargets/PackingDropoff
@onready var charging_target: Marker3D = $JobTargets/ChargingTarget
@onready var shelf_01_source_package: MeshInstance3D = $Shelving/ShelfRow01/PackageD
@onready var shelf_02_source_package: MeshInstance3D = $Shelving/ShelfRow02/PackageD
@onready var shelf_03_source_package: MeshInstance3D = $Shelving/ShelfRow03/PackageD
@onready var shelf_04_source_package: MeshInstance3D = $Shelving/ShelfRow04/PackageD
@onready var shelf_01_stock_a: MeshInstance3D = $Shelving/ShelfRow01/PackageA
@onready var shelf_01_stock_b: MeshInstance3D = $Shelving/ShelfRow01/PackageB
@onready var shelf_01_stock_c: MeshInstance3D = $Shelving/ShelfRow01/PackageC
@onready var shelf_02_stock_a: MeshInstance3D = $Shelving/ShelfRow02/PackageA
@onready var shelf_02_stock_b: MeshInstance3D = $Shelving/ShelfRow02/PackageB
@onready var shelf_02_stock_c: MeshInstance3D = $Shelving/ShelfRow02/PackageC
@onready var shelf_03_stock_a: MeshInstance3D = $Shelving/ShelfRow03/PackageA
@onready var shelf_03_stock_b: MeshInstance3D = $Shelving/ShelfRow03/PackageB
@onready var shelf_03_stock_c: MeshInstance3D = $Shelving/ShelfRow03/PackageC
@onready var shelf_04_stock_a: MeshInstance3D = $Shelving/ShelfRow04/PackageA
@onready var shelf_04_stock_b: MeshInstance3D = $Shelving/ShelfRow04/PackageB
@onready var shelf_04_stock_c: MeshInstance3D = $Shelving/ShelfRow04/PackageC
@onready var carried_package: MeshInstance3D = $Robot01/CargoMount/CarriedPackage
@onready var delivered_package: MeshInstance3D = $JobVisuals/DeliveredPackage
@onready var movement_panel: PanelContainer = $MovementUI/Panel
@onready var status_label: Label = $MovementUI/Panel/Margin/Readout
@onready var job_panel: PanelContainer = $JobUI/Panel
@onready var job_status_label: Label = $JobUI/Panel/Margin/Readout
@onready var inventory_panel: PanelContainer = $InventoryUI/Panel
@onready var inventory_status_label: Label = $InventoryUI/Panel/Margin/Readout
@onready var operations_panel: PanelContainer = $OperationsUI/Panel
@onready var operations_status_label: Label = $OperationsUI/Panel/Margin/Readout

var _navigation_ready := false
var _job_state := JobState.IDLE
var _next_job_id := 1
var _current_job_id := 0
var _current_job_priority := JobPriority.NORMAL
var _current_pickup_marker: Marker3D
var _current_pickup_name := ""
var _current_source_package: MeshInstance3D
var _job_queue: Array[Dictionary] = []
var _queued_start_scheduled := false
var _delivery_flash_id := 0
var _available_stock: Dictionary = {}
var _current_stock_reserved := false
var _jobs_accepted := 0
var _jobs_completed := 0
var _jobs_failed := 0
var _jobs_cancelled := 0
var _current_job_started_msec := 0
var _current_job_accepted_msec := 0
var _current_job_sla_seconds := 0.0
var _completed_execution_seconds := 0.0
var _sla_on_time := 0
var _sla_late := 0
var _recent_job_history: Array[Dictionary] = []
var _battery_percent: float = BATTERY_MAX_PERCENT
var _last_battery_position: Vector3 = Vector3.ZERO
var _charge_state: int = ChargeState.NONE
var _automatic_charge_in_progress: bool = false
var _robot_movement_status := "Idle"
var _robot_speed := 0.0
var _robot_destination := Vector3.ZERO


func _ready() -> void:
	_last_battery_position = robot.global_position
	_available_stock = {
		shelf_01_pickup: INITIAL_STOCK_PER_SHELF,
		shelf_02_pickup: INITIAL_STOCK_PER_SHELF,
		shelf_03_pickup: INITIAL_STOCK_PER_SHELF,
		shelf_04_pickup: INITIAL_STOCK_PER_SHELF,
	}
	_update_visible_stock()
	_update_inventory_ui()
	_update_operations_ui()
	robot.movement_changed.connect(_on_robot_movement_changed)
	robot.destination_reached.connect(_on_robot_destination_reached)
	robot.navigation_target_failed.connect(_on_robot_navigation_target_failed)
	destination_marker.visible = false
	_robot_movement_status = "Preparing navigation..."
	_update_movement_ui()
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
	_robot_movement_status = "Navigation unavailable"
	_robot_speed = 0.0
	_update_movement_ui()
	_update_job_ui("Failed — navigation unavailable")


func _input(event: InputEvent) -> void:
	if event is InputEventKey:
		var key_event := event as InputEventKey
		if key_event.pressed and not key_event.echo:
			var selected_pickup: Marker3D
			var selected_name := ""
			var is_restock := false
			var priority := JobPriority.NORMAL
			match key_event.keycode:
				KEY_C:
					_request_charge()
					get_viewport().set_input_as_handled()
					return
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
				KEY_Q:
					selected_pickup = shelf_01_pickup
					selected_name = "Shelf Row 01"
					priority = JobPriority.HIGH
				KEY_W:
					selected_pickup = shelf_02_pickup
					selected_name = "Shelf Row 02"
					priority = JobPriority.HIGH
				KEY_E:
					selected_pickup = shelf_03_pickup
					selected_name = "Shelf Row 03"
					priority = JobPriority.HIGH
				KEY_R:
					selected_pickup = shelf_04_pickup
					selected_name = "Shelf Row 04"
					priority = JobPriority.HIGH
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
				KEY_Z:
					_cancel_next_pending_job()
					get_viewport().set_input_as_handled()
					return
				KEY_X:
					_cancel_latest_pending_job()
					get_viewport().set_input_as_handled()
					return
			if selected_pickup != null:
				if is_restock:
					_request_restock(selected_pickup, selected_name)
				else:
					_request_job(selected_pickup, selected_name, priority)
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
			or inventory_panel.get_global_rect().has_point(mouse_event.position) \
			or operations_panel.get_global_rect().has_point(mouse_event.position):
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


func _request_job(
		pickup_marker: Marker3D,
		pickup_name: String,
		priority: int = JobPriority.NORMAL
) -> void:
	if _charge_state != ChargeState.NONE:
		print("Job start unavailable: Robot01 is charging")
		return
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
		"priority": priority,
		"accepted_msec": Time.get_ticks_msec(),
		"sla_seconds": _sla_seconds_for_priority(priority),
	}
	_next_job_id += 1
	_jobs_accepted += 1
	_update_operations_ui()
	if not _is_job_active() and _job_queue.is_empty() \
			and not _needs_charge_before_dispatch():
		_begin_job(job)
		return

	_enqueue_job_by_priority(job)
	print("Job #%03d queued: %s [%s]" % [
		job.id, job.pickup_name, _priority_name(job.priority)
	])
	print("Pending jobs: %d/%d" % [_job_queue.size(), MAX_PENDING_JOBS])
	_update_job_ui(_job_status_text())
	if not _is_job_active():
		_schedule_next_queued_job()


func _enqueue_job_by_priority(job: Dictionary) -> void:
	if job.priority == JobPriority.NORMAL:
		_job_queue.append(job)
		return
	var insertion_index := 0
	while insertion_index < _job_queue.size() \
			and _job_queue[insertion_index].priority == JobPriority.HIGH:
		insertion_index += 1
	_job_queue.insert(insertion_index, job)


func _cancel_next_pending_job() -> void:
	if _job_queue.is_empty():
		print("Cancel rejected: no pending jobs")
		return
	var job: Dictionary = _job_queue.pop_front()
	_cancel_pending_job(job)


func _cancel_latest_pending_job() -> void:
	if _job_queue.is_empty():
		print("Cancel rejected: no pending jobs")
		return
	var latest_index := 0
	for job_index in range(1, _job_queue.size()):
		if _job_queue[job_index].id > _job_queue[latest_index].id:
			latest_index = job_index
	var job: Dictionary = _job_queue[latest_index]
	_job_queue.remove_at(latest_index)
	_cancel_pending_job(job)


func _cancel_pending_job(job: Dictionary) -> void:
	var wait_seconds: float = (
		Time.get_ticks_msec() - int(job.accepted_msec)
	) / 1000.0
	_release_stock(job.pickup_marker, job.pickup_name)
	_jobs_cancelled += 1
	_record_job_result(job, "CANCELLED", 0.0, wait_seconds, "")
	print("Job #%03d [%s] %s CANCELLED | Wait %.1fs" % [
		job.id, _priority_name(job.priority), job.pickup_name, wait_seconds
	])
	_update_job_ui(_job_status_text())
	_update_operations_ui()


func _begin_job(job: Dictionary) -> void:
	_current_job_id = job.id
	_current_job_priority = job.priority
	_current_pickup_marker = job.pickup_marker
	_current_pickup_name = job.pickup_name
	_current_job_accepted_msec = job.accepted_msec
	_current_job_sla_seconds = job.sla_seconds
	_current_stock_reserved = true
	carried_package.visible = false
	_current_source_package = _get_source_package_for_pickup(_current_pickup_marker)
	if _current_source_package != null:
		_current_source_package.visible = true
	_job_state = JobState.TRAVELLING_TO_PICKUP
	_current_job_started_msec = Time.get_ticks_msec()
	print("%s started [%s]" % [
		_current_job_label(), _priority_name(_current_job_priority)
	])
	print("Pickup: %s" % _current_pickup_name)
	_update_job_ui("Travelling to %s" % _current_pickup_name)
	_update_operations_ui()
	_command_job_target(_current_pickup_marker, _current_pickup_name)


func _schedule_next_queued_job() -> void:
	if _job_queue.is_empty() or _queued_start_scheduled \
			or _charge_state != ChargeState.NONE:
		return
	_queued_start_scheduled = true
	call_deferred("_start_next_queued_job")


func _start_next_queued_job() -> void:
	_queued_start_scheduled = false
	if not _navigation_ready or _is_job_active() or _job_queue.is_empty() \
			or _charge_state != ChargeState.NONE:
		return
	if _needs_charge_before_dispatch():
		var pending_job: Dictionary = _job_queue.front()
		print("Battery low: %.1f%% — automatically charging before Job #%03d; job remains pending" % [
			_battery_percent, pending_job.id
		])
		_update_job_ui("Charging before next job")
		_begin_charge_trip(true)
		return
	var job: Dictionary = _job_queue.pop_front()
	print("Starting queued Job #%03d: %s [%s]" % [
		job.id, job.pickup_name, _priority_name(job.priority)
	])
	_begin_job(job)


func _needs_charge_before_dispatch() -> bool:
	return _battery_percent <= BATTERY_LOW_PERCENT


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
	if _charge_state == ChargeState.TRAVELLING:
		_begin_station_charging()
		return
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
	if _charge_state == ChargeState.TRAVELLING:
		var was_automatic_charge: bool = _automatic_charge_in_progress
		print("Automatic charge navigation failed; pending jobs remain paused" \
				if was_automatic_charge else "Charge navigation failed")
		print("Charge failure destination: %s" % _format_vector3(destination))
		print("Charge failure horizontal remaining: %.3f" % horizontal_remaining)
		_charge_state = ChargeState.NONE
		_automatic_charge_in_progress = false
		destination_marker.visible = false
		_update_movement_ui()
		return
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
	var elapsed_seconds := _current_job_elapsed_seconds()
	var lead_seconds := _current_job_lead_seconds()
	var sla_result := "ON TIME" if lead_seconds <= _current_job_sla_seconds else "LATE"
	_jobs_completed += 1
	if sla_result == "ON TIME":
		_sla_on_time += 1
	else:
		_sla_late += 1
	_completed_execution_seconds += elapsed_seconds
	_record_job_result(
		_current_job_dictionary(), "COMPLETE", elapsed_seconds, lead_seconds, sla_result
	)
	_current_job_started_msec = 0
	_current_job_accepted_msec = 0
	_current_job_sla_seconds = 0.0
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
	_update_operations_ui()
	print("%s complete" % _current_job_label())
	_schedule_next_queued_job()


func _fail_job(reason: String) -> void:
	var elapsed_seconds := _current_job_elapsed_seconds()
	var lead_seconds := _current_job_lead_seconds()
	_jobs_failed += 1
	_record_job_result(
		_current_job_dictionary(), "FAILED", elapsed_seconds, lead_seconds, "FAILED"
	)
	_current_job_started_msec = 0
	_current_job_accepted_msec = 0
	_current_job_sla_seconds = 0.0
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
	_update_operations_ui()
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
	var stock_packages: Dictionary = {
		shelf_01_pickup: [shelf_01_stock_a, shelf_01_stock_b, shelf_01_stock_c],
		shelf_02_pickup: [shelf_02_stock_a, shelf_02_stock_b, shelf_02_stock_c],
		shelf_03_pickup: [shelf_03_stock_a, shelf_03_stock_b, shelf_03_stock_c],
		shelf_04_pickup: [shelf_04_stock_a, shelf_04_stock_b, shelf_04_stock_c],
	}
	for pickup_marker in stock_packages:
		var available := _get_available_stock(pickup_marker)
		var packages: Array = stock_packages[pickup_marker]
		for package_index in packages.size():
			var stock_package: MeshInstance3D = packages[package_index]
			stock_package.visible = package_index < available


func _update_inventory_ui() -> void:
	inventory_status_label.text = "Available Stock / Restock\nShelf 01: %d   [5] +1\nShelf 02: %d   [6] +1\nShelf 03: %d   [7] +1\nShelf 04: %d   [8] +1" % [
		_get_available_stock(shelf_01_pickup),
		_get_available_stock(shelf_02_pickup),
		_get_available_stock(shelf_03_pickup),
		_get_available_stock(shelf_04_pickup),
	]


func _current_job_elapsed_seconds() -> float:
	return (Time.get_ticks_msec() - _current_job_started_msec) / 1000.0


func _current_job_lead_seconds() -> float:
	if _current_job_accepted_msec == 0:
		return 0.0
	return (Time.get_ticks_msec() - _current_job_accepted_msec) / 1000.0


func _record_job_result(
		job: Dictionary,
		status: String,
		elapsed_seconds: float,
		lead_or_wait_seconds: float,
		sla_result: String
) -> void:
	_recent_job_history.push_front({
		"id": job.id,
		"pickup_name": job.pickup_name,
		"priority": job.priority,
		"status": status,
		"duration": elapsed_seconds,
		"lead_time": lead_or_wait_seconds,
		"wait_time": lead_or_wait_seconds if status == "CANCELLED" else 0.0,
		"sla_seconds": job.sla_seconds,
		"sla_result": sla_result,
	})
	if _recent_job_history.size() > MAX_RECENT_JOB_HISTORY:
		_recent_job_history.pop_back()
	if status == "CANCELLED":
		return
	print("Job #%03d [%s] %s %s | Execution %.1fs | SLA %s %.1f/%.1fs" % [
		job.id,
		_priority_name(job.priority),
		job.pickup_name,
		status,
		elapsed_seconds,
		sla_result,
		lead_or_wait_seconds,
		job.sla_seconds,
	])


func _current_job_dictionary() -> Dictionary:
	return {
		"id": _current_job_id,
		"pickup_name": _current_pickup_name,
		"priority": _current_job_priority,
		"sla_seconds": _current_job_sla_seconds,
	}


func _update_operations_ui() -> void:
	var active_text := "None"
	if _is_job_active():
		active_text = "#%03d [%s] %s" % [
			_current_job_id,
			_priority_name(_current_job_priority),
			_current_pickup_name,
		]
	var average_text := "--"
	if _jobs_completed > 0:
		average_text = "%.1fs" % (_completed_execution_seconds / _jobs_completed)
	var sla_hit_rate_text := "--"
	if _jobs_completed > 0:
		sla_hit_rate_text = "%.1f%%" % (float(_sla_on_time) / _jobs_completed * 100.0)
	var lines: Array[String] = [
		"Operations",
		"Accepted: %d" % _jobs_accepted,
		"Completed: %d" % _jobs_completed,
		"Failed: %d" % _jobs_failed,
		"Cancelled: %d" % _jobs_cancelled,
		"Active: %s" % active_text,
		"Avg complete: %s" % average_text,
		"SLA on-time: %d" % _sla_on_time,
		"SLA late: %d" % _sla_late,
		"SLA hit rate: %s" % sla_hit_rate_text,
		"SLA targets: N 20s / H 12s",
		"",
		"Recent",
	]
	if _recent_job_history.is_empty():
		lines.append("No job history yet")
	else:
		for result in _recent_job_history:
			var history_pickup_name: String = result.pickup_name.replace("Shelf Row ", "Row")
			if result.status == "CANCELLED":
				lines.append("#%03d [%s] %s CANCELLED wait %.1fs" % [
					result.id,
					_priority_name(result.priority),
					history_pickup_name,
					result.wait_time,
				])
				continue
			var result_suffix := "" if result.status == "FAILED" else " %s" % result.sla_result
			lines.append("#%03d [%s] %s %s %.1fs%s" % [
				result.id,
				_priority_name(result.priority),
				history_pickup_name,
				result.status,
				result.duration,
				result_suffix,
			])
	operations_status_label.text = "\n".join(lines)


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
			or _queued_start_scheduled \
			or _charge_state != ChargeState.NONE


func _update_job_ui(status: String) -> void:
	var queue_text := _queue_ui_text()
	if _current_job_id == 0:
		job_status_label.text = "Warehouse Jobs\n1–4: Normal jobs\nQ/W/E/R: High priority\nCancel pending: [Z] next  [X] latest\nStatus: %s\n%s" % [status, queue_text]
		return
	job_status_label.text = "%s\nPriority: %s\nPick: %s\nDrop: Packing Station\nCancel pending: [Z] next  [X] latest\nStatus: %s\n%s" % [
		_current_job_label(), _priority_name(_current_job_priority),
		_current_pickup_name, status, queue_text
	]


func _queue_ui_text() -> String:
	var lines: Array[String] = [
		"Pending: %d/%d" % [_job_queue.size(), MAX_PENDING_JOBS]
	]
	if _job_queue.size() >= 1:
		lines.append("Next: #%03d [%s] %s" % [
			_job_queue[0].id,
			_priority_name(_job_queue[0].priority),
			_job_queue[0].pickup_name,
		])
	if _job_queue.size() >= 2:
		lines.append("Then: #%03d [%s] %s" % [
			_job_queue[1].id,
			_priority_name(_job_queue[1].priority),
			_job_queue[1].pickup_name,
		])
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


func _priority_name(priority: int) -> String:
	return "HIGH" if priority == JobPriority.HIGH else "NORMAL"


func _sla_seconds_for_priority(priority: int) -> float:
	return HIGH_SLA_SECONDS if priority == JobPriority.HIGH else NORMAL_SLA_SECONDS


func _format_vector3(value: Vector3) -> String:
	return "(%.3f, %.3f, %.3f)" % [value.x, value.y, value.z]


func _on_robot_movement_changed(status: String, speed: float, destination: Vector3) -> void:
	var current_position: Vector3 = robot.global_position
	var travelled_meters: float = Vector2(
		current_position.x - _last_battery_position.x,
		current_position.z - _last_battery_position.z
	).length()
	if travelled_meters > 0.0:
		_battery_percent = clampf(
			_battery_percent - travelled_meters * BATTERY_DRAIN_PER_METER,
			0.0,
			BATTERY_MAX_PERCENT
		)
	_last_battery_position = current_position
	_robot_movement_status = status
	_robot_speed = speed
	_robot_destination = destination
	_update_movement_ui()


func _update_movement_ui() -> void:
	var destination_text := "—"
	if destination_marker.visible:
		destination_text = "(%.1f, %.1f)" % [
			_robot_destination.x, _robot_destination.z
		]
	var display_status := _robot_movement_status
	if _charge_state == ChargeState.TRAVELLING:
		display_status = "To Charger"
	elif _charge_state == ChargeState.CHARGING:
		display_status = "Charging"
	status_label.text = "Robot01\nStatus: %s\nSpeed: %.2f m/s\nDestination: %s\nBattery: %.1f%% [%s]   [C] Charge" % [
		display_status,
		_robot_speed,
		destination_text,
		_battery_percent,
		_battery_status_name(),
	]


func _battery_status_name() -> String:
	if _battery_percent <= 0.0:
		return "EMPTY"
	if _battery_percent <= BATTERY_LOW_PERCENT:
		return "LOW"
	return "OK"


func _request_charge() -> void:
	if not _navigation_ready:
		print("Charge unavailable: navigation is not ready")
		return
	if _charge_state != ChargeState.NONE:
		print("Charge already in progress")
		return
	if _is_job_active() or not _job_queue.is_empty() or _queued_start_scheduled:
		print("Charge unavailable: warehouse jobs are active or pending")
		return
	if _battery_percent >= 99.9:
		print("Charge not required: battery full")
		return
	_begin_charge_trip(false)


func _begin_charge_trip(automatic: bool = false) -> void:
	_automatic_charge_in_progress = automatic
	var authored_position: Vector3 = charging_target.global_position
	var navigation_map: RID = navigation_region.get_navigation_map()
	var navigation_position: Vector3 = NavigationServer3D.map_get_closest_point(
		navigation_map, authored_position
	)
	var horizontal_snap_distance: float = Vector2(
		navigation_position.x - authored_position.x,
		navigation_position.z - authored_position.z
	).length()
	print("Charge target authored position: %s" % _format_vector3(authored_position))
	print("Charge target navigation position: %s" % _format_vector3(navigation_position))
	print("Charge target horizontal snap distance: %.3f" % horizontal_snap_distance)
	if horizontal_snap_distance > CHARGE_TARGET_MAX_HORIZONTAL_SNAP:
		if automatic:
			print("Automatic charge unavailable: target is %.3f m from the NavigationMesh; pending jobs remain paused" % horizontal_snap_distance)
		else:
			print("Charge unavailable: target is %.3f m from the NavigationMesh" % horizontal_snap_distance)
		_charge_state = ChargeState.NONE
		_automatic_charge_in_progress = false
		return
	_charge_state = ChargeState.TRAVELLING
	destination_marker.global_position = Vector3(
		navigation_position.x, authored_position.y + 0.04, navigation_position.z
	)
	destination_marker.visible = true
	_robot_destination = navigation_position
	_update_movement_ui()
	robot.set_navigation_target(navigation_position)


func _begin_station_charging() -> void:
	_charge_state = ChargeState.CHARGING
	destination_marker.visible = false
	_robot_speed = 0.0
	_update_movement_ui()
	print("Robot01 charging started")
	await get_tree().create_timer(CHARGE_DURATION_SECONDS).timeout
	if _charge_state != ChargeState.CHARGING:
		return
	_battery_percent = BATTERY_MAX_PERCENT
	_last_battery_position = robot.global_position
	_charge_state = ChargeState.NONE
	var resume_warehouse_queue: bool = _automatic_charge_in_progress
	_automatic_charge_in_progress = false
	_update_movement_ui()
	print("Robot01 charging complete: %.1f%%" % _battery_percent)
	if resume_warehouse_queue:
		print("Automatic charging complete — resuming warehouse queue")
		_schedule_next_queued_job()
