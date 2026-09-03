extends Node3D

enum JobState { IDLE, TRAVELLING_TO_PICKUP, PICKING, TRAVELLING_TO_PACKING, COMPLETE, FAILED }
enum JobPriority { NORMAL, HIGH }
enum ChargeState { NONE, TRAVELLING, CHARGING }
enum DispatchReadiness { READY, CHARGE_REQUIRED, INFEASIBLE }

const JOB_TARGET_MAX_HORIZONTAL_SNAP := 0.75
const MAX_PENDING_JOBS := 5
const INITIAL_STOCK_PER_SHELF := 3
const MAX_RECENT_JOB_HISTORY := 5
const NORMAL_SLA_SECONDS := 20.0
const HIGH_SLA_SECONDS := 12.0
const BATTERY_MAX_PERCENT := 100.0
const BATTERY_LOW_PERCENT := 25.0
const BATTERY_DRAIN_PER_METER := 1.0
const BATTERY_DISPATCH_RESERVE_PERCENT := 10.0
const CHARGE_DURATION_SECONDS := 4.0
const CHARGE_TARGET_MAX_HORIZONTAL_SNAP := 0.75
# Treat sub-decimetre route differences as equal so floating-point path noise
# never changes the deterministic Robot01 tie-break.
const DISPATCH_DISTANCE_TIE_EPSILON := 0.1

@onready var navigation_region: NavigationRegion3D = $NavigationRegion3D
@onready var robot_01: RobotController = $Robot01
@onready var robot_02: RobotController = $Robot02
@onready var robots: Array[RobotController] = [robot_01, robot_02]
@onready var camera: Camera3D = $OverviewCamera
@onready var destination_marker: MeshInstance3D = $DestinationMarker
@onready var shelf_01_pickup: Marker3D = $JobTargets/Shelf01Pickup
@onready var shelf_02_pickup: Marker3D = $JobTargets/Shelf02Pickup
@onready var shelf_03_pickup: Marker3D = $JobTargets/Shelf03Pickup
@onready var shelf_04_pickup: Marker3D = $JobTargets/Shelf04Pickup
@onready var robot_01_packing_dropoff: Marker3D = $JobTargets/Robot01PackingDropoff
@onready var robot_02_packing_dropoff: Marker3D = $JobTargets/Robot02PackingDropoff
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
var _next_job_id := 1
var _job_queue: Array[Dictionary] = []
var _dispatch_scheduled := false
var _delivery_flash_id := 0
var _available_stock: Dictionary = {}
var _robot_state: Dictionary = {}
var _charging_station_owner: RobotController
var _jobs_accepted := 0
var _jobs_completed := 0
var _jobs_failed := 0
var _jobs_cancelled := 0
var _completed_execution_seconds := 0.0
var _sla_on_time := 0
var _sla_late := 0
var _recent_job_history: Array[Dictionary] = []

func _ready() -> void:
	_available_stock = {shelf_01_pickup: 3, shelf_02_pickup: 3, shelf_03_pickup: 3, shelf_04_pickup: 3}
	for fleet_robot in robots:
		_robot_state[fleet_robot] = _new_robot_state(fleet_robot)
		fleet_robot.movement_changed.connect(_on_robot_movement_changed.bind(fleet_robot))
		fleet_robot.destination_reached.connect(_on_robot_destination_reached.bind(fleet_robot))
		fleet_robot.navigation_target_failed.connect(_on_robot_navigation_target_failed.bind(fleet_robot))
	_update_visible_stock()
	_update_inventory_ui()
	_update_operations_ui()
	destination_marker.visible = false
	_update_movement_ui()
	_update_job_ui("Preparing navigation...")
	call_deferred("_build_navigation")

func _new_robot_state(fleet_robot: RobotController) -> Dictionary:
	return {
		"job_state": JobState.IDLE, "job": {}, "pickup_marker": null,
		"pickup_name": "", "source_package": null, "stock_reserved": false,
		"started_msec": 0, "accepted_msec": 0, "sla_seconds": 0.0,
		"battery_percent": BATTERY_MAX_PERCENT,
		"last_battery_position": fleet_robot.global_position,
		"charge_state": ChargeState.NONE, "automatic_charge": false,
		"automatic_charge_failed": false,
		"movement_status": "Preparing navigation...", "speed": 0.0,
		"destination": Vector3.ZERO,
	}

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
	for fleet_robot in robots:
		_robot_state[fleet_robot].movement_status = "Idle"
	_update_movement_ui()
	_update_job_ui("Ready")


