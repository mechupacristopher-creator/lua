# Eze Hub — Street Soccer Pro

Silent aim and auto play hub for [Street Soccer Pro](https://www.roblox.com/games/119242658671952/).

## Loader

```lua
loadstring(game:HttpGet("https://raw.githubusercontent.com/mechupacristopher-creator/lua/main/SSP/ssp_hub.lua"))()
```

Toggle the panel with **RightControl** or the minimize button.

## Features

**Aim**
- Silent Aim: shoot as usual and the shot is re-aimed into the corner farthest from the keeper
- Max Curve: bends the shot in from outside the post
- Height is solved for your charge, so the ball crosses the line at the chosen corner height (Auto / High / Low)
- Power shots keep the aim through the windup
- Works from long range (kickoff power shots, penalties) — Max Distance slider
- Silent Aim for bicycle kicks and volleys
- Keeper read: predicts where the opposing keeper will be and picks the open corner
- Show Target marker and a last-shot readout

**Dribble**
- Auto Dribble: uses the game's dribble move when an opponent rushes you while you have the ball (trigger range slider)
- Auto Tackle: slide-tackles the ball carrier when they're in range and in your path (range slider)

## Notes

- Everything starts **off**; settings are stored in `ssp_aim_cfg.json` in your executor's workspace.
- Running the script again replaces the previous copy.
- Aim is solved with the game's own ball physics, so it follows your shot traits.
