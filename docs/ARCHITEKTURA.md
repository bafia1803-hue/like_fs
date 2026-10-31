# Architektura: przegląd

Szczegółowy projekt (UML, reguły warstw, sekwencje, stany, testy, rozbudowa):
**[ARCHITEKTURA_DOCELOWA.md](ARCHITEKTURA_DOCELOWA.md)**. Ten plik opisuje działanie gry od strony funkcji.

```
GameApp (app/game_app.gd) – menu ↔ świat, sloty zapisu, czas gry
└── World (app/world.gd) – korzeń kompozycji sceny gry
    ├── Simulation  – warstwa gry (sim/): SimulationBuilder → GameContext. Fizyka, zasady, dane. Nic nie rysuje.
    ├── View2D | View3D (views/) – tylko czytają stan przez WorldQuery (przełącznik V: app/view_switcher.gd)
    ├── Hud (ui/hud/) – interfejs: WorldQuery do odczytu, GameActions do poleceń, EventBus do komunikatów
    ├── InputRouter (app/input_router.gd) – tabela klawiszy → polecenia
    └── SleepSequence (app/sleep_sequence.gd) – sen
```

| Katalog | Zawartość |
|---|---|
| `scripts/core/` | czysta logika bez węzłów: komórki pola i zasady pracy, zbiorniki, rozładunek, rura, napełnianie, ekonomia i cennik, zasady zaczepów, trasy (dane, próbki, odtwarzanie, nagrywanie, sygnatura, podgląd), plac sklepu, model opony, osie |
| `scripts/data/` | pliki: sesja (`session_loader.gd`), konfiguracja (`game_config.gd`: farming/routes/prices), zapis gry (`save_codec.gd`), sloty (`save_slots.gd`), ustawienia (`user_settings.gd`) |
| `scripts/sim/` | `GameContext` (DI), `EventBus`, `SimulationBuilder`, `WorldQuery`, `GameActions`, `PlayerControl` |
| `scripts/sim/machines/` | protokół maszyn (`machines.gd`), `MachineFactory` (physics_kind → skrypt), `MachineRegistry`, fizyka maszyn, kolizje na poziomach, rura |
| `scripts/sim/systems/` | zaczepy, praca na polu (+ `field_grid.gd`), przeładunek ziarna, usługi farmy, przeszkody, kierowca, sklep |
| `scripts/sim/routes/` | system tras, zestaw (`sim/routes/route_rig.gd`), kolizje tras |
| `scripts/sim/worker/`, `scripts/core/worker/` | pracownik (test, włącznik `files/workers.json`) – rozdział „Pracownik” |
| `scripts/views/` | widoki 2D i 3D |
| `scripts/ui/` | HUD, informator, sklep, okno tras, okienka |
| `tests/` | runner, testy jednostkowe i integracyjne (`godot --headless --path . -s tests/run_tests.gd`) |

Zasady: warstwa gry nie zna widoków ani UI; widoki nie zmieniają gry; UI zmienia grę tylko przez
`GameActions`; zasady gry są w `core/` i mają testy jednostkowe.

## Grafika i wydajność

- **G** – jakość grafiki: niska → średnia (domyślna) → wysoka (`files/graphics.json`, `app/graphics_settings.gd`),
  zapamiętywana w `user://settings.cfg`. Licznik FPS z nazwą jakości jest w prawym górnym rogu.
- Ustawienia presetu: maksymalna rozdzielczość sceny 3D, wygładzanie (FXAA), cienie (kaskady, zasięg, mapa),
  poświata (tylko wysoka), kółko szczegółów zboża i trawy, cienie drzew. SSAO i MSAA są wyłączone
  we wszystkich presetach (zmierzone: SSAO ~27 ms, scalanie MSAA ~3 ms na słabszej karcie).
  Bez zapisanego wyboru gra na karcie zintegrowanej startuje z jakością niską.