func _navigation_failed(stage: String, detail: String) -> void:
	push_error(
		"Navigation failed during %s: %s; click-to-move is disabled"
		% [stage, detail]
	)
	for fleet_robot in robots:
		var state: Dictionary = _robot_state[fleet_robot]
		state.movement_status = "Navigation unavailable"
		state.speed = 0.0
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
	if _robot_has_autonomous_workload(robot_01):
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
	robot_01.set_navigation_target(valid_position)
	get_viewport().set_input_as_handled()


func _request_job(pickup_marker: Marker3D, pickup_name: String, priority: int = JobPriority.NORMAL) -> void:
	if not _navigation_ready:
		print("Job start unavailable: navigation is not ready")
		return
	if _job_queue.size() >= MAX_PENDING_JOBS:
		print("Job queue full: request rejected")
		return
	if not _has_available_stock(pickup_marker) or not _reserve_stock(pickup_marker, pickup_name):
		print("Job rejected: %s out of stock" % pickup_name)
		return
	var job := {"id": _next_job_id, "pickup_marker": pickup_marker, "pickup_name": pickup_name,
		"priority": priority, "accepted_msec": Time.get_ticks_msec(),
		"sla_seconds": _sla_seconds_for_priority(priority)}
	_next_job_id += 1
	_jobs_accepted += 1
	var selected_robot: RobotController = null
	if _job_queue.is_empty():
		selected_robot = _find_dispatchable_robot(job)
	if selected_robot != null:
		_begin_job(selected_robot, job)
	else:
		_enqueue_job_by_priority(job)
		print("Job #%03d queued: %s [%s]" % [job.id, job.pickup_name, _priority_name(job.priority)])
		_schedule_fleet_dispatch()
	_update_job_ui(_job_status_text())
	_update_operations_ui()

func _find_dispatchable_robot(job: Dictionary) -> RobotController:
	var selection: Dictionary = _select_robot_for_job(job, false)
	var candidate: Dictionary = selection.get("candidate", {})
	if candidate.is_empty() or bool(candidate.requires_charge):
		return null
	_log_dispatch_selection(job, selection)
	_log_full_battery_dispatch(job, candidate)
	return candidate.robot as RobotController

func _enqueue_job_by_priority(job: Dictionary) -> void:
	if job.priority == JobPriority.NORMAL:
		_job_queue.append(job)
		return
	var index := 0
	while index < _job_queue.size() and _job_queue[index].priority == JobPriority.HIGH:
		index += 1
	_job_queue.insert(index, job)

func _schedule_fleet_dispatch() -> void:
	if _dispatch_scheduled or _job_queue.is_empty(): return
	_dispatch_scheduled = true
	call_deferred("_dispatch_pending_jobs")

func _dispatch_pending_jobs() -> void:
	_dispatch_scheduled = false
	if not _navigation_ready: return
	while not _job_queue.is_empty():
		var job: Dictionary = _job_queue.front()
		var selection: Dictionary = _select_robot_for_job(job)
		var candidate: Dictionary = selection.get("candidate", {})
		if candidate.is_empty(): break
		var selected: RobotController = candidate.robot as RobotController
		if bool(candidate.requires_charge):
			print("%s automatically charging before Job #%03d; job remains pending" % [
				selected.name, job.id,
			])
			_begin_charge_trip(selected, true)
			break
		_log_full_battery_dispatch(job, candidate)
		_job_queue.pop_front()
		_begin_job(selected, job)
	_update_job_ui(_job_status_text())

func _begin_job(fleet_robot: RobotController, job: Dictionary) -> void:
	var state: Dictionary = _robot_state[fleet_robot]
	state.job = job
	state.pickup_marker = job.pickup_marker
	state.pickup_name = job.pickup_name
	state.source_package = _get_source_package_for_pickup(job.pickup_marker)
	state.stock_reserved = true
	state.started_msec = Time.get_ticks_msec()
	state.accepted_msec = job.accepted_msec
	state.sla_seconds = job.sla_seconds
	state.job_state = JobState.TRAVELLING_TO_PICKUP
	_cargo_for(fleet_robot).visible = false
	print("%s started Job #%03d [%s]" % [fleet_robot.name, job.id, _priority_name(job.priority)])
	_command_job_target(fleet_robot, job.pickup_marker, job.pickup_name)
	_update_movement_ui(); _update_operations_ui()

