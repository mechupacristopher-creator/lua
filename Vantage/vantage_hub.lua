local VERSION = "1.0.0"

local G = getgenv()
local TOKEN = {}
G.EzeVantageToken = TOKEN
local prev = G.EzeVantage and G.EzeVantage.cfg
if G.EzeVantage and G.EzeVantage.Unload then pcall(G.EzeVantage.Unload) end
if not game:IsLoaded() then game.Loaded:Wait() end
if G.EzeVantageToken ~= TOKEN then return end

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UIS = game:GetService("UserInputService")
local RS = game:GetService("ReplicatedStorage")
local LP = Players.LocalPlayer
local Camera = workspace.CurrentCamera

local cfg = {
	esp = false, espNames = true, espHealth = true, espDist = true, teamCheck = true,
	silent = false,
	aim = false, aimKey = "Always", aimPart = "Head", aimFov = 120, aimSmooth = 4, wallCheck = true, showFov = true,
	trigger = false, triggerDelay = 60,
	noRecoil = false, noSpread = false,
	speed = false, speedMult = 1.3, bhop = false,
}
if type(prev) == "table" then
	for k, v in pairs(prev) do
		if cfg[k] ~= nil and type(cfg[k]) == type(v) then cfg[k] = v end
	end
end

local S = { conns = {}, cfg = cfg, esp = {}, orig = {} }
G.EzeVantage = S
local function alive() return G.EzeVantage == S end
local function conn(c) table.insert(S.conns, c) return c end

local uiParent = (gethui and gethui()) or game:GetService("CoreGui")
local espFolder = Instance.new("Folder")
espFolder.Name = tostring(math.random(1e6, 9e6))
espFolder.Parent = uiParent

local function status(plr, key)
	local s = plr and plr:FindFirstChild("Status")
	local v = s and s:FindFirstChild(key)
	return v and v.Value
end

local function isEnemy(plr)
	if not plr then return true end
	if plr == LP then return false end
	if not cfg.teamCheck then return true end
	local mine, theirs = status(LP, "TeamValue"), status(plr, "TeamValue")
	if not mine or mine == "" or not theirs or theirs == "" then return true end
	return mine ~= theirs
end

local function targets()
	local list = {}
	for _, plr in ipairs(Players:GetPlayers()) do
		local c = plr.Character
		if plr ~= LP and c and status(plr, "Alive") ~= false then
			table.insert(list, { model = c, plr = plr, name = plr.DisplayName })
		end
	end
	local bots = workspace:FindFirstChild("DeathmatchBots")
	if bots then
		for _, m in ipairs(bots:GetChildren()) do
			if m:IsA("Model") then table.insert(list, { model = m, name = m.Name }) end
		end
	end
	return list
end

local function liveEnemies()
	local list = {}
	for _, t in ipairs(targets()) do
		local hum = t.model:FindFirstChildOfClass("Humanoid")
		if hum and hum.Health > 0 and isEnemy(t.plr) then
			t.hum = hum
			table.insert(list, t)
		end
	end
	return list
end

local function iAmAlive()
	local h = LP.Character and LP.Character:FindFirstChildOfClass("Humanoid")
	return h and h.Health > 0 and status(LP, "Alive") ~= false
end

local function rayParams()
	local ex = { Camera }
	if LP.Character then table.insert(ex, LP.Character) end
	for _, n in ipairs({ "ClientProjectiles", "VFXPool", "TSBClientFX", "Effects" }) do
		local f = workspace:FindFirstChild(n)
		if f then table.insert(ex, f) end
	end
	local p = RaycastParams.new()
	p.FilterType = Enum.RaycastFilterType.Exclude
	p.FilterDescendantsInstances = ex
	p.IgnoreWater = true
	return p
end

local function visible(part, model, params)
	local origin = Camera.CFrame.Position
	local hit = workspace:Raycast(origin, part.Position - origin, params)
	return hit == nil or hit.Instance:IsDescendantOf(model)
end

local function findInGc(check)
	for _, t in ipairs(getgc(true)) do
		if type(t) == "table" and check(t) then return t end
	end
end

local WM, GunCfg
local function weaponModule()
	if not WM then
		WM = findInGc(function(t) return type(rawget(t, "fire")) == "function" and type(rawget(t, "FireDue")) == "function" end)
	end
	return WM
end
local function gunConfig()
	if not GunCfg then
		GunCfg = findInGc(function(t) return type(rawget(t, "PatternOffset")) == "function" and type(rawget(t, "Bloom")) == "function" and type(rawget(t, "Get")) == "function" end)
	end
	return GunCfg
end

