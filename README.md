# GOBIGnINTERRUPT

Lightweight Mythic+ party cooldown tracker with interrupt-pull alert and configurable sounds, for World of Warcraft Midnight (Patch 12.0.5).

## Features

- Two configurable bar windows: **Interrupts** and **Cooldowns**, draggable + resizable
- Optional **party-frame overlay** for cooldown icons (OmniCD-style)
- **Interrupt-pull alert**: schedules a sound when an enemy starts casting and your interrupt is ready
- **Burst-ready alert**: fires when every party big CD is simultaneously off cooldown
- **Per-dungeon kick counter** that resets on `CHALLENGE_MODE_START`
- **Configurable sounds** (off / specific / rotate / random) per trigger category
- Minimap button + Settings panel (`/gbi config`)
- Fully self-contained — no external library dependencies

## Slash commands

```
/gbi              - status
/gbi config       - open config UI
/gbi overlay      - toggle CDs on party frames
/gbi kicks        - print interrupt count this run
/gbi help         - full list
```

## License

MIT