func _estimate_navigation_path_distance(from_position: Vector3, to_position: Vector3) -> float:
	var path := NavigationServer3D.map_get_path(navigation_region.get_navigation_map(), from_position, to_position, true)
	if path.size() < 2: return -1.0
	var distance := 0.0
	for index in range(1, path.size()):
		distance += Vector2(path[index].x - path[index - 1].x, path[index].z - path[index - 1].z).length()
	return distance

func _estimate_job_route(fleet_robot: RobotController, job: Dictionary) -> Dictionary:
	var pickup_marker: Marker3D = job.pickup_marker as Marker3D
	var pickup_distance := _estimate_navigation_path_distance(
		fleet_robot.global_position, pickup_marker.global_position
	)
	var packing_dropoff := _packing_dropoff_for(fleet_robot)
	var packing_distance := _estimate_navigation_path_distance(
		pickup_marker.global_position, packing_dropoff.global_position
	)
	if pickup_distance < 0.0 or packing_distance < 0.0:
		return {"valid": false}
	var route_distance: float = pickup_distance + packing_distance
	var predicted_consumption := route_distance * BATTERY_DRAIN_PER_METER
	return {
		"valid": true,
		"distance": route_distance,
		"predicted_consumption": predicted_consumption,
		"required_battery": predicted_consumption + BATTERY_DISPATCH_RESERVE_PERCENT,
	}

func _evaluate_dispatch_candidate(fleet_robot: RobotController, job: Dictionary) -> Dictionary:
	var state: Dictionary = _robot_state[fleet_robot]
	var battery: float = state.battery_percent
	var estimate: Dictionary = _estimate_job_route(fleet_robot, job)
	if not bool(estimate.get("valid", false)):
		# Preserve the established LOW-threshold fallback when NavigationServer
		# cannot provide a meaningful predictive route.
		var fallback_charge_required := battery <= BATTERY_LOW_PERCENT and battery < 99.9
		return {
			"robot": fleet_robot,
			"estimate_valid": false,
			"distance": -1.0,
			"required_battery": -1.0,
			"readiness": DispatchReadiness.CHARGE_REQUIRED \
					if fallback_charge_required else DispatchReadiness.READY,
			"requires_charge": fallback_charge_required,
			"charge_blocked": fallback_charge_required and bool(state.automatic_charge_failed),
		}

	var required_battery: float = estimate.required_battery
	var readiness := DispatchReadiness.READY
	var requires_charge := false
	if required_battery > BATTERY_MAX_PERCENT:
		readiness = DispatchReadiness.INFEASIBLE
		# Match the existing full-battery guard: charge once when below full,
		# then dispatch rather than leaving an impossible job queued forever.
		requires_charge = battery < 99.9
	elif battery < 99.9 and (
			battery <= BATTERY_LOW_PERCENT or battery < required_battery
	):
		readiness = DispatchReadiness.CHARGE_REQUIRED
		requires_charge = true
	return {
		"robot": fleet_robot,
		"estimate_valid": true,
		"distance": estimate.distance,
		"required_battery": required_battery,
		"readiness": readiness,
		"requires_charge": requires_charge,
		"charge_blocked": requires_charge and bool(state.automatic_charge_failed),
	}

func _select_robot_for_job(job: Dictionary, emit_diagnostics: bool = true) -> Dictionary:
	var candidates: Array[Dictionary] = []
	for fleet_robot in robots:
		var state: Dictionary = _robot_state[fleet_robot]
		if _robot_is_available(state):
			candidates.append(_evaluate_dispatch_candidate(fleet_robot, job))
	if candidates.is_empty():
		return {}

	var valid_feasible: Array[Dictionary] = []
	var fallback_feasible: Array[Dictionary] = []
	var infeasible: Array[Dictionary] = []
	for candidate in candidates:
		if bool(candidate.charge_blocked):
			continue
		if int(candidate.readiness) == DispatchReadiness.INFEASIBLE:
			infeasible.append(candidate)
		elif bool(candidate.estimate_valid):
			valid_feasible.append(candidate)
		else:
			fallback_feasible.append(candidate)

	var selection_pool: Array[Dictionary] = valid_feasible
	if selection_pool.is_empty():
		selection_pool = fallback_feasible
	if selection_pool.is_empty():
		selection_pool = infeasible
	if selection_pool.is_empty():
		return {}

	var chosen: Dictionary = selection_pool.front()
	for candidate in selection_pool.slice(1):
		if _dispatch_candidate_is_better(candidate, chosen):
			chosen = candidate
	var selection := {
		"candidate": chosen,
		"candidates": candidates,
		"reason": _dispatch_selection_reason(chosen, candidates),
	}
	if emit_diagnostics:
		_log_dispatch_selection(job, selection)
	return selection

