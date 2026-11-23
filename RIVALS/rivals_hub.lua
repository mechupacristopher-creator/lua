local VERSION = "1.0.0"

local G = getgenv()
local autoload = G.EzeRivalsAutoload
G.EzeRivalsAutoload = nil
local TOKEN = {}
G.EzeRivalsToken = TOKEN
local prev = G.EzeRivals and G.EzeRivals.cfg
if G.EzeRivals and G.EzeRivals.Unload then pcall(G.EzeRivals.Unload) end
if not game:IsLoaded() then game.Loaded:Wait() end

do
	local pg = game:GetService("Players").LocalPlayer:WaitForChild("PlayerGui")
	local lighting = game:GetService("Lighting")
	local t0 = os.clock()
	if autoload then
		while not pg:FindFirstChild("LoadingScreen") and os.clock() - t0 < 20 do task.wait(0.25) end
	end
	while pg:FindFirstChild("LoadingScreen") or lighting:FindFirstChild("LoadingScreen") do task.wait(0.5) end
	if os.clock() - t0 > 1 then task.wait(2) end
end
if G.EzeRivalsToken ~= TOKEN then return end

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UIS = game:GetService("UserInputService")
local RS = game:GetService("ReplicatedStorage")
local LP = Players.LocalPlayer
local PS = LP:WaitForChild("PlayerScripts")
local Camera = workspace.CurrentCamera

local cfg = {
	esp = false, espNames = true, espHealth = true, espDist = true, teamCheck = true,
	silent = false,
	aim = false, aimKey = "Right Mouse", aimPart = "Head", aimFov = 150, aimSmooth = 4, wallCheck = true, showFov = true,
	trigger = false, triggerDelay = 60,
	noRecoil = false, noSpread = false,
	speed = false, speedMult = 1.3, jump = false, jumpBoost = 20, bhop = false,
	autoRematch = false, autoPlayAgain = false,
	unlockSkins = false, skins = {}, emotes = {},
	spoofLevel = false, fakeLevel = 999, spoofStreak = false, fakeStreak = 250, spoofRank = false, fakeRank = "Nemesis", fakeName = "",
}
local HttpService = game:GetService("HttpService")
local CFG_FILE = "rivals_hub_cfg.json"
if type(prev) ~= "table" and isfile and isfile(CFG_FILE) then
	local ok, saved = pcall(function() return HttpService:JSONDecode(readfile(CFG_FILE)) end)
	if ok and type(saved) == "table" then prev = saved end
end
if type(prev) == "table" then
	for k, v in pairs(prev) do
		if cfg[k] ~= nil and type(cfg[k]) == type(v) then cfg[k] = v end
	end
end

for k, v in pairs(cfg.skins) do
	if type(k) ~= "string" or type(v) ~= "table" then cfg.skins[k] = nil end
end

local S = { conns = {}, cfg = cfg, esp = {}, orig = {}, hooked = setmetatable({}, { __mode = "k" }) }
G.EzeRivals = S
local function alive() return G.EzeRivals == S end
local function conn(c) table.insert(S.conns, c) return c end

local function req(inst)
	local ok, m = pcall(require, inst)
	pcall(setthreadidentity, 8)
	return ok and m or nil
end

local FC = req(PS.Controllers.FighterController)
local DC = req(PS.Controllers.DuelController)
local CC = req(PS.Controllers.CameraController)
local VM = req(PS.Modules.ClientReplicatedClasses.ClientFighter.ClientItem.ClientViewModel)
local ItemLib = req(RS.Modules.ItemLibrary)
local CosLib = req(RS.Modules.CosmeticLibrary)
local PDC = req(PS.Controllers.PlayerDataController)
local Eq = req(PS.Modules.UserInterface.Equipment)
local EC = req(PS.Controllers.EmoteController)
local Util = req(RS.Modules.Utility)
local SeasonLib = req(RS.Modules.SeasonLibrary)
local Remotes = RS:WaitForChild("Remotes")

local uiParent = (gethui and gethui()) or game:GetService("CoreGui")
local espFolder = Instance.new("Folder")
espFolder.Name = tostring(math.random(1e6, 9e6))
espFolder.Parent = uiParent