- Szczegóły zboża i trawy liczone są wokół pojazdu gracza (przy wolnej kamerze – wokół miejsca, na które
  patrzy kamera), z płynnym przejściem każdej kępki osobno. Pod kępkami leży łan – siatka podnoszona
  w shaderze do wysokości roślin – więc dalej niż kilkadziesiąt metrów pole nie potrzebuje kępek.
  Do karty trafiają tylko kępki, które mogą być widoczne (`visible_instance_count`).
- **F4** – raport wydajności: co sekundę karta graficzna (etapy, gdy dostępne) i czekanie (na kartę,
  V-Sync, system) posortowane wg czasu; reszta procesora w jednej linii. W nagłówku: nazwa karty
  (z ostrzeżeniem, gdy gra działa na zintegrowanej), rozdzielczość obrazu 3D i okna, jakość grafiki.
- **Shift+F4** – test składników karty: wyłącza po kolei cienie, SSAO, poświatę, mgłę, niebo, kępki zboża,
  łan, glebę, trawę, drzewa, łąkę, farmę, maszyny, połowę rozdzielczości i wygładzanie; pokazuje oszczędność.

## Informator (`scripts/ui/informator.gd`)

Panel w prawym górnym rogu: sterowana maszyna i podpięte narzędzie.
Treść dostarczają skrypty z `scripts/ui/info/` (dziedziczą po `info_provider.gd`):

- `speed_info.gd` – prędkość
- `work_info.gd` – praca narzędzia (B): opuszczone/włączone, limit prędkości
- `storage_info.gd` – zawartość i pojemność zbiorników (kombajn, przyczepa, siewnik)
- `status_info.gd` – bieżący przeładunek (rura, wywrotka, silos, magazyn)

Nowa informacja: utwórz skrypt z metodą `rows(maszyna, rola, query)` zwracającą wiersze
`{"label", "value", "ratio", "color"}` i dopisz jego ścieżkę do `Informator.PROVIDERS`.

## Farma (`files/map.json`)

- `surfaces` – plac farmy (wygląd)
- `static_obstacles` – silosy, elewator, wiata, słupy (kolizja w grze; klucz `visual` tylko dla widoków)
- `unload_points` – krata zrzutu do silosu
- `load_points` – załadunek z silosu: przyczepa staje tak, by wylot był nad skrzynią
- `supply_points` – magazyn przy wiacie: siewnik i rozsiewacz wjeżdżają w obszar i kupują ziarno siewne / nawóz

## Praca maszyn i wzrost roślin

- **B** – opuszcza/podnosi heder i kultywator, włącza/wyłącza siewnik (`FieldWorkSystem.toggle_work`, zasady w `core/field/field_work_rules.gd`).
  Stan jest w `instance_state.work_state` (`enabled`, `lowered`); narzędzie pracuje tylko wtedy.
  Pracujące narzędzie ogranicza prędkość pojazdu do `work.max_working_speed_kmh` z `machines.json`
  (heder 10, kultywator i siewnik 18 km/h). Bez pracy obowiązuje `drive.forward_speed_kmh`
  (kombajn 30, ciągnik 35 km/h). Widoki animują opuszczanie na podstawie `work_state`.
- **Trasy** zapisują w każdej próbce także pracę narzędzia (format trasy v3, kolumna `tool_working`).
  Odtworzenie opuszcza/podnosi narzędzie dokładnie tam, gdzie zrobiono to przy nagrywaniu.
  Starsze trasy (v1, v2) nie zmieniają stanu narzędzia.
- **Sen** (przycisk lub N) – ekran ciemnieje (1,6 s, szybciej na początku), w pełnej ciemności rośliny rosną,
  potem rozjaśnia się (1,9 s, szybciej na końcu); razem ok. 4 s (`app/sleep_sequence.gd`).
  Na czas snu gra jest w pauzie (`get_tree().paused`), więc klawisze, przyciski, kamera i fizyka same
  przestają działać; w pauzie pracują tylko zasłona i odświeżanie pól (`PROCESS_MODE_ALWAYS`).
  Rośliny nie rosną same. Każdy sen przesuwa wszystkie zasiane komórki
  o jedną fazę: zasiane → jasne → ciemne → dojrzałe (`FieldCells.grow`).

