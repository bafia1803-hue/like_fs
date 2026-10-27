extends RefCounted
## Tekstura szumu wartości (value noise), powtarzalna (bez szwów), z mipmapami – wspólna dla
## shaderów podłoża (łąka, plac). Zamiast liczyć szum w każdym pikselu ekranu (kilkanaście sinusów
## na piksel), shader czyta gotową teksturę: 1 odczyt na skalę szumu, a mipmapy wygładzają szum
## w oddali (bez migotania).
## Jedna komórka siatki szumu = CELL_PX pikseli, czyli 1/CELLS tekstury: szum o okresie L metrów
## czyta się jako texture(noise, p / (L · CELLS)).

const SIZE_PX: int = 128
const CELLS: int = 16
const CELL_PX: int = SIZE_PX / CELLS

static var _texture: ImageTexture


static func texture() -> ImageTexture:
	if _texture == null:
		_texture = ImageTexture.create_from_image(build_image(20261027))
	return _texture


static func build_image(seed_value: int) -> Image:
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_value
	var lattice := PackedFloat32Array()
	lattice.resize(CELLS * CELLS)
	for i in lattice.size():
		lattice[i] = rng.randf()
	var data := PackedByteArray()
	data.resize(SIZE_PX * SIZE_PX)
	for y in SIZE_PX:
		var cy: int = y / CELL_PX
		var fy: float = float(y % CELL_PX) / CELL_PX
		var uy: float = fy * fy * (3.0 - 2.0 * fy)
		var row0: int = cy * CELLS
		var row1: int = ((cy + 1) % CELLS) * CELLS
		for x in SIZE_PX:
			var cx: int = x / CELL_PX
			var cx1: int = (cx + 1) % CELLS
			var fx: float = float(x % CELL_PX) / CELL_PX
			var ux: float = fx * fx * (3.0 - 2.0 * fx)
			var top: float = lerpf(lattice[row0 + cx], lattice[row0 + cx1], ux)
			var bottom: float = lerpf(lattice[row1 + cx], lattice[row1 + cx1], ux)
			data[y * SIZE_PX + x] = clampi(roundi(lerpf(top, bottom, uy) * 255.0), 0, 255)
	var image := Image.create_from_data(SIZE_PX, SIZE_PX, false, Image.FORMAT_L8, data)
	image.generate_mipmaps()
	return image
