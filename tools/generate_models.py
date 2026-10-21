"""Generuje low-poly modele 3D (.glb) maszyn i otoczenia na podstawie files/*.json.

Uruchomienie (z katalogu projektu):
    python tools/generate_models.py

Wymaga: Python 3.10+, numpy, Pillow.

Wymiary, osie, koła, zaczepy i rura kombajnu są czytane z files/machines.json,
więc po zmianie katalogu maszyn wystarczy ponownie uruchomić skrypt.

Konwencja nazw węzłów, z której korzysta gra (scripts/machine_view_3d.gd):
  steer_<oś>_L / steer_<oś>_R   – zwrotnica koła skrętnego (obrót wokół Y)
  spin_<oś>_L  / spin_<oś>_R    – obracające się koło (obrót wokół X)
  carriage                      – przedni wózek przyczepy (obrotnica)
  tipper                        – skrzynia przyczepy, zawias z tyłu (wywrot)
  tailgate                      – tylna klapa skrzyni, zawias u góry
  pipe                          – rura rozładunkowa kombajnu (obrót wokół Y)
  grain_fill                    – usypany ładunek, skalowany w osi Y wg zapełnienia
  reel                          – motowidło hedera
  roller                        – wał doprawiający kultywatora
"""
from __future__ import annotations

import json
import math
import os
import sys

import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from gltf_builder import (MeshData, Node, arc_x, beam, box, count_triangles, cylinder,  # noqa: E402
                          frustum, hexa, palette_image, rot_x, translate, write_glb)

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT_MACHINES = os.path.join(ROOT, "models", "machines")
OUT_WORLD = os.path.join(ROOT, "models", "world")


def load(name: str) -> dict:
    with open(os.path.join(ROOT, "files", name), encoding="utf-8") as handle:
        return json.load(handle)


def axle_z(model: dict, axle: dict) -> float:
    return -float(model["dimensions"]["length_m"]) / 2.0 + float(axle["distance_from_front_m"])


# ---------------------------------------------------------------------------
# Koła
# ---------------------------------------------------------------------------

_wheel_cache: dict = {}


def wheel_mesh(radius: float, width: float, rim: str, lugs: int) -> MeshData:
    key = (round(radius, 3), round(width, 3), rim, lugs)
    if key in _wheel_cache:
        return _wheel_cache[key]
    mesh = MeshData(f"wheel_{int(radius * 200)}_{int(width * 100)}")
    sides = 16 if radius > 0.55 else 14
    tire_r = radius - (0.05 if lugs else 0.0)
    cylinder(mesh, "tire", (0, 0, 0), "x", tire_r, width, sides, cap_swatch="tire_side")
    # obręcz trochę wystaje z opony z obu stron
    cylinder(mesh, rim, (0, 0, 0), "x", radius * 0.58, width + 0.03, sides)
    cylinder(mesh, "metal_dark", (0, 0, 0), "x", radius * 0.36, width + 0.05, 8)
    cylinder(mesh, rim, (0, 0, 0), "x", radius * 0.2, width + 0.09, 8)
    # 5 śrub piasty – widać obrót koła
    for side in (-1, 1):
        for i in range(5):
            a = 2 * math.pi * i / 5
            cy, cz = math.cos(a) * radius * 0.28, math.sin(a) * radius * 0.28
            x = side * (width / 2 + 0.03)
            box(mesh, "steel_light", x - 0.012, x + 0.012, cy - 0.022, cy + 0.022, cz - 0.022, cz + 0.022)
    if lugs:
        half = width / 2.0
        for i in range(lugs):
            for side in (-1, 1):
                angle = 2 * math.pi * (i + (0.5 if side > 0 else 0.0)) / lugs
                x0, x1 = (-half + 0.02, -0.02) if side < 0 else (0.02, half - 0.02)
                m = rot_x(angle)
                box(mesh, "tire", x0, x1, tire_r - 0.02, radius, -0.045, 0.045, matrix=m)
    _wheel_cache[key] = mesh
    return mesh


def add_axles(root: Node, model: dict, rims: dict, lug_axles: set, fender=None,
              member: str = "body", parent: Node | None = None, z_override: float | None = None) -> None:
    """Dodaje koła wszystkich osi danego członu maszyny."""
    parent = parent or root
    for axle in model["axles"]:
        if str(axle.get("body_member", "body")) != member:
            continue
        radius = float(axle["tire_length_m"]) / 2.0
        width = float(axle["tire_width_m"])
        half_track = float(axle["track_m"]) / 2.0
        z = axle_z(model, axle) if z_override is None else z_override
        lugs = 18 if axle["id"] in lug_axles else 0
        mesh = wheel_mesh(radius, width, rims.get(axle["id"], "rim_grey"), lugs)
        steerable = bool(axle.get("steerable")) and float(axle.get("max_steering_deg", 0.0)) > 0.0
        for side, suffix in ((-1, "L"), (1, "R")):
            pos = (side * half_track, radius, z)
            if steerable:
                steer = parent.add(Node(f"steer_{axle['id']}_{suffix}", pos))
                steer.add(Node(f"spin_{axle['id']}_{suffix}", mesh=mesh))
                if fender:
                    fender(steer, axle, side, local=True)
            else:
                parent.add(Node(f"spin_{axle['id']}_{suffix}", pos, mesh=mesh))
                if fender:
                    fender(parent, axle, side, local=False)


def fender_mesh(name: str, radius: float, width: float, swatch: str, a0=18.0, a1=162.0,
                segments=6, thickness=0.06) -> MeshData:
    mesh = MeshData(name)
    arc_x(mesh, swatch, (0.0, 0.0), -width / 2, width / 2, radius, thickness, a0, a1, segments)
    return mesh


def lamp(mesh: MeshData, swatch: str, x: float, y: float, z: float, sx=0.07, sy=0.05, sz=0.03) -> None:
    box(mesh, swatch, x - sx, x + sx, y - sy, y + sy, z - sz, z + sz)


def cab(mesh: MeshData, x0, x1, y0, y1, z0, z1, roof_extra=0.08, belt=0.32) -> None:
    """Kabina: dolny panel, szyby, słupki, dach."""
    post = 0.07
    box(mesh, "paint", x0, x1, y0, y0 + belt, z0, z1)
    box(mesh, "glass", x0 + 0.015, x1 - 0.015, y0 + belt, y1, z0 + 0.015, z1 - 0.015)
    for x in (x0, x1 - post):
        for z in (z0, z1 - post):
            box(mesh, "paint", x, x + post, y0, y1, z, z + post)
    # słupki środkowe (drzwi)
    zm = (z0 + z1) / 2
    for x in (x0, x1 - post):
        box(mesh, "paint", x - 0.005, x + post + 0.005, y0 + belt, y1, zm - 0.03, zm + 0.03)
    # rama okien u góry
    box(mesh, "paint", x0, x1, y1 - 0.06, y1, z0, z1)
    frustum(mesh, "paint", (x0 - roof_extra, x1 + roof_extra, z0 - roof_extra, z1 + roof_extra, y1),
            (x0 - roof_extra + 0.05, x1 + roof_extra - 0.05, z0 - roof_extra + 0.05, z1 + roof_extra - 0.05, y1 + 0.16))
    frustum(mesh, "paint", (x0 - roof_extra + 0.05, x1 + roof_extra - 0.05, z0 - roof_extra + 0.05, z1 + roof_extra - 0.05, y1 + 0.16),
            (x0 + 0.05, x1 - 0.05, z0 + 0.05, z1 - 0.05, y1 + 0.22))


