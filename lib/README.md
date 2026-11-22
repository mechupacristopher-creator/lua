# Eze UI

The UI library used by the Eze Hub scripts.

## Loader

```lua
local Library = loadstring(game:HttpGet("https://raw.githubusercontent.com/mechupacristopher-creator/lua/main/lib/eze_ui.lua"))()
```

## Example

```lua
local Library = loadstring(game:HttpGet("https://raw.githubusercontent.com/mechupacristopher-creator/lua/main/lib/eze_ui.lua"))()

local win = Library:window({ name = "Eze Hub" })

local main = win:Tab({ name = "Main", icon = "lucide:home" })
local farm = main:Section({ name = "Farming", side = "left" })

farm:Toggle({ name = "Auto Farm", default = false, Callback = function(on) end })
farm:Slider({ name = "Range", min = 10, max = 100, default = 50, decimals = 0, Callback = function(v) end })
farm:Dropdown({ name = "Mode", items = { "Fast", "Safe" }, default = "Fast", Callback = function(v) end })
farm:Button({ name = "Do it", Callback = function() end })
farm:Label({ name = "Some text" })

Library:create_notification({ name = "Loaded", duration = 3 })
```

- Toggle the window with **RightControl** (changeable in the built-in **UI Settings** tab).
- The top-left watermark says `eze's`; pass `watermark = "..."` to `window` to change it.
- `Library:Unload()` removes the UI and its input connections.

Elements: `Toggle`, `Slider`, `Dropdown` (`multi = true` for multi-select), `Button`, `Textbox`, `Keybind`, `Colorpicker`, `Label`, `Status`, `List`, plus `tab:ViewportSection` for a 3D preview. Every element takes a `Callback`.
