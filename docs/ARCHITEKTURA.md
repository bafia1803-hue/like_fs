# Architektura: warstwa gry i widoki

Gra jest podzielona na trzy niezależne warstwy. Łączy je `scripts/world.gd`.

```
World (world.gd)
├── Simulation          – warstwa gry: fizyka, zasady, dane. Nic nie rysuje.
├── View2D | View3D     – widoki: tylko czytają stan gry i go rysują (przełącznik: V)
└── Interface           – UI: informator, panel tras, komunikaty, przyciski
```

## Warstwa gry (`scripts/*.gd`)

| Skrypt | Odpowiada za |
|---|---|
| `vehicle.gd`, `trailer.gd`, `single_axle_implement.gd`, `mounted_implement.gd` | maszyny i ich fizyka (Rapier2D) |
| `hitch_system.gd` | zaczepy |
| `field_work_system.gd`, `field_grid.gd` | praca na polu, stan komórek (`stage_texture`) |
| `grain_transfer_system.gd`, `unloading_pipe.gd` | rura kombajnu, wywrotka, silosy |
| `farm_services.gd` | załadunek z silosu do przyczepy, stacja nasion |
| `static_obstacles.gd` | kolizje budynków i słupów z `map.json` |
| `route_system.gd` | nagrywanie i odtwarzanie tras (`record_path`, `preview_path`) |
| `save_codec.gd`, `save_manager.gd` | zapis gry |

Zasada: skrypty warstwy gry nie tworzą węzłów graficznych i nie znają widoków.

## Widoki

Oba widoki mają ten sam interfejs: `setup(world)`, `set_active(bool)`, `follow(pojazd)`, `show_overview()`.
Dane gry czytają wyłącznie przez metody `get_*` świata (`get_machines`, `get_field_grids`,
`get_silos`, `get_farm_points`, `get_route_system`, `get_map_data` …).

- `scripts/view2d/` – dotychczasowy widok z góry (kamera 2D, rysunki maszyn, pole, farma, trasy)
- `scripts/view3d/` – grafika low-poly (modele `.glb`, pole na GPU, otoczenie, kamera 3D, animacje)

Nieaktywny widok jest odłączony od drzewa sceny, więc nie zużywa czasu procesora ani karty.
Wybrany widok zapisuje się w `user://settings.cfg`.

Nowy widok (np. minimapa) = nowy skrypt z tymi czterema metodami, dodany w `world.gd` → `_create_views()`.

## Informator (`scripts/ui/informator.gd`)

Panel w prawym górnym rogu: sterowana maszyna i podpięte narzędzie.
Treść dostarczają skrypty z `scripts/ui/info/` (dziedziczą po `info_provider.gd`):

- `speed_info.gd` – prędkość
- `work_info.gd` – praca narzędzia (B): opuszczone/włączone, limit prędkości
- `storage_info.gd` – zawartość i pojemność zbiorników (kombajn, przyczepa, siewnik)
- `status_info.gd` – bieżący przeładunek (rura, wywrotka, silos, stacja nasion)

Nowa informacja: utwórz skrypt z metodą `rows(maszyna, rola, world)` zwracającą wiersze
`{"label", "value", "ratio", "color"}` i dopisz jego ścieżkę do `Informator.PROVIDERS`.

## Farma (`files/map.json`)

- `surfaces` – plac farmy (wygląd)
- `static_obstacles` – silosy, elewator, wiata, słupy (kolizja w grze; klucz `visual` tylko dla widoków)
- `unload_points` – krata zrzutu do silosu
- `load_points` – załadunek z silosu: przyczepa staje tak, by wylot był nad skrzynią
- `seed_points` – stacja nasion: siewnik staje pod lejem; ziarno z silosu zamienia się w materiał siewny (`grain_to_seed`)

## Praca maszyn i wzrost roślin

- **B** – opuszcza/podnosi heder i kultywator, włącza/wyłącza siewnik (`field_work_system.toggle_work`).
  Stan jest w `instance_state.work_state` (`enabled`, `lowered`); narzędzie pracuje tylko wtedy.
  Pracujące narzędzie ogranicza prędkość pojazdu do `work.max_working_speed_kmh` z `machines.json`
  (heder 10, kultywator i siewnik 18 km/h). Bez pracy obowiązuje `drive.forward_speed_kmh`
  (kombajn 30, ciągnik 35 km/h). Widoki animują opuszczanie na podstawie `work_state`.
- **Trasy** zapisują w każdej próbce także pracę narzędzia (format trasy v3, kolumna `tool_working`).
  Odtworzenie opuszcza/podnosi narzędzie dokładnie tam, gdzie zrobiono to przy nagrywaniu.
  Starsze trasy (v1, v2) nie zmieniają stanu narzędzia.
- **Sen** (przycisk lub N) – ekran ciemnieje (1,6 s, szybciej na początku), w pełnej ciemności rośliny rosną,
  potem rozjaśnia się (1,9 s, szybciej na końcu); razem ok. 4 s (`SLEEP_*_SECONDS` w `world.gd`).
  Na czas snu gra jest w pauzie (`get_tree().paused`), więc klawisze, przyciski, kamera i fizyka same
  przestają działać; w pauzie pracują tylko zasłona i odświeżanie pól (`PROCESS_MODE_ALWAYS`).
  Rośliny nie rosną same. Każdy sen przesuwa wszystkie zasiane komórki
  o jedną fazę: zasiane → jasne → ciemne → dojrzałe (`field_grid.sleep`).

## Kombajn: prowadzenie

Kombajn ma napęd na przedniej osi, a skręt na tylnej. Tylna oś ma większą przyczepność bocznej (`lateral_grip` 1.8) i więcej masy (`load_weight` 1.5), dzięki czemu po puszczeniu kierownicy ciało przestaje się obracać w ciągu ok. 0,5 s zamiast 1,5 s. Kąt skrętu: maks. 45°, powrót 70°/s.

## Składanie i profile kolizji (`single_axle_implement.gd`)

- `physics.collision_profiles` w `machines.json`: nazwane zestawy prostokątów kolizji. Aktywny jest jeden:
  - maszyna składana (klucz `folding`): `folded` / `unfolded`,
  - pozostałe (np. siewnik): `inactive` / `working` (zależnie od pracy B).
- `folding.duration_s` – czas rozkładania i składania; animacja skrzydeł (`wing_L`, `wing_R`) trwa dokładnie tyle,
  bo widok 3D czyta postęp z gry (`get_fold_progress`).
- **B** przy maszynie składanej: złożona → rozkłada się i opuszcza; pracująca → podnosi się i składa;
  B w trakcie rozkładania → składa z powrotem.
- Przed rozłożeniem gra sprawdza wolne miejsce pod rozłożonymi skrzydłami (`folding.wings`: zawias, długość,
  głębokość). Brak miejsca → komunikat, maszyna zostaje złożona. W trakcie rozkładania sprawdzany jest obszar
  pod opadającymi skrzydłami; przeszkoda → maszyna składa się z powrotem.
- Twarda kolizja rozłożonego profilu włącza się dopiero po pełnym rozłożeniu (do tego czasu skrzydła
  „czują” przeszkody tylko przez zapytanie o miejsce, więc niczego nie odpychają).
- Trasy (format v4) zapisują też postęp rozłożenia; odtworzenie składa i rozkłada narzędzie tak jak w nagraniu.