## Kombajn: prowadzenie

Kombajn ma napęd na przedniej osi, a skręt na tylnej. Tylna oś ma większą przyczepność bocznej (`lateral_grip` 1.8) i więcej masy (`load_weight` 1.5), dzięki czemu po puszczeniu kierownicy ciało przestaje się obracać w ciągu ok. 0,5 s zamiast 1,5 s. Kąt skrętu: maks. 45°, powrót 70°/s.

## Składanie i profile kolizji (`sim/machines/single_axle_implement.gd`)

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
- **Załadunek z silosu**: przyczepa sterowanego zestawu pod wylotem → przycisk na dole ekranu → okienko wyboru
  ziarna (`ui/fill_dialog.gd`). Bez mieszania: do przyczepy z pszenicą nie da się załadować jęczmienia ani owsa
  (tak samo zbiornik kombajnu).
- **Magazyn przy wiacie** (`supply_points`): maszyna z zbiornikiem pracy (siewnik, rozsiewacz) staje
  środkiem w obszarze → przycisk „Kup ziarno” / „Kup nawóz” od razu rusza zakup (`start_purchase`).
  Towar przybywa stopniowo (`max_transfer_l_per_s`), kosztuje wg `supply_buy_per_l` w `prices.json`.
  Bez rur i strumieni; na placu stoją palety z workami (`models/world/farm_supply.glb`).
- **Gatunek siewu** to ustawienie siewnika (`instance_state.seed_crop_id`, lista `work.sowable_crop_ids`:
  pszenica → jęczmień → owies). Przy podpiętym siewniku w prawym dolnym rogu jest przycisk z kłosem i podpisem;
  kliknięcie zmienia gatunek (`GameActions.cycle_seed_crop`). Trasy nie zapisują gatunku – odtworzona trasa sieje
  to, co jest ustawione. Starsze zapisy (`wheat_seed`/`barley_seed`) są zamieniane na `seed` + gatunek.
- **Owies** (`oats`, ziarno `oats_grain`): plon 0,65 l/m², dojrzały jaśniejszy od pszenicy (kod gatunku 3
  w teksturze stanu pola; jęczmień 2 – ciemniejszy).
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
  kierunek ±30°), wolniej niż 6 km/h i z narzędziem w stanie z nagrania → start od razu (także w przejeździe). Inaczej okno się zamyka,
  komunikat „Podjedź na miejsce startu”, w świecie stoi półprzezroczysty zestaw widmo
  (`views/view3d/route_ghost_3d.gd`, `views/view2d/route_view_2d.gd`) z czerwonym wskaźnikiem, a na dole są przyciski
  „Uruchom trasę” (tylko na miejscu startu) i „Odwołaj przejazd”. Start sprawdza też narzędzie:
  „Aktywuj narzędzie (B)” / „Dezaktywuj narzędzie (B)”. W trakcie jazdy trasą „Odwołaj przejazd” zostaje
  i przerywa przejazd.
- **Podział odpowiedzialności** (pod przyszłe przycinanie, łączenie i kolejność tras):
  - `core/routes/route_preview.gd` (RoutePreview) – jedyne miejsce, które interpretuje próbki trasy dla podglądu.
    Geometrię zestawu bierze z katalogu modeli (sygnatura trasy), nie z maszyn w świecie.
  - `ui/routes/route_minimap.gd` – tylko rysuje: podłoże i place, pola (tekstury stanu jak w 2D), budynki,
    przebieg, maszyny w obecnych pozycjach (matowe) i zestaw z RoutePreview w chwili z suwaka.
  - `ui/routes/route_browser.gd` – łączy listę, minimapę i suwak; stan czyta przez `WorldQuery`,
    polecenia (uruchom, przerwij, zmień nazwę, usuń) wydaje przez `GameActions`.