local function fighterOf(plr)
	return FC and FC._player_to_fighter and FC._player_to_fighter[plr]
end

local function fighterAlive(f)
	if not f then return false end
	local ok, v = pcall(f.IsAlive, f)
	return ok and v
end

local function isEnemy(plr)
	if plr == LP then return false end
	if not cfg.teamCheck then return true end
	local mine, theirs = LP:GetAttribute("TeamID"), plr:GetAttribute("TeamID")
	if mine == nil or theirs == nil then return true end
	return mine ~= theirs
end

local DUMMIES = { ["Dummy"] = true, ["DPS Dummy"] = true }

local function liveEnemies()
	local list = {}
	for _, plr in ipairs(Players:GetPlayers()) do
		local c = plr.Character
		if plr ~= LP and c and isEnemy(plr) and fighterAlive(fighterOf(plr)) then
			local hum = c:FindFirstChildOfClass("Humanoid")
			if hum and hum.Health > 0 then
				table.insert(list, { model = c, hum = hum, name = plr.DisplayName })
			end
		end
	end
	local range = workspace:FindFirstChild("ShootingRangeEntities")
	local myRoot = LP.Character and LP.Character:FindFirstChild("HumanoidRootPart")
	if range and myRoot then
		for _, m in ipairs(range:GetChildren()) do
			if DUMMIES[m.Name] then
				local hum = m:FindFirstChildOfClass("Humanoid")
				local head = m:FindFirstChild("Head")
				if hum and hum.Health > 0 and head and (head.Position - myRoot.Position).Magnitude < 250 then
					table.insert(list, { model = m, hum = hum, name = m.Name })
				end
			end
		end
	end
	return list
end

local function localFighter()
	return FC and FC.LocalFighter
end

local function iAmAlive()
	return fighterAlive(localFighter())
end

local function rayParams()
	local ex = { Camera }
	if LP.Character then table.insert(ex, LP.Character) end
	local vms = workspace:FindFirstChild("ViewModels")
	if vms then table.insert(ex, vms) end
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
	if cfg.aimPart == "Torso" then return model:FindFirstChild("UpperTorso") or model:FindFirstChild("Torso") or model:FindFirstChild("HumanoidRootPart") end
	return model:FindFirstChild("Head")
end

local function bestTarget(forceWallCheck)
	local vp = Camera.ViewportSize
	local center = Vector2.new(vp.X / 2, vp.Y / 2)
	local params = (cfg.wallCheck or forceWallCheck) and rayParams()
	local bestPart, bestDist
	for _, t in ipairs(liveEnemies()) do
		local part = aimPartOf(t.model)
		if part then
			local pos, onScreen = Camera:WorldToViewportPoint(part.Position)
			if onScreen then
				local d = (Vector2.new(pos.X, pos.Y) - center).Magnitude
				if d <= cfg.aimFov and (not bestDist or d < bestDist) and (not params or visible(part, t.model, params)) then
					bestPart, bestDist = part, d
				end
			end
		end
	end
	return bestPart
end

local function wrapAngle(a)
	return (a + math.pi) % (2 * math.pi) - math.pi
end

local function aimAt(pos, k)
	local dir = (pos - Camera.CFrame.Position).Unit
	local look = Camera.CFrame.LookVector
	local cur = CC.Rotation
	CC:SetRotation(Vector2.new(
		cur.X + (math.asin(math.clamp(dir.Y, -1, 1)) - math.asin(math.clamp(look.Y, -1, 1))) * k,
		cur.Y + wrapAngle(math.atan2(-dir.X, -dir.Z) - math.atan2(-look.X, -look.Z)) * k
	))
end

local function stepAim()
	if fovCircle then
		local vp = Camera.ViewportSize
		fovCircle.Visible = (cfg.aim or cfg.silent) and cfg.showFov
		fovCircle.Position = Vector2.new(vp.X / 2, vp.Y / 2)
		fovCircle.Radius = cfg.aimFov
	end
	if not cfg.aim or not CC or not aimHeld() or not iAmAlive() then return end
	local part = bestTarget()
	if not part then return end
	aimAt(part.Position, 1 / math.max(cfg.aimSmooth, 1))
