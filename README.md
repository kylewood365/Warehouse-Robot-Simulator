# Warehouse Robot Simulator

A lightweight 3D warehouse environment for experimenting with autonomous warehouse robotics in Godot. The project intentionally uses only built-in primitive meshes and simple materials so it remains suitable for the GL Compatibility renderer and older hardware.

## Phase 2

- A concrete-style floor and four collidable outer walls
- Four reusable, collidable shelving rows with packages and wide drive aisles
- A single autonomous mobile robot (`Robot01`) with smooth path following
- Dedicated packing/drop-off and charging stations
- Overview camera, aisle markings, and compatibility-friendly directional lighting

- Runtime-baked 3D navigation using the warehouse's static collision geometry
- Click-to-move destinations with an in-world marker and movement status overlay

This phase is intentionally limited to single-robot navigation. Multiple robots,
batteries, charging behavior, pickup jobs, package carrying, task scheduling, and
advanced avoidance are reserved for later phases.

## Controls

- **Left click** a valid warehouse floor location to set `Robot01`'s destination.
- Click another valid floor location at any time to update the destination.

Clicks on shelves, stations, walls, or outside the navigable floor are ignored.

## Requirements

- Godot **4.6.x**
- GL Compatibility renderer

No external models, textures, or third-party assets are required.

## Run

1. Import `project.godot` into Godot 4.6.
2. Open the project.
3. Press **F6** to run the current scene or **F5** to run the configured main scene.

The main scene is `warehouse.tscn`.
