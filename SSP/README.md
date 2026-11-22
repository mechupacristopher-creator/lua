# Eze Hub — Street Soccer Pro

Silent aim and auto play hub for [Street Soccer Pro](https://www.roblox.com/games/119242658671952/).

## Loader

```lua
loadstring(game:HttpGet("https://raw.githubusercontent.com/mechupacristopher-creator/lua/main/SSP/ssp_hub.lua"))()
```

Toggle the panel with **RightControl** or the minimize button. The **UI Settings** tab lets you change colors, the toggle key, opacity and add floating buttons for mobile.

## Features

**Aim**
- Silent Aim: shoot as usual and the shot is re-aimed into the corner farthest from the keeper
- Max Curve: bends the shot in from outside the post
- Height is solved for your charge, so the ball crosses the line at the chosen corner height (Auto / High / Low)
- Power shots keep the aim through the windup
- Works from long range (kickoff power shots, penalties) — Max Distance slider
- Silent Aim for bicycle kicks and volleys: goes for the top corners (with its own self-correction) so the ball keeps its pace
- Far post from the wings (left of goal aims right and vice versa); from the middle the keeper read picks the open corner
- Curves that would clip the side boards or the end wall are rejected automatically
- Show Target marker and a last-shot readout

**Keeper**
- Auto Save: when you're the goalkeeper, predicts where the shot (curve included) crosses your line and dives at the last moment
- Auto Position (experimental, off by default): walks along your line to cover the angle between the ball and the goal (only when you're not moving yourself)

**Dribble**
- Auto Dribble: uses the game's dribble move when an opponent rushes you while you have the ball (trigger range slider)
- Auto Tackle: locks onto the ball carrier, predicts where they'll be and only slides when the hit is certain, steering the slide even while you're moving (lock-on range slider)

## Notes

- Everything starts **off**; settings are stored in `ssp_aim_cfg.json` in your executor's workspace.
- Running the script again replaces the previous copy.
- Aim is solved with the game's own ball physics, so it follows your shot traits.
