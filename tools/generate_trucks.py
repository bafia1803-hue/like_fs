"""Modele 3D tira (ciągnika siodłowego) i naczep zbożowych – szkic do oceny wyglądu.

Uruchomienie (z katalogu projektu):
    python tools/generate_trucks.py

Wymiary bierze z tools/drafts/trucks.json (gra jeszcze tych maszyn nie używa).
Konwencja osi i nazw węzłów jak w generate_models.py (X w prawo, Y w górę, przód w −Z,
środek nadwozia w (0, 0, 0) na poziomie gruntu). Nowe węzły:
  saddle         – siodło tira (płyta z gardzielą), środek w osi sworznia
                   (nie „fifth_wheel”: importer Godota traktuje końcówkę „_wheel” jako koło pojazdu)
  kingpin        – sworzeń naczepy (spód płyty sprzęgu), do dopasowania z siodłem
  landing_legs   – nogi podporowe naczepy; model jest w pozycji opuszczonej (postój),
                   po podpięciu gra podnosi je w osi Y
  tailgate       – tylne drzwi naczepy z zawiasem u góry (uchylają się przy rozładunku)
  grain_fill     – ładunek; początek węzła przy TYLNEJ ścianie, bryła sięga do przodu (−Z),
                   więc skalowanie w osi Z zmniejsza ładunek od przodu (taśmociąg w podłodze)
"""
from __future__ import annotations

import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from gltf_builder import MeshData, Node, arc_x, beam, box, count_triangles, cylinder, frustum, write_glb  # noqa: E402
import generate_models as gm  # noqa: E402

ROOT = gm.ROOT
DRAFTS = os.path.join(ROOT, "tools", "drafts", "trucks.json")

_dual_cache: dict = {}


def dual_wheel_mesh(radius: float, width: float, rim: str, side: int) -> MeshData:
    """Koła bliźniacze: dwie opony obok siebie (oś tira i naczepy); felga po stronie zewnętrznej."""
    key = (round(radius, 3), round(width, 3), rim, side)
    if key in _dual_cache:
        return _dual_cache[key]
    mesh = MeshData(f"dual_{int(radius * 200)}_{int(width * 100)}_{'L' if side < 0 else 'R'}")
    for offset in (-width * 0.52, width * 0.52):
        cylinder(mesh, "tire", (offset, 0, 0), "x", radius, width, 10, cap_swatch="tire_side")
    outer = side * width * 0.52
    cylinder(mesh, rim, (outer + side * 0.01, 0, 0), "x", radius * 0.55, width + 0.02, 8, phase=0.2)
    cylinder(mesh, "steel_light", (outer + side * (width * 0.5 + 0.02), 0, 0), "x", radius * 0.22, 0.06, 8)
    _dual_cache[key] = mesh
    return mesh


def add_wheels(root: Node, model: dict, rim: str, fender=None) -> None:
    for axle in model["axles"]:
        radius = float(axle["tire_length_m"]) / 2.0
        width = float(axle["tire_width_m"])
        half_track = float(axle["track_m"]) / 2.0
        z = gm.axle_z(model, axle)
        for side, suffix in ((-1, "L"), (1, "R")):
            if axle.get("dual"):
                node_mesh = dual_wheel_mesh(radius, width, rim, side)
            else:
                node_mesh = gm.wheel_mesh(radius, width, rim)
            pos = (side * half_track, radius, z)
            if axle.get("steerable"):
                steer = root.add(Node(f"steer_{axle['id']}_{suffix}", pos))
                steer.add(Node(f"spin_{axle['id']}_{suffix}", mesh=node_mesh))
                if fender:
                    fender(steer, axle, side)
            else:
                root.add(Node(f"spin_{axle['id']}_{suffix}", pos, mesh=node_mesh))


# ---------------------------------------------------------------------------
# Tir: amerykański ciągnik siodłowy z długą maską
# ---------------------------------------------------------------------------

