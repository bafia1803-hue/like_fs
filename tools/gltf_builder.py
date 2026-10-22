"""Minimalny zapis low-poly modeli do .glb (glTF 2.0) bez zewnętrznych bibliotek 3D.

Układ współrzędnych modeli (tak jak w Godocie):
  X  w prawo, Y  w górę, -Z  przód maszyny.
  Środek nadwozia leży w (0, 0, 0) na wysokości gruntu.
Punkt 2D gry (x, y) [m] odpowiada punktowi 3D (x, h, y).

Wszystkie bryły są wypukłe i cieniowane płasko (każda ściana ma własną normalną).
Kolory pochodzą z jednej tekstury palety (palette.png), z delikatnym gradientem w pionie.
"""
from __future__ import annotations

import io
import json
import math
import struct
from dataclasses import dataclass, field

import numpy as np
from PIL import Image

# ---------------------------------------------------------------------------
# Paleta: ciepłe, matowe, "cukierkowe" kolory
# ---------------------------------------------------------------------------

PALETTE: dict[str, str] = {
    # Kolor bazowy lakieru. Właściwy kolor maszyny daje materiał "paint" (z machines.json).
    "paint": "#ffffff",
    "tire": "#34302f",
    "tire_side": "#433d3b",
    "rim_cream": "#f3e5c3",
    "rim_grey": "#c4c0b6",
    "rim_red": "#d9573f",
    "metal_dark": "#4d4846",
    "metal": "#8e8983",
    "steel_light": "#cfcac0",
    "glass": "#5f9db3",
    "glass_light": "#8cc3d3",
    "interior": "#3a3230",
    "light_white": "#fff5d6",
    "light_orange": "#ffab3a",
    "light_red": "#e5483d",
    "beacon": "#ffa21f",
    "grain": "#f2c55c",
    "grain_dark": "#dcaa45",
    "straw": "#ead08b",
    "pipe_cream": "#ddd7c5",
    "reel_red": "#d9503f",
    "warn_white": "#f7f1e3",
    "warn_red": "#de4b3c",
    "warn_yellow": "#f5c542",
    "warn_black": "#2f2b2a",
    "trunk": "#8b5a3c",
    "leaf": "#72c04b",
    "leaf_dark": "#4f9a3e",
    "leaf_light": "#98d65d",
    "leaf_yellow": "#c4d65a",
    "barn_red": "#c9533f",
    "barn_red_dark": "#a8432f",
    "roof_dark": "#6e5550",
    "roof_red": "#bf4a3a",
    "wall_cream": "#f4e7ca",
    "wood": "#b57d4c",
    "wood_dark": "#8a5a36",
    "concrete": "#cdc6ba",
    "concrete_dark": "#a9a297",
    "silo_steel": "#d9d6cf",
    "silo_band": "#aaa59c",
    "cloud": "#ffffff",
    "cloud_shade": "#e9f1f7",
    "door_white": "#fbf6ea",
    "black": "#2b2a2e",
}

SWATCH = 32           # rozmiar pojedynczego pola palety (px)
GRID = 8              # 8 x 8 pól = 256 x 256 px
_NAMES = list(PALETTE.keys())
assert len(_NAMES) <= GRID * GRID


def _hex(color: str) -> np.ndarray:
    color = color.lstrip("#")
    return np.array([int(color[i:i + 2], 16) for i in (0, 2, 4)], dtype=np.float64)


def palette_image() -> Image.Image:
    """Tekstura palety: każde pole ma pionowy gradient (jaśniej u góry)."""
    img = np.zeros((GRID * SWATCH, GRID * SWATCH, 3), dtype=np.float64)
    for index, name in enumerate(_NAMES):
        col, row = index % GRID, index // GRID
        base = _hex(PALETTE[name])
        for y in range(SWATCH):
            t = y / (SWATCH - 1)            # 0 = góra pola
            shade = 1.06 - 0.14 * t          # +6% u góry, -8% u dołu
            value = np.clip(base * shade, 0, 255)
            img[row * SWATCH + y, col * SWATCH:(col + 1) * SWATCH] = value
    return Image.fromarray(img.astype(np.uint8), "RGB")


