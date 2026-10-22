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
| `routes/route_preview.gd` | **podgląd trasy** – czysta logika: czas, przebieg, pozy zestawu w chwili t (bez świata i UI) |
| `save_codec.gd`, `save_manager.gd` | zapis gry |
| `economy/economy.gd` | pieniądze gracza (`save_data.economy`), `earn` / `spend`, sygnał `money_changed` |
| `economy/price_list.gd` | **cennik** – jedyne miejsce, które określa ceny (dane w `files/prices.json`) |
| `shop/machine_footprint.gd`, `shop/lot_planner.gd` | obrys maszyny i układanie kupionych maszyn na placu sklepu |

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

## Ekonomia, sklep i pola

- **Ceny** – `files/prices.json`, czytane wyłącznie przez `PriceList`: skup ziarna (zł/l), nasiona (zł/l),
  maszyny (zł), odsetek przy odsprzedaży, ceny pól (stałe, niezależne od powierzchni), pieniądze na start.
- **Zrzut z wywrotki** (silos i skup): skrzynia podnosi się przez `start_delay_seconds`, potem cały ładunek
  przechodzi w jednym kroku (bez limitu l/s). Widok 3D dogrywa 2-sekundową animację wysypu.
- **Skup zboża** (`map.json` → `sell_points`): jak krata silosu, ale ziarno jest sprzedawane;
  pieniądze dopisuje `GrainTransfer` przez `Economy.earn`.
- **Załadunek z silosu i stacja nasion**: maszyna (lub przyczepa/siewnik sterowanego zestawu) pod wylotem →
  przycisk na dole ekranu → okienko wyboru ziarna (`ui/fill_dialog.gd`). Napełnianie trwa, dopóki maszyna stoi
  pod wylotem (`max_transfer_l_per_s`: przyczepa 1000 l/s, siewnik 300 l/s); nasiona pobierają pieniądze.
  Bez mieszania: do przyczepy z pszenicą nie da się załadować jęczmienia (tak samo nasiona i zbiornik kombajnu).
- **Sklep** (K lub przycisk): zakładki „Kup maszyny” i „Moje maszyny”, kafelki z obracanym podglądem 3D
  (`ui/machine_preview.gd`, własny mały świat 3D; obracany tylko myszką). Na czas zakupów gra jest w pauzie.
  Kupiona maszyna staje na placu sklepu (`map.json` → `shop.lot`). `LotPlanner` skanuje plac rzędami od
  lewego górnego rogu i bierze pierwsze miejsce, gdzie obrys maszyny + odstęp (`shop.spacing_m`) nie nachodzi
  na nic – maszyny stają w równych rzędach, a zajęte fragmenty są omijane. Brak miejsca → komunikat, bez opłaty.
- **Sprzedaż maszyn** – także przypiętych: połączenie znika razem z maszyną (narzędzie sprzedanego ciągnika
  zostaje odpięte na miejscu). Zablokowana tylko w trakcie odtwarzania/nagrywania trasy zestawu
  i dla ostatniego pojazdu.
- **Pola** – `owned_at_start` w `map.json`, własność w `save_data.owned_fields`. Nad cudzym polem pojawia się
  przycisk „Kup pole”. Na cudzym polu narzędzia nie pracują. Pól nie można sprzedać.

## Trasy: nagrywanie i przegląd

- **Nagrywanie** – okrągły przycisk w lewym dolnym rogu, nad przyciskiem tras (`ui/routes/record_controls.gd`):
  czerwony trójkąt = nagrywaj, dwie kreski = zatrzymaj (obok czas nagrania). Po zatrzymaniu okienko `record_save_dialog.gd`: nazwa + Zapisz / Kontynuuj / Usuń przejazd
  (gra w pauzie, nagrywanie stoi).
- **Przegląd** – okrągły przycisk tras (start–szlaczek–meta, licznik zestawów w drodze) lub R (`ui/routes/route_browser.gd`, gra w pauzie): zakładki „Ten zestaw”
  (trasy sterowanego zestawu) i „Wszystkie trasy” (trasy takiego samego modelu pojazdu z dowolnym narzędziem);
  przy każdej trasie przycisk oka (przebieg na mapce, domyślnie widoczne tylko trasy zestawu), minimapa, suwak czasu
  z przyciskiem odtwarzania (play/pauza) i prędkością x2 → x3 → x5 → x10 → x20 (suwak działa też w trakcie),
  uruchom / przerwij / zmień nazwę / usuń. W świecie 3D przebieg widać tylko podczas nagrywania.
- **Uruchom trasę** – `RouteSystem.arm()` wyznacza przejazd. Zestaw na miejscu startu (≤ start_distance_m,
  kierunek ±30°), zatrzymany i z narzędziem w stanie z nagrania → start od razu. Inaczej okno się zamyka,
  komunikat „Podjedź na miejsce startu”, w świecie stoi półprzezroczysty zestaw widmo
  (`view3d/route_ghost_3d.gd`, `view2d/route_view_2d.gd`) z czerwonym wskaźnikiem, a na dole są przyciski
  „Uruchom trasę” (tylko na miejscu startu) i „Odwołaj przejazd”. Start sprawdza też narzędzie:
  „Aktywuj narzędzie (B)” / „Dezaktywuj narzędzie (B)”. W trakcie jazdy trasą „Odwołaj przejazd” zostaje
  i przerywa przejazd.
- **Podział odpowiedzialności** (pod przyszłe przycinanie, łączenie i kolejność tras):
  - `routes/route_preview.gd` (RoutePreview) – jedyne miejsce, które interpretuje próbki trasy dla podglądu.
    Geometrię zestawu bierze z katalogu modeli (sygnatura trasy), nie z maszyn w świecie.
  - `ui/routes/route_minimap.gd` – tylko rysuje: podłoże i place, pola (tekstury stanu jak w 2D), budynki,
    przebieg, maszyny w obecnych pozycjach (matowe) i zestaw z RoutePreview w chwili z suwaka.
  - `ui/routes/route_browser.gd` – łączy listę, minimapę i suwak; świat zna tylko przez
    `get_route_system`, `get_controlled_vehicle`, `get_route_map_data`, `get_machine_shapes`, `get_catalog_models`.

## Interfejs: przyciski i menu startowe

- `ui/icon_button.gd` – okrągły przycisk z ikoną rysowaną wektorowo w `_draw` (bez plików graficznych):
  record, pause, routes, cart, sleep, save, exit, fullscreen, folder; opcjonalny licznik (`badge`).
  Nazwa i skrót klawiszowy są w podpowiedzi (tooltip).
- W grze: lewy dolny róg – nagrywanie i trasy (jeden pod drugim); dół środek – grupa: sklep (K), sen (N),
  zapis (F9), menu (Esc). Widok 2D/3D tylko klawiszem V. Z gry nie da się wyjść bezpośrednio – tylko z menu.
- `start_menu.gd` – rysowany w kodzie krajobraz (niebo, słońce, płynące chmury, wzgórza, farma, pola),
  tytuł i trzy karty gospodarstw z podsumowaniem zapisu (`SaveManager.slot_info`): łączny czas gry (h:mm) i konto.
  Czas gry (`session.play_time_s` w pliku zapisu) liczy GameApp bez zegara w tle: przy każdym zapisie dodaje
  czas od poprzedniego zapisu lub wejścia do gry. Starsze zapisy zaczynają od 0:00. W prawym dolnym rogu: pełny ekran (F11), folder zapisów, wyjście z gry.