def build_truck(model: dict) -> Node:
    root = Node(model["id"])
    m = MeshData("truck_body")
    hl = float(model["dimensions"]["length_m"]) / 2.0
    hw = float(model["dimensions"]["width_m"]) / 2.0
    front = next(a for a in model["axles"] if a["id"] == "front")
    drives = [a for a in model["axles"] if a["id"] != "front"]
    zf = gm.axle_z(model, front)
    rf = float(front["tire_length_m"]) / 2.0
    zd = [gm.axle_z(model, a) for a in drives]
    rd = float(drives[0]["tire_length_m"]) / 2.0
    fw = model["fifth_wheel"]
    z5 = -hl + float(fw["distance_from_front_m"])
    y5 = float(fw["height_m"])
    nose = -hl

    # rama: dwie podłużnice na całej długości i poprzeczki
    for x in (-0.45, 0.45):
        box(m, "metal_dark", x - 0.07, x + 0.07, 0.72, 1.0, nose + 0.25, hl - 0.05)
    for z in (zf, zd[0] - 0.7, z5, hl - 0.15):
        box(m, "metal_dark", -0.45, 0.45, 0.78, 0.94, z - 0.06, z + 0.06)
    # zderzak (chrom) i oś przednia
    box(m, "steel_light", -hw + 0.05, hw - 0.05, 0.42, 0.78, nose, nose + 0.18)
    box(m, "metal_dark", -float(front["track_m"]) / 2 + 0.2, float(front["track_m"]) / 2 - 0.2, rf - 0.07, rf + 0.07, zf - 0.08, zf + 0.08)

    # długa maska: lekko zwężana ku górze i do przodu, z atrapą chłodnicy
    hood_front, hood_back = nose + 0.18, nose + 2.45
    frustum(m, "paint", (-0.62, 0.62, hood_front, hood_back, 0.95), (-0.52, 0.52, hood_front + 0.18, hood_back, 2.02))
    box(m, "steel_light", -0.55, 0.55, 0.92, 1.95, hood_front - 0.05, hood_front + 0.02)
    for i in range(7):
        y = 1.04 + i * 0.13
        box(m, "metal_dark", -0.47, 0.47, y, y + 0.06, hood_front - 0.07, hood_front - 0.04)
    box(m, "warn_yellow", -0.1, 0.1, 1.98, 2.06, hood_front + 0.2, hood_front + 0.32)   # znaczek na masce
    # szerokie błotniki przednie przyklejone do maski, z reflektorami
    for side in (-1, 1):
        x0, x1 = sorted((side * 0.6, side * (hw - 0.02)))
        arc_x(m, "paint", (zf, rf), x0, x1, rf + 0.08, 0.08, 8, 172, 6)
        box(m, "paint", x0, x1, 0.95, 1.02, zf + rf * 0.9, hood_back + 0.05)            # stopień błotnika do kabiny
        box(m, "light_white", side * 0.95 - 0.16, side * 0.95 + 0.16, 1.06, 1.2, zf - rf - 0.14, zf - rf - 0.06)
        box(m, "light_orange", side * (hw - 0.12) - 0.06, side * (hw - 0.12) + 0.06, 1.0, 1.08, zf - rf - 0.1, zf - rf - 0.04)
    # filtry powietrza przy masce
    for side in (-1, 1):
        cylinder(m, "steel_light", (side * 0.82, 1.55, hood_back - 0.35), "y", 0.2, 0.75, 8)

    # kabina (dzienna z małym przedziałem sypialnym)
    cab_z0, cab_z1 = hood_back, z5 - 1.75
    floor_y, belt_y, roof_y = 1.0, 2.1, 2.95
    box(m, "paint", -hw + 0.05, hw - 0.05, floor_y, belt_y, cab_z0, cab_z1)
    # przednia szyba pochylona i boczne okna
    frustum(m, "glass", (-hw + 0.1, hw - 0.1, cab_z0 + 0.02, cab_z1 - 0.7, belt_y), (-hw + 0.14, hw - 0.14, cab_z0 + 0.3, cab_z1 - 0.7, roof_y - 0.05))
    box(m, "paint", -hw + 0.1, hw - 0.1, belt_y, roof_y - 0.05, cab_z1 - 0.72, cab_z1)
    for side in (-1, 1):
        x0, x1 = sorted((side * (hw - 0.12), side * (hw - 0.09)))
        box(m, "paint", x0, x1, belt_y, roof_y - 0.05, cab_z0 + 0.28, cab_z0 + 0.36)       # słupek A
    box(m, "paint", -hw + 0.06, hw - 0.06, roof_y - 0.05, roof_y + 0.08, cab_z0 + 0.25, cab_z1)
    # owiewka dachowa
    frustum(m, "paint", (-hw + 0.15, hw - 0.15, cab_z0 + 0.6, cab_z1, roof_y + 0.08), (-hw + 0.3, hw - 0.3, cab_z0 + 1.05, cab_z1, roof_y + 0.62))
    box(m, "light_orange", -0.5, 0.5, roof_y + 0.08, roof_y + 0.14, cab_z0 + 0.3, cab_z0 + 0.36)
    # lusterka
    for side in (-1, 1):
        x = side * (hw + 0.2)
        beam(m, "steel_light", (side * (hw - 0.05), 2.2, cab_z0 + 0.35), (x, 2.3, cab_z0 + 0.35), 0.04, 0.04)
        box(m, "steel_light", x - 0.06, x + 0.06, 2.05, 2.5, cab_z0 + 0.3, cab_z0 + 0.42)
    # zbiorniki paliwa i schodki pod kabiną
    for side in (-1, 1):
        cylinder(m, "steel_light", (side * 0.95, 0.72, (cab_z0 + cab_z1) / 2), "z", 0.3, cab_z1 - cab_z0 - 0.3, 10)
        box(m, "metal_dark", side * 0.9 - 0.2, side * 0.9 + 0.2, 0.36, 0.42, cab_z0 + 0.15, cab_z0 + 0.55)
    # kominy wydechowe za kabiną (chrom)
    for side in (-1, 1):
        x = side * (hw - 0.22)
        cylinder(m, "steel_light", (x, 2.25, cab_z1 + 0.14), "y", 0.09, 2.7, 8)
        cylinder(m, "metal_dark", (x, 3.62, cab_z1 + 0.14), "y", 0.1, 0.06, 8)

    # siodło: podstawa i płyta (osobny węzeł, gardziel skierowana do tyłu)
    box(m, "metal_dark", -0.4, 0.4, 1.0, y5 - 0.1, z5 - 0.35, z5 + 0.35)
    plate = MeshData("saddle_plate")
    cylinder(plate, "metal_dark", (0, -0.05, 0), "y", 0.55, 0.1, 12)
    box(plate, "warn_black", -0.09, 0.09, -0.0, 0.01, 0.0, 0.58)        # gardziel na sworzeń
    box(plate, "metal", -0.62, 0.62, -0.14, -0.08, -0.12, 0.12)        # oś wahliwa
    root.add(Node("saddle", (0.0, y5, z5), mesh=plate))
    # błotniki nad tandemem i chlapacze
    for side in (-1, 1):
        x0, x1 = sorted((side * 0.62, side * (hw - 0.04)))
        box(m, "metal_dark", x0, x1, rd * 2 + 0.08, rd * 2 + 0.13, zd[0] - rd - 0.1, zd[-1] + rd + 0.1)
        box(m, "black", x0 + 0.1 * (side > 0), x1 - 0.1 * (side < 0), 0.25, rd * 2 + 0.08, zd[-1] + rd + 0.1, zd[-1] + rd + 0.14)
    for side in (-1, 1):
        box(m, "light_red", side * 0.8 - 0.12, side * 0.8 + 0.12, 0.85, 0.97, hl - 0.06, hl)

    root.mesh = m

    def front_fender(parent: Node, axle: dict, side: int) -> None:
        pass   # błotniki są stałe (na masce), koła skręcają się pod nimi

    add_wheels(root, model, "rim_grey", front_fender)
    return root