func _dispatch_candidate_is_better(candidate: Dictionary, incumbent: Dictionary) -> bool:
	var candidate_readiness := int(candidate.readiness)
	var incumbent_readiness := int(incumbent.readiness)
	if candidate_readiness != incumbent_readiness:
		return candidate_readiness < incumbent_readiness
	if bool(candidate.estimate_valid) and bool(incumbent.estimate_valid):
		var distance_difference: float = float(candidate.distance) - float(incumbent.distance)
		if absf(distance_difference) > DISPATCH_DISTANCE_TIE_EPSILON:
			return distance_difference < 0.0
	# Candidate lists follow fleet order, so keeping the incumbent makes
	# Robot01 the deterministic winner for ties and unavailable estimates.
	return false

func _dispatch_selection_reason(chosen: Dictionary, candidates: Array[Dictionary]) -> String:
	var chosen_robot: RobotController = chosen.robot as RobotController
	var competing: Array[Dictionary] = []
	for candidate in candidates:
		if candidate.robot != chosen_robot and not bool(candidate.charge_blocked):
			competing.append(candidate)
	if competing.is_empty():
		return "only dispatchable robot"

	for candidate in competing:
		if bool(chosen.estimate_valid) and not bool(candidate.estimate_valid) \
				and int(chosen.readiness) != DispatchReadiness.INFEASIBLE:
			return "valid route estimate"
	if not bool(chosen.estimate_valid):
		for candidate in competing:
			if int(candidate.readiness) != int(chosen.readiness):
				return "battery readiness fallback"
		return "route estimates unavailable; deterministic fallback"
	for candidate in competing:
		if int(chosen.readiness) == DispatchReadiness.READY \
				and int(candidate.readiness) == DispatchReadiness.CHARGE_REQUIRED:
			return "avoids pre-dispatch charge"
	if int(chosen.readiness) == DispatchReadiness.INFEASIBLE:
		return "full-battery fallback"
	for candidate in competing:
		if int(candidate.readiness) != int(chosen.readiness) \
				or not bool(candidate.estimate_valid):
			continue
		if absf(float(chosen.distance) - float(candidate.distance)) \
				<= DISPATCH_DISTANCE_TIE_EPSILON:
			return "distance tie"
		return "shorter route"
	return "battery readiness"

func _log_dispatch_selection(job: Dictionary, selection: Dictionary) -> void:
	var candidates: Array[Dictionary] = selection.candidates
	print("Dispatch evaluation Job #%03d:" % job.id)
	for candidate in candidates:
		var fleet_robot: RobotController = candidate.robot as RobotController
		var state: Dictionary = _robot_state[fleet_robot]
		var route_text := "unavailable"
		if bool(candidate.estimate_valid):
			route_text = "%.1fm" % float(candidate.distance)
		var blocked_text := " (charge retry blocked)" if bool(candidate.charge_blocked) else ""
		print("  %s: route %s | battery %.1f%% | %s%s" % [
			fleet_robot.name,
			route_text,
			float(state.battery_percent),
			_dispatch_readiness_name(int(candidate.readiness)),
			blocked_text,
		])
	var chosen: Dictionary = selection.candidate
	var chosen_robot: RobotController = chosen.robot as RobotController
	print("Smart dispatch Job #%03d -> %s (%s)" % [
		job.id, chosen_robot.name, selection.reason,
	])

func _log_full_battery_dispatch(job: Dictionary, candidate: Dictionary) -> void:
	if int(candidate.readiness) != DispatchReadiness.INFEASIBLE:
		return
	var fleet_robot: RobotController = candidate.robot as RobotController
	print("Job #%03d requirement exceeds capacity — dispatching full %s" % [
		job.id, fleet_robot.name,
	])

func _dispatch_readiness_name(readiness: int) -> String:
	match readiness:
		DispatchReadiness.READY: return "READY"
		DispatchReadiness.CHARGE_REQUIRED: return "CHARGE_REQUIRED"
		_: return "INFEASIBLE"

func _command_job_target(fleet_robot: RobotController, marker: Marker3D, target_name: String) -> void:
	var result := _get_navigation_target_for_job(fleet_robot, marker, target_name)
	if result.valid:
		_robot_state[fleet_robot].destination = result.position
		fleet_robot.set_navigation_target(result.position)