local NONE = {}
local RECOIL_KEYS = { Pattern = NONE, Kick = 0, KickBack = 0, Roll = 0 }
local SPREAD_KEYS = { Base = 0, AdsBase = 0, Walk = 0, Run = 0, Jump = 0, Land = 0, MaxBloom = 0 }

local function applyGunMods()
	local gc = gunConfig()
	local engine = RS:FindFirstChild("WeaponEngine")
	local weapons = engine and engine:FindFirstChild("Weapons")
	if not gc or not weapons then return end
	for _, w in ipairs(weapons:GetChildren()) do
		local ok, conf = pcall(gc.Get, w.Name)
		if ok and type(conf) == "table" then
			local orig = S.orig[conf] or {}
			S.orig[conf] = orig
			for keys, on in pairs({ [RECOIL_KEYS] = cfg.noRecoil, [SPREAD_KEYS] = cfg.noSpread }) do
				for k, v in pairs(keys) do
					if on then
						if orig[k] == nil then
							if conf[k] == nil then orig[k] = NONE else orig[k] = conf[k] end
						end
						if v == NONE then conf[k] = nil else conf[k] = v end
					elseif orig[k] ~= nil then
						if orig[k] == NONE then conf[k] = nil else conf[k] = orig[k] end
						orig[k] = nil
					end
				end
			end
		end
	end
end

S.applyGunMods = applyGunMods

local fovCircle
pcall(function()
	fovCircle = Drawing.new("Circle")
	fovCircle.Thickness = 1
	fovCircle.NumSides = 64
	fovCircle.Filled = false
	fovCircle.Color = Color3.fromRGB(255, 255, 255)
	fovCircle.Transparency = 0.7
	fovCircle.Visible = false
end)

local function aimHeld()
	if cfg.aimKey == "Always" then return true end
	local btn = cfg.aimKey == "Left Mouse" and Enum.UserInputType.MouseButton1 or Enum.UserInputType.MouseButton2
	return UIS:IsMouseButtonPressed(btn)
end

local function aimPartOf(model)
	if cfg.aimPart == "Torso" then return model:FindFirstChild("UpperTorso") or model:FindFirstChild("HumanoidRootPart") end
	return model:FindFirstChild("Head")
end

local function bestTarget(forceWallCheck)
	local vp = Camera.ViewportSize
	local center = Vector2.new(vp.X / 2, vp.Y / 2)
	local params = (cfg.wallCheck or forceWallCheck) and rayParams()
	local best, bestPart, bestDist
	for _, t in ipairs(liveEnemies()) do
		local part = aimPartOf(t.model)
		if part then
			local pos, onScreen = Camera:WorldToViewportPoint(part.Position)
			if onScreen then
				local p2 = Vector2.new(pos.X, pos.Y)
				local d = (p2 - center).Magnitude
				if d <= cfg.aimFov and (not bestDist or d < bestDist) and (not params or visible(part, t.model, params)) then
					best, bestPart, bestDist = p2, part, d
				end
			end
		end
	end
	return best, bestPart, center
end

local function stepAim()
	if fovCircle then
		local vp = Camera.ViewportSize
		fovCircle.Visible = (cfg.aim or cfg.silent) and cfg.showFov
		fovCircle.Position = Vector2.new(vp.X / 2, vp.Y / 2)
		fovCircle.Radius = cfg.aimFov
	end
	local fov, mds = Camera.FieldOfView, UIS.MouseDeltaSensitivity
	if not S.hipFov or fov >= S.hipFov - 0.5 then
		S.hipFov, S.hipMds = math.max(fov, S.hipFov or 0), mds
	end
	if not cfg.aim or not aimHeld() or not iAmAlive() or not mousemoverel then S.rem = nil return end
	local best, _, center = bestTarget()
	if not best then S.rem = nil return end
	local scale = (math.tan(math.rad(fov) / 2) / math.tan(math.rad(S.hipFov) / 2)) * (S.hipMds / math.max(mds, 1e-3))
	local delta = (best - center) * scale / math.max(cfg.aimSmooth, 1) + (S.rem or Vector2.zero)
	local dx, dy = math.round(delta.X), math.round(delta.Y)
	S.rem = Vector2.new(delta.X - dx, delta.Y - dy)
	if dx ~= 0 or dy ~= 0 then mousemoverel(dx, dy) end
end

local function silentAngles()
	local _, part = bestTarget(true)
	if not part then return end
	local cam = Camera.CFrame
	local d = cam:VectorToObjectSpace((part.Position - cam.Position).Unit)
	return math.deg(math.atan2(d.Y, -d.Z)), math.deg(math.asin(math.clamp(-d.X, -1, 1)))
end