end

S.stepAim, S.bestTarget = stepAim, bestTarget

local function hookFighter(lf)
	if not lf or S.hooked[lf] then return end
	local mt = getmetatable(lf)
	local orig = mt and mt.__index and mt.__index.Input
	if type(orig) ~= "function" then return end
	S.hooked[lf] = true
	lf.Input = function(self, action, ...)
		if action == "StartShooting" and cfg.silent and alive() then
			local ok, part = pcall(bestTarget, true)
			if ok and part then
				local cam = workspace.CurrentCamera
				local old = cam.CFrame
				cam.CFrame = CFrame.lookAt(old.Position, part.Position)
				local r = table.pack(pcall(orig, self, action, ...))
				cam.CFrame = old
				if not r[1] then error(r[2], 0) end
				return table.unpack(r, 2, r.n)
			end
		end
		return orig(self, action, ...)
	end
end

local onTargetSince
local function stepTrigger()
	if not cfg.trigger or not iAmAlive() then onTargetSince = nil return end
	local cf = Camera.CFrame
	local hit = workspace:Raycast(cf.Position, cf.LookVector * 2000, rayParams())
	local onEnemy = false
	if hit then
		for _, t in ipairs(liveEnemies()) do
			if hit.Instance:IsDescendantOf(t.model) then onEnemy = true break end
		end
	end
	if not onEnemy then onTargetSince = nil return end
	onTargetSince = onTargetSince or os.clock()
	if os.clock() - onTargetSince < cfg.triggerDelay / 1000 then return end
	local lf = localFighter()
	if lf then pcall(lf.Input, lf, "StartShooting") end
end

local RECOIL_KEYS = { ShootRecoil = 0, ShootCameraDisplacementRecoil = Vector2.zero, ShootCameraDisplacementRecoilWhileAiming = Vector2.zero }
local SPREAD_KEYS = { ShootSpread = 0, QuickShotSpread = 0, ShootSpreadPerVelocityUnit = 0, ShootSpreadPerVelocityLimit = 0 }

local function applyGunMods()
	if not ItemLib or not ItemLib.Items then return end
	for _, info in pairs(ItemLib.Items) do
		if type(info) == "table" and info.Type == "Gun" then
			local orig = S.orig[info] or {}
			S.orig[info] = orig
			for keys, on in pairs({ [RECOIL_KEYS] = cfg.noRecoil, [SPREAD_KEYS] = cfg.noSpread }) do
				for k, v in pairs(keys) do
					if info[k] ~= nil or orig[k] ~= nil then
						if on then
							if orig[k] == nil then orig[k] = info[k] end
							info[k] = v
						elseif orig[k] ~= nil then
							info[k] = orig[k]
							orig[k] = nil
						end
					end
				end
			end
		end
	end
end

S.applyGunMods = applyGunMods

local function cosmeticType(name)
	local c = CosLib and type(name) == "string" and CosLib.Cosmetics[name]
	local t = c and CosLib.Types[c.Type]
	return t and (t.IsWeaponCosmetic or c.Type == "Emote") and c.Type or nil
end

local origOwns = CosLib and CosLib.OwnsCosmetic
local origOwnsAny = CosLib and CosLib.OwnsCosmeticForSomething
S.real = {}

local function picks(w)
	cfg.skins[w] = cfg.skins[w] or {}
	return cfg.skins[w]
end

local function weaponData(w)
	if not PDC or not PDC.CurrentData then return end
	for _, wd in pairs(PDC:Get("WeaponInventory") or {}) do
		if wd.Name == w then return wd end
	end
end

local function refreshInventory()
	if PDC and PDC.CurrentData then
		S.applying = true
		pcall(PDC.CurrentData.Replicate, PDC.CurrentData, "WeaponInventory")
		S.applying = false
	end
end