def grain_heap(name: str, x0, x1, z0, z1, height: float, dome: float) -> MeshData:
    """Usypane ziarno o podstawie y=0; pełna wysokość = height + dome."""
    mesh = MeshData(name)
    box(mesh, "grain", x0, x1, 0.0, height, z0, z1)
    inset_x = (x1 - x0) * 0.22
    inset_z = (z1 - z0) * 0.12
    frustum(mesh, "grain", (x0, x1, z0, z1, height),
            (x0 + inset_x, x1 - inset_x, z0 + inset_z, z1 - inset_z, height + dome))
    return mesh


def a_frame(mesh: MeshData, swatch: str, left, right, tip, width=0.1, height=0.1) -> None:
    beam(mesh, swatch, left, tip, width, height)
    beam(mesh, swatch, right, tip, width, height)


def tow_eye(mesh: MeshData, x: float, y: float, z: float) -> None:
    cylinder(mesh, "steel_light", (x, y, z), "y", 0.085, 0.07, 10)
    cylinder(mesh, "metal_dark", (x, y, z), "y", 0.04, 0.09, 6)


# ---------------------------------------------------------------------------
# Ciągnik
# ---------------------------------------------------------------------------

def build_tractor(model: dict) -> Node:
    root = Node(model["id"])
    body = MeshData("tractor_body")
    front = next(a for a in model["axles"] if a["id"] == "front")
    rear = next(a for a in model["axles"] if a["id"] == "rear")
    zf, zr = axle_z(model, front), axle_z(model, rear)
    rf, rr = float(front["tire_length_m"]) / 2, float(rear["tire_length_m"]) / 2
    half_len = float(model["dimensions"]["length_m"]) / 2

    # rama i oś przednia
    box(body, "metal_dark", -0.36, 0.36, 0.3, 0.62, -half_len + 0.15, zr - 0.25)
    box(body, "metal_dark", -float(front["track_m"]) / 2 + 0.12, float(front["track_m"]) / 2 - 0.12,
        rf - 0.07, rf + 0.07, zf - 0.08, zf + 0.08)
    # obciążnik z przodu
    box(body, "metal_dark", -0.42, 0.42, 0.34, 0.78, -half_len, -half_len + 0.2)
    for i in range(4):
        y = 0.38 + i * 0.1
        box(body, "metal", -0.43, 0.43, y, y + 0.06, -half_len - 0.01, -half_len + 0.21)
    # maska silnika
    hood_front = -half_len + 0.2
    frustum(body, "paint", (-0.46, 0.46, hood_front, -0.12, 0.6), (-0.41, 0.41, hood_front + 0.08, -0.12, 1.42))
    frustum(body, "paint", (-0.41, 0.41, hood_front + 0.08, -0.12, 1.42), (-0.32, 0.32, hood_front + 0.14, -0.12, 1.52))
    # atrapa i lampy
    box(body, "metal_dark", -0.34, 0.34, 0.66, 1.3, hood_front - 0.03, hood_front + 0.02)
    for i in range(4):
        y = 0.76 + i * 0.13
        box(body, "steel_light", -0.3, 0.3, y, y + 0.04, hood_front - 0.045, hood_front - 0.02)
    lamp(body, "light_white", -0.3, 1.36, hood_front + 0.05, 0.07, 0.045, 0.04)
    lamp(body, "light_white", 0.3, 1.36, hood_front + 0.05, 0.07, 0.045, 0.04)
    # pasek boczny maski
    for side in (-1, 1):
        x = side * 0.445
        box(body, "metal_dark", x - 0.02, x + 0.02, 0.95, 1.12, hood_front + 0.35, -0.3)
    # skrzynia biegów pod kabiną
    box(body, "metal_dark", -0.55, 0.55, 0.55, 1.25, -0.2, zr + 0.35)
    # kabina
    cab(body, -0.62, 0.62, 1.25, 2.55, -0.05, zr + 0.2)
    lamp(body, "light_white", -0.45, 2.72, -0.12, 0.08, 0.04, 0.03)
    lamp(body, "light_white", 0.45, 2.72, -0.12, 0.08, 0.04, 0.03)
    box(body, "beacon", -0.09, 0.09, 2.77, 2.9, zr - 0.15, zr + 0.03)
    # lusterka
    for side in (-1, 1):
        beam(body, "metal_dark", (side * 0.62, 2.3, 0.0), (side * 0.9, 2.3, -0.06), 0.03, 0.03)
        box(body, "metal_dark", side * 0.9 - 0.03, side * 0.9 + 0.03, 2.12, 2.42, -0.1, -0.03)
    # wydech
    cylinder(body, "metal_dark", (0.3, 2.05, -0.38), "y", 0.055, 1.25, 8)
    cylinder(body, "black", (0.3, 2.7, -0.38), "y", 0.065, 0.06, 8)
    # stopnie
    for i, y in enumerate((0.55, 0.85)):
        box(body, "metal_dark", -0.78, -0.62, y, y + 0.04, 0.35, 0.7)
    # błotniki tylnych kół
    half_track_r = float(rear["track_m"]) / 2
    wr = float(rear["tire_width_m"])
    for side in (-1, 1):
        cx = side * half_track_r
        arc_x(body, "paint", (zr, rr), cx - wr / 2 - 0.05, cx + wr / 2 + 0.05, rr + 0.07, 0.06, 12, 168, 8)
        lamp(body, "light_red", cx, rr + 0.35, zr + rr + 0.1, 0.06, 0.05, 0.03)
        lamp(body, "light_orange", cx + side * 0.17, rr + 0.35, zr + rr + 0.1, 0.04, 0.05, 0.03)
    # zaczep tylny
    hitch = next(p for p in model["hitch_ports"] if p["role"] == "socket")
    hz = float(hitch["position_m"][1])
    box(body, "metal_dark", -0.09, 0.09, 0.42, 0.52, zr + 0.4, hz + 0.05)
    cylinder(body, "steel_light", (0.0, 0.47, hz), "y", 0.035, 0.22, 8)
    box(body, "metal_dark", -0.32, 0.32, 0.55, 0.75, zr + 0.45, zr + 0.62)
    root.mesh = body

    def front_fender(parent: Node, axle: dict, side: int, local: bool) -> None:
        if axle["id"] != "front":
            return
        r = float(axle["tire_length_m"]) / 2
        w = float(axle["tire_width_m"])
        parent.add(Node(f"fender_{axle['id']}_{'L' if side < 0 else 'R'}",
                        mesh=fender_mesh("front_fender", r + 0.06, w + 0.08, "paint", 25, 150, 5)))

    add_axles(root, model, {"front": "rim_cream", "rear": "rim_cream"}, {"front", "rear"}, front_fender)
    return root


# ---------------------------------------------------------------------------
# Przyczepa dwuosiowa
# ---------------------------------------------------------------------------