func _get_navigation_target_for_job(fleet_robot: RobotController, marker: Marker3D, target_name: String) -> Dictionary:
	var authored := marker.global_position
	var target := NavigationServer3D.map_get_closest_point(navigation_region.get_navigation_map(), authored)
	var snap := Vector2(target.x - authored.x, target.z - authored.z).length()
	if snap > JOB_TARGET_MAX_HORIZONTAL_SNAP:
		_fail_job(fleet_robot, "%s target is %.3f m from the NavigationMesh" % [target_name, snap])
		return {"valid": false}
	return {"valid": true, "position": target}

func _on_robot_destination_reached(_destination: Vector3, fleet_robot: RobotController) -> void:
	var state: Dictionary = _robot_state[fleet_robot]
	if state.charge_state == ChargeState.TRAVELLING:
		_begin_station_charging(fleet_robot); return
	match state.job_state:
		JobState.TRAVELLING_TO_PICKUP: _begin_pickup(fleet_robot)
		JobState.TRAVELLING_TO_PACKING: _complete_job(fleet_robot)
		_: _schedule_fleet_dispatch()

func _on_robot_navigation_target_failed(destination: Vector3, remaining: float, fleet_robot: RobotController) -> void:
	var state: Dictionary = _robot_state[fleet_robot]
	if state.charge_state == ChargeState.TRAVELLING:
		var was_automatic_charge: bool = state.automatic_charge
		print("%s charge navigation failed at %s (%.3f m)" % [fleet_robot.name, _format_vector3(destination), remaining])
		state.charge_state = ChargeState.NONE; state.automatic_charge = false
		state.automatic_charge_failed = was_automatic_charge
		if _charging_station_owner == fleet_robot:
			_charging_station_owner = null
		_schedule_fleet_dispatch(); _update_movement_ui(); return
	if _is_job_active(state):
		_fail_job(fleet_robot, "navigation failed")
	else:
		# A failed manual Robot01 target must not leave pending fleet work asleep.
		_schedule_fleet_dispatch()

func _begin_pickup(fleet_robot: RobotController) -> void:
	var state: Dictionary = _robot_state[fleet_robot]
	state.job_state = JobState.PICKING
	_update_job_ui(_job_status_text())
	await get_tree().create_timer(1.0).timeout
	if state.job_state != JobState.PICKING: return
	if state.source_package != null: state.source_package.visible = false
	_cargo_for(fleet_robot).visible = true
	state.job_state = JobState.TRAVELLING_TO_PACKING
	_command_job_target(fleet_robot, _packing_dropoff_for(fleet_robot), "Packing Station")

func _complete_job(fleet_robot: RobotController) -> void:
	var state: Dictionary = _robot_state[fleet_robot]
	var elapsed := _elapsed_seconds(state)
	var lead := _lead_seconds(state)
	var sla_result := "ON TIME" if lead <= float(state.sla_seconds) else "LATE"
	_jobs_completed += 1; _completed_execution_seconds += elapsed
	if sla_result == "ON TIME": _sla_on_time += 1
	else: _sla_late += 1
	_record_job_result(state.job, "COMPLETE", elapsed, lead, sla_result)
	_cargo_for(fleet_robot).visible = false
	if state.source_package != null: state.source_package.visible = true
	state.stock_reserved = false
	print("%s completed Job #%03d" % [fleet_robot.name, state.job.id])
	_reset_job_state(state, JobState.COMPLETE)
	_show_delivered_package_briefly()
	_update_operations_ui(); _schedule_fleet_dispatch()

func _fail_job(fleet_robot: RobotController, reason: String) -> void:
	var state: Dictionary = _robot_state[fleet_robot]
	_jobs_failed += 1
	_record_job_result(state.job, "FAILED", _elapsed_seconds(state), _lead_seconds(state), "FAILED")
	_cargo_for(fleet_robot).visible = false
	if state.source_package != null: state.source_package.visible = true
	if state.stock_reserved: _release_stock(state.pickup_marker, state.pickup_name)
	print("%s Job #%03d failed: %s" % [fleet_robot.name, state.job.id, reason])
	_reset_job_state(state, JobState.FAILED)
	_update_operations_ui(); _schedule_fleet_dispatch()

func _reset_job_state(state: Dictionary, final_state: int) -> void:
	state.job_state = final_state; state.job = {}; state.pickup_marker = null; state.pickup_name = ""
	state.source_package = null; state.stock_reserved = false; state.started_msec = 0
	state.accepted_msec = 0; state.sla_seconds = 0.0
func _cancel_next_pending_job() -> void:
	if _job_queue.is_empty(): print("Cancel rejected: no pending jobs"); return
	_cancel_pending_job(_job_queue.pop_front())