local function restoreReal(w, ty)
	local key = w .. "|" .. ty
	local wd = weaponData(w)
	if wd and S.real[key] ~= nil then wd[ty] = S.real[key] or nil end
	S.real[key] = nil
end

local function applyLocalCosmetics()
	if S.applying or not cfg.unlockSkins or not PDC or not PDC.CurrentData then return end
	local changed = false
	for _, wd in pairs(PDC:Get("WeaponInventory") or {}) do
		for ty, want in pairs(cfg.skins[wd.Name] or {}) do
			if not wd[ty] or wd[ty].Name ~= want then
				local key = wd.Name .. "|" .. ty
				if S.real[key] == nil then S.real[key] = wd[ty] or false end
				local new = wd[ty] and table.clone(wd[ty]) or {}
				new.Name = want
				wd[ty] = new
				changed = true
			end
		end
	end
	if changed then refreshInventory() end
end

local function restoreAllReal()
	for key in pairs(S.real) do
		local w, ty = key:match("^(.-)|(.+)$")
		if w then restoreReal(w, ty) end
	end
	refreshInventory()
end

local function onSelectCosmetic(name)
	if not cfg.unlockSkins or not Eq then return end
	local ty, w = Eq:GetCustomizingType(), Eq:GetSelectedWeapon()
	if not w or not ty or not CosLib.Types[ty] or not CosLib.Types[ty].IsWeaponCosmetic then return end
	local owned = name == "NONE_COSMETIC" or cosmeticType(name) ~= ty or origOwns(CosLib, PDC:Get("CosmeticInventory"), name, w)
	if owned then
		picks(w)[ty] = nil
		restoreReal(w, ty)
		refreshInventory()
	else
		picks(w)[ty] = name
		applyLocalCosmetics()
	end
end

S.realEmote = {}

local function realOwns(name)
	return origOwns(CosLib, PDC:Get("CosmeticInventory"), name)
end

local function replicateEmotes()
	if PDC and PDC.CurrentData then
		S.applying = true
		pcall(PDC.CurrentData.Replicate, PDC.CurrentData, "EquippedEmotes")
		S.applying = false
	end
end

local function applyLocalEmotes()
	if S.applying or not cfg.unlockSkins or not PDC or not PDC.CurrentData then return end
	local eq = PDC:Get("EquippedEmotes")
	if type(eq) ~= "table" then return end
	local changed = false
	for slot, name in pairs(cfg.emotes) do
		if not eq[slot] or eq[slot].Name ~= name then
			if S.realEmote[slot] == nil then S.realEmote[slot] = eq[slot] or false end
			eq[slot] = { Name = name }
			changed = true
		end
	end
	if changed then replicateEmotes() end
end

local function restoreEmoteSlot(slot)
	local eq = PDC and PDC.CurrentData and PDC:Get("EquippedEmotes")
	if eq and S.realEmote[slot] ~= nil then eq[slot] = S.realEmote[slot] or nil end
	S.realEmote[slot] = nil
end

local function restoreAllEmotes()
	for slot in pairs(S.realEmote) do restoreEmoteSlot(slot) end
	replicateEmotes()
end

local function stopLocalEmote()
	local e = S.emote
	S.emote = nil
	if e then pcall(e.Destroy, e) end
	if S.tpSet and CC then
		S.tpSet = false
		pcall(CC.SetThirdPersonOverride, CC, S.prevTP)
	end
end

local function playLocalEmote(name)
	stopLocalEmote()
	local folder = RS.Modules:FindFirstChild("Emotes")
	local mod = folder and folder:FindFirstChild(name)
	local hum = LP.Character and LP.Character:FindFirstChildOfClass("Humanoid")
	local E = mod and req(mod)
	if not E or not hum then return end
	local e = E.new(hum)
	S.emote = e
	if CC then
		S.prevTP = CC._third_person_override
		S.tpSet = true
		pcall(CC.SetThirdPersonOverride, CC, true)
	end
	task.spawn(pcall, e.PlayClient, e)
	local t0 = os.clock()
	task.spawn(function()
		task.wait(0.4)
		while S.emote == e and alive() do
			if e.Lifetime and os.clock() - t0 > e.Lifetime then break end
			if hum.Health <= 0 or hum.MoveDirection.Magnitude > 0.1 then break end
			task.wait(0.1)
		end
		if S.emote == e then stopLocalEmote() end
	end)
