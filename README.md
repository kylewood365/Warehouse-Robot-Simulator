# Warehouse Robot Simulator

A lightweight 3D warehouse environment for experimenting with autonomous warehouse robotics in Godot. The project intentionally uses only built-in primitive meshes and simple materials so it remains suitable for the GL Compatibility renderer and older hardware.

## Phase 1

- A concrete-style floor and four collidable outer walls
- Four reusable, collidable shelving rows with packages and wide drive aisles
- A stationary autonomous mobile robot (`Robot01`)
- Dedicated packing/drop-off and charging stations
- Overview camera, aisle markings, and compatibility-friendly directional lighting

Movement, navigation, battery simulation, and robot AI are deliberately reserved for later phases.

## Requirements

- Godot **4.6.x**
- GL Compatibility renderer

No external models, textures, or third-party assets are required.

## Run

1. Import `project.godot` into Godot 4.6.
2. Open the project.
3. Press **F6** to run the current scene or **F5** to run the configured main scene.

The main scene is `warehouse.tscn`.
