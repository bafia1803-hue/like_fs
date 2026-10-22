extends RefCounted
## Stan nowej maszyny w formacie zapisu gry (zakup w sklepie) – czysta logika.


## Pierwszy wolny identyfikator "prefiks_NN" (np. tractor_03).
static func next_id(prefix: String, taken: Dictionary) -> String:
	var number: int = 1
	while taken.has("%s_%02d" % [prefix, number]):
		number += 1
	return "%s_%02d" % [prefix, number]


## Prefiks identyfikatora: kategoria modelu albo jego id.
static func prefix_for(model: Dictionary) -> String:
	return str(model.get("category", model["id"]))


static func new_state(model: Dictionary, instance_id: String, position_m: Vector2, rotation: float) -> Dictionary:
	var storages: Dictionary = {}
	for storage in model.get("storage_definitions", []):
		storages[str(storage["id"])] = {"material_id": null, "amount_l": 0.0}
	var state: Dictionary = {
		"instance_id": instance_id,
		"model_id": str(model["id"]),
		"owner_id": "player_01",
		"transform": {"position_m": [position_m.x, position_m.y], "rotation_deg": rad_to_deg(rotation)},
		"motion": {"linear_velocity_m_per_s": [0.0, 0.0], "angular_velocity_deg_per_s": 0.0},
		"steering_input": 0.0,
		"parking_brake_engaged": true,
		"storages": storages,
		"articulated_state": {},
		"work_state": {"enabled": false, "lowered": false} if model.get("work") is Dictionary else null,
	}
	if str(model["physics_kind"]) == "towed_turntable":
		state["articulated_state"] = {"front_carriage": {"relative_rotation_deg": 0.0, "relative_angular_velocity_deg_per_s": 0.0}}
	return state
