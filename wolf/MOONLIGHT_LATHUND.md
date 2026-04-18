# Moonlight + Wolf Lathund

Snabbreferens för att strömma spel till Wolf via Moonlight-klienter.
Täcker tangentbordsgenvägar, sessionskontroll, klientinställningar och
app-specifika tips (Prism Launcher, Steam, Minecraft).

## Sessionskontroll

| Åtgärd | Tangentbord | Handkontroll |
| --- | --- | --- |
| Återgå till Wolf UI | `Ctrl+Alt+Shift+W` | `Start+Upp+RB` |
| Avsluta Moonlight-session | `Ctrl+Alt+Shift+Q` | — |
| Växla tangentbordsinfångning | `Ctrl+Alt+Shift+Z` | — |
| Växla musinfångning (Qt) | `Ctrl+Alt+Shift+M` | — |
| Växla statistik-overlay | `Ctrl+Alt+Shift+S` | — |
| Växla helskärm (klientfönster) | `Ctrl+Alt+Shift+X` | — |

`Ctrl+Alt+Shift` är Moonlights standardprefix. Kan ändras i Moonlight Qt
under Inställningar → Inmatning.

## Skicka Super / Windows / systemtangenter till värden

Som standard fångar klient-OS:et Super, Alt+Tab, Ctrl+Esc. För att
skicka dem vidare till Wolf:

**Moonlight Qt (Linux/Windows/macOS):**
Inställningar → Inmatning → **Fånga systemgenvägar på tangentbordet** →
välj `I helskärm` eller `Alltid`.

**Moonlight iOS / Android:**
Inställningar → **Byt plats på Windows/Alt/Ctrl-tangenter** (för
Mac-liknande mappning). Systemtangenter skickas automatiskt från
mobila tangentbord.

Infångning fungerar bara när Moonlight har fokus. Helskärmsläge fångar
allt, inklusive Super+L och Alt+F4.

## Tangentbordslayout

Wolf skickar endast skankoder — layouten tolkas av kompositören inuti
runner-containern via XKB.

Nuvarande konfiguration: `XKB_DEFAULT_LAYOUT=se` (svenska) satt på
varje app-runner i `releases/mr_spel/wolf/release.cue`.

Byta layout:

1. Redigera varje `env:`-lista i release-filen. Sätt `XKB_DEFAULT_LAYOUT=<kod>`.
2. `task fmt && task vet` i `releases/`.
3. Driftsätt om och starta om sessionen (ny env gäller endast nya
   runner-containrar — koppla upp Moonlight igen).

Vanliga layoutkoder: `us`, `se`, `no`, `dk`, `fi`, `de`, `fr`, `gb`.
Variant: lägg till `XKB_DEFAULT_VARIANT=nodeadkeys` osv.

Verifiera i sessionen: `setxkbmap -query` (X) eller `swaymsg -t get_inputs` (Sway).

## Rekommenderade Moonlight Qt-inställningar

Inställningar → **Grundinställningar**:

- Upplösning / FPS: matcha skärmen (t.ex. 1920x1080 @ 60)
- Videobitrate: 20 Mbps (1080p60), 40 Mbps (1440p60), 80 Mbps (4K60)
- Videokodek: `HEVC (H.265)` om värd/klient stödjer det; annars H.264
- HDR: endast om båda sidor stödjer det

Inställningar → **Avancerade inställningar**:

- Frame pacing: PÅ (jämnare, liten latenskostnad)
- V-Sync: AV (lägre latens; slå på vid tearing)
- Avkodare: `Auto` på Linux låter VAAPI/NVDEC välja bästa vägen
- Ljud: `Stereo` om inte värden exponerar 5.1/7.1

Inställningar → **Inmatning**:

- Musacceleration: AV (servern bestämmer)
- Handkontroll: `Aktivera inmatning från handkontroll` PÅ
- Invertera scrollriktning: efter smak
- Absolut musläge: PÅ för skrivbordsappar, AV för FPS-spel

## Tips för handkontroll

- Wolf skapar en virtuell Xbox 360 / DualSense på värden per klient.
- Hot-plug: att koppla in/ur under en session stöds.
- Rumble + gyro: skickas vidare för DualSense via Moonlight Qt.
- Kombination för att avsluta session: `Start+Select+L1+R1` (om konfigurerad).

## Prism Launcher (Minecraft)

- **Dölj launchern när spelet startar**: Prism → Inställningar → Minecraft →
  **Launcher visibility on Minecraft window activation** → `Hide` eller
  `Close`. Annars staplas både launcher och spel sida vid sida i Sway.
- **Helskärm i Minecraft**: `F11` i spelet.
- **Tangentbordslayout**: om svenska tangenter fortfarande ger US-tecken
  i spelet, verifiera att env-ändringen slog igenom: kör
  `echo $XKB_DEFAULT_LAYOUT` i sessionsterminalen.

## Steam

- Starta i Big Picture för handkontrollsnavigering.
- Proton-problem: sätt `PROTON_LOG=1` (redan satt i release) och kolla
  `/tmp/steam-*.log` inuti runnern.
- Gamescope-flaggor: justera `GAMESCOPE_FLAGS` i `release.cue`.

## Avsluta ett spel

Tre sätt beroende på vad du vill:

| Vad du vill | Så gör du |
| --- | --- |
| Stänga spelet, stanna kvar i strömningen | `Ctrl+Alt+Shift+W` (tangent) eller `Start+Upp+RB` (pad) → tillbaka till Wolf UI |
| Avsluta hela Moonlight-sessionen | `Ctrl+Alt+Shift+Q`, eller i Moonlight Qt: för musen till toppen → **Koppla från**. Högerklick på värd-tile → **Quit App** |
| Avsluta från spelet | Använd spelets egen avslutningsmeny (Minecraft: Spara och avsluta → Avsluta spel) |

Containern stoppas automatiskt när strömmen avslutas om
`WOLF_STOP_CONTAINER_ON_EXIT=true` (standard).

## Felsökning

| Symptom | Trolig orsak | Åtgärd |
| --- | --- | --- |
| "Slow connection to PC — reduce bitrate" overlay | Bandbreddstak eller WiFi-tapp | Sänk bitrate, byt till trådbundet, använd 5 GHz |
| Fel tecken skrivs | XKB-layouten stämmer inte | Se "Tangentbordslayout" ovan |
| Super/Alt+Tab går till lokalt OS | Systemgenvägsinfångning är av | Slå på i Moonlight Qt → Inmatning |
| Prism ligger över Minecraft | Sway lade fönstren sida vid sida | Sätt Prism "launcher visibility" till Hide |
| Svart skärm / inget ljud | Kompositör / PulseAudio-socket | Gå tillbaka till Wolf UI, starta om appen |
| Handkontroll upptäcks inte | uinput/uhid device cgroup | Kontrollera `DeviceCgroupRules` i `base_create_json` |
| Kommer inte tillbaka till Wolf UI | Tangentbordsinfångning av i helskärm | `Ctrl+Alt+Shift+W` kräver att infångning är på |

## Referenser

- Wolf-dokumentation: <https://games-on-whales.github.io/wolf/>
- Moonlight Qt: <https://github.com/moonlight-stream/moonlight-qt>
- GOW app-images (Prism, Steam, Firefox m.fl.):
  <https://github.com/games-on-whales/gow>
- Wolf README (den här modulen): `modules/wolf/README.md`
- Release-konfiguration: `releases/mr_spel/wolf/release.cue`