## Interfejs: przyciski i menu startowe

- `ui/icon_button.gd` – okrągły przycisk z ikoną rysowaną wektorowo w `_draw` (bez plików graficznych):
  record, pause, routes, cart, sleep, save, exit, fullscreen, folder; opcjonalny licznik (`badge`).
  Nazwa i skrót klawiszowy są w podpowiedzi (tooltip).
- W grze: lewy dolny róg – nagrywanie i trasy (jeden pod drugim); dół środek – grupa: sklep (K), sen (N),
  zapis (F9), menu (Esc). Widok 2D/3D tylko klawiszem V. Z gry nie da się wyjść bezpośrednio – tylko z menu.
- `start_menu.gd` – rysowany w kodzie krajobraz (niebo, słońce, płynące chmury, wzgórza, farma, pola),
  tytuł „FarmOrchestra” i trzy karty gospodarstw z podsumowaniem zapisu (`SaveSlots.slot_info`): konto i łączny czas gry (h:mm).
  Czas gry (`session.play_time_s` w pliku zapisu) liczy GameApp bez zegara w tle: przy każdym zapisie dodaje
  czas od poprzedniego zapisu lub wejścia do gry. Starsze zapisy zaczynają od 0:00. W prawym dolnym rogu: pełny ekran (F11), folder zapisów, wyjście z gry.

## Tir i naczepy

- **Tir** (`truck_basic`, `powered_vehicle`): 3 osie (przednia skrętna, tandem napędowy z kołami
  bliźniaczymi), 80 km/h, duża siła napędu i hamowania. Siodło = port `fifth_wheel` (socket) z własną
  tolerancją podpinania (`attach_distance_m`, `attach_angle_deg`). Osie z `carries_coupled_load`
  dostają nacisk naczepy na siodło (więcej przyczepności z ciężką naczepą).
- **Tandemy** (`tandem_group` w osiach, `core/machines/axle_groups.gd`): dwie nieskrętne osie obok siebie fizyka liczy jak
  jedną oś w środku grupy (bez „szorowania” w zakręcie); widoki pokazują wszystkie koła.
- **Naczepy** (`semitrailer_small` 10,5 m / 35 000 l, `semitrailer_large` 13,6 m / 50 000 l,
  `towed_semitrailer`): tandem nieskrętnych osi z tyłu, sworzeń = port `fifth_wheel` (plug).
  Ciężar dzielony z geometrii między osie i siodło (po podpięciu) albo nogi (`landing_legs`, po odpięciu:
  stopy trą jak zablokowane koła). Hamulec roboczy naczepy działa razem z hamulcem tira
  (`service_brake_decel_g`). Podpinanie/odpinanie klawiszem **E**; nogi podnoszą się animacją po
  podpięciu (wysuw chowa się w rurach nóg), po odpięciu stoją od razu.
- **Kolizje na poziomach** (`sim/machines/collision_levels.gd`): bryły w `physics.collision_shapes` mają `levels`
  (`low`, `high` albo oba – domyślnie). Zderzają się tylko bryły ze wspólnym poziomem. Tir: maska i kabina
  na obu poziomach, rama z siodłem tylko `low`; naczepa: przód nad siodłem tylko `high`, skrzynia nad osiami
  oba, nogi `low` (grupa `legs`, kolizja tylko po odpięciu). Godot ma warstwy na całe ciało, więc bryły
  jednego poziomu siedzą na lekkich „ciałach poziomów” zespawanych z nadwoziem (Rapier `joint_make_fixed`,
  stały moment bezwładności, bo ciało bez brył zablokowałoby obrót). Budynki i dotychczasowe maszyny są na
  obu poziomach. Trasy (`sim/routes/route_rig.gd`) zbierają bryły także z ciał poziomów.
  Nowa maszyna z poziomami = tylko konfiguracja w `machines.json`.