func _cancel_latest_pending_job() -> void:
	if _job_queue.is_empty(): print("Cancel rejected: no pending jobs"); return
	var latest := 0
	for index in range(1, _job_queue.size()):
		if _job_queue[index].id > _job_queue[latest].id: latest = index
	var job: Dictionary = _job_queue[latest]; _job_queue.remove_at(latest); _cancel_pending_job(job)

func _cancel_pending_job(job: Dictionary) -> void:
	var wait := (Time.get_ticks_msec() - int(job.accepted_msec)) / 1000.0
	_release_stock(job.pickup_marker, job.pickup_name); _jobs_cancelled += 1
	_record_job_result(job, "CANCELLED", 0.0, wait, "")
	_update_job_ui(_job_status_text()); _update_operations_ui()

func _request_restock(marker: Marker3D, pickup_name: String) -> void:
	if not _available_stock.has(marker) or _has_reserved_jobs_for_shelf(marker):
		print("Restock unavailable: %s" % pickup_name); return
	var available := _get_available_stock(marker)
	if available >= INITIAL_STOCK_PER_SHELF: print("Restock rejected: already full"); return
	_available_stock[marker] = available + 1; _refresh_stock_displays()

func _has_reserved_jobs_for_shelf(marker: Marker3D) -> bool:
	for fleet_robot in robots:
		var state: Dictionary = _robot_state[fleet_robot]
		if state.stock_reserved and state.pickup_marker == marker: return true
	for job in _job_queue:
		if job.pickup_marker == marker: return true
	return false

func _get_available_stock(marker: Marker3D) -> int: return int(_available_stock.get(marker, 0))
func _has_available_stock(marker: Marker3D) -> bool: return _get_available_stock(marker) > 0
func _reserve_stock(marker: Marker3D, pickup_name: String) -> bool:
	var available := _get_available_stock(marker)
	if available <= 0: return false
	_available_stock[marker] = available - 1
	print("Inventory reserved: %s — %d/%d available" % [pickup_name, available - 1, INITIAL_STOCK_PER_SHELF])
	_refresh_stock_displays(); return true
func _release_stock(marker: Marker3D, pickup_name: String) -> void:
	_available_stock[marker] = mini(_get_available_stock(marker) + 1, INITIAL_STOCK_PER_SHELF)
	print("Inventory reservation released: %s" % pickup_name); _refresh_stock_displays()

func _refresh_stock_displays() -> void: _update_visible_stock(); _update_inventory_ui()
func _update_visible_stock() -> void:
	var displays := {shelf_01_pickup: [shelf_01_stock_a, shelf_01_stock_b, shelf_01_stock_c], shelf_02_pickup: [shelf_02_stock_a, shelf_02_stock_b, shelf_02_stock_c], shelf_03_pickup: [shelf_03_stock_a, shelf_03_stock_b, shelf_03_stock_c], shelf_04_pickup: [shelf_04_stock_a, shelf_04_stock_b, shelf_04_stock_c]}
	for marker in displays:
		for index in displays[marker].size(): displays[marker][index].visible = index < _get_available_stock(marker)
func _update_inventory_ui() -> void:
	inventory_status_label.text = "Available Stock / Restock\nShelf 01: %d   [5] +1\nShelf 02: %d   [6] +1\nShelf 03: %d   [7] +1\nShelf 04: %d   [8] +1" % [_get_available_stock(shelf_01_pickup), _get_available_stock(shelf_02_pickup), _get_available_stock(shelf_03_pickup), _get_available_stock(shelf_04_pickup)]

func _elapsed_seconds(state: Dictionary) -> float: return (Time.get_ticks_msec() - int(state.started_msec)) / 1000.0
func _lead_seconds(state: Dictionary) -> float:
	return 0.0 if int(state.accepted_msec) == 0 else (Time.get_ticks_msec() - int(state.accepted_msec)) / 1000.0
func _record_job_result(job: Dictionary, status: String, elapsed: float, lead: float, sla_result: String) -> void:
	_recent_job_history.push_front({"id": job.id, "pickup_name": job.pickup_name, "priority": job.priority, "status": status, "duration": elapsed, "lead_time": lead, "wait_time": lead if status == "CANCELLED" else 0.0, "sla_seconds": job.sla_seconds, "sla_result": sla_result})
	if _recent_job_history.size() > MAX_RECENT_JOB_HISTORY: _recent_job_history.pop_back()