# ---------------------------------------------------------------------------
# Naczepa zbożowa: skrzynia z ruchomą podłogą, tylne drzwi, nogi podporowe
# ---------------------------------------------------------------------------

def build_semitrailer(model: dict) -> Node:
    root = Node(model["id"])
    m = MeshData(model["id"] + "_body")
    length = float(model["dimensions"]["length_m"])
    hl = length / 2.0
    hw = float(model["dimensions"]["width_m"]) / 2.0
    zk = -hl + float(model["kingpin"]["distance_from_front_m"])
    deck = float(model["deck_height_m"])
    floor_top = deck + 0.15
    top = floor_top + float(model["box_height_m"])
    zs = [gm.axle_z(model, a) for a in model["axles"]]
    r = float(model["axles"][0]["tire_length_m"]) / 2.0
    zl = -hl + float(model["legs_from_front_m"])

    # rama: dwie podłużnice pod całą skrzynią, płyta sprzęgu z przodu (leży na siodle)
    for x in (-0.5, 0.5):
        box(m, "metal_dark", x - 0.07, x + 0.07, 2 * r + 0.05, deck, -hl + 0.1, hl - 0.15)
    box(m, "metal_dark", -0.9, 0.9, deck - 0.05, deck, -hl + 0.05, zk + 1.2)
    # podłoga i skrzynia (ściany z żebrami)
    box(m, "metal", -hw, hw, deck, floor_top, -hl, hl)
    for side in (-1, 1):
        x0, x1 = sorted((side * hw, side * (hw - 0.06)))
        box(m, "paint", x0, x1, floor_top, top, -hl, hl)
        box(m, "steel_light", x0 - 0.02, x1 + 0.02, top - 0.08, top + 0.02, -hl, hl)    # górna krawędź
        rib = -hl + 0.6
        while rib < hl - 0.3:
            xo = side * (hw + 0.02)
            box(m, "metal", min(xo, side * hw), max(xo, side * hw), floor_top, top - 0.08, rib - 0.05, rib + 0.05)
            rib += 1.2
        box(m, "metal_dark", x0 - 0.02, x1 + 0.02, deck - 0.1, floor_top, -hl, hl)       # listwa dolna
    box(m, "paint", -hw, hw, floor_top, top + 0.15, -hl, -hl + 0.08)                     # ściana czołowa (wyższa)
    box(m, "steel_light", -hw, hw, top + 0.1, top + 0.18, -hl - 0.02, -hl + 0.1)
    # płyta tylnej ramy drzwi
    for side in (-1, 1):
        x0, x1 = sorted((side * hw, side * (hw - 0.12)))
        box(m, "metal_dark", x0, x1, deck, top, hl - 0.1, hl)
    # osie, wspólny błotnik tandemu, odbojnica i światła z tyłu
    for z in zs:
        box(m, "metal_dark", -0.85, 0.85, r - 0.07, r + 0.07, z - 0.07, z + 0.07)
        box(m, "metal", -0.55, 0.55, r + 0.05, 2 * r + 0.05, z - 0.1, z + 0.1)
    for side in (-1, 1):
        x0, x1 = sorted((side * 0.62, side * (hw - 0.02)))
        box(m, "metal_dark", x0, x1, 2 * r + 0.06, 2 * r + 0.11, zs[0] - r - 0.15, zs[-1] + r + 0.15)
        box(m, "black", x0, x1, 0.3, 2 * r + 0.06, zs[-1] + r + 0.15, zs[-1] + r + 0.19)
    box(m, "warn_red", -hw + 0.1, hw - 0.1, 0.45, 0.6, hl - 0.05, hl + 0.02)
    for side in (-1, 1):
        x = side * (hw - 0.25)
        beam(m, "metal_dark", (x, 0.52, hl), (x, deck, hl - 0.3), 0.08, 0.08)
        box(m, "light_red", x - 0.14, x + 0.14, 0.62, 0.74, hl - 0.02, hl + 0.03)
    # boczne osłony przeciwwjazdowe między nogami a osiami
    for side in (-1, 1):
        x = side * (hw - 0.08)
        for y in (0.55, 0.85):
            box(m, "steel_light", x - 0.03, x + 0.03, y, y + 0.08, zl + 0.6, zs[0] - r - 0.3)
        for z in (zl + 0.7, (zl + zs[0]) / 2, zs[0] - r - 0.4):
            box(m, "metal_dark", x - 0.03, x + 0.03, 0.55, deck, z - 0.04, z + 0.04)
    # sworzeń (osobny węzeł: spód płyty sprzęgu nad siodłem)
    pin = MeshData("kingpin")
    cylinder(pin, "steel_light", (0, -0.08, 0), "y", 0.05, 0.16, 8)
    root.add(Node("kingpin", (0.0, deck, zk), mesh=pin))
    root.mesh = m

    # nogi podporowe (opuszczone: stopy na ziemi)
    legs = MeshData("landing_legs")
    for side in (-1, 1):
        x = side * 0.95
        box(legs, "metal_dark", x - 0.08, x + 0.08, 0.35, deck - 0.02, -0.08, 0.08)       # rura zewnętrzna
        box(legs, "metal", x - 0.055, x + 0.055, 0.08, 0.4, -0.055, 0.055)                # wysuw
        box(legs, "metal_dark", x - 0.17, x + 0.17, 0.0, 0.08, -0.17, 0.17)               # stopa
        beam(legs, "metal_dark", (x, 0.75, 0.0), (side * 0.45, deck - 0.05, 0.75), 0.06, 0.06)
    beam(legs, "metal_dark", (-0.95, 0.7, 0.0), (0.95, 0.7, 0.0), 0.06, 0.06)
    box(legs, "metal_dark", 0.95 + 0.08, 0.95 + 0.22, 0.8, 1.0, -0.08, 0.08)              # przekładnia z korbą
    beam(legs, "steel_light", (1.2, 0.9, 0.0), (1.2, 0.6, 0.18), 0.03, 0.03)
    root.add(Node("landing_legs", (0.0, 0.0, zl), mesh=legs))

    # tylne drzwi: zawias u góry
    hinge = (0.0, top, hl)
    door = MeshData(model["id"] + "_door")
    box(door, "paint", -hw + 0.12, hw - 0.12, floor_top - top, 0.0, -0.06, 0.0)
    for x in (-0.6, 0.6):
        box(door, "metal", x - 0.03, x + 0.03, floor_top - top + 0.1, -0.1, 0.0, 0.04)
    box(door, "warn_white", -0.5, 0.5, floor_top - top + 0.15, floor_top - top + 0.3, 0.0, 0.02)
    root.add(Node("tailgate", hinge, mesh=door))

    # ładunek: początek przy tylnej ścianie, bryła do przodu (−Z)
    fill_len = length - 0.3
    fill = MeshData(model["id"] + "_grain")
    fill_h = top - floor_top - 0.25
    box(fill, "grain", -hw + 0.08, hw - 0.08, 0.0, fill_h, -fill_len, 0.0)
    frustum(fill, "grain", (-hw + 0.08, hw - 0.08, -fill_len, 0.0, fill_h), (-hw + 0.5, hw - 0.5, -fill_len + 0.4, -0.4, fill_h + 0.25))
    root.add(Node("grain_fill", (0.0, floor_top, hl - 0.15), mesh=fill))
    add_wheels(root, model, "rim_grey")
    return root


def main() -> None:
    with open(DRAFTS, encoding="utf-8") as handle:
        drafts = json.load(handle)
    for model in drafts["machines"]:
        builder = {"truck": build_truck, "semitrailer": build_semitrailer}[model["category"]]
        root = builder(model)
        path = os.path.join(gm.OUT_MACHINES, f"{model['id']}.glb")
        write_glb(path, root, str(model["visual"]["body_color"]))
        print(f"  {model['id']:18s} {count_triangles(root):6d} trójkątów -> {os.path.relpath(path, ROOT)}")


if __name__ == "__main__":
    main()
