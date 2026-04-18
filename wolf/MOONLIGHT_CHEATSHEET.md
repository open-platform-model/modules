# Moonlight + Wolf Cheatsheet

Quick reference for streaming games to Wolf via Moonlight clients. Covers
keyboard shortcuts, session control, client settings, and app-side tips
(Prism Launcher, Steam, Minecraft).

## Session control

| Action | Keyboard | Gamepad |
| --- | --- | --- |
| Return to Wolf UI | `Ctrl+Alt+Shift+W` | `Start+Up+RB` |
| Quit Moonlight session | `Ctrl+Alt+Shift+Q` | — |
| Toggle keyboard capture | `Ctrl+Alt+Shift+Z` | — |
| Toggle mouse capture (Qt) | `Ctrl+Alt+Shift+M` | — |
| Toggle streaming stats overlay | `Ctrl+Alt+Shift+S` | — |
| Toggle fullscreen (client window) | `Ctrl+Alt+Shift+X` | — |

`Ctrl+Alt+Shift` is the default Moonlight modifier prefix. Rebindable in
Moonlight Qt under Preferences → Input.

## Sending Super / Windows / system keys to host

By default the client OS swallows Super, Alt+Tab, Ctrl+Esc. To pass them
through to Wolf:

**Moonlight Qt (Linux/Windows/macOS):**
Preferences → Input → **Capture system keyboard shortcuts** →
set to `In fullscreen` or `Always`.

**Moonlight iOS / Android:**
Settings → **Swap Windows/Alt/Ctrl keys** (for Mac-style remaps).
System keys pass through automatically on mobile virtual keyboards.

Capture only works while Moonlight has focus. Fullscreen Moonlight
captures everything including Super+L and Alt+F4.

## Keyboard layout

Wolf passes scancodes only — layout is interpreted by the compositor
inside the runner container via XKB.

Current config: `XKB_DEFAULT_LAYOUT=se` (Swedish) set on every app
runner in `releases/mr_spel/wolf/release.cue`.

To change layout:

1. Edit each `env:` list in the release file. Set `XKB_DEFAULT_LAYOUT=<code>`.
2. `task fmt && task vet` in `releases/`.
3. Redeploy and restart the session (new env applies only to new
   runner containers — reconnect Moonlight).

Common layout codes: `us`, `se`, `no`, `dk`, `fi`, `de`, `fr`, `gb`.
Variant: add `XKB_DEFAULT_VARIANT=nodeadkeys` etc.

Verify inside session: `setxkbmap -query` (X) or `swaymsg -t get_inputs` (Sway).

## Moonlight Qt client settings (recommended)

Preferences → **Basic Settings**:

- Resolution / FPS: match your display (e.g. 1920x1080 @ 60)
- Video bitrate: 20 Mbps (1080p60), 40 Mbps (1440p60), 80 Mbps (4K60)
- Video codec: `HEVC (H.265)` if host/client support; fall back to H.264
- HDR: only if both ends support it

Preferences → **Advanced Settings**:

- Frame pacing: ON (smoother, tiny latency cost)
- V-Sync: OFF (lower latency; enable if tearing)
- Decoder: `Auto` on Linux lets VAAPI/NVDEC pick best path
- Audio: `Stereo` unless host exposes 5.1/7.1

Preferences → **Input**:

- Mouse acceleration: OFF (server decides)
- Gamepad: `Enable gamepad input` ON
- Reverse scroll direction: per preference
- Absolute mouse mode: ON for desktop apps, OFF for FPS games

## Gamepad tips

- Wolf creates a virtual Xbox 360 / DualSense on the host per client.
- Hot-plug: plug/unplug during session is supported.
- Rumble + gyro: pass through on DualSense via Moonlight Qt.
- Combo to exit session: `Start+Select+L1+R1` (if configured).

## Prism Launcher (Minecraft)

- **Hide launcher on game start**: Prism → Settings → Minecraft →
  **Launcher visibility on Minecraft window activation** → `Hide` or
  `Close`. Otherwise both launcher and game tile side-by-side in Sway.
- **Fullscreen Minecraft**: `F11` inside game.
- **Keyboard layout**: if Swedish keys still output US glyphs in-game,
  confirm the env change landed: in session terminal run
  `echo $XKB_DEFAULT_LAYOUT`.

## Steam

- Launch in Big Picture for gamepad nav.
- Proton issues: set `PROTON_LOG=1` (already set in release) and check
  `/tmp/steam-*.log` inside runner.
- Gamescope flags: tweak `GAMESCOPE_FLAGS` in `release.cue`.

## Troubleshooting

| Symptom | Likely cause | Fix |
| --- | --- | --- |
| "Slow connection to PC — reduce bitrate" overlay | Client-host bandwidth cap or WiFi drops | Lower bitrate, switch to wired, use 5 GHz |
| Wrong keys typed | XKB layout mismatch | See "Keyboard layout" above |
| Super/Alt+Tab goes to local OS | System shortcut capture off | Enable in Moonlight Qt → Input |
| Prism overlapping Minecraft | Sway tiled both windows | Set Prism "launcher visibility" to Hide |
| Session black screen / no audio | Compositor / PulseAudio socket | Exit to Wolf UI, restart app |
| Controller not detected | uinput/uhid device cgroup | Check `DeviceCgroupRules` in `base_create_json` |
| Can't return to Wolf UI | Keyboard capture off in fullscreen | `Ctrl+Alt+Shift+W` only works with capture on |

## Reference

- Wolf docs: <https://games-on-whales.github.io/wolf/>
- Moonlight Qt: <https://github.com/moonlight-stream/moonlight-qt>
- GOW app images (Prism, Steam, Firefox, etc.):
  <https://github.com/games-on-whales/gow>
- Wolf README (this module): `modules/wolf/README.md`
- Release config: `releases/mr_spel/wolf/release.cue`