func _update_operations_ui() -> void:
	var active: Array[String] = []
	for fleet_robot in robots:
		var state: Dictionary = _robot_state.get(fleet_robot, {})
		if not state.is_empty() and _is_job_active(state): active.append("%s #%03d" % [fleet_robot.name, state.job.id])
	var average := "--" if _jobs_completed == 0 else "%.1fs" % (_completed_execution_seconds / _jobs_completed)
	var hit_rate := "--" if _jobs_completed == 0 else "%.1f%%" % (float(_sla_on_time) / _jobs_completed * 100.0)
	var lines: Array[String] = ["Operations", "Accepted: %d" % _jobs_accepted, "Completed: %d" % _jobs_completed, "Failed: %d" % _jobs_failed, "Cancelled: %d" % _jobs_cancelled, "Active: %s" % ("None" if active.is_empty() else ", ".join(active)), "Avg complete: %s" % average, "SLA on-time: %d" % _sla_on_time, "SLA late: %d" % _sla_late, "SLA hit rate: %s" % hit_rate, "SLA targets: N 20s / H 12s", "", "Recent"]
	if _recent_job_history.is_empty(): lines.append("No job history yet")
	else:
		for result in _recent_job_history:
			if result.status == "CANCELLED":
				lines.append("#%03d [%s] %s CANCELLED wait %.1fs" % [
					result.id,
					_priority_name(result.priority),
					result.pickup_name.replace("Shelf Row ", "Row"),
					result.wait_time,
				])
				continue
			lines.append("#%03d [%s] %s %s %.1fs%s" % [result.id, _priority_name(result.priority), result.pickup_name.replace("Shelf Row ", "Row"), result.status, result.duration, "" if result.sla_result == "" else " " + result.sla_result])
	operations_status_label.text = "\n".join(lines)

func _get_source_package_for_pickup(marker: Marker3D) -> MeshInstance3D:
	if marker == shelf_01_pickup: return shelf_01_source_package
	if marker == shelf_02_pickup: return shelf_02_source_package
	if marker == shelf_03_pickup: return shelf_03_source_package
	if marker == shelf_04_pickup: return shelf_04_source_package
	return null
func _packing_dropoff_for(fleet_robot: RobotController) -> Marker3D:
	return robot_01_packing_dropoff if fleet_robot == robot_01 else robot_02_packing_dropoff
func _cargo_for(fleet_robot: RobotController) -> MeshInstance3D: return fleet_robot.get_node("CargoMount/CarriedPackage")
func _show_delivered_package_briefly() -> void:
	_delivery_flash_id += 1; var flash_id := _delivery_flash_id; delivered_package.visible = true
	await get_tree().create_timer(0.75).timeout
	if flash_id == _delivery_flash_id: delivered_package.visible = false

func _is_job_active(state: Dictionary) -> bool:
	return state.job_state in [JobState.TRAVELLING_TO_PICKUP, JobState.PICKING, JobState.TRAVELLING_TO_PACKING]
func _robot_is_available(state: Dictionary) -> bool:
	return not _is_job_active(state) and state.charge_state == ChargeState.NONE \
			and state.movement_status != "Moving"
func _robot_has_autonomous_workload(fleet_robot: RobotController) -> bool:
	var state: Dictionary = _robot_state[fleet_robot]
	return _is_job_active(state) or state.charge_state != ChargeState.NONE
func _fleet_has_warehouse_workload() -> bool:
	if not _job_queue.is_empty() or _dispatch_scheduled:
		return true
	for fleet_robot in robots:
		var state: Dictionary = _robot_state[fleet_robot]
		if _is_job_active(state):
			return true
	return false

func _update_job_ui(status: String) -> void:
	job_status_label.text = "Warehouse Jobs\n1–4: Normal jobs\nQ/W/E/R: High priority\nCancel pending: [Z] next  [X] latest\nStatus: %s\n%s" % [status, _queue_ui_text()]
func _queue_ui_text() -> String:
	var lines: Array[String] = ["Pending: %d/%d" % [_job_queue.size(), MAX_PENDING_JOBS]]
	if _job_queue.size() > 0: lines.append("Next: #%03d [%s] %s" % [_job_queue[0].id, _priority_name(_job_queue[0].priority), _job_queue[0].pickup_name])
	if _job_queue.size() > 1: lines.append("Then: #%03d [%s] %s" % [_job_queue[1].id, _priority_name(_job_queue[1].priority), _job_queue[1].pickup_name])
	if _job_queue.size() > 2: lines.append("+%d more" % (_job_queue.size() - 2))
	return "\n".join(lines)