end

local function installUnlock()
	if not CosLib or not origOwns or S.unlockHook then return end
	S.unlockHook = true
	CosLib.OwnsCosmetic = function(self, inv, name, w, ...)
		if cfg.unlockSkins and alive() and cosmeticType(name) then return true end
		return origOwns(self, inv, name, w, ...)
	end
	CosLib.OwnsCosmeticForSomething = function(self, inv, name, ...)
		if cfg.unlockSkins and alive() and cosmeticType(name) then return true end
		return origOwnsAny(self, inv, name, ...)
	end
	if Eq then
		local mt = getmetatable(Eq)
		local origSelect = mt and mt.__index and mt.__index.SelectCosmetic
		if type(origSelect) == "function" then
			Eq.SelectCosmetic = function(self, ...)
				local r = table.pack(origSelect(self, ...))
				if alive() then pcall(onSelectCosmetic, (...)) end
				return table.unpack(r, 1, r.n)
			end
		end
	end
	if EC then
		local mt = getmetatable(EC)
		local idx = mt and mt.__index
		local origEquip = idx and idx.EquipEmote
		local origUse = idx and idx.UseEmoteByName
		if type(origEquip) == "function" and type(origUse) == "function" then
			EC.EquipEmote = function(self, slot, name, ...)
				if cfg.unlockSkins and alive() then
					if name and not realOwns(name) then
						cfg.emotes[slot] = name
						applyLocalEmotes()
						return
					end
					if cfg.emotes[slot] then
						cfg.emotes[slot] = nil
						restoreEmoteSlot(slot)
						replicateEmotes()
						if not name then return end
					end
				end
				return origEquip(self, slot, name, ...)
			end
			EC.UseEmoteByName = function(self, name, ...)
				if cfg.unlockSkins and alive() and cosmeticType(name) == "Emote" and not realOwns(name) then
					pcall(playLocalEmote, name)
					return
				end
				return origUse(self, name, ...)
			end
		end
	end
	if PDC and PDC.CurrentData then
		conn(PDC:GetDataChangedSignal("WeaponInventory"):Connect(function()
			if alive() then task.defer(applyLocalCosmetics) end
		end))
		conn(PDC:GetDataChangedSignal("EquippedEmotes"):Connect(function()
			if alive() then task.defer(applyLocalEmotes) end
		end))
	end
end

local function installSkins()
	if not VM or S.skinHook then return end
	S.skinHook = true
	VM.Get = function(self, key)
		local v = self.Data[key]
		if (key == "Name" or key == "Wrap" or key == "Charm") and cfg.unlockSkins and alive() then
			local item = rawget(self, "ClientItem")
			local f = item and item.ClientFighter
			local p = f and f.IsLocalPlayer and type(item.Name) == "string" and cfg.skins[item.Name]
			if p then
				if key == "Name" then return p.Skin or v end
				local want = p[key]
				if want then
					local new = type(v) == "table" and table.clone(v) or {}
					new.Name = want
					return new
				end
			end
		end
		return v
	end
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
	if S.jumpHum ~= hum then
		S.jumpHum = hum
		if S.jumpConn then S.jumpConn:Disconnect() end
		S.jumpConn = conn(hum.StateChanged:Connect(function(_, new)
			if new == Enum.HumanoidStateType.Jumping and cfg.jump and alive() then
				local r = hum.Parent and hum.Parent:FindFirstChild("HumanoidRootPart")
				if r then r.AssemblyLinearVelocity += Vector3.new(0, cfg.jumpBoost, 0) end
			end
		end))
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
	local list = liveEnemies()

	if myRoot then
		for _, t in ipairs(list) do
			local h = t.model:FindFirstChild("Head")
			t.dist = h and (h.Position - myRoot.Position).Magnitude or math.huge
		end
		table.sort(list, function(a, b) return a.dist < b.dist end)
	end
	for i, t in ipairs(list) do
		local head = t.model:FindFirstChild("Head")
		if head then
			seen[t.model] = true
			local e = S.esp[t.model] or newEsp(t.model)
			S.esp[t.model] = e
			e.hl.FillColor = color
			e.hl.OutlineColor = color
			e.hl.Enabled = i <= 28
			e.bb.Adornee = head
			local parts = {}
			if cfg.espNames then table.insert(parts, t.name) end
			if cfg.espHealth then table.insert(parts, math.floor(t.hum.Health) .. " HP") end
			if cfg.espDist and myRoot then table.insert(parts, math.floor((head.Position - myRoot.Position).Magnitude) .. " studs") end
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