local function installSilent()
	local wm = weaponModule()
	if not wm or S.origFire then return end
	local orig = rawget(wm, "fire")
	S.origFire, S.wm = orig, wm
	wm.fire = function(self, ...)
		if cfg.silent and alive() then
			local ok, pitch, yaw = pcall(silentAngles)
			if ok and pitch then
				self.AimPitch, self.AimYaw = pitch, yaw
			end
		end
		return orig(self, ...)
	end
end

local onTargetSince
local function stepTrigger()
	if not cfg.trigger or not iAmAlive() then onTargetSince = nil return end
	local cf = Camera.CFrame
	local hit = workspace:Raycast(cf.Position, cf.LookVector * 1500, rayParams())
	local onEnemy = false
	if hit then
		for _, t in ipairs(liveEnemies()) do
			if hit.Instance:IsDescendantOf(t.model) then onEnemy = true break end
		end
	end
	if not onEnemy then onTargetSince = nil return end
	onTargetSince = onTargetSince or os.clock()
	if os.clock() - onTargetSince < cfg.triggerDelay / 1000 then return end
	local wm = weaponModule()
	if wm then pcall(wm.FireDue, wm, true) end
end

local function stepMove(dt)
	local char = LP.Character
	local hum = char and char:FindFirstChildOfClass("Humanoid")
	local root = char and char:FindFirstChild("HumanoidRootPart")
	if not hum or not root or hum.Health <= 0 then return end
	if cfg.speed and cfg.speedMult > 1 then
		local v = root.AssemblyLinearVelocity
		local flat = Vector3.new(v.X, 0, v.Z)
		if flat.Magnitude > 1 then
			root.CFrame += flat * (cfg.speedMult - 1) * dt
		end
	end
	if cfg.bhop and UIS:IsKeyDown(Enum.KeyCode.Space) and not UIS:GetFocusedTextBox() and hum.FloorMaterial ~= Enum.Material.Air then
		hum:ChangeState(Enum.HumanoidStateType.Jumping)
	end
end

local function newEsp(model)
	local hl = Instance.new("Highlight")
	hl.FillTransparency = 0.6
	hl.OutlineTransparency = 0
	hl.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
	hl.Adornee = model
	hl.Parent = espFolder
	local bb = Instance.new("BillboardGui")
	bb.AlwaysOnTop = true
	bb.Size = UDim2.fromOffset(200, 34)
	bb.StudsOffset = Vector3.new(0, 3, 0)
	bb.Parent = espFolder
	local tl = Instance.new("TextLabel")
	tl.BackgroundTransparency = 1
	tl.Size = UDim2.fromScale(1, 1)
	tl.Font = Enum.Font.GothamBold
	tl.TextSize = 13
	tl.TextStrokeTransparency = 0.3
	tl.Parent = bb
	return { hl = hl, bb = bb, tl = tl }
end

local function clearEsp()
	for model, e in pairs(S.esp) do
		e.hl:Destroy()
		e.bb:Destroy()
		S.esp[model] = nil
	end
end

local function updateEsp()
	if not cfg.esp then
		if next(S.esp) then clearEsp() end
		return
	end
	local seen = {}
	local myRoot = LP.Character and LP.Character:FindFirstChild("HumanoidRootPart")
	local color = Color3.fromRGB(255, 60, 60)
	for _, t in ipairs(liveEnemies()) do
		local head = t.model:FindFirstChild("Head")
		if head then
			seen[t.model] = true
			local e = S.esp[t.model] or newEsp(t.model)
			S.esp[t.model] = e
			e.hl.FillColor = color
			e.hl.OutlineColor = color
			e.bb.Adornee = head
			local parts = {}
			if cfg.espNames then table.insert(parts, t.name) end
			if cfg.espHealth then table.insert(parts, math.floor(t.hum.Health) .. " HP") end
			if cfg.espDist and myRoot then table.insert(parts, math.floor((head.Position - myRoot.Position).Magnitude / 3.64) .. "m") end
			e.tl.Text = table.concat(parts, "  ")
			e.tl.TextColor3 = color
			e.bb.Enabled = #parts > 0
		end
	end
	for model, e in pairs(S.esp) do
		if not seen[model] then
			e.hl:Destroy()
			e.bb:Destroy()
			S.esp[model] = nil
		end
	end
end

local lastEsp = 0
conn(RunService.RenderStepped:Connect(function()
	if not alive() then return end
	Camera = workspace.CurrentCamera
	local now = os.clock()
	if now - lastEsp > 0.1 then
		lastEsp = now
		pcall(updateEsp)
	end
	pcall(stepAim)
	pcall(stepTrigger)
end))

conn(RunService.Heartbeat:Connect(function(dt)
	if not alive() then return end
	pcall(stepMove, dt)
end))