- **Załadunek** jak przyczepa: rura kombajnu i silos na całej długości skrzyni (`receiving.area`).
- **Rozładunek** (`unloading.mode = "conveyor"`): tył naczepy (`outlet_in_body_m`) nad dowolnym miejscem
  zrzutu lub skupem z `map.json` → drzwi się uchylają (`start_delay_seconds`), ziarno płynie
  `max_transfer_l_per_s`. Wywrotka i naczepa korzystają z tej samej logiki miejsca, więc nowe punkty zrzutu
  działają dla obu bez zmian w kodzie. W 3D (`visual.fill_mode = "conveyor"`) ładunek to bryła z przekrojami
  wzdłuż skrzyni: przy rozładunku poziom opada od tyłu do przodu (pochyła powierzchnia), poza tym leży równo.
- **Wygląd z góry** (widok 2D, minimapa tras): `visual.top_view` – lista prostokątów z kolorem
  (`body`, `body_dark` albo `#rrggbb`), czytana przez `views/view2d/top_view.gd`. Bez tego klucza maszyna jest
  jednym prostokątem jak dotąd.
- **Modele 3D**: `tools/generate_trucks.py` (wywoływany też przez `generate_models.py`) czyta wymiary z
  `machines.json`. Węzły: `saddle`, `kingpin`, `landing_legs`, `tailgate`, `grain_fill` (początek przy tylnej ścianie).
- **Start gry**: tir i obie naczepy stoją na placu sklepu (plac 26×15 m); pole południowe ma trzy pasy
  dojrzałych zbóż (`save.json` → `field_states[].initial_strips`). Dotyczy nowych gier.

## Odtwarzanie tras: ogranicznik prędkości i płynne wejście na trasę

`routes/route_playback.gd` (czysta logika, jedna instancja na przejazd):

- **Start/koniec nagrywania i start trasy** są możliwe w ruchu do `max_start_speed_kmh` (6 km/h),
  ale nie w trakcie składania/rozkładania narzędzia (stan musi być jednoznaczny).
- **Ogranicznik prędkości** `speed_limit`: trasa przesuwa się o mniejszą z dróg – nagraną albo
  `speed_limit · dt`; postoje z nagrania trwają jak w nagraniu. Ten sam mechanizm obsługuje:
  start (od prędkości zestawu, rośnie z `playback_accel_m_s2`), wznowienie po przeszkodzie (od zera),
  „Odwołaj przejazd” (`request_stop`: od rzeczywistej prędkości maleje z `playback_decel_m_s2` do zera,
  zestaw jedzie dalej po trasie) i koniec trasy (`speed_limit ≤ √(2·opóźnienie·droga_do_końca)` –
  nagranie zakończone w ruchu wyhamowuje dokładnie na końcu).
- **Płynne wejście** przy starcie w ruchu lub obok punktu startu (tolerancja bez zmian: 3 m, 30°):
  zestaw zaczyna z rzeczywistej pozy, a różnica (boczna, wzdłużna, kąty pojazdu i przegubów) zanika wraz
  z przejechaną drogą trasy (min. `start_blend_min_m`, dłużej przy dużym przesunięciu). Boczne przesunięcie
  to krzywa Hermite'a styczna do rzeczywistego kierunku jazdy na starcie i do trasy na końcu; kierunek
  nadwozia liczony z kierunku ruchu – zestaw skręca do linii nagrania, nie jedzie bokiem.
- **Narzędzie**: każdy przekroczony odcinek nagrania jest stosowany po kolei (praca B, składanie), więc
  zdarzenia z początku trasy nie giną przy wolnym starcie ani spadku FPS; składanie biegnie w czasie trasy.

## Nawożenie

