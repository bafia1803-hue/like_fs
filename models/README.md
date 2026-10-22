# Modele 3D

Low-poly modele w formacie `.glb` (glTF 2.0). Otworzysz je w Godocie albo w Blenderze (File → Import → glTF).

- `machines/` – maszyny z `files/machines.json`: ciągnik, przyczepa dwuosiowa, kombajn, heder, siewnik, kultywator;
  tir i dwie naczepy (`truck_basic`, `semitrailer_small`, `semitrailer_large`) – robi je
  `tools/generate_trucks.py` (uruchamiany też przez `generate_models.py`)
- `world/` – otoczenie i farma: drzewa, krzak, stodoła, dom, silosy, elewator, magazyn (palety z workami), krata rozładunkowa, bele, płot, chmura
- `palette.png` – wspólna tekstura palety kolorów (8×8 pól z delikatnym gradientem), osadzona w każdym `.glb`

Rośliny na polu (fazy wzrostu, dojrzałe zboże, ściernisko), trawa i gleba nie są plikami `.glb`.
Rysuje je karta graficzna na podstawie stanu komórek pola: `scripts/view3d/field_view_3d.gd`, `shaders/`.

## Generowanie

Modele powstają ze skryptu, który czyta wymiary, osie, koła, zaczepy i rurę z `files/machines.json`:

```
python tools/generate_models.py      # wymaga numpy i Pillow
```

Po zmianie katalogu maszyn uruchom skrypt ponownie; Godot sam zaimportuje nowe pliki.
Podgląd wszystkich modeli: `godot -s tools/preview_models.gd -- <folder_na_obrazki>`.

## Nazwy węzłów używane przez grę

Gra (`scripts/view3d/machine_view_3d.gd`) porusza częściami modelu po nazwach węzłów. Jeśli podmienisz
model na własny (np. z Blendera), zachowaj te nazwy i osie (X w prawo, Y w górę, przód w −Z,
środek nadwozia w (0, 0, 0) na poziomie gruntu):

| Węzeł | Co robi |
|---|---|
| `steer_<oś>_L`, `steer_<oś>_R` | zwrotnica koła skrętnego, obrót wokół Y o kąt z fizyki |
| `spin_<oś>_L`, `spin_<oś>_R` | koło toczy się (obrót wokół X); promień z `tire_length_m` |
| `carriage` | przedni wózek przyczepy na obrotnicy (obrót wokół Y) |
| `tipper` | skrzynia przyczepy z zawiasem z tyłu, podnoszona przy rozładunku (wywrotka) |
| `tailgate` | tylna klapa skrzyni z zawiasem u góry, odchyla się przy wysypie |
| `pipe` | rura rozładunkowa kombajnu, rura wzdłuż lokalnego +Z, wylot w odległości `length_m` |
| `grain_fill` | ładunek ziarna, skalowany w osi Y według zapełnienia |
| `reel` | motowidło hedera (kręci się podczas pracy i jazdy) |
| `roller`, `roller_L`, `roller_R` | wały kultywatora (toczą się podczas pracy) |
| `saddle` / `kingpin` | siodło tira / sworzeń naczepy (punkt sprzęgu) |
| `landing_legs` | nogi podporowe naczepy; po podpięciu gra podnosi je w osi Y |
| `spinner_L` / `spinner_R` | tarcze rozsiewacza nawozu (obrót wokół Y podczas pracy) |
| `lift` | część opuszczana do pracy (heder, rama kultywatora, redlice siewnika). Model jest w pozycji roboczej; poza pracą gra podnosi ją o `visual.lift_height_m` |
| `wing_L`, `wing_R` | skrzydła maszyny składanej (kultywator); zawias na górnej krawędzi ramy, złożone = obrót o 90° wokół Z |
| `marker_L`, `marker_R` | znaczniki siewnika: poza pracą złożone pionowo, przy pracy rozłożone |

Materiał o nazwie `paint` dostaje kolor `visual.body_color` z `machines.json`, więc kolor maszyny
zmienisz bez ponownego generowania modelu.