task.spawn(function()
	while alive() do
		if cfg.noRecoil or cfg.noSpread then pcall(applyGunMods) end
		task.wait(3)
	end
end)

local Library = loadstring(game:HttpGet("https://raw.githubusercontent.com/mechupacristopher-creator/lua/main/lib/eze_ui.lua"))()
if not alive() then pcall(function() Library:Unload() end) return end
S.lib = Library

local function setCfg(key) return function(v) cfg[key] = v end end
local function toggle(sec, name, key, cb)
	return sec:Toggle({ name = name, default = cfg[key], Callback = cb or setCfg(key) })
end
local function slider(sec, name, key, min, max, dec)
	return sec:Slider({ name = name, min = min, max = max, default = cfg[key], decimals = dec or 0, Callback = setCfg(key) })
end
local function gunToggle(key) return function(v) cfg[key] = v pcall(applyGunMods) end end

local win = Library:window({ name = "Eze Hub" })

local combatTab = win:Tab({ name = "Combat", icon = "lucide:crosshair" })
local sa = combatTab:Section({ name = "Silent Aim", side = "left" })
toggle(sa, "Silent Aim", "silent", function(v) cfg.silent = v if v then pcall(installSilent) end end)
sa:Label({ name = "Bullets go to the closest visible enemy in the FOV circle. Uses the aimbot FOV and target part." })
local ab = combatTab:Section({ name = "Aimbot", side = "left" })
toggle(ab, "Aimbot", "aim")
ab:Dropdown({ name = "Aim Key", items = { "Always", "Right Mouse", "Left Mouse" }, default = cfg.aimKey, Callback = setCfg("aimKey") })
ab:Dropdown({ name = "Target Part", items = { "Head", "Torso" }, default = cfg.aimPart, Callback = setCfg("aimPart") })
slider(ab, "FOV Radius", "aimFov", 20, 500)
slider(ab, "Smoothing", "aimSmooth", 1, 20)
toggle(ab, "Wall Check", "wallCheck")
toggle(ab, "Show FOV Circle", "showFov")
ab:Label({ name = "Smoothing 1 snaps instantly. Higher is slower and looks more legit." })
local tb = combatTab:Section({ name = "Triggerbot", side = "right" })
toggle(tb, "Triggerbot", "trigger")
slider(tb, "Delay (ms)", "triggerDelay", 0, 300)
tb:Label({ name = "Fires when your crosshair is on an enemy." })
local gm = combatTab:Section({ name = "Gun Mods", side = "right" })
toggle(gm, "No Recoil", "noRecoil", gunToggle("noRecoil"))
toggle(gm, "No Spread", "noSpread", gunToggle("noSpread"))

local visTab = win:Tab({ name = "Visuals", icon = "lucide:eye" })
local es = visTab:Section({ name = "ESP", side = "left" })
toggle(es, "ESP", "esp")
toggle(es, "Names", "espNames")
toggle(es, "Health", "espHealth")
toggle(es, "Distance", "espDist")
toggle(es, "Team Check", "teamCheck")

local plTab = win:Tab({ name = "Player", icon = "lucide:user" })
local mv = plTab:Section({ name = "Movement", side = "left" })
toggle(mv, "Speed Boost", "speed")
slider(mv, "Speed Multiplier", "speedMult", 1, 2, 2)
toggle(mv, "Bunny Hop (hold Space)", "bhop")
mv:Label({ name = "Big multipliers can get you rubberbanded by the server." })

local miscTab = win:Tab({ name = "Misc", icon = "lucide:info" })
local actions = miscTab:Section({ name = "Script", side = "left" })
actions:Label({ name = "v" .. VERSION .. " - RightControl toggles the UI" })
actions:Button({ name = "Unload Script", Callback = function() S.Unload() end })

function S.Unload()
	if G.EzeVantage == S then G.EzeVantage = nil end
	for _, c in ipairs(S.conns) do pcall(function() c:Disconnect() end) end
	clearEsp()
	pcall(function() espFolder:Destroy() end)
	local keep = { noRecoil = cfg.noRecoil, noSpread = cfg.noSpread }
	cfg.noRecoil, cfg.noSpread = false, false
	pcall(applyGunMods)
	cfg.noRecoil, cfg.noSpread = keep.noRecoil, keep.noSpread
	if S.wm and S.origFire then S.wm.fire = S.origFire end
	if fovCircle then pcall(function() fovCircle:Remove() end) end
	pcall(function() Library:Unload() end)
end

if cfg.noRecoil or cfg.noSpread then pcall(applyGunMods) end
if cfg.silent then pcall(installSilent) end
Library:create_notification({ name = "Eze Hub loaded - RightControl to toggle", duration = 4 })