func _job_status_text() -> String: return "Ready" if _navigation_ready else "Preparing navigation..."
func _priority_name(priority: int) -> String: return "HIGH" if priority == JobPriority.HIGH else "NORMAL"
func _sla_seconds_for_priority(priority: int) -> float: return HIGH_SLA_SECONDS if priority == JobPriority.HIGH else NORMAL_SLA_SECONDS
func _format_vector3(value: Vector3) -> String: return "(%.3f, %.3f, %.3f)" % [value.x, value.y, value.z]

func _on_robot_movement_changed(status: String, speed: float, destination: Vector3, fleet_robot: RobotController) -> void:
	var state: Dictionary = _robot_state[fleet_robot]
	var position := fleet_robot.global_position
	var previous: Vector3 = state.last_battery_position
	var travelled := Vector2(position.x - previous.x, position.z - previous.z).length()
	state.battery_percent = clampf(float(state.battery_percent) - travelled * BATTERY_DRAIN_PER_METER, 0.0, BATTERY_MAX_PERCENT)
	state.last_battery_position = position; state.movement_status = status; state.speed = speed; state.destination = destination
	_update_movement_ui()
func _update_movement_ui() -> void:
	var lines: Array[String] = []
	for fleet_robot in robots:
		var state: Dictionary = _robot_state.get(fleet_robot, {})
		if state.is_empty(): continue
		var display: String = state.movement_status
		if state.charge_state == ChargeState.TRAVELLING: display = "To Charger"
		elif state.charge_state == ChargeState.CHARGING: display = "Charging"
		elif _is_job_active(state): display = _job_leg_status(state)
		var job_text := "" if state.job.is_empty() else " | Job #%03d" % state.job.id
		lines.append("%s: %s%s | Battery %.1f%% [%s]" % [fleet_robot.name, display, job_text, state.battery_percent, _battery_status_name(state)])
	lines.append(""); lines.append("[C] Charge Robot01")
	status_label.text = "\n".join(lines)
func _job_leg_status(state: Dictionary) -> String:
	if state.job_state == JobState.TRAVELLING_TO_PICKUP: return "To " + str(state.pickup_name).replace("Shelf Row ", "Shelf ")
	if state.job_state == JobState.PICKING: return "Picking"
	return "To Packing"
func _battery_status_name(state: Dictionary) -> String:
	if state.battery_percent <= 0.0: return "EMPTY"
	if state.battery_percent <= BATTERY_LOW_PERCENT: return "LOW"
	return "OK"

func _request_charge() -> void:
	if _fleet_has_warehouse_workload():
		print("Charge unavailable: warehouse jobs are active or pending"); return
	var state: Dictionary = _robot_state[robot_01]
	if not _navigation_ready or not _robot_is_available(state):
		print("Robot01 charge unavailable"); return
	if state.battery_percent >= 99.9: print("Charge not required: battery full"); return
	_begin_charge_trip(robot_01, false)
func _begin_charge_trip(fleet_robot: RobotController, automatic: bool = false) -> void:
	if _charging_station_owner != null and _charging_station_owner != fleet_robot:
		print("%s charge waiting: Charging Station occupied by %s" % [
			fleet_robot.name, _charging_station_owner.name
		])
		return
	var state: Dictionary = _robot_state[fleet_robot]
	var authored := charging_target.global_position
	var target := NavigationServer3D.map_get_closest_point(navigation_region.get_navigation_map(), authored)
	var snap := Vector2(target.x - authored.x, target.z - authored.z).length()
	if snap > CHARGE_TARGET_MAX_HORIZONTAL_SNAP:
		print("%s charge unavailable: target off NavigationMesh" % fleet_robot.name); return
	_charging_station_owner = fleet_robot
	state.automatic_charge_failed = false
	state.automatic_charge = automatic; state.charge_state = ChargeState.TRAVELLING; state.destination = target
	fleet_robot.set_navigation_target(target); _update_movement_ui()
func _begin_station_charging(fleet_robot: RobotController) -> void:
	var state: Dictionary = _robot_state[fleet_robot]
	state.charge_state = ChargeState.CHARGING; state.speed = 0.0; _update_movement_ui()
	print("%s charging started" % fleet_robot.name)
	await get_tree().create_timer(CHARGE_DURATION_SECONDS).timeout
	if state.charge_state != ChargeState.CHARGING: return
	state.battery_percent = BATTERY_MAX_PERCENT; state.last_battery_position = fleet_robot.global_position
	state.charge_state = ChargeState.NONE; state.automatic_charge = false
	if _charging_station_owner == fleet_robot:
		_charging_station_owner = null
	print("%s charging complete" % fleet_robot.name); _update_movement_ui(); _schedule_fleet_dispatch()