local handledDuel = setmetatable({}, { __mode = "k" })
local function stepDuel()
	if not (cfg.autoRematch or cfg.autoPlayAgain) or not DC then return end
	local d = DC.CurrentObject
	if not d or handledDuel[d] then return end
	local ok, avail = pcall(d.Get, d, "RematchAvailable")
	if not ok or avail == nil then return end
	handledDuel[d] = true
	if cfg.autoRematch then
		Remotes.Duels.Rematch:FireServer()
	end
	if cfg.autoPlayAgain then
		task.delay(cfg.autoRematch and 8 or 2, function()
			if alive() and cfg.autoPlayAgain and DC.CurrentObject == d then
				Remotes.Matchmaking.PlayAgain:FireServer()
			end
		end)
	end
end

local function claimRewards()
	local data = Remotes:FindFirstChild("Data")
	if not data then return 0 end
	local n = 0
	for _, name in ipairs({ "ClaimLoginReward", "ClaimGroupReward", "ClaimLikeReward", "ClaimFavoriteReward", "ClaimNotificationsReward", "ClaimWelcomeBackGift" }) do
		local r = data:FindFirstChild(name)
		if r then
			n += 1
			if r:IsA("RemoteFunction") then
				task.spawn(pcall, r.InvokeServer, r)
			else
				pcall(r.FireServer, r)
			end
		end
	end
	return n
end

local lastEsp, lastSlow = 0, 0
conn(RunService.RenderStepped:Connect(function()
	if not alive() then return end
	Camera = workspace.CurrentCamera
	local now = os.clock()
	if now - lastEsp > 0.1 then
		lastEsp = now
		pcall(updateEsp)
	end
	if now - lastSlow > 0.5 then
		lastSlow = now
		pcall(hookFighter, localFighter())
		pcall(stepDuel)
	end
	pcall(stepAim)
	pcall(stepTrigger)
end))

conn(RunService.Heartbeat:Connect(function(dt)
	if not alive() then return end
	pcall(stepMove, dt)
end))

local rankNames, rankElo = {}, {}
pcall(function()
	local rp = SeasonLib.CurrentSeason.RankProfile
	for _, n in ipairs(rp.RanksOrder) do
		local elo = rp.Ranks[n].RequiredELO
		if type(elo) == "number" and elo >= 0 then
			table.insert(rankNames, n)
			rankElo[n] = elo
		end
	end
end)

local SPOOF_ATTRS = { "Level", "StatisticDuelsWinStreak", "DisplayELO" }
S.realAttr = {}

local function wantedAttr(k)
	if k == "Level" then return cfg.spoofLevel and cfg.fakeLevel or nil end
	if k == "StatisticDuelsWinStreak" then return cfg.spoofStreak and cfg.fakeStreak or nil end
	if k == "DisplayELO" then return cfg.spoofRank and rankElo[cfg.fakeRank] or nil end
end

local function applyAttrs()
	for _, k in ipairs(SPOOF_ATTRS) do
		local want = alive() and wantedAttr(k) or nil
		if want ~= nil then
			if not S.realAttr[k] then S.realAttr[k] = { v = LP:GetAttribute(k) } end
			if LP:GetAttribute(k) ~= want then
				S.settingAttr = true
				LP:SetAttribute(k, want)
				S.settingAttr = false
			end
		elseif S.realAttr[k] then
			local real = S.realAttr[k].v
			S.realAttr[k] = nil
			S.settingAttr = true
			LP:SetAttribute(k, real)
			S.settingAttr = false
		end
	end