- **Rozsiewacz** (`spreader_basic`, `rigid_mounted`): zawieszany na TUZ ciągnika (port `three_point`;
  ciągnik ma osobne gniazdo `rear_three_point` obok zaczepu dyszla). Bryła ~szerokość ciągnika, obszar pracy
  to trójkąt rozwarty (wierzchołek przy tarczach, podstawa 20 m, 3 m za wierzchołkiem, `work.area.polygon_m`; każde narzędzie może
  mieć taki wielokąt – `field_grid.cells_in_polygon`, widok 2D rysuje kształt). Włączanie B, limit 20 km/h, zbiornik 1500 l nawozu (`fertilizer`), dawka `fertilizer_l_per_m2`.
  W 3D tarcze (`spinner_L/R`) kręcą się i rzucają granulki (CPUParticles3D) gdy rozsiewacz pracuje i jedzie;
  kierunek i zasięg wyrzutu wynikają z kształtu trójkąta obszaru pracy.
- **Zasady** (`field_grid.gd`): dwie fazy nawożenia, każda liczy się raz → poziom 0–2:
  przed siewem (puste pole albo ściernisko) i w trakcie wzrostu (zasiane … przed dojrzałością).
  Dojrzałe zboże nie przyjmuje nawozu. Nawóz zużywa się tylko na komórkach, którym poziom wzrósł.
  Zbiór zużywa nawożenie; kultywacja go nie kasuje. Plon: `fertilizer_yield_bonus` w `farming.json`
  (0 / +15% / +35%). Nawiezione pole jest subtelnie ciemniejsze (kanał B tekstury stanu).
- **Zapis pola** (`field_cells_v3`): bajt na komórkę (faza 3 bity | gatunek 3 bity | nawożenie 2 bity),
  deflate + base64 – kilkaset znaków zamiast setek kB JSON. Stare zapisy (`field_cells_v2`) nadal się wczytują.
- **Trasy**: rozsiewacz nagrywa się i odtwarza jak każde narzędzie. Sygnatura trasy haszuje konfigurację maszyn
  tylko z użytymi zaczepami, więc dodanie gniazda TUZ nie unieważniło starych tras ciągnika
  (`route_rig.gd` → `matches`, także dawny format sygnatury).

## Pracownik (test; `files/workers.json`)

Pracownik obrabia pole „wężykiem” zestawem pojazd + podpięte narzędzie, jak pomocnik w Farming Simulator.
Na razie tylko na osobnej mapie: przycisk **„Test: pracownik”** w lewym dolnym rogu menu startowego
(`files/test/worker_save.json` + `worker_map.json`; gra testowa nie jest zapisywana – F9 tylko informuje,
Esc wraca do menu). Zestawy stoją podpięte przy polach:
- pole północne (ściernisko): dwa kultywatory (pod polem i nad polem) i siewnik z lewej strony, przodem na wschód,
- pole południowe (pszenica): kombajn z hederem, pole wschodnie (goła ziemia),
- nad polami stoją przyczepa i ciężarówka (przeszkody przy zawrotach).

- **H** – zatrudnia pracownika dla sterowanego zestawu (pole przed pojazdem, do 40 m) albo go odwołuje
  (zestaw płynnie hamuje). TAB przełącza na inny zestaw, pracownik jedzie dalej. Plan widać w widoku 2D (V):
  dojazd fioletowy, wjazdy białe, praca żółta, zawroty błękitne, cofanie pomarańczowe.
- **Wyłączenie**: `"enabled": false` w `files/workers.json` – system nie powstaje, H nic nie robi, przycisk
  testu znika. `"maps"` – mapy, na których pracownik działa (dziś tylko `worker_test_map`).

| Plik | Rola |
|---|---|
| `core/worker/dubins.gd` | krzywe Dubinsa: najkrótsza jazda do przodu z pozy do pozy przy promieniu R |
| `core/worker/worker_rig.gd` | model zestawu: punkt prowadzący (oś bez skrętu), promień, narzędzie zawieszane / przyczepiane (kinematyka osi bez poślizgu, także przy cofaniu), obszar roboczy |
| `core/worker/field_planner.gd` | pasy z komórek pola, dojazd na linię pasa, kolejność, zawroty do przodu i z cofaniem, skracanie pasów, próbki trasy |
| `core/worker/worker_rules.gd` | które komórki wymagają pracy, kto po kim (FEEDS), komunikaty zatrzymujące |
| `sim/worker/worker_system.gd` | model zestawu z katalogu, profil pracy pasów z pola (+ rezerwacje), test kolizji, jazda przez `RouteSystem.start_generated`, dalsza praca, korytarze i pierwszeństwo, nadzór |
| `sim/worker/worker_feature.gd` | włącznik: ustawienia, mapy, szablon testu |
| `views/view2d/worker_view_2d.gd` | podgląd planu w 2D |