def swatch_uv(name: str, t: float) -> tuple[float, float]:
    """UV wewnątrz pola palety; t: 0 = góra bryły, 1 = dół."""
    index = _NAMES.index(name)
    col, row = index % GRID, index // GRID
    size = GRID * SWATCH
    u = (col * SWATCH + SWATCH * 0.5) / size
    inner = 0.25 + 0.5 * min(max(t, 0.0), 1.0)     # środkowa połowa pola: brak przenikania kolorów
    v = (row * SWATCH + SWATCH * inner) / size
    return u, v


# ---------------------------------------------------------------------------
# Siatki
# ---------------------------------------------------------------------------

MATERIALS = {
    # nazwa: (roughness, baseColorFactor)
    "atlas": (0.92, (1.0, 1.0, 1.0, 1.0)),
    "paint": (0.85, (1.0, 1.0, 1.0, 1.0)),   # kolor nadpisywany kolorem maszyny
    "glass": (0.35, (1.0, 1.0, 1.0, 1.0)),
}


@dataclass
class MeshData:
    name: str
    # material -> listy wierzchołków
    prims: dict = field(default_factory=dict)

    def _prim(self, material: str) -> dict:
        if material not in self.prims:
            self.prims[material] = {"pos": [], "nrm": [], "uv": []}
        return self.prims[material]

    def polygon(self, material: str, swatch: str, points, centroid, yrange) -> None:
        pts = [np.asarray(p, dtype=np.float64) for p in points]
        # usuń zdublowane punkty (bryły zdegenerowane, np. klin)
        clean = []
        for p in pts:
            if not clean or np.linalg.norm(p - clean[-1]) > 1e-7:
                clean.append(p)
        if len(clean) > 2 and np.linalg.norm(clean[0] - clean[-1]) < 1e-7:
            clean.pop()
        if len(clean) < 3:
            return
        normal = np.zeros(3)
        for i in range(len(clean)):           # metoda Newella, odporna na lekką niepłaskość
            a, b = clean[i], clean[(i + 1) % len(clean)]
            normal += np.array([
                (a[1] - b[1]) * (a[2] + b[2]),
                (a[2] - b[2]) * (a[0] + b[0]),
                (a[0] - b[0]) * (a[1] + b[1]),
            ])
        length = np.linalg.norm(normal)
        if length < 1e-10:
            return
        normal /= length
        face_center = np.mean(clean, axis=0)
        if np.dot(normal, face_center - np.asarray(centroid)) < 0.0:
            clean.reverse()
            normal = -normal
        y0, y1 = yrange
        span = max(y1 - y0, 1e-6)
        prim = self._prim(material)
        for i in range(1, len(clean) - 1):
            for p in (clean[0], clean[i], clean[i + 1]):
                prim["pos"].append(p)
                prim["nrm"].append(normal)
                prim["uv"].append(swatch_uv(swatch, 1.0 - (p[1] - y0) / span))

    def merge(self, other: "MeshData", matrix: np.ndarray | None = None) -> None:
        for material, prim in other.prims.items():
            target = self._prim(material)
            for p, n, uv in zip(prim["pos"], prim["nrm"], prim["uv"]):
                if matrix is not None:
                    p = (matrix @ np.append(p, 1.0))[:3]
                    n = matrix[:3, :3] @ n
                    n = n / np.linalg.norm(n)
                target["pos"].append(p)
                target["nrm"].append(n)
                target["uv"].append(uv)

    def is_empty(self) -> bool:
        return not any(prim["pos"] for prim in self.prims.values())


def _material_for(swatch: str) -> str:
    if swatch == "paint":
        return "paint"
    if swatch.startswith("glass"):
        return "glass"
    return "atlas"


def hexa(mesh: MeshData, swatch: str, P) -> None:
    """Bryła o 8 wierzchołkach: 0-3 podstawa, 4-7 góra (w tej samej kolejności)."""
    P = [np.asarray(p, dtype=np.float64) for p in P]
    centroid = np.mean(P, axis=0)
    ys = [p[1] for p in P]
    yr = (min(ys), max(ys))
    faces = [[0, 1, 2, 3], [4, 5, 6, 7], [0, 1, 5, 4], [1, 2, 6, 5], [2, 3, 7, 6], [3, 0, 4, 7]]
    material = _material_for(swatch)
    for face in faces:
        mesh.polygon(material, swatch, [P[i] for i in face], centroid, yr)