end

for _, k in ipairs(SPOOF_ATTRS) do
	conn(LP:GetAttributeChangedSignal(k):Connect(function()
		if S.settingAttr or not alive() then return end
		if S.realAttr[k] then
			S.realAttr[k].v = LP:GetAttribute(k)
			task.defer(applyAttrs)
		end
	end))
end

local origGetName = Util and Util.GetName
if Util and origGetName then
	Util.GetName = function(self, plr, ...)
		if plr == LP and cfg.fakeName ~= "" and alive() then return cfg.fakeName end
		return origGetName(self, plr, ...)
	end
end

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

local winProps = { name = "Eze Hub" }
if autoload then winProps.discord = false end
local win = Library:window(winProps)

local combatTab = win:Tab({ name = "Combat", icon = "lucide:crosshair" })
local sa = combatTab:Section({ name = "Silent Aim", side = "left" })
toggle(sa, "Silent Aim", "silent")
sa:Label({ name = "Shots go to the closest visible enemy in the FOV circle. Uses the aimbot FOV and target part." })
local ab = combatTab:Section({ name = "Aimbot", side = "left" })
toggle(ab, "Aimbot", "aim")
ab:Label({ name = "Tip: click Aim Key or Target Part to switch them." })
ab:Dropdown({ name = "Aim Key", items = { "Right Mouse", "Left Mouse", "Always" }, default = cfg.aimKey, Callback = setCfg("aimKey") })
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
local skTab = win:Tab({ name = "Skins", icon = "lucide:palette" })
local sk = skTab:Section({ name = "Cosmetics", side = "left" })
toggle(sk, "Unlock All Cosmetics", "unlockSkins", function(v)
	cfg.unlockSkins = v
	if v then applyLocalCosmetics() applyLocalEmotes() else restoreAllReal() restoreAllEmotes() stopLocalEmote() end
end)
sk:Button({ name = "Reset Cosmetics", Callback = function()
	table.clear(cfg.skins)
	table.clear(cfg.emotes)
	restoreAllReal()
	restoreAllEmotes()
end })
sk:Label({ name = "Unlocks every Skin, Wrap, Charm, Finisher and Emote in the game's Equipment menu. Equip them there like normal. Weapon changes show on the next spawn (new round or respawn)." })

local plTab = win:Tab({ name = "Player", icon = "lucide:user" })
local mv = plTab:Section({ name = "Movement", side = "left" })
toggle(mv, "Speed Boost", "speed")
slider(mv, "Speed Multiplier", "speedMult", 1, 2, 2)
toggle(mv, "Jump Boost", "jump")
slider(mv, "Extra Jump Velocity", "jumpBoost", 0, 60)
toggle(mv, "Bunny Hop (hold Space)", "bhop")
mv:Label({ name = "Big values can get you rubberbanded by the server." })

local cfTab = win:Tab({ name = "Clipfarming", icon = "lucide:video" })
local pf = cfTab:Section({ name = "Profile Spoof", side = "left" })
local function numBox(sec, name, key)
	return sec:Textbox({ name = name, placeholder = name .. " (now " .. tostring(cfg[key]) .. ")", Callback = function(t)
		local n = tonumber(t)
		if n then cfg[key] = math.floor(n) pcall(applyAttrs) end
	end })