def build_trailer(model: dict) -> Node:
    root = Node(model["id"])
    length = float(model["dimensions"]["length_m"])
    width = float(model["dimensions"]["width_m"])
    hl, hw = length / 2, width / 2
    carriage_data = model["front_carriage"]
    pivot = carriage_data["pivot_in_body_m"]
    pz = float(pivot[1])
    rear = next(a for a in model["axles"] if a["id"] != carriage_data["axle_id"])
    front = next(a for a in model["axles"] if a["id"] == carriage_data["axle_id"])
    zr = axle_z(model, rear)
    rr = float(rear["tire_length_m"]) / 2
    rf = float(front["tire_length_m"]) / 2
    floor_y = max(rr, rf) + 0.62

    body = MeshData("trailer_chassis")
    for side in (-1, 1):
        box(body, "metal_dark", side * 0.45 - 0.08, side * 0.45 + 0.08, floor_y - 0.3, floor_y - 0.08, -hl + 0.2, hl - 0.15)
    for z in (-hl + 0.3, -0.4, 0.6, hl - 0.25):
        box(body, "metal_dark", -0.55, 0.55, floor_y - 0.26, floor_y - 0.1, z - 0.06, z + 0.06)
    # oś tylna z resorami
    box(body, "metal_dark", -float(rear["track_m"]) / 2 + 0.1, float(rear["track_m"]) / 2 - 0.1,
        rr - 0.07, rr + 0.07, zr - 0.07, zr + 0.07)
    for side in (-1, 1):
        box(body, "metal", side * 0.5 - 0.06, side * 0.5 + 0.06, rr + 0.07, floor_y - 0.3, zr - 0.45, zr + 0.45)
    # górny pierścień obrotnicy
    cylinder(body, "metal_dark", (0, floor_y - 0.33, pz), "y", 0.6, 0.06, 14)
    # błotniki tylne
    for side in (-1, 1):
        cx = side * float(rear["track_m"]) / 2
        w = float(rear["tire_width_m"])
        arc_x(body, "metal_dark", (zr, rr), cx - w / 2 - 0.04, cx + w / 2 + 0.04, rr + 0.05, 0.05, 15, 165, 6)
    # belka świateł z tyłu
    box(body, "metal_dark", -0.98, 0.98, floor_y - 0.3, floor_y - 0.14, hl - 0.12, hl - 0.02)
    for side in (-1, 1):
        lamp(body, "light_red", side * 0.82, floor_y - 0.22, hl + 0.0, 0.08, 0.05, 0.03)
        lamp(body, "light_orange", side * 0.65, floor_y - 0.22, hl + 0.0, 0.05, 0.05, 0.03)
    root.mesh = body

    # skrzynia ładunkowa: zawias z tyłu, do późniejszej animacji wywrotu
    hinge = (0.0, floor_y, hl - 0.05)
    tipper = root.add(Node("tipper", hinge))
    box_mesh = MeshData("trailer_box")
    wall_h = 0.78
    T = translate(-hinge[0], -hinge[1], -hinge[2])

    def tbox(sw, x0, x1, y0, y1, z0, z1):
        box(box_mesh, sw, x0, x1, y0, y1, z0, z1, matrix=T)

    bl, br = -hl + 0.05, hl - 0.05      # długość skrzyni
    tbox("metal", -hw + 0.03, hw - 0.03, floor_y, floor_y + 0.08, bl, br)
    for side in (-1, 1):
        x_out, x_in = side * (hw - 0.02), side * (hw - 0.09)
        tbox("paint", min(x_in, x_out), max(x_in, x_out), floor_y + 0.08, floor_y + wall_h, bl, br)
        # wzmocnienia (żebra)
        for z in np.linspace(bl + 0.35, br - 0.35, 5):
            xo = side * (hw + 0.02)
            tbox("paint", min(x_out, xo), max(x_out, xo), floor_y + 0.08, floor_y + wall_h, z - 0.05, z + 0.05)
        # górna krawędź
        xr = side * (hw + 0.035)
        tbox("paint", min(x_in, xr), max(x_in, xr), floor_y + wall_h - 0.05, floor_y + wall_h + 0.04, bl - 0.02, br + 0.02)
        # dolny pas
        tbox("metal_dark", min(x_in, xr), max(x_in, xr), floor_y, floor_y + 0.1, bl, br)
    tbox("paint", -hw + 0.02, hw - 0.02, floor_y + 0.08, floor_y + wall_h + 0.04, bl, bl + 0.07)          # przód
    tipper.mesh = box_mesh
    # tylna klapa: osobny węzeł z zawiasem u góry, odchyla się przy wysypie
    gate_hinge = (0.0, floor_y + wall_h + 0.04, br - 0.035)
    gate = MeshData("trailer_tailgate")
    G = translate(-gate_hinge[0], -gate_hinge[1], -gate_hinge[2])

    def gbox(sw, x0, x1, y0, y1, z0, z1):
        box(gate, sw, x0, x1, y0, y1, z0, z1, matrix=G)

    gbox("paint", -hw + 0.1, hw - 0.1, floor_y + 0.09, floor_y + wall_h + 0.03, br - 0.07, br)
    for x in (-0.6, 0.0, 0.6):
        gbox("paint", x - 0.05, x + 0.05, floor_y + 0.09, floor_y + wall_h, br, br + 0.04)
    # trójkąt wyróżniający pojazd wolnobieżny
    tri_y, tri_z = floor_y + 0.38, br + 0.045
    pts = [(-0.2, tri_y - 0.16, tri_z), (0.2, tri_y - 0.16, tri_z), (0.0, tri_y + 0.2, tri_z)]
    pts_back = [(p[0], p[1], p[2] - 0.02) for p in pts]
    hexa(gate, "warn_red", [np.array(p) - np.array(gate_hinge) for p in
                            (pts_back[0], pts_back[1], pts_back[2], pts_back[2], pts[0], pts[1], pts[2], pts[2])])
    tipper.add(Node("tailgate", tuple(np.array(gate_hinge) - np.array(hinge)), mesh=gate))
    # słupki klapy na stałe przy skrzyni
    for side in (-1, 1):
        x = side * (hw - 0.055)
        tbox("paint", x - 0.045, x + 0.045, floor_y + 0.08, floor_y + wall_h + 0.04, br - 0.07, br)
    inner_h = wall_h - 0.08
    fill = grain_heap("trailer_grain", -hw + 0.1, hw - 0.1, bl + 0.08, br - 0.08, inner_h - 0.12, 0.2)
    tipper.add(Node("grain_fill", (-hinge[0], floor_y + 0.08 - hinge[1], -hinge[2]), mesh=fill))

    # przedni wózek z obrotnicą i dyszlem
    carriage = root.add(Node("carriage", (0.0, 0.0, pz)))
    cmesh = MeshData("trailer_carriage")
    cylinder(cmesh, "metal_dark", (0, floor_y - 0.39, 0), "y", 0.58, 0.06, 14)
    box(cmesh, "metal_dark", -0.4, 0.4, rf + 0.05, floor_y - 0.42, -0.3, 0.3)
    box(cmesh, "metal_dark", -float(front["track_m"]) / 2 + 0.1, float(front["track_m"]) / 2 - 0.1,
        rf - 0.07, rf + 0.07, -0.07, 0.07)
    plug = next(p for p in model["hitch_ports"] if p["role"] == "plug")
    eye_z = float(plug["position_m"][1])
    y_bar = rf + 0.08
    a_frame(cmesh, "metal_dark", (-0.55, y_bar, -0.05), (0.55, y_bar, -0.05), (0.0, y_bar, eye_z + 0.22), 0.09, 0.09)
    beam(cmesh, "metal_dark", (0.0, y_bar, eye_z + 0.25), (0.0, y_bar, eye_z + 0.05), 0.1, 0.09)
    tow_eye(cmesh, 0.0, y_bar, eye_z)
    for side in (-1, 1):
        cx = side * float(front["track_m"]) / 2
        w = float(front["tire_width_m"])
        arc_x(cmesh, "metal_dark", (0.0, rf), cx - w / 2 - 0.04, cx + w / 2 + 0.04, rf + 0.05, 0.05, 15, 165, 6)
    carriage.mesh = cmesh
    add_axles(root, model, {front["id"]: "rim_red", rear["id"]: "rim_red"}, set(),
              member="front_carriage", parent=carriage, z_override=0.0)
    add_axles(root, model, {front["id"]: "rim_red", rear["id"]: "rim_red"}, set(), member="body")
    return root


