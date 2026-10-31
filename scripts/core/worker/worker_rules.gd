extends RefCounted
## Reguły pracownika (czysta logika): które komórki pasa wymagają pracy danej operacji
## i czy zestaw nadaje się do pracy na polu.

const FieldCells = preload("res://scripts/core/field/field_cells.gd")
const Rules = preload("res://scripts/core/field/field_work_rules.gd")
const Stage = FieldCells.Stage
const SUPPORTED_TOOLS: Array[String] = ["rigid_mounted", "towed_single_axle"]


## Czy komórka wymaga pracy pracownika:
##   – siew tylko na gołej (zakultywowanej) ziemi – ściernisko jest dla siewnika „końcem pola”,
##   – kultywacja tylko ścierniska – pracownik nie zaorze zasiewów ani dojrzałego zboża,
##   – zbiór i nawożenie jak przy jeździe gracza.
static func cell_needs(operation: String, stage: int, fertilized_bits: int) -> bool:
	match operation:
		"sow":
			return stage == Stage.PLAIN
		"cultivate":
			return stage == Stage.HARVESTED
	return Rules.cell_needs_work(operation, stage, fertilized_bits)


## Praca, po której ta praca może mieć więcej do zrobienia (pracownik czeka, gdy na polu
## pracuje taki zestaw): siew po kultywacji, kultywacja po zbiorze.
const FEEDS := {"sow": ["cultivate"], "cultivate": ["harvest"], "fertilize": ["sow", "cultivate", "harvest"]}


## Komunikaty pracy na polu, przy których pracownik musi stanąć (brak materiału, pełny zbiornik,
## inne ziarno, nie to pole). Pozostałe (np. siewnik nad ścierniskiem) dotyczą pojedynczych komórek.
const BLOCKING_MESSAGES: Array[String] = ["nie ma ziarna", "jest pusty", "nie zbiera tej rośliny",
	"nie ma zbiornika", "zmianą rodzaju ziarna", "Brak przelicznika", "pełny", "nie jest twoje"]


static func blocking(text: String) -> bool:
	for part in BLOCKING_MESSAGES:
		if text.contains(part):
			return true
	return false


## Profil pasa: udział komórek wymagających pracy w kolejnych koszach wzdłuż pasa.
## positions[i] – położenie komórki indices[i] wzdłuż pasa (0 … 1).
static func strip_profile(operation: String, indices: PackedInt32Array, positions: PackedFloat32Array,
		states: PackedByteArray, fertilized: PackedByteArray, bins: int) -> PackedFloat32Array:
	var counts := PackedInt32Array()
	counts.resize(bins)
	var needed := PackedInt32Array()
	needed.resize(bins)
	for i in indices.size():
		var bin: int = clampi(int(positions[i] * bins), 0, bins - 1)
		counts[bin] += 1
		var index: int = indices[i]
		if cell_needs(operation, states[index], fertilized[index]):
			needed[bin] += 1
	var result := PackedFloat32Array()
	result.resize(bins)
	for bin in bins:
		result[bin] = float(needed[bin]) / counts[bin] if counts[bin] > 0 else 0.0
	return result


## Liczba komórek pola wymagających pracy.
static func remaining(operation: String, states: PackedByteArray, fertilized: PackedByteArray) -> int:
	var total: int = 0
	for index in states.size():
		if cell_needs(operation, states[index], fertilized[index]):
			total += 1
	return total


## Powód, dla którego zestaw nie może pracować (pusty = może).
static func rig_problem(tool_kind: String, has_work: bool) -> String:
	if tool_kind.is_empty():
		return "Pracownik potrzebuje podpiętego narzędzia roboczego (E podpina)."
	if not has_work:
		return "To narzędzie nie pracuje na polu."
	if not SUPPORTED_TOOLS.has(tool_kind):
		return "Pracownik obsługuje narzędzia zawieszane i jednoosiowe przyczepiane."
	return ""