def box(mesh: MeshData, swatch: str, x0, x1, y0, y1, z0, z1, matrix=None) -> None:
    P = [(x0, y0, z0), (x1, y0, z0), (x1, y0, z1), (x0, y0, z1),
         (x0, y1, z0), (x1, y1, z0), (x1, y1, z1), (x0, y1, z1)]
    if matrix is not None:
        P = [(matrix @ np.append(np.asarray(p, float), 1.0))[:3] for p in P]
    hexa(mesh, swatch, P)


def frustum(mesh: MeshData, swatch: str, bottom, top) -> None:
    """bottom/top: (x0, x1, z0, z1, y)."""
    bx0, bx1, bz0, bz1, by = bottom
    tx0, tx1, tz0, tz1, ty = top
    hexa(mesh, swatch, [(bx0, by, bz0), (bx1, by, bz0), (bx1, by, bz1), (bx0, by, bz1),
                        (tx0, ty, tz0), (tx1, ty, tz0), (tx1, ty, tz1), (tx0, ty, tz1)])


def beam(mesh: MeshData, swatch: str, a, b, width: float, height: float, up=(0.0, 1.0, 0.0)) -> None:
    """Prostopadłościenna belka między punktami a i b."""
    a = np.asarray(a, float)
    b = np.asarray(b, float)
    axis = b - a
    axis_len = np.linalg.norm(axis)
    if axis_len < 1e-6:
        return
    d = axis / axis_len
    up = np.asarray(up, float)
    if abs(np.dot(up, d)) > 0.95:
        up = np.array([1.0, 0.0, 0.0]) if abs(d[0]) < 0.9 else np.array([0.0, 0.0, 1.0])
    side = np.cross(d, up)
    side /= np.linalg.norm(side)
    top = np.cross(side, d)
    hw, hh = width / 2.0, height / 2.0
    corners = []
    for p in (a, b):
        corners.append([p - side * hw - top * hh, p + side * hw - top * hh,
                        p + side * hw + top * hh, p - side * hw + top * hh])
    P = [corners[0][0], corners[0][1], corners[1][1], corners[1][0],
         corners[0][3], corners[0][2], corners[1][2], corners[1][3]]
    hexa(mesh, swatch, P)


def cylinder(mesh: MeshData, swatch: str, center, axis: str, radius: float, length: float,
             sides: int = 12, radius_end: float | None = None, phase: float = 0.0,
             cap_swatch: str | None = None) -> None:
    """Graniastosłup/stożek ścięty wzdłuż osi x, y lub z. radius_end: promień na końcu +osi."""
    c = np.asarray(center, float)
    r0 = radius
    r1 = radius if radius_end is None else radius_end
    half = length / 2.0
    ring0, ring1 = [], []
    for i in range(sides):
        angle = phase + 2.0 * math.pi * i / sides
        ca, sa = math.cos(angle), math.sin(angle)
        if axis == "x":
            ring0.append(c + np.array([-half, ca * r0, sa * r0]))
            ring1.append(c + np.array([half, ca * r1, sa * r1]))
        elif axis == "y":
            ring0.append(c + np.array([ca * r0, -half, sa * r0]))
            ring1.append(c + np.array([ca * r1, half, sa * r1]))
        else:
            ring0.append(c + np.array([ca * r0, sa * r0, -half]))
            ring1.append(c + np.array([ca * r1, sa * r1, half]))
    pts = ring0 + ring1
    ys = [p[1] for p in pts]
    yr = (min(ys), max(ys))
    material = _material_for(swatch)
    for i in range(sides):
        j = (i + 1) % sides
        mesh.polygon(material, swatch, [ring0[i], ring0[j], ring1[j], ring1[i]], c, yr)
    cap = cap_swatch or swatch
    cap_material = _material_for(cap)
    if r0 > 1e-6:
        mesh.polygon(cap_material, cap, ring0, c, yr)
    if r1 > 1e-6:
        mesh.polygon(cap_material, cap, ring1, c, yr)