# ---------------------------------------------------------------------------
# Kombajn
# ---------------------------------------------------------------------------

def build_combine(model: dict) -> Node:
    root = Node(model["id"])
    hl = float(model["dimensions"]["length_m"]) / 2
    front = next(a for a in model["axles"] if a["id"] == "front")
    rear = next(a for a in model["axles"] if a["id"] == "rear")
    zf, zr = axle_z(model, front), axle_z(model, rear)
    rf, rr = float(front["tire_length_m"]) / 2, float(rear["tire_length_m"]) / 2
    pipe = model["unloading"]["pipe"]
    pivot = pipe["pivot_in_body_m"]
    px = float(pivot[0]) * (-1 if pipe["side"] == "right" else 1)
    pz = float(pivot[1])

    m = MeshData("combine_body")
    # dolna część kadłuba (między kołami przednimi)
    box(m, "paint", -0.95, 0.95, 0.7, 2.45, -hl + 0.6, zr - 0.55)
    # tylna część: wąska obudowa osi skrętnej, wyżej pełna szerokość
    box(m, "paint", -0.42, 0.42, 0.55, 1.6, zr - 0.6, hl - 0.25)
    box(m, "paint", -0.95, 0.95, 1.6, 2.45, zr - 0.6, hl - 0.25)
    box(m, "metal_dark", -float(rear["track_m"]) / 2 + 0.15, float(rear["track_m"]) / 2 - 0.15,
        rr - 0.07, rr + 0.07, zr - 0.07, zr + 0.07)
    # górna część szersza
    box(m, "paint", -1.2, 1.2, 2.45, 3.0, -1.6, hl - 0.25)
    # pasy ozdobne
    for side in (-1, 1):
        x = side * 1.205
        box(m, "steel_light", min(x, x + side * 0.02), max(x, x + side * 0.02), 2.55, 2.68, -1.55, hl - 0.3)
        x2 = side * 0.955
        box(m, "steel_light", min(x2, x2 + side * 0.02), max(x2, x2 + side * 0.02), 1.9, 2.0, -hl + 0.7, zr - 0.6)
    # osłony silnika z tyłu, kratka chłodnicy, rozdrabniacz słomy
    box(m, "metal_dark", -0.85, 0.85, 2.5, 2.95, hl - 0.26, hl - 0.2)
    for i in range(5):
        y = 2.55 + i * 0.08
        box(m, "metal", -0.82, 0.82, y, y + 0.03, hl - 0.215, hl - 0.18)
    frustum(m, "metal_dark", (-0.85, 0.85, hl - 0.45, hl + 0.05, 0.62), (-0.8, 0.8, hl - 0.45, hl - 0.05, 1.15))
    for side in (-1, 1):
        lamp(m, "light_red", side * 0.82, 1.75, hl - 0.22, 0.07, 0.06, 0.03)
        lamp(m, "light_orange", side * 0.62, 1.75, hl - 0.22, 0.05, 0.06, 0.03)
    # wydech
    cylinder(m, "metal_dark", (0.85, 3.25, hl - 0.8), "y", 0.07, 0.5, 8)
    # przenośnik pochyły (do hedera)
    socket = next(p for p in model["hitch_ports"] if p["role"] == "socket")
    sz = float(socket["position_m"][1])
    hexa(m, "paint", [(-0.62, 0.32, sz), (0.62, 0.32, sz), (0.62, 0.85, -hl + 0.6), (-0.62, 0.85, -hl + 0.6),
                      (-0.62, 1.1, sz), (0.62, 1.1, sz), (0.62, 1.85, -hl + 0.6), (-0.62, 1.85, -hl + 0.6)])
    box(m, "metal_dark", -0.66, 0.66, 0.28, 1.14, sz, sz + 0.08)
    # pomost i kabina
    box(m, "metal_dark", -1.05, 1.05, 2.15, 2.25, -hl + 0.05, -1.55)
    for side in (-1, 1):
        x = side * 1.02
        for y in (2.55, 2.85):
            box(m, "metal_dark", x - 0.02, x + 0.02, y, y + 0.03, -hl + 0.1, -1.6)
        for z in (-hl + 0.12, -1.62):
            box(m, "metal_dark", x - 0.02, x + 0.02, 2.25, 2.88, z - 0.02, z + 0.02)
    cab(m, -0.85, 0.85, 2.25, 3.55, -hl + 0.15, -1.7, roof_extra=0.1)
    for x in (-0.6, -0.2, 0.2, 0.6):
        lamp(m, "light_white", x, 3.72, -hl + 0.06, 0.08, 0.04, 0.03)
    for x in (-0.7, 0.7):
        box(m, "beacon", x - 0.07, x + 0.07, 3.8, 3.92, -2.0, -1.86)
    # drabinka na kabinę
    lx = -1.1
    for z in (-1.95, -1.65):
        box(m, "metal_dark", lx - 0.025, lx + 0.025, 0.35, 2.2, z - 0.02, z + 0.02)
    for y in np.linspace(0.45, 2.05, 6):
        box(m, "metal_dark", lx - 0.02, lx + 0.02, y, y + 0.03, -1.95, -1.65)
    # lusterka
    for side in (-1, 1):
        beam(m, "metal_dark", (side * 0.85, 3.25, -hl + 0.2), (side * 1.25, 3.25, -hl + 0.1), 0.03, 0.03)
        box(m, "metal_dark", side * 1.25 - 0.03, side * 1.25 + 0.03, 3.0, 3.35, -hl + 0.05, -hl + 0.12)
    # zbiornik ziarna (otwarty od góry)
    tz0, tz1 = pz + 0.2, hl - 0.6
    frustum(m, "paint", (-1.12, 1.12, tz0, tz1, 3.0), (-1.32, 1.32, tz0 - 0.12, tz1 + 0.12, 3.42))
    wall = 0.06
    top = 3.9
    box(m, "interior", -1.27, 1.27, 3.42, 3.44, tz0 - 0.08, tz1 + 0.08)
    for side in (-1, 1):
        xo = side * 1.33
        xi = side * (1.33 - wall)
        box(m, "paint", min(xo, xi), max(xo, xi), 3.42, top, tz0 - 0.13, tz1 + 0.13)
    box(m, "paint", -1.33, 1.33, 3.42, top, tz0 - 0.13, tz0 - 0.13 + wall)
    box(m, "paint", -1.33, 1.33, 3.42, top, tz1 + 0.13 - wall, tz1 + 0.13)
    box(m, "steel_light", -1.36, 1.36, top - 0.02, top + 0.03, tz0 - 0.16, tz0 - 0.1)
    box(m, "steel_light", -1.36, 1.36, top - 0.02, top + 0.03, tz1 + 0.1, tz1 + 0.16)
    for side in (-1, 1):
        x = side * 1.33
        box(m, "steel_light", min(x, x + side * 0.03), max(x, x + side * 0.03), top - 0.02, top + 0.03, tz0 - 0.16, tz1 + 0.16)
    # podpora rury (kołyska) na końcu zbiornika
    pipe_y = top + 0.12
    rest_z = min(pz + float(pipe["length_m"]) * 0.75, hl - 0.3)
    box(m, "metal_dark", px - 0.06, px + 0.06, 2.95, pipe_y - 0.12, rest_z - 0.04, rest_z + 0.04)
    box(m, "metal_dark", px - 0.16, px + 0.16, pipe_y - 0.14, pipe_y - 0.1, rest_z - 0.06, rest_z + 0.06)
    # podstawa obrotowa rury
    cylinder(m, "metal_dark", (px, (2.95 + pipe_y) / 2, pz), "y", 0.16, pipe_y - 2.95, 10)
    root.mesh = m

    tank_zc = (tz0 + tz1) / 2
    fill = grain_heap("combine_grain", -1.25, 1.25, tz0 - 0.06 - tank_zc, tz1 + 0.06 - tank_zc, 0.25, 0.3)
    root.add(Node("grain_fill", (0.0, 3.44, tank_zc), mesh=fill))

    # rura rozładunkowa, oś lokalna +Z wzdłuż rury
    length = float(pipe["length_m"])
    radius = max(float(pipe.get("width_m", 0.18)) * 0.65, 0.1)
    pmesh = MeshData("combine_pipe")
    cylinder(pmesh, "metal_dark", (0, 0.0, 0), "y", 0.2, 0.18, 10)
    cylinder(pmesh, "pipe_cream", (0, 0.0, length * 0.48), "z", radius, length * 0.96, 10)
    for t in (0.12, 0.45, 0.78):
        cylinder(pmesh, "metal", (0, 0.0, length * t), "z", radius + 0.025, 0.08, 10)
    # kolano i wylot skierowany w dół, wylot w punkcie length
    box(pmesh, "pipe_cream", -radius, radius, -radius, radius, length * 0.96 - radius, length + radius * 0.6)
    frustum(pmesh, "metal_dark", (-radius * 0.8, radius * 0.8, length - radius * 0.8, length + radius * 0.8, -0.55),
            (-radius, radius, length - radius, length + radius, -radius + 0.01))
    root.add(Node("pipe", (px, pipe_y, pz), mesh=pmesh))

    def front_fender(parent: Node, axle: dict, side: int, local: bool) -> None:
        if axle["id"] != "front":
            return
        r = float(axle["tire_length_m"]) / 2
        w = float(axle["tire_width_m"])
        cx = side * float(axle["track_m"]) / 2
        mesh = MeshData("combine_front_fender")
        arc_x(mesh, "paint", (axle_z(model, axle), r), cx - w / 2 - 0.05, cx + w / 2 + 0.05, r + 0.07, 0.06, 10, 115, 6)
        parent.add(Node(f"fender_front_{'L' if side < 0 else 'R'}", mesh=mesh))

    add_axles(root, model, {"front": "rim_grey", "rear": "rim_grey"}, {"front"}, front_fender)
    return root


