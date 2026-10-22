extends RefCounted
## Sygnatura zestawu zapisana w trasie: modele, konfiguracja (hash) i użyte zaczepy.
## Trasę można odtworzyć tylko tym samym zestawem. Konfiguracja maszyn jest haszowana tylko
## z użytymi zaczepami (gniazdo pojazdu, zaczep narzędzia) – dodanie nowego zaczepu do maszyny
## (np. TUZ) nie unieważnia nagranych tras.

## Zaczepy dodane po wprowadzeniu tras (dawne trasy haszowały pełną konfigurację bez nich).
const LATER_PORT_TYPES: Array[String] = ["three_point"]


static func build(vehicle_model: Dictionary, tool_model: Dictionary, socket: Dictionary, plug: Dictionary) -> Dictionary:
	return _signature(vehicle_model, tool_model, _ports_used(vehicle_model, socket),
		_ports_used(tool_model, plug) if not tool_model.is_empty() else {}, socket, plug)


## Czy trasa (jej sygnatura) pasuje do zestawu. Przyjmuje też trasy nagrane przed zmianą zasady
## haszowania (pełna konfiguracja bez zaczepów dodanych później).
static func matches(route_signature: Variant, vehicle_model: Dictionary, tool_model: Dictionary,
		socket: Dictionary, plug: Dictionary) -> bool:
	if route_signature == build(vehicle_model, tool_model, socket, plug):
		return true
	return route_signature == _signature(vehicle_model, tool_model, _without_later_ports(vehicle_model),
		_without_later_ports(tool_model), socket, plug)


static func _signature(vehicle_model: Dictionary, tool_model: Dictionary, vehicle_config: Dictionary,
		tool_config: Dictionary, socket: Dictionary, plug: Dictionary) -> Dictionary:
	return {"vehicle_model": vehicle_model["id"], "tool_model": tool_model.get("id", ""),
		"vehicle_config": JSON.stringify(vehicle_config, "", true).sha256_text(),
		"tool_config": JSON.stringify(tool_config, "", true).sha256_text() if not tool_model.is_empty() else JSON.stringify({}, "", true).sha256_text(),
		"socket": socket.get("id", ""), "plug": plug.get("id", "")}


static func _ports_used(model: Dictionary, port: Dictionary) -> Dictionary:
	var copy: Dictionary = model.duplicate(true)
	var used: Array = []
	for item in model.get("hitch_ports", []):
		if not port.is_empty() and str(item["id"]) == str(port["id"]):
			used.append(item)
	copy["hitch_ports"] = used
	return copy


static func _without_later_ports(model: Dictionary) -> Dictionary:
	if model.is_empty():
		return model
	var copy: Dictionary = model.duplicate(true)
	var kept: Array = []
	for item in model.get("hitch_ports", []):
		if not LATER_PORT_TYPES.has(str(item.get("type", ""))):
			kept.append(item)
	copy["hitch_ports"] = kept
	return copy
