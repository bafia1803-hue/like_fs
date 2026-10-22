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
  lift                          – część opuszczana do pracy (heder, rama kultywatora,
                                  redlice siewnika); model jest w pozycji roboczej,
                                  w transporcie gra podnosi ją o visual.lift_height_m
  marker_L / marker_R           – znaczniki siewnika, złożone pionowo poza pracą
  wing_L / wing_R               – skrzydła składanej maszyny (kultywator), zawias na
                                  górnej krawędzi ramy; złożone = obrót o 90° wokół Z
"""
from __future__ import annotations

import json
import math
import os
import sys

import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from gltf_builder import (MeshData, Node, arc_x, beam, box, count_triangles, cylinder,  # noqa: E402
                          frustum, hexa, palette_image, translate, write_glb)

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT_MACHINES = os.path.join(ROOT, "models", "machines")
OUT_WORLD = os.path.join(ROOT, "models", "world")


def load(name: str) -> dict:
    with open(os.path.join(ROOT, "files", name), encoding="utf-8") as handle:
        return json.load(handle)


def axle_z(model: dict, axle: dict) -> float:
    return -float(model["dimensions"]["length_m"]) / 2.0 + float(axle["distance_from_front_m"])


# ---------------------------------------------------------------------------
# Koła (minimalistyczne: wielokątna opona + sześciokątna felga, żeby było widać obrót)
# ---------------------------------------------------------------------------

_wheel_cache: dict = {}


def wheel_mesh(radius: float, width: float, rim: str) -> MeshData:
    key = (round(radius, 3), round(width, 3), rim)
    if key in _wheel_cache:
        return _wheel_cache[key]
    mesh = MeshData(f"wheel_{int(radius * 200)}_{int(width * 100)}")
    sides = 10 if radius > 0.55 else 8
    cylinder(mesh, "tire", (0, 0, 0), "x", radius, width, sides, cap_swatch="tire_side")
    cylinder(mesh, rim, (0, 0, 0), "x", radius * 0.58, width + 0.04, 6, phase=0.3)
    box(mesh, "metal_dark", -width / 2 - 0.05, width / 2 + 0.05, -radius * 0.12, radius * 0.12,
        -radius * 0.12, radius * 0.12)
    _wheel_cache[key] = mesh
    return mesh


def add_axles(root: Node, model: dict, rims: dict, fender=None,
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
        mesh = wheel_mesh(radius, width, rims.get(axle["id"], "rim_grey"))
        steerable = bool(axle.get("steerable")) and float(axle.get("max_steering_deg", 0.0)) > 0.0
        for side, suffix in ((-1, "L"), (1, "R")):
            pos = (side * half_track, radius, z)
            if steerable:
                steer = parent.add(Node(f"steer_{axle['id']}_{suffix}", pos))
                steer.add(Node(f"spin_{axle['id']}_{suffix}", mesh=mesh))
                if fender:
                    fender(steer, axle, side)
            else:
                parent.add(Node(f"spin_{axle['id']}_{suffix}", pos, mesh=mesh))


def fender_mesh(name: str, radius: float, width: float, swatch: str, a0=25.0, a1=150.0,
                segments=3, thickness=0.06) -> MeshData:
    mesh = MeshData(name)
    arc_x(mesh, swatch, (0.0, 0.0), -width / 2, width / 2, radius, thickness, a0, a1, segments)
    return mesh


def cab(mesh: MeshData, x0, x1, y0, y1, z0, z1, belt=0.3, roof=0.12) -> None:
    """Kabina: dolny panel, szklana bryła, 4 słupki i płaski dach."""
    post = 0.07
    box(mesh, "paint", x0, x1, y0, y0 + belt, z0, z1)
    box(mesh, "glass", x0 + 0.02, x1 - 0.02, y0 + belt, y1, z0 + 0.02, z1 - 0.02)
    for x in (x0, x1 - post):
        for z in (z0, z1 - post):
            box(mesh, "paint", x, x + post, y0 + belt, y1, z, z + post)
    frustum(mesh, "paint", (x0 - 0.08, x1 + 0.08, z0 - 0.08, z1 + 0.08, y1),
            (x0 - 0.02, x1 + 0.02, z0 - 0.02, z1 + 0.02, y1 + roof))


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


def drawbar(mesh: MeshData, model: dict, y: float, z_back: float, spread: float, swatch="metal_dark") -> None:
    """Dyszel A z uchem zaczepu w porcie z machines.json."""
    plug = next(p for p in model["hitch_ports"] if p["role"] == "plug")
    eye_z = float(plug["position_m"][1])
    a_frame(mesh, swatch, (-spread, y, z_back), (spread, y, z_back), (0.0, y, eye_z + 0.15), 0.1, 0.1)
    cylinder(mesh, "steel_light", (0.0, y, eye_z), "y", 0.08, 0.07, 6)


def warn_board(mesh: MeshData, x: float, y: float, z: float) -> None:
    box(mesh, "warn_white", x - 0.12, x + 0.12, y, y + 0.26, z - 0.02, z + 0.02)
    box(mesh, "warn_red", x - 0.125, x + 0.125, y + 0.08, y + 0.17, z - 0.025, z + 0.025)


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
    nose = -half_len + 0.05

    # rama i przednia oś
    box(body, "metal_dark", -0.32, 0.32, rf - 0.1, rf + 0.25, nose + 0.1, zr)
    box(body, "metal_dark", -float(front["track_m"]) / 2 + 0.15, float(front["track_m"]) / 2 - 0.15,
        rf - 0.06, rf + 0.06, zf - 0.07, zf + 0.07)
    # maska: jedna lekko zwężona bryła, atrapa i dwie lampy
    hood_back = zr - rr - 0.05
    frustum(body, "paint", (-0.44, 0.44, nose, hood_back, rf + 0.15), (-0.36, 0.36, nose + 0.12, hood_back, 1.45))
    box(body, "metal_dark", -0.3, 0.3, rf + 0.3, 1.25, nose - 0.02, nose + 0.02)
    for x in (-0.28, 0.28):
        box(body, "light_white", x - 0.07, x + 0.07, 1.3, 1.38, nose + 0.08, nose + 0.12)
    # wydech
    cylinder(body, "metal_dark", (0.26, 1.9, hood_back - 0.25), "y", 0.05, 1.0, 6)
    # kadłub pod kabiną i kabina nad tylną osią
    cab_z0, cab_z1 = hood_back - 0.1, zr + 0.55
    box(body, "metal_dark", -0.5, 0.5, rf, 1.25, hood_back - 0.05, zr + 0.5)
    cab(body, -0.6, 0.6, 1.25, 2.5, cab_z0, cab_z1)
    box(body, "beacon", -0.08, 0.08, 2.62, 2.72, cab_z1 - 0.3, cab_z1 - 0.15)
    # błotniki tylnych kół
    half_track_r = float(rear["track_m"]) / 2
    wr = float(rear["tire_width_m"])
    for side in (-1, 1):
        cx = side * half_track_r
        arc_x(body, "paint", (zr, rr), cx - wr / 2 - 0.05, cx + wr / 2 + 0.05, rr + 0.06, 0.06, 20, 160, 4)
    # zaczep
    hitch = next(p for p in model["hitch_ports"] if p["role"] == "socket")
    hz = float(hitch["position_m"][1])
    box(body, "metal_dark", -0.09, 0.09, 0.42, 0.54, zr + 0.4, hz + 0.08)
    root.mesh = body

    def front_fender(parent: Node, axle: dict, side: int) -> None:
        r = float(axle["tire_length_m"]) / 2
        w = float(axle["tire_width_m"])
        parent.add(Node(f"fender_{axle['id']}_{'L' if side < 0 else 'R'}",
                        mesh=fender_mesh("front_fender", r + 0.06, w + 0.08, "paint")))

    add_axles(root, model, {"front": "rim_cream", "rear": "rim_cream"}, front_fender)
    return root


# ---------------------------------------------------------------------------
# Przyczepa dwuosiowa (wywrotka)
# ---------------------------------------------------------------------------

def build_trailer(model: dict) -> Node:
    root = Node(model["id"])
    length = float(model["dimensions"]["length_m"])
    width = float(model["dimensions"]["width_m"])
    hl, hw = length / 2, width / 2
    carriage_data = model["front_carriage"]
    pz = float(carriage_data["pivot_in_body_m"][1])
    rear = next(a for a in model["axles"] if a["id"] != carriage_data["axle_id"])
    front = next(a for a in model["axles"] if a["id"] == carriage_data["axle_id"])
    zr = axle_z(model, rear)
    rr = float(rear["tire_length_m"]) / 2
    rf = float(front["tire_length_m"]) / 2
    floor_y = max(rr, rf) + 0.6

    body = MeshData("trailer_chassis")
    for side in (-1, 1):
        box(body, "metal_dark", side * 0.45 - 0.08, side * 0.45 + 0.08, floor_y - 0.3, floor_y - 0.06, -hl + 0.2, hl - 0.1)
    box(body, "metal_dark", -float(rear["track_m"]) / 2 + 0.12, float(rear["track_m"]) / 2 - 0.12,
        rr - 0.06, rr + 0.06, zr - 0.06, zr + 0.06)
    for side in (-1, 1):
        box(body, "metal", side * 0.5 - 0.06, side * 0.5 + 0.06, rr, floor_y - 0.3, zr - 0.08, zr + 0.08)
    cylinder(body, "metal_dark", (0, floor_y - 0.33, pz), "y", 0.6, 0.06, 8)
    for side in (-1, 1):
        box(body, "light_red", side * 0.8 - 0.08, side * 0.8 + 0.08, floor_y - 0.26, floor_y - 0.16, hl - 0.1, hl)
    root.mesh = body

    # skrzynia: zawias z tyłu (wywrot)
    hinge = (0.0, floor_y, hl - 0.05)
    tipper = root.add(Node("tipper", hinge))
    box_mesh = MeshData("trailer_box")
    wall_h = 0.78
    T = translate(-hinge[0], -hinge[1], -hinge[2])

    def tbox(sw, x0, x1, y0, y1, z0, z1):
        box(box_mesh, sw, x0, x1, y0, y1, z0, z1, matrix=T)

    bl, br = -hl + 0.05, hl - 0.05
    tbox("metal", -hw + 0.03, hw - 0.03, floor_y, floor_y + 0.08, bl, br)
    for side in (-1, 1):
        x_out, x_in = side * hw, side * (hw - 0.08)
        tbox("paint", min(x_in, x_out), max(x_in, x_out), floor_y + 0.08, floor_y + wall_h, bl, br)
        tbox("metal_dark", min(x_in, x_out) - 0.01, max(x_in, x_out) + 0.01, floor_y, floor_y + 0.12, bl, br)
    tbox("paint", -hw, hw, floor_y + 0.08, floor_y + wall_h, bl, bl + 0.08)
    tipper.mesh = box_mesh
    # tylna klapa z zawiasem u góry
    gate_hinge = (0.0, floor_y + wall_h, br - 0.04)
    gate = MeshData("trailer_tailgate")
    G = translate(-gate_hinge[0], -gate_hinge[1], -gate_hinge[2])
    box(gate, "paint", -hw + 0.08, hw - 0.08, floor_y + 0.09, floor_y + wall_h, br - 0.08, br, matrix=G)
    box(gate, "warn_red", -0.18, 0.18, floor_y + 0.3, floor_y + 0.45, br, br + 0.02, matrix=G)
    tipper.add(Node("tailgate", tuple(np.array(gate_hinge) - np.array(hinge)), mesh=gate))
    fill = grain_heap("trailer_grain", -hw + 0.1, hw - 0.1, bl + 0.1, br - 0.1, wall_h - 0.2, 0.2)
    tipper.add(Node("grain_fill", (-hinge[0], floor_y + 0.08 - hinge[1], -hinge[2]), mesh=fill))

    # przedni wózek z obrotnicą i dyszlem
    carriage = root.add(Node("carriage", (0.0, 0.0, pz)))
    cmesh = MeshData("trailer_carriage")
    cylinder(cmesh, "metal_dark", (0, floor_y - 0.39, 0), "y", 0.58, 0.06, 8)
    box(cmesh, "metal_dark", -0.35, 0.35, rf + 0.05, floor_y - 0.42, -0.25, 0.25)
    box(cmesh, "metal_dark", -float(front["track_m"]) / 2 + 0.12, float(front["track_m"]) / 2 - 0.12,
        rf - 0.06, rf + 0.06, -0.06, 0.06)
    drawbar(cmesh, model, rf + 0.08, -0.05, 0.5)
    carriage.mesh = cmesh
    add_axles(root, model, {front["id"]: "rim_red"}, member="front_carriage", parent=carriage, z_override=0.0)
    add_axles(root, model, {rear["id"]: "rim_red"}, member="body")
    return root


# ---------------------------------------------------------------------------
# Kombajn
# ---------------------------------------------------------------------------

def build_combine(model: dict) -> Node:
    root = Node(model["id"])
    hl = float(model["dimensions"]["length_m"]) / 2
    front = next(a for a in model["axles"] if a["id"] == "front")
    rear = next(a for a in model["axles"] if a["id"] == "rear")
    zr = axle_z(model, rear)
    rr = float(rear["tire_length_m"]) / 2
    pipe = model["unloading"]["pipe"]
    pivot = pipe["pivot_in_body_m"]
    px = float(pivot[0]) * (-1 if pipe["side"] == "right" else 1)
    pz = float(pivot[1])

    m = MeshData("combine_body")
    # kadłub: dół między kołami, wąsko nad osią skrętną, wyżej pełna szerokość
    box(m, "paint", -0.95, 0.95, 0.7, 2.45, -hl + 0.6, zr - 0.55)
    box(m, "paint", -0.42, 0.42, rr - 0.05, 1.6, zr - 0.6, hl - 0.2)
    box(m, "paint", -0.95, 0.95, 1.6, 2.45, zr - 0.6, hl - 0.2)
    box(m, "metal_dark", -float(rear["track_m"]) / 2 + 0.15, float(rear["track_m"]) / 2 - 0.15,
        rr - 0.06, rr + 0.06, zr - 0.06, zr + 0.06)
    box(m, "paint", -1.2, 1.2, 2.45, 3.0, -1.6, hl - 0.2)
    box(m, "metal_dark", -0.8, 0.8, 2.5, 2.95, hl - 0.22, hl - 0.16)
    cylinder(m, "metal_dark", (0.85, 3.25, hl - 0.8), "y", 0.07, 0.5, 6)
    # przenośnik pochyły do hedera
    socket = next(p for p in model["hitch_ports"] if p["role"] == "socket")
    sz = float(socket["position_m"][1])
    hexa(m, "paint", [(-0.62, 0.32, sz), (0.62, 0.32, sz), (0.62, 0.85, -hl + 0.6), (-0.62, 0.85, -hl + 0.6),
                      (-0.62, 1.1, sz), (0.62, 1.1, sz), (0.62, 1.85, -hl + 0.6), (-0.62, 1.85, -hl + 0.6)])
    # pomost i kabina
    box(m, "metal_dark", -1.05, 1.05, 2.15, 2.25, -hl + 0.05, -1.55)
    cab(m, -0.85, 0.85, 2.25, 3.5, -hl + 0.15, -1.7, belt=0.25)
    box(m, "beacon", -0.08, 0.08, 3.62, 3.72, -2.0, -1.86)
    # zbiornik ziarna (otwarty od góry)
    tz0, tz1 = pz + 0.2, hl - 0.6
    top = 3.9
    frustum(m, "paint", (-1.12, 1.12, tz0, tz1, 3.0), (-1.32, 1.32, tz0 - 0.12, tz1 + 0.12, 3.42))
    box(m, "interior", -1.27, 1.27, 3.42, 3.44, tz0 - 0.08, tz1 + 0.08)
    wall = 0.07
    for side in (-1, 1):
        xo, xi = side * 1.33, side * (1.33 - wall)
        box(m, "paint", min(xo, xi), max(xo, xi), 3.42, top, tz0 - 0.13, tz1 + 0.13)
    box(m, "paint", -1.33, 1.33, 3.42, top, tz0 - 0.13, tz0 - 0.13 + wall)
    box(m, "paint", -1.33, 1.33, 3.42, top, tz1 + 0.13 - wall, tz1 + 0.13)
    # podstawa obrotowa rury
    pipe_y = top + 0.12
    cylinder(m, "metal_dark", (px, (2.95 + pipe_y) / 2, pz), "y", 0.16, pipe_y - 2.95, 6)
    root.mesh = m

    tank_zc = (tz0 + tz1) / 2
    fill = grain_heap("combine_grain", -1.25, 1.25, tz0 - 0.06 - tank_zc, tz1 + 0.06 - tank_zc, 0.25, 0.3)
    root.add(Node("grain_fill", (0.0, 3.44, tank_zc), mesh=fill))

    # rura rozładunkowa, oś lokalna +Z wzdłuż rury, wylot w odległości length_m
    length = float(pipe["length_m"])
    radius = max(float(pipe.get("width_m", 0.18)) * 0.65, 0.1)
    pmesh = MeshData("combine_pipe")
    cylinder(pmesh, "pipe_cream", (0, 0.0, length * 0.48), "z", radius, length * 0.96, 6, phase=0.52)
    box(pmesh, "pipe_cream", -radius, radius, -radius, radius, length * 0.96 - radius, length + radius * 0.6)
    frustum(pmesh, "metal_dark", (-radius * 0.8, radius * 0.8, length - radius * 0.8, length + radius * 0.8, -0.55),
            (-radius, radius, length - radius, length + radius, -radius + 0.01))
    root.add(Node("pipe", (px, pipe_y, pz), mesh=pmesh))

    add_axles(root, model, {"front": "rim_grey", "rear": "rim_grey"})
    return root


# ---------------------------------------------------------------------------
# Heder zbożowy – cała bryła w węźle "lift" (podnoszona/opuszczana klawiszem B)
# ---------------------------------------------------------------------------

def build_header(model: dict) -> Node:
    root = Node(model["id"])
    lift = root.add(Node("lift"))
    w = float(model["dimensions"]["width_m"]) / 2
    l = float(model["dimensions"]["length_m"]) / 2
    m = MeshData("header_body")
    hx = w - 0.1
    # tylna ściana, dno, ślimak
    box(m, "paint", -hx, hx, 0.18, 1.12, l - 0.14, l)
    hexa(m, "paint", [(-hx, 0.06, -l + 0.05), (hx, 0.06, -l + 0.05), (hx, 0.18, l - 0.1), (-hx, 0.18, l - 0.1),
                      (-hx, 0.14, -l + 0.05), (hx, 0.14, -l + 0.05), (hx, 0.3, l - 0.1), (-hx, 0.3, l - 0.1)])
    cylinder(m, "steel_light", (0, 0.45, l - 0.32), "x", 0.17, hx * 2 - 0.1, 6)
    # boczne ściany zakończone klinem rozdzielacza
    for side in (-1, 1):
        x0, x1 = side * hx, side * (hx + 0.1)
        xa, xb = min(x0, x1), max(x0, x1)
        hexa(m, "paint", [(xa, 0.04, -l - 0.5), (xb, 0.04, -l - 0.5), (xb, 0.06, l), (xa, 0.06, l),
                          (xa, 0.3, -l), (xb, 0.3, -l), (xb, 1.12, l), (xa, 1.12, l)])
        beam(m, "paint", (side * (hx - 0.05), 1.12, l - 0.1), (side * (hx - 0.05), 1.18, -0.15), 0.09, 0.1)
    # listwa nożowa
    box(m, "metal_dark", -hx, hx, 0.03, 0.09, -l - 0.12, -l + 0.06)
    lift.mesh = m

    # motowidło: wałek, 5 listew i 2 krzyżaki
    reel = MeshData("header_reel")
    radius = 0.5
    cylinder(reel, "steel_light", (0, 0, 0), "x", 0.06, hx * 2 - 0.2, 6)
    for i in range(5):
        a = 2 * math.pi * i / 5
        cy, cz = math.cos(a) * radius, math.sin(a) * radius
        beam(reel, "reel_red", (-hx + 0.12, cy, cz), (hx - 0.12, cy, cz), 0.08, 0.06)
        for x in (-hx * 0.55, hx * 0.55):
            beam(reel, "metal_dark", (x, 0, 0), (x, cy, cz), 0.04, 0.04)
    lift.add(Node("reel", (0.0, 1.18, -0.15), mesh=reel))
    return root


# ---------------------------------------------------------------------------
# Siewnik – redlice w "lift", znaczniki przejazdów "marker_L"/"marker_R"
# ---------------------------------------------------------------------------

def build_seeder(model: dict) -> Node:
    root = Node(model["id"])
    l = float(model["dimensions"]["length_m"]) / 2
    axle = model["axles"][0]
    za = axle_z(model, axle)
    ra = float(axle["tire_length_m"]) / 2
    half_track = float(axle["track_m"]) / 2
    tw = float(axle["tire_width_m"])
    m = MeshData("seeder_body")
    frame_x = half_track - tw / 2 - 0.08
    # rama: belka przednia i tylna
    box(m, "metal_dark", -frame_x, frame_x, 0.55, 0.7, -0.4, -0.25)
    box(m, "metal_dark", -frame_x, frame_x, 0.55, 0.68, za + 0.25, za + 0.38)
    for x in (-1.2, 1.2):
        box(m, "metal_dark", x - 0.06, x + 0.06, 0.55, 0.7, -0.9, za + 0.38)
    # zbiornik nasion z pokrywą
    frustum(m, "paint", (-1.55, 1.55, -0.9, 0.15, 0.9), (-1.95, 1.95, -1.05, 0.3, 1.7))
    box(m, "steel_light", -2.0, 2.0, 1.7, 1.8, -1.1, 0.35)
    # podpory kół (słupek, wzdłuż którego jeździ belka redlic)
    for side in (-1, 1):
        x = side * (half_track - tw / 2 - 0.05)
        box(m, "metal_dark", x - 0.05, x + 0.05, ra, 0.7, za - 0.05, za + 0.05)
    drawbar(m, model, 0.58, -0.4, 1.2)
    for side in (-1, 1):
        warn_board(m, side * (frame_x - 0.1), 0.72, -0.44)
    root.mesh = m

    # belka redlic (opuszczana przy pracy)
    coulters = MeshData("seeder_coulters")
    disc_z = l - 0.35
    box(coulters, "metal_dark", -frame_x, frame_x, 0.38, 0.48, disc_z - 0.1, disc_z)
    for x in np.linspace(-frame_x + 0.2, frame_x - 0.2, 12):
        box(coulters, "metal", x - 0.025, x + 0.025, 0.2, 0.4, disc_z - 0.06, disc_z - 0.02)
        cylinder(coulters, "steel_light", (x, 0.16, disc_z), "x", 0.15, 0.04, 6)
    root.add(Node("lift", mesh=coulters))

    # znaczniki przejazdów: ramię z talerzem, w spoczynku złożone pionowo
    reach = 2.6
    for side, suffix in ((-1, "L"), (1, "R")):
        arm = MeshData(f"seeder_marker_{suffix}")
        beam(arm, "paint", (0.0, 0.0, 0.0), (side * reach, -0.55, 0.0), 0.07, 0.07)
        cylinder(arm, "steel_light", (side * reach, -0.6, 0.0), "x", 0.17, 0.03, 6)
        root.add(Node(f"marker_{suffix}", (side * frame_x, 0.75, -0.3), mesh=arm))
    add_axles(root, model, {axle["id"]: "rim_cream"})
    return root


# ---------------------------------------------------------------------------
# Kultywator – sekcja środkowa + dwa skrzydła składane do góry (U od tyłu)
#   lift            – cała rama (opuszczana do pracy)
#   wing_L / wing_R – skrzydła z zawiasem na górnej krawędzi ramy (obrót wokół Z)
#   roller*         – wały (środkowy i na skrzydłach)
# ---------------------------------------------------------------------------

def _cultivator_section(m: MeshData, x0: float, x1: float, beams_z, top: float, row_offset: int,
                        T=None) -> None:
    """Rama sekcji z zębami w trzech rzędach; współrzędne w układzie modelu (T: przesunięcie)."""
    def b(sw, a0, a1, y0, y1, z0, z1):
        box(m, sw, a0, a1, y0, y1, z0, z1, matrix=T)
    for z in beams_z:
        b("paint", x0, x1, top - 0.14, top, z - 0.07, z + 0.07)
    for x in (x0 + 0.06, x1 - 0.06):
        b("paint", x - 0.06, x + 0.06, top - 0.14, top - 0.02, beams_z[0] - 0.1, beams_z[-1] + 0.1)
    for row, z in enumerate(beams_z):
        offset = ((row + row_offset) % 3) * 0.25
        for x in np.arange(x0 + 0.2 + offset, x1 - 0.1, 0.75):
            p0 = np.array([x, top - 0.12, z])
            p1 = np.array([x, 0.08, z + 0.1])
            if T is not None:
                p0 = (T @ np.append(p0, 1.0))[:3]
                p1 = (T @ np.append(p1, 1.0))[:3]
            beam(m, "metal_dark", tuple(p0), tuple(p1), 0.05, 0.05)
            b("steel_light", x - 0.04, x + 0.04, 0.0, 0.08, z, z + 0.16)


def build_cultivator(model: dict) -> Node:
    root = Node(model["id"])
    l = float(model["dimensions"]["length_m"]) / 2
    axle = model["axles"][0]
    za = axle_z(model, axle)
    ra = float(axle["tire_length_m"]) / 2
    half_track = float(axle["track_m"]) / 2
    lift_h = float(model.get("visual", {}).get("lift_height_m", 0.4))
    folding = model.get("folding", {})
    top = float(folding.get("hinge_height_m", 0.74))
    wings = folding.get("wings", [])
    center_half = abs(float(wings[0]["hinge_m"][0])) if wings else 1.4
    beams_z = (-l + 0.3, -l + 0.95, -l + 1.55)
    roller_z = l - 0.22
    roller_r = 0.22

    # część stała: dyszel i słupki kół pod sekcją środkową
    base = MeshData("cultivator_base")
    drawbar(base, model, top - 0.12 + lift_h * 0.5, beams_z[0], 1.0, swatch="paint")
    for side in (-1, 1):
        x = side * (half_track - 0.25)
        box(base, "metal_dark", x - 0.06, x + 0.06, ra, top + 0.06 + lift_h, za - 0.06, za + 0.06)
    root.mesh = base

    lift = root.add(Node("lift"))
    center = MeshData("cultivator_center")
    _cultivator_section(center, -center_half, center_half, beams_z, top, 0)
    for side in (-1, 1):
        beam(center, "paint", (side * (center_half - 0.2), top - 0.08, beams_z[-1]), (side * (center_half - 0.2), roller_r, roller_z), 0.08, 0.1)
        # siłownik składania skrzydła
        box(center, "metal", side * (center_half - 0.45) - 0.05, side * (center_half - 0.45) + 0.05, top, top + 0.35, beams_z[1] - 0.05, beams_z[1] + 0.05)
    lift.mesh = center
    roller = MeshData("cultivator_roller_center")
    length = center_half * 2 - 0.3
    cylinder(roller, "metal", (0, 0, 0), "x", roller_r, length, 8, cap_swatch="metal_dark")
    for i in range(4):
        a = 2 * math.pi * i / 4
        y, z = math.cos(a) * roller_r, math.sin(a) * roller_r
        box(roller, "metal_dark", -length / 2, length / 2, y - 0.02, y + 0.02, z - 0.02, z + 0.02)
    lift.add(Node("roller", (0.0, roller_r, roller_z), mesh=roller))

    # skrzydła: zawias na górnej krawędzi ramy przy końcu sekcji środkowej
    for wing in wings:
        side = -1 if wing.get("side") == "left" else 1
        suffix = "L" if side < 0 else "R"
        hx = float(wing["hinge_m"][0])
        wl = float(wing["length_m"])
        hinge = (hx, top, 0.0)
        T = translate(-hinge[0], -hinge[1], -hinge[2])
        wm = MeshData(f"cultivator_wing_{suffix}")
        x0, x1 = sorted((hx + side * 0.02, hx + side * wl))
        _cultivator_section(wm, x0, x1, beams_z, top, 1, T)
        # zawias
        box(wm, "metal_dark", hx - 0.07 - hinge[0], hx + 0.07 - hinge[0], -0.03, 0.05, beams_z[0] - 0.1, beams_z[-1] + 0.1)
        xr = hx + side * (wl - 0.2)
        beam(wm, "paint", (xr - hinge[0], -0.08, beams_z[-1]), (xr - hinge[0], roller_r - top, roller_z), 0.08, 0.1)
        warn_board(wm, hx + side * (wl - 0.1) - hinge[0], top + 0.02 - top, beams_z[0] - 0.1)
        node = lift.add(Node(f"wing_{suffix}", hinge, mesh=wm))
        rm = MeshData(f"cultivator_roller_{suffix}")
        rlen = wl - 0.3
        cylinder(rm, "metal", (0, 0, 0), "x", roller_r, rlen, 8, cap_swatch="metal_dark")
        for i in range(4):
            a = 2 * math.pi * i / 4
            y, z = math.cos(a) * roller_r, math.sin(a) * roller_r
            box(rm, "metal_dark", -rlen / 2, rlen / 2, y - 0.02, y + 0.02, z - 0.02, z + 0.02)
        node.add(Node(f"roller_{suffix}", (side * (0.15 + rlen / 2), roller_r - top, roller_z), mesh=rm))
    add_axles(root, model, {axle["id"]: "rim_cream"})
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
    cylinder(m, "concrete_dark", (0, 0.2, 0), "y", r + 0.4, 0.4, 10)
    cylinder(m, "silo_steel", (0, 0.4 + h / 2, 0), "y", r, h, 10)
    for y in (3.0, 6.5):
        cylinder(m, "silo_band", (0, y, 0), "y", r + 0.04, 0.15, 10)
    cylinder(m, "silo_steel", (0, 0.4 + h + 0.9, 0), "y", r + 0.15, 1.8, 10, radius_end=0.35)
    cylinder(m, "silo_band", (0, 0.4 + h + 1.9, 0), "y", 0.4, 0.3, 6)
    # drabina: dwie szyny
    for x in (-0.25, 0.25):
        box(m, "metal_dark", x - 0.04, x + 0.04, 0.4, h + 0.6, r + 0.03, r + 0.11)
    return Node("silo_tower", mesh=m)


def build_grain_pit(area: dict) -> Node:
    """Krata rozładunkowa (punkt zrzutu ziarna) o wymiarach z map.json."""
    m = MeshData("grain_pit")
    hw = float(area["width_m"]) / 2
    hl = float(area["length_m"]) / 2
    rim = 0.45
    box(m, "concrete", -hw - rim, hw + rim, -0.05, 0.06, -hl - rim, hl + rim)
    box(m, "interior", -hw, hw, 0.0, 0.065, -hl, hl)
    # żółte obramowanie i krata co 1 m
    for edge_z in (-hl - rim, hl):
        box(m, "warn_yellow", -hw - rim, hw + rim, 0.06, 0.075, edge_z, edge_z + rim)
    for edge_x in (-hw - rim, hw):
        box(m, "warn_yellow", edge_x, edge_x + rim, 0.06, 0.075, -hl, hl)
    for x in np.arange(-hw + 0.5, hw, 1.0):
        box(m, "metal", x - 0.05, x + 0.05, 0.065, 0.085, -hl, hl)
    for z in np.arange(-hl + 1.0, hl, 2.0):
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


def build_grain_elevator(map_data: dict) -> Node:
    """Elewator kubełkowy przy silosach; rury prowadzą do dachów silosów z map.json."""
    m = MeshData("grain_elevator")
    obstacles = {o["id"]: o for o in map_data.get("static_obstacles", [])}
    me = obstacles.get("grain_elevator", {"center_m": [0, 0]})
    ex, ez = float(me["center_m"][0]), float(me["center_m"][1])
    top = 18.0
    box(m, "concrete_dark", -1.1, 1.1, 0.0, 0.3, -1.1, 1.1)
    box(m, "silo_steel", -0.7, 0.7, 0.3, top, -0.7, 0.7)
    # głowica
    box(m, "silo_band", -1.0, 1.0, top, top + 1.4, -0.9, 0.9)
    frustum(m, "roof_red", (-1.1, 1.1, -1.0, 1.0, top + 1.4), (-0.6, 0.6, -0.5, 0.5, top + 1.9))
    # stopa elewatora (kosz zasypowy)
    frustum(m, "metal", (-1.0, 1.0, -1.0, 1.0, 0.3), (-0.8, 0.8, -0.8, 0.8, 1.6))
    # rury spustowe do silosów
    for o in obstacles.values():
        if o.get("visual", {}).get("model") != "silo_tower":
            continue
        sx = float(o["center_m"][0]) - ex
        sz = float(o["center_m"][1]) - ez
        scale = float(o["visual"].get("scale", 1.0))
        roof = (0.4 + 10.0 + 1.8) * scale
        beam(m, "pipe_cream", (0.0, top + 0.6, 0.0), (sx * 0.92, roof + 0.3, sz * 0.92), 0.28, 0.28)
    return Node("grain_elevator", mesh=m)


def build_seed_station(map_data: dict) -> Node:
    """Stacja nasion: rama nad przejazdem, worek big-bag z lejem nad wylotem."""
    m = MeshData("seed_station")
    point = (map_data.get("seed_points") or [{}])[0]
    ox = float(point.get("outlet_m", [0, 0])[0])
    outlet_h = float(point.get("outlet_height_m", 2.5))
    posts = [o for o in map_data.get("static_obstacles", []) if o["id"].startswith("seed_station_post")]
    half = max([abs(float(o["center_m"][0]) - ox) for o in posts] or [3.8])
    top = 4.8
    for side in (-1, 1):
        x = side * half
        box(m, "concrete_dark", x - 0.35, x + 0.35, 0.0, 0.2, -0.35, 0.35)
        box(m, "barn_red", x - 0.14, x + 0.14, 0.2, top, -0.14, 0.14)
        beam(m, "barn_red", (x, top - 1.2, 0.0), (x * 0.7, top - 0.15, 0.0), 0.1, 0.1)
    box(m, "barn_red", -half - 0.25, half + 0.25, top - 0.15, top + 0.15, -0.2, 0.2)
    box(m, "wall_cream", -1.6, 1.6, top + 0.15, top + 0.75, -0.08, 0.08)
    # zawiesia i worek big-bag
    for x in (-0.55, 0.55):
        for z in (-0.55, 0.55):
            beam(m, "metal_dark", (x * 0.6, top - 0.15, z * 0.3), (x, top - 0.9, z), 0.03, 0.03)
    bag_bottom = outlet_h + 0.9
    box(m, "warn_white", -0.6, 0.6, bag_bottom, top - 0.9, -0.6, 0.6)
    frustum(m, "warn_white", (-0.6, 0.6, -0.6, 0.6, top - 0.9), (-0.45, 0.45, -0.45, 0.45, top - 0.75))
    box(m, "leaf_dark", -0.61, 0.61, bag_bottom + 0.35, bag_bottom + 0.75, -0.61, 0.61)
    frustum(m, "metal", (-0.12, 0.12, -0.12, 0.12, outlet_h + 0.2), (-0.6, 0.6, -0.6, 0.6, bag_bottom))
    cylinder(m, "metal_dark", (0.0, outlet_h + 0.1, 0.0), "y", 0.1, 0.2, 8)
    return Node("seed_station", mesh=m)


def build_shop_building() -> Node:
    """Salon z maszynami: przeszklony front od strony placu (+Z), płaski dach z pasem szyldu."""
    m = MeshData("shop_building")
    w, d, h = 10.0, 6.0, 5.0
    box(m, "concrete_dark", -w - 0.3, w + 0.3, 0.0, 0.25, -d - 0.3, d + 0.3)
    box(m, "wall_cream", -w, w, 0.25, h, -d, d - 0.6)
    # witryna od frontu
    box(m, "glass", -w + 0.8, w - 0.8, 0.5, h - 0.9, d - 0.62, d - 0.5)
    for x in np.linspace(-w + 0.8, w - 0.8, 5):
        box(m, "metal_dark", x - 0.08, x + 0.08, 0.25, h - 0.8, d - 0.65, d - 0.45)
    box(m, "metal_dark", -w + 0.8, w - 0.8, h - 0.9, h - 0.75, d - 0.65, d - 0.45)
    # brama boczna na maszyny
    box(m, "barn_red_dark", -w - 0.05, -w + 0.02, 0.25, 4.0, -3.5, 2.5)
    # dach z okapem i pas szyldu
    box(m, "roof_dark", -w - 0.6, w + 0.6, h, h + 0.35, -d - 0.6, d + 0.6)
    box(m, "barn_red", -w - 0.6, w + 0.6, h - 0.75, h, d - 0.6, d + 0.6)
    box(m, "warn_white", -3.0, 3.0, h - 0.65, h - 0.1, d + 0.6, d + 0.65)
    return Node("shop_building", mesh=m)


def build_grain_buyer() -> Node:
    """Skup zboża: magazyn z dwuspadowym dachem, wieża elewatora i rura nad kratą (+Z)."""
    m = MeshData("grain_buyer")
    w, d, h = 9.0, 5.0, 5.5
    box(m, "concrete_dark", -w - 0.3, w + 0.3, 0.0, 0.25, -d - 0.3, d + 0.3)
    box(m, "wood", -w, w, 0.25, h, -d, d)
    for side in (-1, 1):
        hexa(m, "roof_red", [(-w - 0.4, h - 0.2, side * (d + 0.5)), (w + 0.4, h - 0.2, side * (d + 0.5)), (w + 0.4, h + 2.4, 0.0), (-w - 0.4, h + 2.4, 0.0),
                             (-w - 0.4, h, side * (d + 0.5)), (w + 0.4, h, side * (d + 0.5)), (w + 0.4, h + 2.6, 0.0), (-w - 0.4, h + 2.6, 0.0)])
    for x0 in (-w, w - 0.01):
        hexa(m, "wood", [(x0, h, -d), (x0, h, d), (x0 + 0.01, h, d), (x0 + 0.01, h, -d),
                         (x0, h + 2.4, 0.0), (x0, h + 2.4, 0.0), (x0 + 0.01, h + 2.4, 0.0), (x0 + 0.01, h + 2.4, 0.0)])
    box(m, "barn_red_dark", -2.5, 2.5, 0.25, 4.0, d, d + 0.06)
    # wieża elewatora i rura do magazynu
    box(m, "silo_steel", w - 2.6, w - 0.8, 0.25, 13.0, d - 1.8, d)
    frustum(m, "roof_red", (w - 2.8, w - 0.6, d - 2.0, d + 0.2, 13.0), (w - 2.0, w - 1.4, d - 1.2, d - 0.6, 13.8))
    beam(m, "pipe_cream", (w - 1.7, 12.0, d - 0.9), (0.0, h + 2.2, 0.0), 0.35, 0.35)
    return Node("grain_buyer", mesh=m)


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
            if str(model["category"]) not in ("truck", "semitrailer"):   # te robi generate_trucks.py
                print(f"  pominięto {model['id']} (kategoria {model['category']})")
            continue
        root = builder(model)
        color = str(model.get("visual", {}).get("body_color", "#cccccc"))
        path = os.path.join(OUT_MACHINES, f"{model['id']}.glb")
        write_glb(path, root, color)
        print(f"  {model['id']:18s} {count_triangles(root):6d} trójkątów -> {os.path.relpath(path, ROOT)}")
    import generate_trucks  # noqa: E402 – tir i naczepy (osobny plik)
    generate_trucks.main()
    print("Otoczenie:")
    world = [build_tree_round(), build_tree_pine(), build_bush(), build_barn(), build_house(),
             build_silo_tower(), build_cloud(), build_fence_segment(), build_hay_bale()]
    world.append(build_grain_elevator(map_data))
    world.append(build_seed_station(map_data))
    world.append(build_shop_building())
    world.append(build_grain_buyer())
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