# ---------------------------------------------------------------------------
# Heder zbożowy
# ---------------------------------------------------------------------------

def build_header(model: dict) -> Node:
    root = Node(model["id"])
    w = float(model["dimensions"]["width_m"]) / 2
    l = float(model["dimensions"]["length_m"]) / 2
    m = MeshData("header_body")
    hx = w - 0.1
    # tylna ściana, dno, ślimak
    box(m, "paint", -hx, hx, 0.18, 1.12, l - 0.14, l)
    box(m, "paint", -hx, hx, 1.06, 1.16, l - 0.35, l)
    hexa(m, "paint", [(-hx, 0.08, -l + 0.05), (hx, 0.08, -l + 0.05), (hx, 0.18, l - 0.1), (-hx, 0.18, l - 0.1),
                      (-hx, 0.16, -l + 0.05), (hx, 0.16, -l + 0.05), (hx, 0.3, l - 0.1), (-hx, 0.3, l - 0.1)])
    cylinder(m, "steel_light", (0, 0.48, l - 0.32), "x", 0.17, hx * 2 - 0.1, 10)
    for x in np.linspace(-hx + 0.3, hx - 0.3, 22):
        cylinder(m, "metal", (x, 0.48, l - 0.32), "x", 0.2, 0.04, 10)
    box(m, "interior", -0.62, 0.62, 0.32, 1.0, l - 0.005, l + 0.005)
    # boczne ściany z rozdzielaczami
    for side in (-1, 1):
        x0, x1 = side * hx, side * (hx + 0.1)
        xa, xb = min(x0, x1), max(x0, x1)
        hexa(m, "paint", [(xa, 0.06, -l), (xb, 0.06, -l), (xb, 0.06, l), (xa, 0.06, l),
                          (xa, 0.55, -l), (xb, 0.55, -l), (xb, 1.12, l), (xa, 1.12, l)])
        # stożkowy rozdzielacz łanu
        hexa(m, "paint", [(xa, 0.06, -l), (xb, 0.06, -l), (xb, 0.06, -l), (xa, 0.06, -l),
                          (xa, 0.5, -l), (xb, 0.5, -l), (xb, 0.04, -l - 0.55), (xa, 0.04, -l - 0.55)])
        # ramię motowidła
        beam(m, "paint", (side * (hx - 0.05), 1.12, l - 0.1), (side * (hx - 0.05), 1.18, -0.15), 0.09, 0.12)
    # listwa nożowa i palce
    box(m, "metal_dark", -hx, hx, 0.05, 0.11, -l - 0.06, -l + 0.06)
    for x in np.arange(-hx + 0.08, hx - 0.05, 0.19):
        hexa(m, "steel_light", [(x - 0.025, 0.06, -l - 0.06), (x + 0.025, 0.06, -l - 0.06), (x + 0.025, 0.06, -l - 0.06), (x - 0.025, 0.06, -l - 0.06),
                                (x - 0.025, 0.1, -l), (x + 0.025, 0.1, -l), (x, 0.08, -l - 0.18), (x, 0.08, -l - 0.18)])
    # lampy ostrzegawcze
    for side in (-1, 1):
        lamp(m, "warn_red", side * (hx + 0.05), 0.8, l - 0.2, 0.06, 0.09, 0.05)
    root.mesh = m

    # motowidło
    reel = MeshData("header_reel")
    radius = 0.5
    cylinder(reel, "steel_light", (0, 0, 0), "x", 0.06, hx * 2 - 0.2, 8)
    for x in (-hx + 0.25, 0.0, hx - 0.25):
        for i in range(6):
            a = 2 * math.pi * i / 6
            beam(reel, "metal_dark", (x, 0, 0), (x, math.cos(a) * radius, math.sin(a) * radius), 0.04, 0.04)
    for i in range(6):
        a = 2 * math.pi * i / 6
        cy, cz = math.cos(a) * radius, math.sin(a) * radius
        beam(reel, "reel_red", (-hx + 0.12, cy, cz), (hx - 0.12, cy, cz), 0.09, 0.06)
        for x in np.arange(-hx + 0.3, hx - 0.2, 0.55):
            direction = np.array([0.0, math.cos(a), math.sin(a)])
            tangent = np.array([0.0, -math.sin(a), math.cos(a)])
            tip = np.array([x, cy, cz]) + direction * 0.25 + tangent * 0.06
            beam(reel, "metal_dark", (x, cy, cz), tuple(tip), 0.025, 0.025)
    root.add(Node("reel", (0.0, 1.18, -0.15), mesh=reel))
    return root


