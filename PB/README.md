# Eze Hub — Practical Basketball

Auto green and utility hub for [Practical Basketball](https://www.roblox.com/games/80681221431821/) (works in Private Gym too).

## Loader

```lua
loadstring(game:HttpGet("https://raw.githubusercontent.com/mechupacristopher-creator/lua/main/PB/pb_hub.lua"))()
```

Toggle the panel with **RightControl**.

## Features

**Shooting**
- Auto Green: hold or tap E and the shot is released for you, with ping compensation
- Timing Offset slider and Auto Calibrate (learns from every Early / Late result, per meter type)
- Auto Shoot with range, Anti Contest (only shoots with open space)
- Shot Glide and Gather Glide

**Dribbling**
- Dribble Glide
- Auto Ankle Breaker (uses a dribble move when a defender gets close)
- Combos: type moves (e.g. `Crossover, Spin, StepBack`), play them with a key or button, optional loop

**Defense**
- Auto Block (range and delay), Auto Steal, Auto Rebound

**Player**
- Speed Boost, Infinite Stamina, Always Sprint
- Custom FOV, Fullbright, Remove Post Effects, Anti AFK

## Notes

- Everything starts **off**; settings are stored in `pg_hub_cfg.json` in your executor's workspace.
- Running the script again replaces the previous copy.
