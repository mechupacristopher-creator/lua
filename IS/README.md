# Eze Hub — Illegal Soccer

Hub for [Illegal Soccer](https://www.roblox.com/games/126987974021910/).

## Loader

```lua
loadstring(game:HttpGet("https://raw.githubusercontent.com/mechupacristopher-creator/lua/main/IS/illegalsoccer_hub.lua"))()
```

Toggle the panel with **RightControl**.

## Features

**Shooting**
- Silent Aim: shots, volleys, headers and bicycle kicks go to a corner of the goal you face (Away From Keeper, Far or Near; Top or Low), using the game's own ball physics so your screen and the server agree
- Curve Into Corners: the ball bends on the way and still ends in the corner (Into Corner or Around Post style, Curve Amount slider)
- Dragging the camera while charging can't throw the shot off while Silent Aim is on
- Goal Aimbot: the camera locks onto the corner while you charge

**Player**
- Infinite Stamina
- Walkspeed with separate multipliers for field player and goalkeeper (up to 3x; 1.5x had no pullbacks in testing, 2x about one per 40s)
- Auto Dribble: dribbles the moment an opponent slide tackles toward you while you have the ball
- Tackle Reach Assist: steers your slide at where the ball carrier will be, so tackles connect from the slide's full reach
- Extended Ball Reach: steps you up to 2 studs onto loose balls

## Notes

- Everything starts **off**. Settings are saved.
- Running the script again replaces the previous copy.
- Ball pickup, slide length and tackle hitboxes are checked by the server, so reach works by moving you, not by growing hitboxes. Extended Ball Reach can cause small pullbacks.