# ---------------------------------------------------------------------------
# Siewnik
# ---------------------------------------------------------------------------

def build_seeder(model: dict) -> Node:
    root = Node(model["id"])
    w = float(model["dimensions"]["width_m"]) / 2
    l = float(model["dimensions"]["length_m"]) / 2
    axle = model["axles"][0]
    za = axle_z(model, axle)
    ra = float(axle["tire_length_m"]) / 2
    half_track = float(axle["track_m"]) / 2
    tw = float(axle["tire_width_m"])
    m = MeshData("seeder_body")
    frame_x = half_track - tw / 2 - 0.08
    # rama
    box(m, "metal_dark", -frame_x, frame_x, 0.55, 0.7, -0.35, -0.2)
    box(m, "metal_dark", -frame_x, frame_x, 0.5, 0.62, za + 0.25, za + 0.37)
    for x in (-1.2, 1.2):
        box(m, "metal_dark", x - 0.06, x + 0.06, 0.55, 0.7, -0.9, za + 0.37)
    # zbiornik nasion
    frustum(m, "paint", (-1.55, 1.55, -0.9, 0.15, 0.95), (-1.95, 1.95, -1.05, 0.3, 1.72))
    frustum(m, "paint", (-1.99, 1.99, -1.09, 0.34, 1.72), (-1.88, 1.88, -1.0, 0.25, 1.86))
    box(m, "steel_light", -1.99, 1.99, 1.62, 1.68, -1.1, 0.35)
    for x in (-1.3, 1.3):
        box(m, "metal_dark", x - 0.05, x + 0.05, 0.7, 0.95, -0.85, -0.75)
        box(m, "metal_dark", x - 0.05, x + 0.05, 0.7, 0.95, 0.05, 0.15)
    # pomost
    box(m, "metal", -1.4, 1.4, 0.78, 0.82, -1.35, -1.1)
    for x in (-1.4, 1.4):
        box(m, "metal_dark", x - 0.02, x + 0.02, 0.82, 1.4, -1.35, -1.31)
    box(m, "metal_dark", -1.4, 1.4, 1.37, 1.41, -1.35, -1.31)
    # redlice i przewody nasienne
    count = 24
    xs = np.linspace(-frame_x + 0.2, frame_x - 0.2, count)
    disc_z = za + 0.55
    box(m, "metal_dark", -frame_x, frame_x, 0.42, 0.52, disc_z - 0.15, disc_z - 0.05)
    for x in xs:
        top = (np.clip(x * 0.72, -1.4, 1.4), 0.95, -0.35)
        beam(m, "metal_dark", top, (x, 0.47, disc_z - 0.1), 0.035, 0.035)
        beam(m, "metal", (x, 0.47, disc_z - 0.1), (x, 0.2, disc_z), 0.05, 0.04)
        cylinder(m, "steel_light", (x, 0.18, disc_z), "x", 0.16, 0.035, 10)
    # zgrzebło
    harrow_z = l - 0.05
    box(m, "metal_dark", -frame_x, frame_x, 0.45, 0.52, harrow_z - 0.25, harrow_z - 0.18)
    for x in np.linspace(-frame_x + 0.1, frame_x - 0.1, 30):
        beam(m, "steel_light", (x, 0.47, harrow_z - 0.21), (x, 0.04, harrow_z + 0.1), 0.025, 0.025)
    # ramiona kół
    for side in (-1, 1):
        x = side * (half_track - tw / 2 - 0.05)
        beam(m, "metal_dark", (x, 0.6, -0.28), (x, ra, za), 0.08, 0.08)
    # dyszel A
    plug = next(p for p in model["hitch_ports"] if p["role"] == "plug")
    eye_z = float(plug["position_m"][1])
    a_frame(m, "metal_dark", (-1.2, 0.6, -0.35), (1.2, 0.6, -0.35), (0.0, 0.55, eye_z + 0.2), 0.1, 0.1)
    beam(m, "metal_dark", (0, 0.55, eye_z + 0.22), (0, 0.55, eye_z + 0.04), 0.09, 0.09)
    tow_eye(m, 0.0, 0.55, eye_z)
    cylinder(m, "metal_dark", (0.0, 0.27, eye_z + 0.55), "y", 0.035, 0.54, 6)
    box(m, "metal_dark", -0.08, 0.08, 0.0, 0.03, eye_z + 0.47, eye_z + 0.63)
    # tablice ostrzegawcze
    for side in (-1, 1):
        x = side * (frame_x - 0.1)
        box(m, "warn_white", x - 0.12, x + 0.12, 0.72, 1.0, -0.41, -0.37)
        box(m, "warn_red", x - 0.12, x + 0.12, 0.8, 0.9, -0.42, -0.36)
    root.mesh = m
    add_axles(root, model, {axle["id"]: "rim_cream"}, set())
    return root


# ---------------------------------------------------------------------------
# Kultywator
# ---------------------------------------------------------------------------

