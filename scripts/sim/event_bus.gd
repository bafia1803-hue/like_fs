extends RefCounted
## Zdarzenia domenowe gry. Systemy ogłaszają, prezentacja (widoki, HUD) słucha.
## Dzięki temu nowy odbiorca nie wymaga zmian w nadawcy ani w świecie.

## Krótki komunikat dla gracza (dymek u góry ekranu).
signal notice(text: String)
## Komunikat dotyczący konkretnej maszyny; PlayerControl przekazuje go dalej jako notice,
## gdy maszyna należy do zestawu gracza.
signal machine_message(machine_id: String, text: String)
signal money_changed(money: float, change: float, reason: String)
signal machine_added(machine: Node2D)
signal machine_removed(machine: Node2D)
signal controlled_changed(vehicle: RigidBody2D)