Zasady:

1. **Pasy z komórek** – kierunek równoległy do krawędzi pola najbliższej kierunkowi pojazdu (przy dalszej pracy
   ten sam). Pasy kładzione od boku bliższego pojazdowi, każdy zaczyna się tam, gdzie jest coś do zrobienia,
   rozstaw = szerokość − zakładka. **Ostatni pasek węższy niż narzędzie** – narzędzie jedzie jego środkiem.
   Wzdłuż pasa praca trwa w najdłuższym ciągłym odcinku do zrobienia: granica (np. niezakultywowana ziemia dla
   siewnika) jest jak koniec pola – tam zawrót.
2. **Dojazd** – na linię najbliższego pasa, w kierunku zgodnym z pojazdem, łagodnym łukiem (bez pętli); pas
   zaczyna się tam, gdzie zestaw na niego wjechał (kawałek za nim zostaje). Gdy łagodnie się nie da (zestaw
   stoi tyłem) – zwykły zawrót.
3. **Kolejność** – od pasa startowego w stronę bliższego boku, potem reszta. Plan obejmuje najwyżej
   `max_lanes_per_plan` pasów; po nich pracownik planuje dalej.
4. **Zawrót** – kandydaci sprawdzani pod kątem kolizji (cały zestaw z narzędziem, zapas `collision_margin_m`):
   do przodu (Dubins, R i większe promienie); z cofaniem, gdy przed zestawem jest przeszkoda – podjazd jak
   najdalej, łuk wstecz, łuk do przodu, cofnięcie na początek pasa (albo odwrotnie); dopiero potem pasy
   krótsze o 2–10 m. Narzędzie przyczepiane nie może się złożyć (`max_tool_angle_deg`). Gdy nic się nie
   mieści – pracownik zatrzymuje się po tym pasie. Maszyna stojąca na pasie kończy pas przed nią.
5. **Niedokończone kawałki** zostają – pracownik do nich nie wraca (pasy raz przejechane są wyłączone z
   kolejnych planów). Wyjątek: siewnik za kultywatorem (`FEEDS`) wraca na swoje pasy, bo zakultywowana część rośnie.
6. **Kilku pracowników na polu** – każdy rezerwuje pasy swojego planu (do ich przejechania); inny pracownik tej
   samej pracy bierze pasy wolne. Różne prace (kultywator północ–południe, siewnik wschód–zachód) działają
   razem: siewnik bez pracy czeka, póki na polu pracuje kultywator, i rusza, gdy jest zakultywowana ziemia.
7. **Droga przed zestawem** – na pasie `look_ahead_m`, w trakcie zawrotu cały zawrót. Pierwszeństwo ma ten,
   kto już zawraca, potem wcześniej zatrudniony; drugi czeka. Przeszkoda (stojąca maszyna) – po
   `replan_after_s` nowy plan z miejsca postoju; inny pracownik na drodze – czekanie do `yield_timeout_s`.
8. **Nadzór** – pełny zbiornik kombajnu, pusty siewnik/rozsiewacz albo odmowa pracy (np. inne ziarno w zbiorniku)
   zatrzymuje pracownika; po rozładunku/uzupełnieniu H wznawia.
9. Narzędzia: zawieszane (heder, rozsiewacz) i jednoosiowe przyczepiane (kultywator, siewnik); pojazd ze
   skrętną osią. Kultywator pracownika uprawia tylko ściernisko (nie zaorze zasiewów).