end
toggle(pf, "Spoof Level", "spoofLevel", function(v) cfg.spoofLevel = v pcall(applyAttrs) end)
numBox(pf, "Level", "fakeLevel")
toggle(pf, "Spoof Win Streak", "spoofStreak", function(v) cfg.spoofStreak = v pcall(applyAttrs) end)
numBox(pf, "Win Streak", "fakeStreak")
toggle(pf, "Spoof Rank", "spoofRank", function(v) cfg.spoofRank = v pcall(applyAttrs) end)
pf:Dropdown({ name = "Rank", items = rankNames, default = rankElo[cfg.fakeRank] and cfg.fakeRank or rankNames[#rankNames], Callback = function(v) cfg.fakeRank = v pcall(applyAttrs) end })
pf:Textbox({ name = "Fake Name", placeholder = "Fake name (empty = off)", Callback = function(t) cfg.fakeName = t end })
pf:Label({ name = "Only you see these. Shows on nametags, the 1v1 scoreboard and the results screen. Name changes show on the next spawn." })

local miscTab = win:Tab({ name = "Misc", icon = "lucide:settings" })
local actions = miscTab:Section({ name = "Hub", side = "left" })
actions:Button({ name = "Unload Hub", Callback = function() S.Unload() end })
actions:Label({ name = "v" .. VERSION .. " - RightControl toggles the UI. Unload removes the hub and puts the game back to normal." })
local mt = miscTab:Section({ name = "Matches", side = "left" })
toggle(mt, "Auto Rematch", "autoRematch")
toggle(mt, "Auto Play Again", "autoPlayAgain")
mt:Label({ name = "Votes rematch and/or re-queues as soon as a match ends." })
local lb = miscTab:Section({ name = "Lobby", side = "right" })
lb:Button({ name = "Claim Free Rewards", Callback = function()
	local n = claimRewards()
	Library:create_notification({ name = "Sent " .. n .. " reward claims", duration = 3 })
end })
lb:Label({ name = "Login, group, like, favorite and notification rewards. Already-claimed ones are ignored by the server." })

function S.Unload()
	if G.EzeRivals == S then G.EzeRivals = nil end
	for _, c in ipairs(S.conns) do pcall(function() c:Disconnect() end) end
	clearEsp()
	pcall(function() espFolder:Destroy() end)
	local keep = { noRecoil = cfg.noRecoil, noSpread = cfg.noSpread }
	cfg.noRecoil, cfg.noSpread = false, false
	pcall(applyGunMods)
	cfg.noRecoil, cfg.noSpread = keep.noRecoil, keep.noSpread
	for lf in pairs(S.hooked) do pcall(rawset, lf, "Input", nil) end
	if VM and S.skinHook then pcall(rawset, VM, "Get", nil) end
	if S.unlockHook then
		pcall(rawset, CosLib, "OwnsCosmetic", origOwns)
		pcall(rawset, CosLib, "OwnsCosmeticForSomething", origOwnsAny)
		if Eq then pcall(rawset, Eq, "SelectCosmetic", nil) end
		pcall(restoreAllReal)
		pcall(restoreAllEmotes)
		pcall(stopLocalEmote)
		if EC then
			pcall(rawset, EC, "EquipEmote", nil)
			pcall(rawset, EC, "UseEmoteByName", nil)
		end
	end
	if fovCircle then pcall(function() fovCircle:Remove() end) end
	pcall(applyAttrs)
	if Util and origGetName then pcall(rawset, Util, "GetName", nil) end
	pcall(function() Library:Unload() end)
end

installSkins()
installUnlock()
if cfg.unlockSkins then pcall(applyLocalCosmetics) pcall(applyLocalEmotes) end
if cfg.noRecoil or cfg.noSpread then pcall(applyGunMods) end
pcall(applyAttrs)

local qot = queue_on_teleport or queueonteleport
if qot and not G.EzeRivalsQueued then
	G.EzeRivalsQueued = true
	pcall(qot, 'if not getgenv().EzeRivals then getgenv().EzeRivalsAutoload = true local src = isfile and isfile("rivals_hub.lua") and readfile("rivals_hub.lua") or game:HttpGet("https://raw.githubusercontent.com/mechupacristopher-creator/lua/main/RIVALS/rivals_hub.lua") loadstring(src)() end')
end
task.spawn(function()
	while alive() do
		local ok, json = pcall(HttpService.JSONEncode, HttpService, cfg)
		if ok and json ~= S.savedJson and writefile then
			S.savedJson = json
			pcall(writefile, CFG_FILE, json)
		end
		task.wait(2)
	end
end)
Library:create_notification({ name = "Eze Hub loaded - RightControl to toggle", duration = 4 })
