extends RefCounted
## Reguły pracownika (czysta logika): które komórki pasa wymagają pracy danej operacji
## i czy zestaw nadaje się do pracy na polu.

const FieldCells = preload("res://scripts/core/field/field_cells.gd")
const Rules = preload("res://scripts/core/field/field_work_rules.gd")
const Stage = FieldCells.Stage
const SUPPORTED_TOOLS: Array[String] = ["rigid_mounted", "towed_single_axle"]


## Czy komórka wymaga pracy – jak przy jeździe gracza, ale siew tylko na gołej ziemi
## (dojrzałego zboża i ścierniska siewnik i tak nie obsieje).
static func cell_needs(operation: String, stage: int, fertilized_bits: int) -> bool:
	if operation == "sow":
		return stage == Stage.PLAIN
	return Rules.cell_needs_work(operation, stage, fertilized_bits)


## Czy pas wymaga pracy: wystarczająco dużo komórek do zrobienia (pojedyncze resztki pomijamy).
static func strip_needs(operation: String, indices: PackedInt32Array, states: PackedByteArray,
		fertilized: PackedByteArray, minimum_fraction: float = 0.002) -> bool:
	var needed: int = 0
	var threshold: int = maxi(8, int(indices.size() * minimum_fraction))
	for index in indices:
		if cell_needs(operation, states[index], fertilized[index]):
			needed += 1
			if needed >= threshold:
				return true
	return false


## Powód, dla którego zestaw nie może pracować (pusty = może).
static func rig_problem(tool_kind: String, has_work: bool) -> String:
	if tool_kind.is_empty():
		return "Pracownik potrzebuje podpiętego narzędzia roboczego (E podpina)."
	if not has_work:
		return "To narzędzie nie pracuje na polu."
	if not SUPPORTED_TOOLS.has(tool_kind):
		return "Pracownik obsługuje narzędzia zawieszane i jednoosiowe przyczepiane."
	return ""