def arc_x(mesh: MeshData, swatch: str, center_zy, x0: float, x1: float, radius: float,
          thickness: float, a0: float, a1: float, segments: int) -> None:
    """Łuk (błotnik) wokół osi X. Kąt 0 = przód (-Z), 90 = góra, 180 = tył (+Z)."""
    zc, yc = center_zy
    for i in range(segments):
        aa = math.radians(a0 + (a1 - a0) * i / segments)
        ab = math.radians(a0 + (a1 - a0) * (i + 1) / segments)
        inner_a = (zc - math.cos(aa) * radius, yc + math.sin(aa) * radius)
        inner_b = (zc - math.cos(ab) * radius, yc + math.sin(ab) * radius)
        outer_a = (zc - math.cos(aa) * (radius + thickness), yc + math.sin(aa) * (radius + thickness))
        outer_b = (zc - math.cos(ab) * (radius + thickness), yc + math.sin(ab) * (radius + thickness))
        P = [(x0, inner_a[1], inner_a[0]), (x1, inner_a[1], inner_a[0]),
             (x1, inner_b[1], inner_b[0]), (x0, inner_b[1], inner_b[0]),
             (x0, outer_a[1], outer_a[0]), (x1, outer_a[1], outer_a[0]),
             (x1, outer_b[1], outer_b[0]), (x0, outer_b[1], outer_b[0])]
        hexa(mesh, swatch, P)


def rot_x(angle: float) -> np.ndarray:
    c, s = math.cos(angle), math.sin(angle)
    m = np.eye(4)
    m[1, 1], m[1, 2], m[2, 1], m[2, 2] = c, -s, s, c
    return m


def rot_y(angle: float) -> np.ndarray:
    c, s = math.cos(angle), math.sin(angle)
    m = np.eye(4)
    m[0, 0], m[0, 2], m[2, 0], m[2, 2] = c, s, -s, c
    return m


def translate(x: float, y: float, z: float) -> np.ndarray:
    m = np.eye(4)
    m[:3, 3] = (x, y, z)
    return m


# ---------------------------------------------------------------------------
# Węzły i zapis GLB
# ---------------------------------------------------------------------------

@dataclass
class Node:
    name: str
    translation: tuple = (0.0, 0.0, 0.0)
    rotation: tuple = (0.0, 0.0, 0.0, 1.0)   # kwaternion x, y, z, w
    mesh: MeshData | None = None
    children: list = field(default_factory=list)

    def add(self, child: "Node") -> "Node":
        self.children.append(child)
        return child