def build_cultivator(model: dict) -> Node:
    root = Node(model["id"])
    l = float(model["dimensions"]["length_m"]) / 2
    axle = model["axles"][0]
    za = axle_z(model, axle)
    ra = float(axle["tire_length_m"]) / 2
    half_track = float(axle["track_m"]) / 2
    tw = float(axle["tire_width_m"])
    m = MeshData("cultivator_body")
    fx = half_track - tw / 2 - 0.1
    beams_z = (-l + 0.3, -l + 0.95, -l + 1.55)
    for z in beams_z:
        box(m, "paint", -fx, fx, 0.6, 0.75, z - 0.07, z + 0.07)
    for x in (-fx + 0.05, -fx * 0.5, 0.0, fx * 0.5, fx - 0.05):
        box(m, "paint", x - 0.06, x + 0.06, 0.6, 0.73, beams_z[0] - 0.1, beams_z[-1] + 0.1)
    # zęby sprężynowe w trzech rzędach
    for row, z in enumerate(beams_z):
        offset = (row % 3) * 0.2
        for x in np.arange(-fx + 0.25 + offset, fx - 0.15, 0.6):
            beam(m, "metal_dark", (x, 0.62, z), (x, 0.32, z + 0.12), 0.05, 0.06)
            beam(m, "metal_dark", (x, 0.32, z + 0.12), (x, 0.12, z + 0.02), 0.05, 0.05)
            beam(m, "steel_light", (x, 0.13, z + 0.04), (x, 0.02, z - 0.16), 0.08, 0.03)
    # ramiona wału
    roller_z = l - 0.22
    roller_r = 0.22
    for side in (-1, 1):
        x = side * (fx - 0.15)
        beam(m, "paint", (x, 0.66, beams_z[-1]), (x, roller_r, roller_z), 0.08, 0.1)
    # ramiona kół
    for side in (-1, 1):
        x = side * (half_track - tw / 2 - 0.06)
        beam(m, "paint", (x, 0.66, beams_z[1]), (x, ra, za), 0.09, 0.09)
    # dyszel
    plug = next(p for p in model["hitch_ports"] if p["role"] == "plug")
    eye_z = float(plug["position_m"][1])
    a_frame(m, "paint", (-1.3, 0.66, beams_z[0]), (1.3, 0.66, beams_z[0]), (0.0, 0.56, eye_z + 0.2), 0.11, 0.11)
    beam(m, "metal_dark", (0, 0.56, eye_z + 0.22), (0, 0.56, eye_z + 0.04), 0.09, 0.09)
    tow_eye(m, 0.0, 0.56, eye_z)
    # tablice ostrzegawcze
    for side in (-1, 1):
        x = side * (fx - 0.05)
        box(m, "warn_white", x - 0.13, x + 0.13, 0.76, 1.06, beams_z[0] - 0.12, beams_z[0] - 0.08)
        for i in range(2):
            box(m, "warn_red", x - 0.13, x + 0.13, 0.8 + i * 0.13, 0.86 + i * 0.13, beams_z[0] - 0.13, beams_z[0] - 0.07)
    root.mesh = m

    roller = MeshData("cultivator_roller")
    length = (fx - 0.2) * 2
    cylinder(roller, "metal", (0, 0, 0), "x", roller_r - 0.03, length, 10)
    for x in np.linspace(-length / 2 + 0.05, length / 2 - 0.05, 20):
        cylinder(roller, "metal_dark", (x, 0, 0), "x", roller_r, 0.06, 10)
    for i in range(10):
        a = 2 * math.pi * i / 10
        y, z = math.cos(a) * (roller_r - 0.02), math.sin(a) * (roller_r - 0.02)
        box(roller, "metal_dark", -length / 2, length / 2, y - 0.015, y + 0.015, z - 0.015, z + 0.015)
    root.add(Node("roller", (0.0, roller_r, roller_z), mesh=roller))
    add_axles(root, model, {axle["id"]: "rim_cream"}, set())
    return root


BUILDERS = {
    "tractor": build_tractor,
    "trailer": build_trailer,
    "combine": build_combine,
    "header": build_header,
    "seeder": build_seeder,
    "cultivator": build_cultivator,
}


# ---------------------------------------------------------------------------
# Otoczenie
# ---------------------------------------------------------------------------

def blob(mesh: MeshData, swatch: str, cx, cy, cz, radius, height, sides=7, phase=0.3) -> None:
    """Zaokrąglona, wieloboczna korona drzewa / krzaka."""
    h3 = height / 3.0
    bottom = cy - height / 2
    rings = [(radius * 0.55, bottom), (radius, bottom + h3), (radius, bottom + 2 * h3), (radius * 0.5, bottom + height)]
    for (r0, y0), (r1, y1) in zip(rings[:-1], rings[1:]):
        cylinder(mesh, swatch, (cx, (y0 + y1) / 2, cz), "y", r0, y1 - y0, sides, radius_end=r1, phase=phase)


def build_tree_round() -> Node:
    m = MeshData("tree_round")
    cylinder(m, "trunk", (0, 0.9, 0), "y", 0.2, 1.8, 6, radius_end=0.14)
    blob(m, "leaf", 0, 2.9, 0, 1.45, 2.6)
    blob(m, "leaf_light", 0.55, 3.55, 0.35, 0.8, 1.3, sides=6, phase=0.8)
    blob(m, "leaf_dark", -0.6, 2.45, -0.3, 0.75, 1.1, sides=6, phase=0.1)
    return Node("tree_round", mesh=m)


def build_tree_pine() -> Node:
    m = MeshData("tree_pine")
    cylinder(m, "trunk", (0, 0.6, 0), "y", 0.16, 1.2, 6, radius_end=0.12)
    for i, (r, y, h) in enumerate(((1.25, 1.6, 1.6), (1.0, 2.6, 1.5), (0.72, 3.5, 1.4), (0.42, 4.3, 1.1))):
        cylinder(m, "leaf_dark" if i % 2 == 0 else "leaf", (0, y, 0), "y", r, h, 7, radius_end=0.06 if i == 3 else r * 0.35, phase=i * 0.4)
    return Node("tree_pine", mesh=m)


def build_bush() -> Node:
    m = MeshData("bush")
    blob(m, "leaf", 0, 0.45, 0, 0.75, 0.9)
    blob(m, "leaf_light", 0.45, 0.4, 0.2, 0.5, 0.7, sides=6, phase=0.9)
    blob(m, "leaf_dark", -0.4, 0.35, -0.15, 0.45, 0.6, sides=6, phase=0.2)
    return Node("bush", mesh=m)


def build_barn() -> Node:
    m = MeshData("barn")
    w, d, h, roof_h = 5.0, 7.0, 4.5, 3.4
    box(m, "concrete_dark", -w - 0.1, w + 0.1, 0.0, 0.25, -d - 0.1, d + 0.1)
    box(m, "barn_red", -w, w, 0.25, h, -d, d)
    # szczyty
    for z0, z1 in ((-d, -d + 0.01), (d - 0.01, d)):
        hexa(m, "barn_red", [(-w, h, z0), (w, h, z0), (w, h, z1), (-w, h, z1),
                             (0, h + roof_h, z0), (0, h + roof_h, z0), (0, h + roof_h, z1), (0, h + roof_h, z1)])
    # dach dwuspadowy
    for side in (-1, 1):
        x_eave = side * (w + 0.45)
        hexa(m, "roof_dark", [(x_eave, h - 0.3, -d - 0.4), (0, h + roof_h, -d - 0.4), (0, h + roof_h, d + 0.4), (x_eave, h - 0.3, d + 0.4),
                              (x_eave, h - 0.1, -d - 0.4), (0, h + roof_h + 0.2, -d - 0.4), (0, h + roof_h + 0.2, d + 0.4), (x_eave, h - 0.1, d + 0.4)])
    # wrota z białym krzyżem
    for z, dz in ((d, 0.05), (-d, -0.05)):
        z1 = z + dz
        box(m, "barn_red_dark", -2.0, 2.0, 0.25, 3.6, min(z, z1), max(z, z1))
        for x0, x1 in ((-2.1, -1.9), (1.9, 2.1), (-0.1, 0.1)):
            box(m, "door_white", x0, x1, 0.25, 3.7, min(z, z1 + dz), max(z, z1 + dz))
        box(m, "door_white", -2.1, 2.1, 3.6, 3.75, min(z, z1 + dz), max(z, z1 + dz))
        for sgn in (-1, 1):
            beam(m, "door_white", (sgn * 1.95, 0.35, z1 + dz), (sgn * 0.1, 3.55, z1 + dz), 0.14, 0.04, up=(0, 0, 1))
        # okienko na szczycie
        box(m, "door_white", -0.6, 0.6, h + 0.6, h + 1.8, min(z, z1 + dz), max(z, z1 + dz))
        box(m, "glass", -0.45, 0.45, h + 0.75, h + 1.65, min(z, z1 + dz * 1.5), max(z, z1 + dz * 1.5))
    # białe narożniki
    for x in (-w, w):
        for z in (-d, d):
            box(m, "door_white", x - 0.08, x + 0.08, 0.25, h, z - 0.08, z + 0.08)
    return Node("barn", mesh=m)


