# Eze Hub — UTD

Tower defense macro for UTD.

## Loader

```lua
loadstring(game:HttpGet("https://raw.githubusercontent.com/mechupacristopher-creator/lua/main/UTD/eze_hub_utd.lua"))()
```

Toggle the panel with **RightControl** (change it in the **UI Settings** tab). Drag the bottom-right corner to resize; on mobile, **UI Settings → Mobile** adds floating buttons for toggles.

## Features

**Main**
- Auto Start Match, then Replay / Next / nothing when the match ends (Next falls back to Replay when the game doesn't offer it; goes back to the lobby when replays run out)
- Two modes: **Auto** (places units next to the path) or **Recorded** (replays a run you recorded on that map)
- Auto Bounty: takes the hardest bounty, plays it on Hard with 30 waves, claims the reward
- Infinite Tower support
- Auto fish in the lobby

**Units**
- Auto place with per-unit on/off and limits
- Auto dragons (turns on the game's own auto button) and Auto Shen Long
- Auto ability
- Auto pick path for units with paths (Bomb Girl, Krumi, Claudius…): choose Path 1 or Path 2 per unit, uses the other one if a unique path is already taken

**Recording**
- Record your placements and sells per map, rename, delete
- Edit steps without re-recording: change slot, move a placement by clicking the map, reorder, delete

**Cards**
- Auto pick dungeon cards with an editable priority list

**Halloween**
- Re-enters the Halloween event map from the lobby (Normal or Hard bubbles)

## Notes

- Settings and recordings are saved per account in `td_macro_cfg_<UserId>.json` in your executor's workspace.
- Two accounts in the same match won't stack units on the same spot.
- Reloads itself after teleports; running it again replaces the previous copy.