def write_glb(path: str, root: Node, paint_color: str = "#ffffff") -> None:
    gltf: dict = {
        "asset": {"version": "2.0", "generator": "like_fs tools/generate_models.py"},
        "scene": 0,
        "scenes": [{"nodes": [0], "name": root.name}],
        "nodes": [], "meshes": [], "accessors": [], "bufferViews": [],
        "materials": [], "textures": [], "images": [], "samplers": [],
        "buffers": [],
    }
    blob = bytearray()

    def align() -> None:
        while len(blob) % 4:
            blob.append(0)

    def add_view(data: bytes, target: int | None = None) -> int:
        align()
        offset = len(blob)
        blob.extend(data)
        view = {"buffer": 0, "byteOffset": offset, "byteLength": len(data)}
        if target is not None:
            view["target"] = target
        gltf["bufferViews"].append(view)
        return len(gltf["bufferViews"]) - 1

    # tekstura palety
    png = io.BytesIO()
    palette_image().save(png, "PNG")
    image_view = add_view(png.getvalue())
    gltf["images"].append({"bufferView": image_view, "mimeType": "image/png", "name": "palette"})
    gltf["samplers"].append({"magFilter": 9729, "minFilter": 9987, "wrapS": 33071, "wrapT": 33071})
    gltf["textures"].append({"source": 0, "sampler": 0})

    # baseColorFactor w glTF jest liniowy, a kolory w JSON są w sRGB
    srgb = _hex(paint_color) / 255.0
    paint_rgb = np.where(srgb <= 0.04045, srgb / 12.92, ((srgb + 0.055) / 1.055) ** 2.4)
    material_index = {}
    for name, (roughness, factor) in MATERIALS.items():
        color = list(factor)
        if name == "paint":
            color = [float(paint_rgb[0]), float(paint_rgb[1]), float(paint_rgb[2]), 1.0]
        gltf["materials"].append({
            "name": name,
            "pbrMetallicRoughness": {
                "baseColorTexture": {"index": 0},
                "baseColorFactor": color,
                "metallicFactor": 0.0,
                "roughnessFactor": roughness,
            },
        })
        material_index[name] = len(gltf["materials"]) - 1

    mesh_cache: dict[int, int] = {}

    def add_mesh(mesh: MeshData) -> int:
        key = id(mesh)
        if key in mesh_cache:
            return mesh_cache[key]
        primitives = []
        for material, prim in mesh.prims.items():
            if not prim["pos"]:
                continue
            pos = np.asarray(prim["pos"], dtype=np.float32)
            nrm = np.asarray(prim["nrm"], dtype=np.float32)
            uv = np.asarray(prim["uv"], dtype=np.float32)
            count = len(pos)
            idx = np.arange(count, dtype=np.uint32)
            accessors = {}
            view = add_view(pos.tobytes(), 34962)
            gltf["accessors"].append({"bufferView": view, "componentType": 5126, "count": count, "type": "VEC3",
                                      "min": pos.min(axis=0).tolist(), "max": pos.max(axis=0).tolist()})
            accessors["POSITION"] = len(gltf["accessors"]) - 1
            view = add_view(nrm.tobytes(), 34962)
            gltf["accessors"].append({"bufferView": view, "componentType": 5126, "count": count, "type": "VEC3"})
            accessors["NORMAL"] = len(gltf["accessors"]) - 1
            view = add_view(uv.tobytes(), 34962)
            gltf["accessors"].append({"bufferView": view, "componentType": 5126, "count": count, "type": "VEC2"})
            accessors["TEXCOORD_0"] = len(gltf["accessors"]) - 1
            view = add_view(idx.tobytes(), 34963)
            gltf["accessors"].append({"bufferView": view, "componentType": 5125, "count": count, "type": "SCALAR"})
            primitives.append({"attributes": accessors, "indices": len(gltf["accessors"]) - 1,
                               "material": material_index[material], "mode": 4})
        gltf["meshes"].append({"name": mesh.name, "primitives": primitives})
        mesh_cache[key] = len(gltf["meshes"]) - 1
        return mesh_cache[key]

    def add_node(node: Node) -> int:
        index = len(gltf["nodes"])
        entry: dict = {"name": node.name}
        gltf["nodes"].append(entry)
        if any(abs(v) > 1e-9 for v in node.translation):
            entry["translation"] = [float(v) for v in node.translation]
        if tuple(node.rotation) != (0.0, 0.0, 0.0, 1.0):
            entry["rotation"] = [float(v) for v in node.rotation]
        if node.mesh is not None and not node.mesh.is_empty():
            entry["mesh"] = add_mesh(node.mesh)
        children = [add_node(child) for child in node.children]
        if children:
            entry["children"] = children
        return index

    add_node(root)
    align()
    gltf["buffers"].append({"byteLength": len(blob)})
    json_bytes = json.dumps(gltf, separators=(",", ":")).encode("utf-8")
    while len(json_bytes) % 4:
        json_bytes += b" "
    total = 12 + 8 + len(json_bytes) + 8 + len(blob)
    with open(path, "wb") as handle:
        handle.write(struct.pack("<4sII", b"glTF", 2, total))
        handle.write(struct.pack("<I4s", len(json_bytes), b"JSON"))
        handle.write(json_bytes)
        handle.write(struct.pack("<I4s", len(blob), b"BIN\x00"))
        handle.write(bytes(blob))


def count_triangles(node: Node) -> int:
    total = 0
    if node.mesh is not None:
        total += sum(len(p["pos"]) for p in node.mesh.prims.values()) // 3
    return total + sum(count_triangles(child) for child in node.children)
