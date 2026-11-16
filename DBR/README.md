# DBR Hub — Dragon Ball Rage

Auto farm hub for [Dragon Ball Rage](https://www.roblox.com/games/71315343/).

## Loader

```lua
loadstring(game:HttpGet("https://raw.githubusercontent.com/mechupacristopher-creator/lua/main/DBR/dbr_hub.lua"))()
```

Toggle the panel with **RightControl** or the minimize button.

## Features

**Farming**
- Auto Farm Stats: pick a stat or **Auto** (trains whatever is below the cap, moves on when a stat is capped)
- Teleport to the best world for that stat (Gravity Chamber, Hell, Beerus Planet, Time Chamber)
- Safe Farm: trains high up in the sky (off on Earth)
- Auto Zenkai when every stat is capped
- Auto Transform
- Prefer small servers

**Quests**
- Auto Quests: accepts the daily quest and does daily + weekly kill quests
- Dragon Ball Finder (server hops until you have all 7)

**Event (Halloween)**
- Lights lanterns, fights Corruptkin / Corruptkin Ablaze, smashes pumpkins, claims challenge rewards
- Pumpkin Farm

**Combat**
- Bosses: keeps distance, orbits to dodge and chains every equipped **Ki** skill (melee skills are never used)
- Safe mode: retreats at low health and comes back when healed (sliders)

**Misc**
- Anti-AFK, auto reconnect
- Reloads itself after world teleports; settings are saved

## Notes

- Everything starts **off**; settings are stored in `dbr_farm_cfg.json` in your executor's workspace.
- Running the script again replaces the previous copy.