def build_house() -> Node:
    m = MeshData("house")
    w, d, h = 4.0, 5.0, 3.2
    box(m, "concrete_dark", -w - 0.1, w + 0.1, 0.0, 0.3, -d - 0.1, d + 0.1)
    box(m, "wall_cream", -w, w, 0.3, h, -d, d)
    for side in (-1, 1):
        x_eave = side * (w + 0.5)
        hexa(m, "roof_red", [(x_eave, h - 0.2, -d - 0.4), (0, h + 2.6, -d - 0.4), (0, h + 2.6, d + 0.4), (x_eave, h - 0.2, d + 0.4),
                             (x_eave, h, -d - 0.4), (0, h + 2.8, -d - 0.4), (0, h + 2.8, d + 0.4), (x_eave, h, d + 0.4)])
    for z0, z1 in ((-d, -d + 0.01), (d - 0.01, d)):
        hexa(m, "wall_cream", [(-w, h, z0), (w, h, z0), (w, h, z1), (-w, h, z1),
                               (0, h + 2.6, z0), (0, h + 2.6, z0), (0, h + 2.6, z1), (0, h + 2.6, z1)])
    box(m, "roof_dark", 1.6, 2.4, h + 1.0, h + 3.4, -1.5, -0.7)
    for side in (-1, 1):
        x = side * (w + 0.03)
        for z in (-2.8, 0.0, 2.8):
            box(m, "door_white", min(x, x + side * 0.03), max(x, x + side * 0.03), 1.2, 2.5, z - 0.6, z + 0.6)
            box(m, "glass", min(x, x + side * 0.06), max(x, x + side * 0.06), 1.3, 2.4, z - 0.48, z + 0.48)
    box(m, "wood_dark", -0.6, 0.6, 0.3, 2.4, d, d + 0.06)
    return Node("house", mesh=m)


def build_silo_tower() -> Node:
    m = MeshData("silo_tower")
    r, h = 2.6, 10.0
    cylinder(m, "concrete_dark", (0, 0.2, 0), "y", r + 0.4, 0.4, 14)
    cylinder(m, "silo_steel", (0, 0.4 + h / 2, 0), "y", r, h, 14)
    for y in np.arange(1.4, h, 1.6):
        cylinder(m, "silo_band", (0, y, 0), "y", r + 0.04, 0.12, 14)
    cylinder(m, "silo_steel", (0, 0.4 + h + 0.9, 0), "y", r + 0.15, 1.8, 14, radius_end=0.35)
    cylinder(m, "silo_band", (0, 0.4 + h + 1.9, 0), "y", 0.4, 0.3, 8)
    # drabina
    for x in (-0.25, 0.25):
        box(m, "metal_dark", x - 0.03, x + 0.03, 0.4, h + 0.6, r + 0.05, r + 0.11)
    for y in np.arange(0.8, h + 0.4, 0.45):
        box(m, "metal_dark", -0.25, 0.25, y, y + 0.03, r + 0.06, r + 0.1)
    return Node("silo_tower", mesh=m)


def build_grain_pit(area: dict) -> Node:
    """Krata rozładunkowa (punkt zrzutu ziarna) o wymiarach z map.json."""
    m = MeshData("grain_pit")
    hw = float(area["width_m"]) / 2
    hl = float(area["length_m"]) / 2
    rim = 0.45
    box(m, "concrete", -hw - rim, hw + rim, -0.05, 0.06, -hl - rim, hl + rim)
    box(m, "interior", -hw, hw, 0.0, 0.065, -hl, hl)
    # pasy ostrzegawcze żółto-czarne wzdłuż obramowania
    n = int((hw * 2) / 0.5)
    for edge_z in (-hl - rim, hl):
        for i in range(n):
            x0 = -hw + i * (hw * 2 / n)
            sw = "warn_yellow" if i % 2 == 0 else "warn_black"
            box(m, sw, x0, x0 + hw * 2 / n, 0.06, 0.075, edge_z, edge_z + rim)
    nz = int((hl * 2) / 0.5)
    for edge_x in (-hw - rim, hw):
        for i in range(nz):
            z0 = -hl + i * (hl * 2 / nz)
            sw = "warn_yellow" if i % 2 == 0 else "warn_black"
            box(m, sw, edge_x, edge_x + rim, 0.06, 0.075, z0, z0 + hl * 2 / nz)
    # krata
    for x in np.arange(-hw + 0.25, hw, 0.5):
        box(m, "metal", x - 0.04, x + 0.04, 0.065, 0.085, -hl, hl)
    for z in np.arange(-hl + 1.0, hl, 1.0):
        box(m, "metal_dark", -hw, hw, 0.06, 0.08, z - 0.05, z + 0.05)
    return Node("grain_pit", mesh=m)


def build_cloud() -> Node:
    m = MeshData("cloud")
    box(m, "cloud", -6.0, 6.0, 0.0, 2.2, -3.5, 3.5)
    box(m, "cloud", -3.5, 4.0, 1.2, 3.6, -2.5, 2.8)
    box(m, "cloud_shade", -8.0, -4.5, 0.0, 1.5, -2.0, 2.5)
    box(m, "cloud", 3.0, 8.0, 0.0, 1.8, -2.5, 2.0)
    return Node("cloud", mesh=m)


def build_fence_segment() -> Node:
    m = MeshData("fence")
    for x in (-2.0, 2.0):
        box(m, "wood_dark", x - 0.07, x + 0.07, 0.0, 1.1, -0.07, 0.07)
    for y in (0.45, 0.85):
        box(m, "wood", -2.0, 2.0, y, y + 0.12, -0.04, 0.04)
    return Node("fence", mesh=m)


def build_hay_bale() -> Node:
    m = MeshData("hay_bale")
    cylinder(m, "straw", (0, 0.65, 0), "x", 0.65, 1.2, 12, cap_swatch="grain_dark")
    return Node("hay_bale", mesh=m)


def main() -> None:
    os.makedirs(OUT_MACHINES, exist_ok=True)
    os.makedirs(OUT_WORLD, exist_ok=True)
    catalog = load("machines.json")
    map_data = load("map.json")
    palette_image().save(os.path.join(ROOT, "models", "palette.png"))
    print("Maszyny:")
    for model in catalog["machines"]:
        builder = BUILDERS.get(str(model["category"]))
        if builder is None:
            print(f"  pominięto {model['id']} (kategoria {model['category']})")
            continue
        root = builder(model)
        color = str(model.get("visual", {}).get("body_color", "#cccccc"))
        path = os.path.join(OUT_MACHINES, f"{model['id']}.glb")
        write_glb(path, root, color)
        print(f"  {model['id']:18s} {count_triangles(root):6d} trójkątów -> {os.path.relpath(path, ROOT)}")
    print("Otoczenie:")
    world = [build_tree_round(), build_tree_pine(), build_bush(), build_barn(), build_house(),
             build_silo_tower(), build_cloud(), build_fence_segment(), build_hay_bale()]
    for point in map_data.get("unload_points", []):
        node = build_grain_pit(point["area"])
        node.name = "grain_pit"
        world.append(node)
        break
    for root in world:
        path = os.path.join(OUT_WORLD, f"{root.name}.glb")
        write_glb(path, root)
        print(f"  {root.name:18s} {count_triangles(root):6d} trójkątów -> {os.path.relpath(path, ROOT)}")


if __name__ == "__main__":
    main()
