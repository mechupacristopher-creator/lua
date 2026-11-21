local instance = {}
getgenv().TD_INSTANCE = instance
if getgenv().TD_UNLOAD then pcall(getgenv().TD_UNLOAD) task.wait(0.3) end
if not game:IsLoaded() then game.Loaded:Wait() end

local Players = game:GetService("Players")
local RS = game:GetService("ReplicatedStorage")
local UIS = game:GetService("UserInputService")
local Http = game:GetService("HttpService")
local TweenService = game:GetService("TweenService")
local lp = Players.LocalPlayer
local Net = RS:WaitForChild("GenericModules"):WaitForChild("Service"):WaitForChild("Network")

local G = getrenv()._G
while not (G.data and G.serverType and G.FireNetwork) do task.wait(0.5) G = getrenv()._G end
if getgenv().TD_INSTANCE ~= instance then return end
if getgenv().TD_UNLOAD then pcall(getgenv().TD_UNLOAD) task.wait(0.3) end

local alive = true
local connections = {}
local function bind(c) table.insert(connections, c) return c end

local CFG_FILE = "td_macro_cfg_" .. lp.UserId .. ".json"
if not isfile(CFG_FILE) and isfile("td_macro_cfg.json") then pcall(writefile, CFG_FILE, readfile("td_macro_cfg.json")) end
local cfg = {
	enabled = true, autoStart = true, autoPlace = true,
	endAction = "replay",
	unknownMap = "auto",
	autoCards = true,
	autoAbility = true,
	autoFish = false,
	infTower = false,
	autoBounty = false,
	halloween = false,
	halloweenDiff = "Normal",
	autoGolden = true,
	autoShenron = true,
	cardOrder = {},
	recNames = {},
	mode = "auto",
	firstUnitCost = 350,
	units = {},
	recordings = {},
	stats = { matches = 0, wins = 0 },
}
pcall(function() for k, v in pairs(Http:JSONDecode(readfile(CFG_FILE))) do cfg[k] = v end end)
cfg.mode = (cfg.mode == "recorded") and "recorded" or "auto"
if cfg.autoReplay == false and not cfg.endAction then cfg.endAction = "none" end
cfg.endAction = cfg.endAction or "replay"
cfg.unknownMap = cfg.unknownMap or "auto"
cfg.cardOrder = cfg.cardOrder or {}
cfg.cards = nil
cfg.recNames = cfg.recNames or {}
if cfg.autoCards == nil then cfg.autoCards = true end
if cfg.autoAbility == nil then cfg.autoAbility = true end
cfg.stats.wins = cfg.stats.wins or 0
local function save() pcall(writefile, CFG_FILE, Http:JSONEncode(cfg)) end

local function fixIdentity() if setthreadidentity then pcall(setthreadidentity, 8) end end
local function gameCall(f)
	local ok, r = pcall(f)
	fixIdentity()
	if ok then return r end
end

local function inMatch() return G.serverType == "Match" end
local function gameStarted() return gameCall(function() return G.root.roundStats.gameStarted end) end

local function isGameOver()
	return G.gameover == true and not gameCall(function() return G.root.matchStartActive end)
end
local function cash() return G.data.cash or 0 end
local function wave() return gameCall(function() return G.root.wave.index end) or 0 end
local function fire(name, ...) local args = { ... } gameCall(function() G.FireNetwork(name, table.unpack(args)) end) end

local function equipped() return gameCall(function() return G.data:GetEquippedTowers() end) or {} end

local function slotOf(id)
	for i, t in pairs(equipped()) do if t.id == id then return i end end
end
local function stepTower(s) return s.slot and equipped()[s.slot] end

local OLD_IDS = { ["6076429612:1234"] = 2 }
do
	local changed = false
	for _, steps in pairs(cfg.recordings) do
		for _, s in ipairs(steps) do
			if s.t == "place" and not s.slot and s.id then
				s.slot = OLD_IDS[s.id] or slotOf(s.id)
				changed = true
			end
		end
	end
	if changed then save() end
end
local function costs(t) return gameCall(function() return t:GetCashCosts() end) or {} end
local function limitOf(t) return gameCall(function() return t:GetPlacementLimit() end) or 1 end
local function unitName(t) return tostring(gameCall(function() return t.Name end) or t.id) end
local function isDragon(t)
	return gameCall(function() return t.Class:Is(G.Tower.BaseDrago) end) or tostring(t.id):find("Shenron") ~= nil
end

local function unitCfg(t)
	local u = cfg.units[t.id]
	if not u then
		u = { on = not isDragon(t), cap = limitOf(t) }
		cfg.units[t.id] = u
	end
	return u
end

local entities, lastScan = nil, 0
local function findEntities()
	if entities then return entities end

	local models = workspace:FindFirstChild("EntityModels")
	local towers = models and models:FindFirstChild("Towers")
	if towers and #towers:GetChildren() == 0 then return {} end
	if os.clock() - lastScan < 1 then return nil end
	lastScan = os.clock()
	local seen = {}
	local function scan(f, depth)
		if type(f) ~= "function" or depth > 3 or seen[f] then return end
		seen[f] = true
		local ok, ups = pcall(debug.getupvalues, f)
		if not ok then return end
		for _, u in pairs(ups) do
			if entities then return end
			if type(u) == "table" then
				local _, v = next(u)
				if type(v) == "table" and rawget(v, "classId") ~= nil and rawget(v, "model") ~= nil then entities = u end
			elseif type(u) == "function" then
				scan(u, depth + 1)
			end
		end
	end
	local ctm = G.ClientTowerManager
	if ctm then
		scan(ctm.updateHotbarSlots, 0)
		scan(ctm.DeselectTower, 0)
	end
	fixIdentity()
	return entities
end

local function myTowers()
	local set = {}
	local ents = findEntities()
	if ents then
		for eid, e in pairs(ents) do
			if type(e) == "table" and e.ownerId == lp.UserId and typeof(e.model) == "Instance" and e.model.Parent then
				set[tostring(eid)] = e
			end
		end
	end
	return set
end

local MAX_PHANTOMS = 3
local function myPhantoms()
	local list = {}
	local folder = workspace:FindFirstChild("PhantomTowers")
	if folder then
		for _, m in ipairs(folder:GetChildren()) do
			if m:GetAttribute("OwnerId") == lp.UserId then table.insert(list, m) end
		end
	end
	return list
end

local function countPlaced(towerId)
	local n = 0
	for _, e in pairs(myTowers()) do if e.id == towerId then n += 1 end end
	for _, m in ipairs(myPhantoms()) do if m:GetAttribute("TowerId") == towerId then n += 1 end end
	return n
end

local function waitCountUp(towerId, before, timeout)
	local t0 = os.clock()
	repeat
		if countPlaced(towerId) > before then return true end
		task.wait(0.1)
	until os.clock() - t0 > timeout
	return false
end

local function waitNewTower(towerId, before, timeout)
	local t0 = os.clock()
	repeat
		for eid, e in pairs(myTowers()) do
			if not before[eid] and e.id == towerId then return eid end
		end
		task.wait(0.1)
	until os.clock() - t0 > timeout
end

local function occupied(pos)
	local function near(p) return ((p - pos) * Vector3.new(1, 0, 1)).Magnitude < 3.2 end
	local ents = findEntities()
	if ents then
		for _, e in pairs(ents) do
			if type(e) == "table" and typeof(e.placementPoint) == "CFrame" and typeof(e.model) == "Instance" and e.model.Parent
				and near(e.placementPoint.Position) then
				return true
			end
		end
	end
	local folder = workspace:FindFirstChild("PhantomTowers")
	if folder then
		for _, m in ipairs(folder:GetChildren()) do
			if m:IsA("Model") and near(m:GetPivot().Position) then return true end
		end
	end
	return false
end

local function canPlace(cost) return cash() >= cost or #myPhantoms() < MAX_PHANTOMS end

local rayParams = RaycastParams.new()
rayParams.CollisionGroup = "TowerPlacement"
rayParams.FilterType = Enum.RaycastFilterType.Exclude

local function floorAt(pos)
	rayParams.FilterDescendantsInstances = { workspace:FindFirstChild("EntityColliders"), workspace:FindFirstChild("EntityModels") }
	local hit = workspace:Raycast(pos + Vector3.new(0, 40, 0), Vector3.new(0, -120, 0), rayParams)
	if hit and hit.Instance.CollisionGroup == "Floor" then return hit.Position end
end

local function itStart()
	local folder = workspace:FindFirstChild("Map") and workspace.Map:FindFirstChild("StartPositions")
	if not folder then return end
	for _, p in ipairs(folder:GetChildren()) do
		if p:FindFirstChild("StartTag") then return p end
	end
end

local function mapKey()
	if G.gamemode == "InfiniteTower" then
		local s = itStart()
		return "InfiniteTower_" .. (s and string.format("%d_%d", math.floor(s.Position.X), math.floor(s.Position.Z)) or "?")
	end
	local map = workspace:FindFirstChild("Map")
	local tag = map and (map:FindFirstChild("StartTag") or map:FindFirstChild("DefendTag"))
	if not (tag and tag:IsA("BasePart")) then return "none" end
	local p = tag.Position
	local key = string.format("%d_%d_%d", math.floor(p.X), math.floor(p.Y), math.floor(p.Z))
	return tag.Name == "StartTag" and key or (tostring(G.gamemode) .. "_" .. key)
end

local bad, noSpot = {}, {}
local cachedSpots, cachedKey
local function pathSpots()
	local map = workspace:FindFirstChild("Map")

	local folder = map and (map:FindFirstChild("Path") or map:FindFirstChild("PathParts"))
	if not folder then return {} end
	local parts = {}
	for _, p in ipairs(folder:GetChildren()) do
		if p:IsA("Model") then p = p.PrimaryPart or p:FindFirstChild("Primary") end
		if p and p:IsA("BasePart") then table.insert(parts, p) end
	end

	local key = mapKey() .. (parts[1] and tostring(parts[1].Position) or "")
	if cachedKey == key then return cachedSpots end

	local tag = G.gamemode == "InfiniteTower" and itStart() or map:FindFirstChild("StartTag")
	local base = map:FindFirstChild("DefendTag")
	if not tag and base and #parts > 0 then
		tag = parts[1]
		for _, p in ipairs(parts) do
			if (p.Position - base.Position).Magnitude > (tag.Position - base.Position).Magnitude then tag = p end
		end
	end
	if not tag then return {} end

	local ordered, from = {}, tag.Position
	while #parts > 0 do
		local bi, bd = 1, math.huge
		for i, p in ipairs(parts) do
			local d = (p.Position - from).Magnitude
			if d < bd then bi, bd = i, d end
		end
		table.insert(ordered, table.remove(parts, bi))
		from = ordered[#ordered].Position
	end

	local close, far, zig = {}, {}, 1
	for _, p in ipairs(ordered) do
		local cf, size = p.CFrame, p.Size
		local alongX = size.X >= size.Z
		local len = alongX and size.X or size.Z
		local half = (alongX and size.Z or size.X) / 2
		local axis = alongX and cf.RightVector or cf.LookVector
		local side = alongX and cf.LookVector or cf.RightVector
		local nearEnd = ((cf.Position + axis * len / 2) - tag.Position).Magnitude < ((cf.Position - axis * len / 2) - tag.Position).Magnitude
		local sign = nearEnd and 1 or -1
		for d = len / 2, -len / 2, -2 do
			table.insert(close, cf.Position + axis * d * sign + side * zig * (half + 2))
			zig = -zig
		end
		for d = len / 2, -len / 2, -4 do
			for _, s in ipairs({ 1, -1 }) do
				for _, off in ipairs({ half + 5, half + 8 }) do
					table.insert(far, cf.Position + axis * d * sign + side * s * off)
				end
			end
		end
	end
	local spots = table.move(far, 1, #far, #close + 1, close)
	cachedSpots, cachedKey = spots, key
	return spots
end

local status = "Starting"
local notify = function() end

local function isBad(pos)
	for _, b in ipairs(bad) do if (b - pos).Magnitude < 2 then return true end end
	return false
end

local function tryPlace(t)
	for _, raw in ipairs(pathSpots()) do
		if not alive or not cfg.enabled then return false end
		local pos = floorAt(raw)
		if pos and not isBad(pos) and not occupied(pos) then
			local before = countPlaced(t.id)
			Net.PlayerPlaceTower:FireServer(t.id, pos, 0)
			if waitCountUp(t.id, before, 1) then return true end
			table.insert(bad, pos)
		end
	end
	return false
end

local function placementQueue()
	local first, rest = {}, {}
	for _, t in ipairs(equipped()) do
		if unitCfg(t).on and not isDragon(t) then
			if costs(t)[1] == cfg.firstUnitCost then table.insert(first, t) else table.insert(rest, t) end
		end
	end
	table.sort(rest, function(a, b) return (costs(a)[1] or 0) < (costs(b)[1] or 0) end)
	for _, t in ipairs(rest) do table.insert(first, t) end
	return first
end

local function placeTick()

	if not findEntities() then status = "Reading game towers…" return true end
	for _, t in ipairs(placementQueue()) do
		local cap = math.min(unitCfg(t).cap, limitOf(t))
		local placed = countPlaced(t.id)
		if placed < cap and not noSpot[t.id] then
			local cost = costs(t)[1] or math.huge
			if not canPlace(cost) then
				status = string.format("3 ghosts pending; next: %s (%d/%d)", unitName(t), placed, cap)
			else
				status = string.format("%s %s (%d/%d)", cash() >= cost and "Placing" or "Ghost of", unitName(t), placed + 1, cap)
				if not tryPlace(t) then noSpot[t.id] = true end
			end
			return true
		end
	end
	return false
end

local recording, recSteps, entToStep, recKey = false, {}, {}, nil

local function saveRecording()
	if not recKey then return 0 end
	local clean, remap = {}, {}
	for i, s in ipairs(recSteps) do
		if not s.failed then
			local copy = table.clone(s)
			if copy.ref then copy.ref = remap[copy.ref] end
			if copy.t == "place" or copy.ref then
				table.insert(clean, copy)
				remap[i] = #clean
			end
		end
	end
	if #clean > 0 then
		cfg.recordings[recKey] = clean
		save()
	end
	return #clean
end

local function stopRecording()
	if not recording then return end
	recording = false
	local n = saveRecording()
	notify("Recording saved", n .. " steps for this map")
end

local function startRecording()
	recSteps, entToStep, recording, recKey = {}, {}, true, mapKey()
	notify("Recording", "Place your units; every step is saved")
end

local function recordCall(remote, args)
	fixIdentity()
	if remote == Net.PlayerPlaceTower then
		local id, pos, rot = args[1], args[2], args[3]
		if typeof(pos) ~= "Vector3" then return end
		local beforeCount, beforeTowers = countPlaced(id), myTowers()
		table.insert(recSteps, { t = "place", slot = slotOf(id), id = id, pos = { pos.X, pos.Y, pos.Z }, rot = rot or 0 })
		local idx = #recSteps
		if not waitCountUp(id, beforeCount, 2) then recSteps[idx].failed = true return end
		saveRecording()

		local eid = waitNewTower(id, beforeTowers, 300)
		if eid then entToStep[eid] = idx end
	elseif remote == Net.PlayerSellTower then
		local idx = entToStep[tostring(args[1])]
		if idx then
			table.insert(recSteps, { t = "sell", ref = idx })
			saveRecording()
		end
	end
end

local lastHalloweenTry, halloweenPad = 0, 0

local function halloweenPads()
	local area = workspace.Lobby:FindFirstChild("HalloweenEventLobby")
	local folder = area and area:FindFirstChild("EventTeleporters")
	local pads = {}
	for _, t in ipairs(folder and folder:GetChildren() or {}) do
		local diff = t:FindFirstChild("Difficulty", true)
		local hitbox = t:FindFirstChild("hitbox", true)
		if hitbox and diff and diff:IsA("TextLabel") and diff.Text == cfg.halloweenDiff then table.insert(pads, hitbox) end
	end
	table.sort(pads, function(a, b) return a:GetFullName() < b:GetFullName() end)
	return pads
end

local function halloweenTick()
	local pads = halloweenPads()
	if #pads == 0 then status = "Halloween: no " .. cfg.halloweenDiff .. " bubbles in this lobby" return end
	local hrp = lp.Character and lp.Character:FindFirstChild("HumanoidRootPart")
	if not hrp then return end
	status = string.format("Halloween %s: waiting for teleport…", cfg.halloweenDiff)
	if os.clock() - lastHalloweenTry < 20 then return end
	lastHalloweenTry = os.clock()
	halloweenPad = halloweenPad % #pads + 1
	hrp.CFrame = pads[halloweenPad].CFrame
	notify("Halloween", string.format("Bubble %s %d/%d", cfg.halloweenDiff, halloweenPad, #pads))
end

local oldNamecall
oldNamecall = hookmetamethod(game, "__namecall", function(self, ...)
	if alive and recording and not checkcaller() and getnamecallmethod() == "FireServer"
		and (self == Net.PlayerPlaceTower or self == Net.PlayerSellTower) then
		local args = { ... }
		task.spawn(function()
			local ok, e = pcall(recordCall, self, args)
			if not ok then getgenv().TD_LASTERR = "recording: " .. tostring(e) end
		end)
	end
	return oldNamecall(self, ...)
end)

local replay = { i = 1, ents = {}, tries = 0 }

local function replayTick()
	local steps = cfg.recordings[mapKey()]
	if not steps or #steps == 0 then status = "No recording for this map" return end
	local s = steps[replay.i]
	if not s then status = string.format("Recording finished (%d steps) ✔", #steps) return end
	local function nextStep() replay.i += 1 replay.tries = 0 end
	local function failed() replay.tries += 1 if replay.tries >= 3 then nextStep() end end
	local prefix = string.format("Step %d/%d: ", replay.i, #steps)

	if not findEntities() then status = "Reading game towers…" return end
	if s.t == "place" then
		local t = stepTower(s)
		if not t then nextStep() return end
		local id = t.id
		local cost = costs(t)[1] or 0
		if not canPlace(cost) then status = prefix .. "3 ghosts pending, waiting" return end
		status = prefix .. "placing " .. unitName(t)
		local beforeCount, beforeTowers, i = countPlaced(id), myTowers(), replay.i
		local pos = Vector3.new(s.pos[1], s.pos[2], s.pos[3])
		if occupied(pos) then

			local free
			for r = 4, 12, 4 do
				for a = 0, 315, 45 do
					local p = floorAt(pos + Vector3.new(math.cos(math.rad(a)) * r, 0, math.sin(math.rad(a)) * r))
					if p and not isBad(p) and not occupied(p) then free = p break end
				end
				if free then break end
			end
			if not free then failed() return end
			pos = free
		end
		Net.PlayerPlaceTower:FireServer(id, pos, s.rot or 0)
		if waitCountUp(id, beforeCount, 1.5) then
			task.spawn(function()
				local eid = waitNewTower(id, beforeTowers, 300)
				if eid then replay.ents[i] = eid end
			end)
			nextStep()
		else
			failed()
		end
	elseif s.t == "sell" then
		local eid = replay.ents[s.ref]
		if eid and myTowers()[eid] then Net.PlayerSellTower:FireServer(eid) end
		nextStep()
	else
		nextStep()
	end
end

local CARD_WORST = { "UselessArtifacts", "UselessTraits", "ElementalShield", "ShieldHealth", "Shielded", "TowerDegrading" }
local CARD_DEFAULT_ORDER = {
	"BleedingImmunity", "PoisonImmunity", "BurningImmunity", "SlowImmunity", "TimestopImmunity",
	"NoRefunds", "NoSelling", "UselessFarms",
	"Healer", "Tank", "EnemySpawnCount", "Explosive",
	"Stealth", "EnemySpeed", "EnemyHealth", "DoubleBosses",
	"TowerRange", "TowerDamage", "DoubleTowerCosts", "SinglePlacement",
	table.unpack(CARD_WORST),
}
local CARD_TOKENS = { Immunity = 15, Gameplay = 10, Special = 10, Enemy = 7, Repeatable = 4 }

local function cardInfo(id)
	return gameCall(function()
		local d = G.Item.Challenges[id]
		return { title = d.title, category = d.category, text = d.subText }
	end) or { title = id, category = "?", text = "" }
end

local function cardOrder()
	local order, seen = {}, {}
	local source = #cfg.cardOrder > 0 and cfg.cardOrder or CARD_DEFAULT_ORDER
	for _, id in ipairs(source) do
		if not seen[id] and RS.Modules.Item.Challenges:FindFirstChild(id) then table.insert(order, id) seen[id] = true end
	end

	for _, c in ipairs(RS.Modules.Item.Challenges:GetChildren()) do
		if not seen[c.Name] then table.insert(order, math.max(1, #order - #CARD_WORST + 1), c.Name) seen[c.Name] = true end
	end
	return order
end

local function pickCard(set)
	local rank = {}
	for i, id in ipairs(cardOrder()) do rank[id] = i end
	local bestI
	for i, id in ipairs(set) do
		if not bestI or (rank[id] or 999) < (rank[set[bestI]] or 999) then bestI = i end
	end
	return bestI
end

local function onCardVote(set)
	fixIdentity()
	if not alive or not cfg.enabled or not cfg.autoCards or type(set) ~= "table" or #set == 0 then return end
	local i = pickCard(set)
	local info = cardInfo(set[i])
	task.wait(1.5)
	fire("PlayerVoteForChallenge", i)
	notify("Card picked", tostring(info.title))
end

gameCall(function()
	G.OnNetworkEvent("ServerStartChallengeVote", function(set)
		task.spawn(onCardVote, set)
	end)
end)

local SHENRON_RANGE = 50

local function placeAt(t, spots)
	for _, pos in ipairs(spots) do
		if not occupied(pos) then
			local before = countPlaced(t.id)
			Net.PlayerPlaceTower:FireServer(t.id, pos, 0)
			if waitCountUp(t.id, before, 1.5) then return true end
		end
	end
	return false
end

local function validSpots()
	local out = {}
	for _, raw in ipairs(pathSpots()) do
		local pos = floorAt(raw)
		if pos and not isBad(pos) then table.insert(out, pos) end
	end
	return out
end

local function dragonTick()
	local golden, shenron
	for _, t in pairs(equipped()) do
		local name = tostring(gameCall(function() return t.Name end))
		if name == "GoldenDrago" then golden = t elseif tostring(t.id):find("Shenron") then shenron = t end
	end
	if cfg.autoShenron and shenron and countPlaced(shenron.id) == 0 and cash() >= (costs(shenron)[1] or 250000) then
		local mine = {}
		for _, e in pairs(myTowers()) do
			if typeof(e.placementPoint) == "CFrame" then table.insert(mine, e.placementPoint.Position) end
		end
		local spots, score = validSpots(), {}
		for _, pos in ipairs(spots) do
			local n = 0
			for _, p in ipairs(mine) do if ((p - pos) * Vector3.new(1, 0, 1)).Magnitude <= SHENRON_RANGE then n += 1 end end
			score[pos] = n
		end
		table.sort(spots, function(a, b) return score[a] > score[b] end)
		if placeAt(shenron, { spots[1], spots[2], spots[3], spots[4], spots[5] }) then
			notify("Shen Long", string.format("+200%% damage to %d towers", score[spots[1]] or 0))
		end
	end
end

local abilityTries, lastAbilityCheck = {}, 0
local function abilityTick()
	if not cfg.autoAbility or os.clock() - lastAbilityCheck < 2 then return end
	lastAbilityCheck = os.clock()
	for eid, e in pairs(myTowers()) do
		local tries = abilityTries[eid]
		if not tries or tries.level ~= e.level then
			tries = { n = 0, level = e.level }
			abilityTries[eid] = tries
		end
		if e.autoAbility == false and tries.n < 3 then
			tries.n += 1
			fire("PlayerToggleAutoAbility", e.entityId or tonumber(eid) or eid)
		end
	end
end

local BOUNTY_NAMES = { "Easy", "Hard", "Extreme" }
local lastBountyTry = 0
local function selectedBounty() return gameCall(function() return G.data.selectedBounty end) or 0 end
local function bountyInfo(i) return gameCall(function() return G.data.bountiesFinished[tostring(i)] end) end
local function bountyActive() return cfg.autoBounty and selectedBounty() > 0 end

local function onBountyMap()
	local sel = selectedBounty()
	if sel == 0 then return false end
	return gameCall(function() return G.BountyManager:GetBounty(sel).mapId == G.data.selectedMapId end) == true
end

local function claimBounty()
	local sel = selectedBounty()
	local info = sel > 0 and bountyInfo(sel)
	if info and info.canClaim then
		fire("ClaimBountyQuestReward")
		notify("Bounty", BOUNTY_NAMES[sel] .. " reward claimed")
		task.wait(3)
		return true
	end
end

local function freeTeleporter()
	local folder = workspace.Lobby:FindFirstChild("ClassicPartyTeleporters")
	if not folder then return end
	for _, t in ipairs(folder:GetChildren()) do
		local players = 0
		gameCall(function()
			for uid in G.root.teleporters[t.Name].playerList:Pairs() do
				if tostring(uid) ~= tostring(lp.UserId) then players += 1 end
			end
		end)
		if t:GetAttribute("originalName") == "Teleporter" and players == 0 then return t:FindFirstChild("hitbox", true) end
	end
end

local function bountyLobbyTick()
	if claimBounty() then return end
	local sel = selectedBounty()
	if sel == 0 then
		for i = 3, 1, -1 do
			local info = bountyInfo(i)
			if info and not info.hasFinished then
				status = "Bounty: taking " .. BOUNTY_NAMES[i]
				fire("PlayerRequestSelectBounty", i)
				task.wait(3)
				return
			end
		end
		status = "Today's bounties done ✔"
		return
	end
	local b = gameCall(function() return G.BountyManager:GetBounty(sel) end)
	if not b then return end
	status = string.format("Bounty %s: %s (Hard, 30 waves)", BOUNTY_NAMES[sel], tostring(b.mapId))
	if os.clock() - lastBountyTry < 30 then return end
	lastBountyTry = os.clock()
	local hrp = lp.Character and lp.Character:FindFirstChild("HumanoidRootPart")
	local pad = freeTeleporter()
	if not (hrp and pad) then status = "Bounty: no free teleporter" return end
	hrp.CFrame = pad.CFrame + Vector3.new(0, 3, 0)
	task.wait(2)
	fire("PlayerSelectedStage", "Casual")
	task.wait(0.4)
	fire("PlayerSelectedMap", b.mapId)
	task.wait(0.4)
	fire("PlayerSelectedDifficulty", "HardDifficulty")
	task.wait(0.4)
	fire("PlayerSelectedWaveCount", 30)
	task.wait(0.6)

	if hrp.Parent then hrp.CFrame = pad.CFrame + Vector3.new(0, 3, 0) end
	fire("PlayerQuickstartTeleport")
	notify("Bounty " .. BOUNTY_NAMES[sel], tostring(b.mapId) .. " · Hard · 30 waves")
end

local function dragoAutoTick()
	if not cfg.autoGolden then return end
	local hotbar = gameCall(function() return G.mainGui.HUD.Toolbox.Hotbar end)
	for _, slot in ipairs(hotbar and hotbar:GetChildren() or {}) do
		local b = slot:FindFirstChild("Button") and slot.Button:FindFirstChild("ToggleAuto")
		local bg = b and b.Visible and b:FindFirstChild("Background")
		if bg and bg.BackgroundColor3.G < 0.5 then
			for _, c in ipairs(getconnections(b.Activated)) do
				local f = c.Function
				if f and tostring(debug.getinfo(f).source):find("ClientTowerManager") then gameCall(f) end
			end
		end
	end
end

local lastSpeedTry = 0
local function speedTick()
	if os.clock() - lastSpeedTry < 5 then return end
	local want = gameCall(function() return G.Item.Gamepass.GameSpeed3x:IsOwnedBy(G.player) end) and 2 or 1.5
	if gameCall(function() return G.root.gameSpeedMultiplier end) ~= want then
		lastSpeedTry = os.clock()
		fire("ClientRequestGameSpeed", tostring(want))
	end
end

local ended = false
local lastFloor
local END_VOTES = { replay = "PlayerVoteReplay", next = "PlayerVoteNext", lobby = "PlayerVoteReturn" }
local END_NAMES = { replay = "Replay", next = "Next", none = "nothing", lobby = "return to lobby" }
local endVoteAt, endStart, gameoverVotes = 0, 0, nil

gameCall(function() G.OnNetworkEvent("GameoverVote", function(votes) gameoverVotes = votes end) end)
local function myEndVote()
	if type(gameoverVotes) ~= "table" then return false end
	for _, voters in pairs(gameoverVotes) do
		if type(voters) == "table" then
			for k, v in pairs(voters) do
				if v == lp or k == lp or v == lp.UserId or k == lp.UserId or tostring(v) == tostring(lp.UserId) or tostring(k) == tostring(lp.UserId) then return true end
			end
		end
	end
	return false
end

local function replaysExhausted()
	return gameCall(function()
		if G.gamemode == "InfiniteTower" or G.isDungeon or G.Item.Gamemode.Classic:HasUnlimitedReplays() then return false end
		return (G.root.serverData.replayTimes or 0) >= 4
	end) == true
end

local function step()
	if not cfg.enabled then status = "Paused" return end
	if not inMatch() then
		if cfg.autoBounty then bountyLobbyTick()
		elseif claimBounty() then return
		elseif cfg.halloween then halloweenTick()
		else status = "In lobby: join a match" end
		return
	end
	if G.gamemode == "InfiniteTower" and not cfg.infTower then status = "Infinite Tower: enable it in Main" return end
	if G.gamemode ~= "Battlemode" then speedTick() end
	dragoAutoTick()

	local floor = gameCall(function() return G.root.currentFloor end)
	if floor ~= lastFloor then
		if lastFloor then
			bad, noSpot, abilityTries = {}, {}, {}
			replay = { i = 1, ents = {}, tries = 0 }
		end
		lastFloor = floor
	end

	if recording and mapKey() ~= recKey then stopRecording() end
	if isGameOver() then
		stopRecording()

		local action = (bountyActive() or onBountyMap()) and "lobby" or cfg.endAction

		local roundOver = gameCall(function() return G.mainGui.MainFrames.RoundOver end)
		if action == "next" and roundOver and roundOver.Visible and not (roundOver:FindFirstChild("Next") and roundOver.Next.Visible) then
			action = "replay"
		end
		if action == "replay" and replaysExhausted() then action = "lobby" end
		if not ended then
			ended, endVoteAt, endStart, gameoverVotes = true, os.clock() + 1, os.clock(), nil
			cfg.stats.matches += 1
			if gameCall(function() return G.root.roundStats.health > 0 end) then cfg.stats.wins += 1 end
			save()
		end

		if END_VOTES[action] and os.clock() >= endVoteAt and not myEndVote()
			and (roundOver == nil or roundOver.Visible or os.clock() - endStart > 10) then
			fire(END_VOTES[action])
			notify("Match over", "Voted: " .. END_NAMES[action])
			endVoteAt = os.clock() + 5
		end
		status = "Match over → " .. END_NAMES[action]
		return
	end
	if ended then

		ended = false
		bad, noSpot, abilityTries = {}, {}, {}
		replay = { i = 1, ents = {}, tries = 0 }
	end

	local recordUnknown = cfg.unknownMap == "record" and not bountyActive()
	if cfg.mode == "recorded" and recordUnknown and not recording and not cfg.recordings[mapKey()]
		and (not gameStarted() or wave() <= 1) then
		startRecording()
	end
	if not gameStarted() then
		status = recording and string.format("⏺ Recording (before start)… %d steps", #recSteps) or "Waiting for start"

		if cfg.autoStart then fire("PlayerVoteToStartMatch", gameCall(function() return G.root.matchStartVoteId end)) task.wait(2) end
		return
	end
	abilityTick()
	if recording then
		status = string.format("⏺ Recording… %d steps", #recSteps)
	elseif cfg.mode == "recorded" and cfg.recordings[mapKey()] then
		local rec = cfg.recordings[mapKey()]
		replayTick()
		if replay.i > #rec then dragonTick() end
	elseif cfg.mode == "recorded" and recordUnknown then
		status = "Map not recorded: will record next match"
	elseif not (cfg.autoPlace and placeTick()) then
		status = "Everything placed ✔"
		dragonTick()
	end
end

local queue = queue_on_teleport or (syn and syn.queue_on_teleport)

if queue and not getgenv().TD_QUEUED then
	getgenv().TD_QUEUED = true

	pcall(queue, 'if isfile("td_macro.lua") then loadstring(readfile("td_macro.lua"))() else loadstring(game:HttpGet("https://raw.githubusercontent.com/mechupacristopher-creator/lua/main/UTD/eze_hub_utd.lua"))() end')
end

local C = {
	panel = Color3.fromRGB(24, 24, 26), bg = Color3.fromRGB(32, 32, 35), side = Color3.fromRGB(20, 20, 22), card = Color3.fromRGB(40, 40, 44),
	hover = Color3.fromRGB(46, 46, 51), line = Color3.fromRGB(52, 52, 58),
	text = Color3.fromRGB(236, 236, 240), sub = Color3.fromRGB(150, 150, 158), mute = Color3.fromRGB(100, 100, 108),
	accent = Color3.fromRGB(78, 78, 86), accent2 = Color3.fromRGB(255, 255, 255),
	on = Color3.fromRGB(80, 200, 120), off = Color3.fromRGB(52, 52, 58), red = Color3.fromRGB(200, 60, 70), gold = Color3.fromRGB(240, 190, 80),
}
local FONT, BOLD, BLACK = Enum.Font.Gotham, Enum.Font.GothamBold, Enum.Font.GothamBlack

local function new(class, props, parent)
	local o = Instance.new(class)
	for k, v in pairs(props) do o[k] = v end
	o.Parent = parent
	return o
end
local function round(o, r) new("UICorner", { CornerRadius = UDim.new(0, r or 8) }, o) end
local function outline(o, color) return new("UIStroke", { Color = color or C.line, Thickness = 1, ApplyStrokeMode = Enum.ApplyStrokeMode.Border }, o) end
local function pad(o, px) new("UIPadding", { PaddingLeft = UDim.new(0, px), PaddingRight = UDim.new(0, px), PaddingTop = UDim.new(0, px), PaddingBottom = UDim.new(0, px) }, o) end
local function list(o, gap) return new("UIListLayout", { Padding = UDim.new(0, gap or 6), SortOrder = Enum.SortOrder.LayoutOrder }, o) end
local function tween(o, p, t) TweenService:Create(o, TweenInfo.new(t or 0.16, Enum.EasingStyle.Quad), p):Play() end
local function text(parent, props)
	local base = { BackgroundTransparency = 1, TextColor3 = C.text, Font = FONT, TextSize = 13, TextXAlignment = Enum.TextXAlignment.Left, TextYAlignment = Enum.TextYAlignment.Center }
	for k, v in pairs(props) do base[k] = v end
	return new("TextLabel", base, parent)
end
local function hoverable(btn, normal)
	bind(btn.MouseEnter:Connect(function() tween(btn, { BackgroundColor3 = C.hover }) end))
	bind(btn.MouseLeave:Connect(function() tween(btn, { BackgroundColor3 = normal }) end))
end

local screen = new("ScreenGui", { Name = "TDMacro", ResetOnSpawn = false, ZIndexBehavior = Enum.ZIndexBehavior.Sibling, IgnoreGuiInset = true }, (gethui and gethui()) or game:GetService("CoreGui"))

local W, H, SIDE, TOP = 560, 370, 150, 44
local shadow = new("Frame", { Size = UDim2.fromOffset(W + 16, H + 16), Position = UDim2.new(0.5, -W / 2 - 8, 0.5, -H / 2 - 8), BackgroundColor3 = Color3.new(0, 0, 0), BackgroundTransparency = 0.55 }, screen)
round(shadow, 16)
local win = new("Frame", { Size = UDim2.fromOffset(W, H), Position = UDim2.fromOffset(8, 8), BackgroundColor3 = C.panel, ClipsDescendants = true }, shadow)
round(win, 8) outline(win)

local top = new("Frame", { Size = UDim2.new(1, 0, 0, TOP), BackgroundColor3 = C.side, BorderSizePixel = 0 }, win)
new("Frame", { Size = UDim2.new(1, 0, 0, 1), Position = UDim2.new(0, 0, 1, -1), BackgroundColor3 = C.line, BorderSizePixel = 0 }, top)
local titleL = text(top, { Size = UDim2.new(0, 0, 1, 0), AutomaticSize = Enum.AutomaticSize.X, Position = UDim2.fromOffset(16, 0), Text = "Eze Hub", Font = BOLD, TextSize = 16 })
local subtitle = text(top, { Size = UDim2.new(0, 260, 1, 0), Position = UDim2.fromOffset(110, 1), Text = "", TextSize = 11, TextColor3 = C.mute })
task.defer(function() subtitle.Position = UDim2.fromOffset(16 + titleL.AbsoluteSize.X + 10, 1) end)

local function topButton(x, glyph)
	local b = new("TextButton", { Size = UDim2.fromOffset(26, 26), Position = UDim2.new(1, x, 0.5, -13), BackgroundColor3 = C.bg, Text = glyph, Font = BOLD, TextSize = 14, TextColor3 = C.sub, AutoButtonColor = false }, top)
	round(b, 5) outline(b)
	hoverable(b, C.bg)
	return b
end
local closeBtn = topButton(-36, "×")
local minBtn = topButton(-68, "–")

do
	local dragging, startPos, startMouse
	bind(top.InputBegan:Connect(function(i)
		if i.UserInputType == Enum.UserInputType.MouseButton1 or i.UserInputType == Enum.UserInputType.Touch then
			dragging, startPos, startMouse = true, shadow.Position, i.Position
		end
	end))
	bind(UIS.InputChanged:Connect(function(i)
		if dragging and (i.UserInputType == Enum.UserInputType.MouseMovement or i.UserInputType == Enum.UserInputType.Touch) then
			local d = i.Position - startMouse
			shadow.Position = UDim2.new(startPos.X.Scale, startPos.X.Offset + d.X, startPos.Y.Scale, startPos.Y.Offset + d.Y)
		end
	end))
	bind(UIS.InputEnded:Connect(function(i)
		if i.UserInputType == Enum.UserInputType.MouseButton1 or i.UserInputType == Enum.UserInputType.Touch then dragging = false end
	end))
end

cfg.uiScale = cfg.uiScale or ((UIS.TouchEnabled and not UIS.KeyboardEnabled) and 0.7 or 1)
local uiScale = new("UIScale", { Scale = cfg.uiScale }, shadow)
local function renderMin(animate)
	local h = cfg.minimized and TOP or H
	if animate then
		tween(win, { Size = UDim2.fromOffset(W, h) })
		tween(shadow, { Size = UDim2.fromOffset(W + 16, h + 16) })
	else
		win.Size, shadow.Size = UDim2.fromOffset(W, h), UDim2.fromOffset(W + 16, h + 16)
	end
end
renderMin(false)
bind(minBtn.Activated:Connect(function()
	cfg.minimized = not cfg.minimized
	save()
	renderMin(true)
end))
bind(UIS.InputBegan:Connect(function(i, gp)
	if not gp and i.KeyCode == Enum.KeyCode.RightShift then shadow.Visible = not shadow.Visible end
end))

local side = new("Frame", { Size = UDim2.new(0, SIDE, 1, -TOP), Position = UDim2.fromOffset(0, TOP), BackgroundColor3 = C.side, BorderSizePixel = 0 }, win)
new("Frame", { Size = UDim2.new(0, 1, 1, 0), Position = UDim2.new(1, -1, 0, 0), BackgroundColor3 = C.line, BorderSizePixel = 0 }, side)
local tabList = new("Frame", { Size = UDim2.new(1, -16, 1, -70), Position = UDim2.fromOffset(8, 10), BackgroundTransparency = 1 }, side)
list(tabList, 4)

local power = new("TextButton", { Size = UDim2.new(1, 0, 0, 54), Position = UDim2.new(0, 0, 1, -54), BackgroundColor3 = C.side, Text = "", AutoButtonColor = false }, side)
new("Frame", { Size = UDim2.new(1, 0, 0, 1), BackgroundColor3 = C.line, BorderSizePixel = 0 }, power)
local avatar = new("ImageLabel", { Size = UDim2.fromOffset(32, 32), Position = UDim2.fromOffset(10, 11), BackgroundColor3 = C.card, Image = "" }, power)
round(avatar, 16)
task.spawn(function()
	local ok, img = pcall(Players.GetUserThumbnailAsync, Players, lp.UserId, Enum.ThumbnailType.HeadShot, Enum.ThumbnailSize.Size48x48)
	if ok then avatar.Image = img end
end)
local powerDot = new("Frame", { Size = UDim2.fromOffset(10, 10), Position = UDim2.fromOffset(34, 33), BackgroundColor3 = C.on }, power)
round(powerDot, 5)
new("UIStroke", { Color = C.side, Thickness = 2 }, powerDot)
text(power, { Size = UDim2.new(1, -54, 0, 15), Position = UDim2.fromOffset(50, 11), Text = lp.DisplayName, Font = BOLD, TextSize = 12, TextTruncate = Enum.TextTruncate.AtEnd })
local powerText = text(power, { Size = UDim2.new(1, -54, 0, 13), Position = UDim2.fromOffset(50, 27), Text = "Macro running", TextSize = 10, TextColor3 = C.mute })
local function renderPower()
	tween(powerDot, { BackgroundColor3 = cfg.enabled and C.on or C.red })
	powerText.Text = cfg.enabled and "Running · click to pause" or "Paused · click to resume"
end
bind(power.Activated:Connect(function()
	cfg.enabled = not cfg.enabled
	save() renderPower()
	notify(cfg.enabled and "Macro resumed" or "Macro paused", "")
end))
renderPower()

local pages, tabs = {}, {}
local function selectTab(name)
	for n, t in pairs(tabs) do
		local active = n == name
		pages[n].Visible = active
		tween(t.btn, { BackgroundColor3 = active and C.bg or C.side })
		tween(t.label, { TextColor3 = active and C.text or C.sub })
		tween(t.icon, { TextColor3 = active and C.text or C.mute })
		t.icon.Text = active and "◉" or "○"
	end
end
local function addTab(name, _, order)
	local btn = new("TextButton", { Size = UDim2.new(1, 0, 0, 30), BackgroundColor3 = C.side, Text = "", AutoButtonColor = false, LayoutOrder = order }, tabList)
	round(btn, 6)
	local ic = text(btn, { Size = UDim2.fromOffset(16, 30), Position = UDim2.fromOffset(8, 0), Text = "○", TextSize = 13, Font = BOLD, TextXAlignment = Enum.TextXAlignment.Center, TextColor3 = C.mute })
	local lb = text(btn, { Size = UDim2.new(1, -36, 1, 0), Position = UDim2.fromOffset(30, 0), Text = name, Font = BOLD, TextSize = 13, TextColor3 = C.sub })
	local page = new("ScrollingFrame", { Size = UDim2.new(1, -SIDE, 1, -TOP), Position = UDim2.fromOffset(SIDE, TOP), BackgroundTransparency = 1, BorderSizePixel = 0, ScrollBarThickness = 3, ScrollBarImageColor3 = C.line, AutomaticCanvasSize = Enum.AutomaticSize.Y, CanvasSize = UDim2.new(), Visible = false }, win)
	pad(page, 10)
	list(page, 10)
	pages[name], tabs[name] = page, { btn = btn, label = lb, icon = ic }
	bind(btn.Activated:Connect(function() selectTab(name) end))
	bind(btn.MouseEnter:Connect(function() if not pages[name].Visible then tween(btn, { BackgroundColor3 = C.hover }) end end))
	bind(btn.MouseLeave:Connect(function() if not pages[name].Visible then tween(btn, { BackgroundColor3 = C.side }) end end))
	return page
end

local function section(page, title, order)

	local card = new("Frame", { Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y, BackgroundTransparency = 1, LayoutOrder = order or 0 }, page)
	list(card, 6)
	if title then text(card, { Size = UDim2.new(1, 0, 0, 16), Text = string.upper(title), Font = BOLD, TextSize = 11, TextColor3 = C.sub, LayoutOrder = -1 }) end
	return card
end

local function hint(parent, str)
	return text(parent, { Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y, Text = str, TextSize = 11, TextColor3 = C.sub, TextWrapped = true })
end

local function toggle(parent, title, desc, key, onChange)
	local row = new("TextButton", { Size = UDim2.new(1, 0, 0, desc and 44 or 34), BackgroundColor3 = C.bg, Text = "", AutoButtonColor = false }, parent)
	round(row, 6) outline(row) hoverable(row, C.bg)
	text(row, { Size = UDim2.new(1, -52, 0, 16), Position = UDim2.fromOffset(10, desc and 6 or 9), Text = title, Font = BOLD, TextSize = 13 })
	if desc then text(row, { Size = UDim2.new(1, -52, 0, 14), Position = UDim2.fromOffset(10, 23), Text = desc, TextSize = 11, TextColor3 = C.sub, TextTruncate = Enum.TextTruncate.AtEnd }) end
	local box = new("TextLabel", { Size = UDim2.fromOffset(20, 20), Position = UDim2.new(1, -30, 0.5, -10), BackgroundColor3 = C.off, Text = "", Font = BOLD, TextSize = 13, TextColor3 = C.panel }, row)
	round(box, 4)
	local function render()
		tween(box, { BackgroundColor3 = cfg[key] and C.text or C.off })
		box.Text = cfg[key] and "✓" or ""
	end
	bind(row.Activated:Connect(function() cfg[key] = not cfg[key] save() render() if onChange then onChange() end end))
	render()
end

local function segmented(parent, title, desc, key, options, onChange)
	local holder = new("Frame", { Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y, BackgroundTransparency = 1 }, parent)
	list(holder, 6)
	text(holder, { Size = UDim2.new(1, 0, 0, 16), Text = title, Font = BOLD, TextSize = 13 })
	if desc then hint(holder, desc) end
	local bar = new("Frame", { Size = UDim2.new(1, 0, 0, 30), BackgroundColor3 = C.bg }, holder)
	round(bar, 8) outline(bar)
	local btns = {}
	local function render()
		for k, b in pairs(btns) do
			local active = cfg[key] == k
			tween(b, { BackgroundTransparency = active and 0 or 1, TextColor3 = active and Color3.new(1, 1, 1) or C.sub })
		end
	end
	for i, opt in ipairs(options) do
		local b = new("TextButton", { Size = UDim2.new(1 / #options, -4, 1, -4), Position = UDim2.new((i - 1) / #options, 2, 0, 2), Text = opt[2], Font = BOLD, TextSize = 12, BackgroundColor3 = C.accent, BackgroundTransparency = 1, TextColor3 = C.sub, AutoButtonColor = false }, bar)
		round(b, 6)
		btns[opt[1]] = b
		bind(b.Activated:Connect(function() cfg[key] = opt[1] save() render() if onChange then onChange() end end))
	end
	render()
end

local function button(parent, label, style, cb)
	local colors = { primary = C.accent, danger = C.red, normal = C.hover }
	local color = colors[style or "normal"]
	local b = new("TextButton", { Size = UDim2.new(1, 0, 0, 32), BackgroundColor3 = color, Text = label, Font = BOLD, TextSize = 13, TextColor3 = Color3.new(1, 1, 1), AutoButtonColor = false }, parent)
	round(b, 8)
	bind(b.MouseEnter:Connect(function() tween(b, { BackgroundColor3 = color:Lerp(Color3.new(1, 1, 1), 0.12) }) end))
	bind(b.MouseLeave:Connect(function() tween(b, { BackgroundColor3 = color }) end))
	bind(b.Activated:Connect(cb))
	return b, function(newColor)
		if newColor ~= color then color = newColor b.BackgroundColor3 = newColor end
	end
end

local function infoRow(parent, label)
	local row = new("Frame", { Size = UDim2.new(1, 0, 0, 20), BackgroundTransparency = 1 }, parent)
	text(row, { Size = UDim2.new(0.5, 0, 1, 0), Text = label, TextSize = 12, TextColor3 = C.sub })
	return text(row, { Size = UDim2.new(0.5, 0, 1, 0), Position = UDim2.fromScale(0.5, 0), Text = "—", Font = BOLD, TextSize = 12, TextXAlignment = Enum.TextXAlignment.Right })
end

local toastHolder = new("Frame", { Size = UDim2.fromOffset(260, 400), Position = UDim2.new(1, -272, 1, -412), BackgroundTransparency = 1 }, screen)
new("UIListLayout", { Padding = UDim.new(0, 6), VerticalAlignment = Enum.VerticalAlignment.Bottom, SortOrder = Enum.SortOrder.LayoutOrder }, toastHolder)
notify = function(title, body)
	task.spawn(function()
		local t = new("Frame", { Size = UDim2.new(1, 0, 0, 52), BackgroundColor3 = C.card, BackgroundTransparency = 1 }, toastHolder)
		round(t, 10)
		local st = outline(t)
		st.Transparency = 1
		local accentBar = new("Frame", { Size = UDim2.new(0, 3, 1, -16), Position = UDim2.fromOffset(8, 8), BackgroundColor3 = C.accent, BackgroundTransparency = 1 }, t)
		round(accentBar, 2)
		local tl = text(t, { Size = UDim2.new(1, -28, 0, 16), Position = UDim2.fromOffset(20, 9), Text = title, Font = BOLD, TextTransparency = 1 })
		local bl = text(t, { Size = UDim2.new(1, -28, 0, 14), Position = UDim2.fromOffset(20, 28), Text = body or "", TextSize = 11, TextColor3 = C.sub, TextTransparency = 1, TextTruncate = Enum.TextTruncate.AtEnd })
		local function fade(v, time)
			tween(t, { BackgroundTransparency = v }, time) tween(st, { Transparency = v }, time)
			tween(accentBar, { BackgroundTransparency = v }, time) tween(tl, { TextTransparency = v }, time) tween(bl, { TextTransparency = v }, time)
		end
		fade(0, 0.2)
		task.wait(3.5)
		fade(1, 0.3)
		task.wait(0.35)
		t:Destroy()
	end)
end

local panel = addTab("Main", "◉", 1)
local statusDot, statusLabel
do
	local card = section(panel, nil, 1)
	local line = new("Frame", { Size = UDim2.new(1, 0, 0, 34), BackgroundColor3 = C.bg }, card)
	round(line, 6) outline(line)
	statusDot = new("Frame", { Size = UDim2.fromOffset(8, 8), Position = UDim2.fromOffset(12, 13), BackgroundColor3 = C.on }, line)
	round(statusDot, 4)
	statusLabel = text(line, { Size = UDim2.new(1, -38, 1, 0), Position = UDim2.fromOffset(28, 0), Text = "", Font = BOLD, TextTruncate = Enum.TextTruncate.AtEnd })
end
local tiles = {}
do
	local grid = new("Frame", { Size = UDim2.new(1, 0, 0, 58), BackgroundTransparency = 1, LayoutOrder = 2 }, panel)
	new("UIGridLayout", { CellSize = UDim2.new(0.25, -6, 1, 0), CellPadding = UDim2.fromOffset(8, 0), SortOrder = Enum.SortOrder.LayoutOrder }, grid)
	for i, def in ipairs({ { "wave", "WAVE", C.text }, { "cash", "CASH", C.on }, { "towers", "TOWERS", C.accent2 }, { "wins", "WINS", C.gold } }) do
		local tile = new("Frame", { BackgroundColor3 = C.card, LayoutOrder = i }, grid)
		round(tile, 10) outline(tile)
		text(tile, { Size = UDim2.new(1, -16, 0, 14), Position = UDim2.fromOffset(8, 8), Text = def[2], Font = BOLD, TextSize = 10, TextColor3 = C.mute })
		tiles[def[1]] = text(tile, { Size = UDim2.new(1, -16, 0, 22), Position = UDim2.fromOffset(8, 26), Text = "0", Font = BLACK, TextSize = 18, TextColor3 = def[3], TextTruncate = Enum.TextTruncate.AtEnd })
	end
end
do
	local card = section(panel, "Macro", 3)
	segmented(card, "Mode", "Auto: the macro picks spots. Recorded: replays what you recorded on this map.", "mode",
		{ { "auto", "🤖  Auto" }, { "recorded", "🎬  Recorded" } }, function() notify("Mode", cfg.mode == "auto" and "Auto" or "Recorded") end)
	segmented(card, "Unrecorded map", "In Recorded mode, what to do if this map has no recording yet.", "unknownMap",
		{ { "auto", "🤖  Auto" }, { "record", "⏺  Record it myself" } })
	segmented(card, "When the match ends", nil, "endAction", { { "replay", "🔁  Replay" }, { "next", "⏭  Next" }, { "none", "✋  Nothing" } })
	toggle(card, "Auto Start Match", "Votes to start the match automatically", "autoStart")
	toggle(card, "Auto Bounty", "Takes the hardest bounty, plays its map on Hard 30 waves, returns and claims it", "autoBounty")
	toggle(card, "Infinite Tower", "Also play Infinite Tower: reads each floor's spawn and places from the start", "infTower")
	toggle(card, "Auto fish (lobby)", "Perfect catch every 5 s until the daily limit", "autoFish")
end

local unitsPage = addTab("Units", "▦", 2)
local unitRows = {}
local function buildUnits()
	for _, c in ipairs(unitsPage:GetChildren()) do if c:IsA("GuiObject") then c:Destroy() end end
	unitRows = {}
	local autoCard = section(unitsPage, "Auto mode", 1)
	toggle(autoCard, "Auto place", "Places next to the path; uses ghosts when short on cash", "autoPlace")
	toggle(autoCard, "Auto dragons", "Turns on the game's auto button (⟳) on every dragon: they re-summon when the effect ends", "autoGolden")
	toggle(autoCard, "Auto Shen Long", "At 250k, places it where it covers most of your towers (+200% dmg)", "autoShenron")
	toggle(autoCard, "Auto ability", "Turns on auto ability for every tower that has one", "autoAbility")
	local card = section(unitsPage, "Equipped units", 2)
	hint(card, "The $" .. cfg.firstUnitCost .. " unit goes first, then cheapest to most expensive.")
	for _, t in ipairs(equipped()) do
		local u, limit = unitCfg(t), limitOf(t)
		local row = new("Frame", { Size = UDim2.new(1, 0, 0, 38), BackgroundColor3 = C.bg }, card)
		round(row, 8) outline(row)
		local check = new("TextButton", { Size = UDim2.fromOffset(20, 20), Position = UDim2.fromOffset(9, 9), Text = "", Font = BOLD, TextSize = 12, TextColor3 = Color3.new(1, 1, 1), AutoButtonColor = false }, row)
		round(check, 6)
		text(row, { Size = UDim2.new(1, -150, 0, 16), Position = UDim2.fromOffset(38, 4), Text = unitName(t) .. (isDragon(t) and "  🐉" or ""), Font = BOLD, TextSize = 12, TextTruncate = Enum.TextTruncate.AtEnd })
		text(row, { Size = UDim2.new(1, -150, 0, 14), Position = UDim2.fromOffset(38, 20), Text = "$" .. tostring(costs(t)[1] or "?") .. "  ·  limit " .. limit, TextSize = 11, TextColor3 = C.sub })
		local stepper = new("Frame", { Size = UDim2.fromOffset(98, 24), Position = UDim2.new(1, -106, 0.5, -12), BackgroundColor3 = C.card }, row)
		round(stepper, 6) outline(stepper)
		local minus = new("TextButton", { Size = UDim2.fromOffset(24, 24), BackgroundTransparency = 1, Text = "−", Font = BOLD, TextSize = 14, TextColor3 = C.sub }, stepper)
		local capL = text(stepper, { Size = UDim2.new(1, -48, 1, 0), Position = UDim2.fromOffset(24, 0), Text = "", Font = BOLD, TextSize = 12, TextXAlignment = Enum.TextXAlignment.Center })
		local plus = new("TextButton", { Size = UDim2.fromOffset(24, 24), Position = UDim2.new(1, -24, 0, 0), BackgroundTransparency = 1, Text = "+", Font = BOLD, TextSize = 14, TextColor3 = C.sub }, stepper)
		local function renderCheck()
			tween(check, { BackgroundColor3 = u.on and C.accent or C.off })
			check.Text = u.on and "✓" or ""
		end
		renderCheck()
		bind(check.Activated:Connect(function() u.on = not u.on save() renderCheck() end))
		bind(minus.Activated:Connect(function() u.cap = math.max(0, math.min(u.cap, limit) - 1) save() end))
		bind(plus.Activated:Connect(function() u.cap = math.min(limit, u.cap + 1) save() end))
		unitRows[t.id] = { capL = capL, u = u, limit = limit }
	end
	button(card, "↻  Reload units", "normal", buildUnits)
end
buildUnits()

local recPage = addTab("Recording", "⏺", 3)
local recState, recMap, recCount, recBtn, setRecColor, savedList, editTitle, stepsList
local editKey
local editVersion = 0

local function recName(key, index)
	if cfg.recNames[key] and cfg.recNames[key] ~= "" then return cfg.recNames[key] end
	return (key:match("^(%a+)_") or "Classic") .. " #" .. tostring(index or "")
end

do
	local card = section(recPage, "Record macro", 1)
	hint(card, "Press Record and play: your placements and sells are saved with their exact position (the game handles upgrades). Saved to disk on every step, so it survives leaving the game.")
	recState = infoRow(card, "Status")
	recMap = infoRow(card, "Gamemode")
	recCount = infoRow(card, "Steps on this map")
	recBtn, setRecColor = button(card, "⏺  Record", "primary", function()
		if recording then stopRecording() else startRecording() end
	end)

	local savedCard = section(recPage, "Saved recordings", 2)
	hint(savedCard, "Click a name to rename it. Each map uses its own recording automatically.")
	savedList = new("Frame", { Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y, BackgroundTransparency = 1 }, savedCard)
	list(savedList, 4)

	local stepsCard = section(recPage, nil, 3)
	editTitle = text(stepsCard, { Size = UDim2.new(1, 0, 0, 16), Text = "STEPS", Font = BOLD, TextSize = 11, TextColor3 = C.sub })
	stepsList = new("Frame", { Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y, BackgroundTransparency = 1 }, stepsCard)
	list(stepsList, 2)
end

local function smallButton(parent, label, color, x, cb)
	local b = new("TextButton", { Size = UDim2.fromOffset(22, 20), Position = UDim2.new(1, x, 0.5, -10), BackgroundColor3 = color or C.card, Text = label, Font = BOLD, TextSize = 11, TextColor3 = C.text, AutoButtonColor = false }, parent)
	round(b, 5)
	hoverable(b, color or C.card)
	bind(b.Activated:Connect(cb))
	return b
end

local function deleteStep(steps, i)
	table.remove(steps, i)
	for j = #steps, 1, -1 do
		local s = steps[j]
		if s.ref == i then table.remove(steps, j) end
	end
	for _, s in ipairs(steps) do if s.ref and s.ref > i then s.ref -= 1 end end
end
local function swapSteps(steps, a, b)
	if a < 1 or b < 1 or a > #steps or b > #steps then return end
	steps[a], steps[b] = steps[b], steps[a]
	for _, s in ipairs(steps) do
		if s.ref == a then s.ref = b elseif s.ref == b then s.ref = a end
	end
end
local function edited()
	editVersion += 1
	save()
end

local savedSig
local function renderSaved()
	local keys = {}
	for k, v in pairs(cfg.recordings) do table.insert(keys, k) end
	table.sort(keys)
	local here = mapKey()
	local sig = here .. "|" .. tostring(editKey) .. "|" .. editVersion
	for _, k in ipairs(keys) do sig ..= k .. #cfg.recordings[k] .. tostring(cfg.recNames[k]) end
	if sig == savedSig then return end
	savedSig = sig
	for _, c in ipairs(savedList:GetChildren()) do if c:IsA("GuiObject") then c:Destroy() end end
	if #keys == 0 then
		text(savedList, { Size = UDim2.new(1, 0, 0, 16), Text = "No recordings yet", TextSize = 11, TextColor3 = C.mute })
		return
	end
	for i, key in ipairs(keys) do
		local isHere, isEditing = key == here, key == (editKey or here)
		local row = new("Frame", { Size = UDim2.new(1, 0, 0, 40), BackgroundColor3 = isEditing and C.hover or C.bg }, savedList)
		round(row, 8)
		local st = outline(row, isEditing and C.accent or C.line)
		st.Transparency = isEditing and 0.3 or 0
		local nameBox = new("TextBox", { Size = UDim2.new(1, -110, 0, 18), Position = UDim2.fromOffset(10, 3), BackgroundTransparency = 1, Text = recName(key, i), PlaceholderText = "Name", ClearTextOnFocus = false, Font = BOLD, TextSize = 12, TextColor3 = C.text, TextXAlignment = Enum.TextXAlignment.Left, TextTruncate = Enum.TextTruncate.AtEnd }, row)
		bind(nameBox.FocusLost:Connect(function()
			cfg.recNames[key] = nameBox.Text
			edited()
			notify("Recording renamed", nameBox.Text)
		end))
		text(row, { Size = UDim2.new(1, -110, 0, 14), Position = UDim2.fromOffset(10, 21), RichText = true, TextSize = 11, TextColor3 = C.sub,
			Text = string.format("%d steps%s", #cfg.recordings[key], isHere and "  ·  <font color='#FFFFFF'><b>this map</b></font>" or "") })
		local del = smallButton(row, "🗑", C.card, -30, function() end)
		local armed = false
		bind(del.Activated:Connect(function()
			if not armed then
				armed = true
				del.Text, del.BackgroundColor3 = "?", C.red
				task.delay(2, function() if del.Parent then armed = false del.Text, del.BackgroundColor3 = "🗑", C.card end end)
				return
			end
			cfg.recordings[key], cfg.recNames[key] = nil, nil
			if editKey == key then editKey = nil end
			edited()
			notify("Recording deleted", recName(key, i))
		end))
		local editBtn = new("TextButton", { Size = UDim2.fromOffset(60, 20), Position = UDim2.new(1, -96, 0.5, -10), BackgroundColor3 = isEditing and C.accent or C.card, Text = isEditing and "Editing" or "Edit", Font = BOLD, TextSize = 11, TextColor3 = C.text, AutoButtonColor = false }, row)
		round(editBtn, 5)
		bind(editBtn.Activated:Connect(function() editKey = key edited() end))
	end
end

local moving
local function setMoving(s)
	moving = s
	editVersion += 1
	if s then notify("Move placement", "Click on the map · right click cancels") end
end
bind(UIS.InputBegan:Connect(function(input, processed)
	if not moving or processed then return end
	if input.UserInputType == Enum.UserInputType.MouseButton2 then
		setMoving(nil)
		notify("Move placement", "Cancelled")
	elseif input.UserInputType == Enum.UserInputType.MouseButton1 then
		local m = UIS:GetMouseLocation()
		local ray = workspace.CurrentCamera:ViewportPointToRay(m.X, m.Y)
		rayParams.FilterDescendantsInstances = { workspace:FindFirstChild("EntityColliders"), workspace:FindFirstChild("EntityModels") }
		local hit = workspace:Raycast(ray.Origin, ray.Direction * 1000, rayParams)
		local pos = hit and floorAt(hit.Position)
		if not pos then notify("Move placement", "No ground there, try again") return end
		moving.pos = { pos.X, pos.Y, pos.Z }
		setMoving(nil)
		edited()
		notify("Move placement", "Position saved")
	end
end))

local stepsSig
local function renderSteps()
	local key = editKey or mapKey()
	local live = recording and key == recKey
	local steps = live and recSteps or cfg.recordings[key]
	local sig = key .. ":" .. tostring(steps and #steps) .. ":" .. replay.i .. ":" .. tostring(live) .. cfg.mode .. editVersion
	if sig == stepsSig then return end
	stepsSig = sig
	editTitle.Text = "STEPS · " .. string.upper(recName(key, "")) .. (live and "  (recording)" or "")
	for _, c in ipairs(stepsList:GetChildren()) do if c:IsA("GuiObject") then c:Destroy() end end
	if not steps or #steps == 0 then
		text(stepsList, { Size = UDim2.new(1, 0, 0, 16), Text = "No steps", TextSize = 11, TextColor3 = C.mute })
		return
	end
	for i, s in ipairs(steps) do
		if i > 60 then
			text(stepsList, { Size = UDim2.new(1, 0, 0, 16), Text = "… and " .. (#steps - 60) .. " more", TextSize = 11, TextColor3 = C.mute })
			break
		end
		local place = s.t == "place"
		local t = place and stepTower(s)
		local what = place and string.format("Slot %s · %s", tostring(s.slot or "?"), t and unitName(t) or "empty")
			or s.t == "sell" and ("Sell the one from step " .. tostring(s.ref)) or s.t
		local active = cfg.mode == "recorded" and not live and key == mapKey() and i == replay.i
		local row = new("Frame", { Size = UDim2.new(1, 0, 0, 22), BackgroundColor3 = active and C.hover or C.bg, BackgroundTransparency = active and 0 or 1 }, stepsList)
		round(row, 5)
		text(row, { Size = UDim2.new(1, live and -10 or -142, 1, 0), Position = UDim2.fromOffset(6, 0), Text = string.format("%s%d.  %s", active and "▶  " or "", i, what), TextSize = 11, TextColor3 = active and C.accent2 or C.sub, Font = active and BOLD or FONT, TextTruncate = Enum.TextTruncate.AtEnd })
		if not live and place then
			local slotBtn = smallButton(row, "S" .. tostring(s.slot or "?"), nil, -134, function()
				local slots = 0
				for k in pairs(equipped()) do slots = math.max(slots, k) end
				s.slot = (s.slot or 0) % math.max(slots, 7) + 1
				edited()
			end)
			slotBtn.Size = UDim2.fromOffset(30, 20)
			smallButton(row, "📍", moving == s and C.accent or nil, -100, function() setMoving(moving ~= s and s or nil) end)
		end
		if not live then
			smallButton(row, "↑", nil, -78, function() swapSteps(steps, i, i - 1) edited() end)
			smallButton(row, "↓", nil, -52, function() swapSteps(steps, i, i + 1) edited() end)
			smallButton(row, "✕", nil, -26, function() deleteStep(steps, i) edited() end)
		end
	end
end

local cardsPage = addTab("Cards", "🃏", 4)
do
	local card = section(cardsPage, "Dungeon cards", 1)
	toggle(card, "Auto pick cards", "In Dungeons, votes for the highest-priority card", "autoCards")
	hint(card, "Of the 3 cards offered, votes for the one highest in the list. Use ↑ ↓ to reorder.")

	local tableCard = section(cardsPage, "Priority list", 2)
	local rows = new("Frame", { Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y, BackgroundTransparency = 1 }, tableCard)
	list(rows, 3)
	local infos = {}

	local function renderTable()
		for _, c in ipairs(rows:GetChildren()) do if c:IsA("GuiObject") then c:Destroy() end end
		local order = cardOrder()
		for i, id in ipairs(order) do
			infos[id] = infos[id] or cardInfo(id)
			local info = infos[id]
			local tier = i <= 5 and C.on or i > #order - #CARD_WORST and C.red or C.mute
			local row = new("Frame", { Size = UDim2.new(1, 0, 0, 34), BackgroundColor3 = C.bg }, rows)
			round(row, 7)
			local badge = new("Frame", { Size = UDim2.fromOffset(24, 20), Position = UDim2.fromOffset(6, 7), BackgroundColor3 = tier }, row)
			round(badge, 5)
			text(badge, { Size = UDim2.fromScale(1, 1), Text = tostring(i), Font = BOLD, TextSize = 11, TextXAlignment = Enum.TextXAlignment.Center, TextColor3 = Color3.new(1, 1, 1) })
			text(row, { Size = UDim2.new(1, -96, 0, 15), Position = UDim2.fromOffset(38, 2), Text = tostring(info.title), Font = BOLD, TextSize = 12, TextTruncate = Enum.TextTruncate.AtEnd })
			text(row, { Size = UDim2.new(1, -96, 0, 13), Position = UDim2.fromOffset(38, 18), Text = string.format("%s · %d tokens", tostring(info.category), CARD_TOKENS[info.category] or 0), TextSize = 10, TextColor3 = C.sub })
			local function move(delta)
				local j = i + delta
				if j < 1 or j > #order then return end
				order[i], order[j] = order[j], order[i]
				cfg.cardOrder = order
				save()
				renderTable()
			end
			smallButton(row, "↑", nil, -54, function() move(-1) end)
			smallButton(row, "↓", nil, -28, function() move(1) end)
		end
	end
	renderTable()
	button(tableCard, "Restore default order", "normal", function()
		cfg.cardOrder = {}
		save()
		renderTable()
		notify("Cards", "Default order restored")
	end)
end

local halloweenPage = addTab("Halloween", "🎃", 5)
do
	local card = section(halloweenPage, "Farm Halloween", 1)
	toggle(card, "Farm Halloween", "In the lobby, steps into an event bubble and waits for the teleport", "halloween")
	segmented(card, "Difficulty", "Which bubbles to use.", "halloweenDiff", { { "Normal", "🎃  Normal" }, { "Hard", "💀  Hard" } })
	hint(card, "The game only allows 4 Replays per server on this map: after that the macro returns to the lobby and joins again. If no teleport in 20 s, it tries the next bubble.")
end

local settingsPage = addTab("Settings", "⚙", 6)
local runtimeL, matchesL
do
	local card = section(settingsPage, "Session", 1)
	runtimeL = infoRow(card, "Uptime")
	matchesL = infoRow(card, "Wins / matches")
	button(card, "Reset stats", "normal", function()
		cfg.stats = { matches = 0, wins = 0 }
		save()
		notify("Stats reset", "")
	end)
	local uiCard = section(settingsPage, "Interface", 2)
	do
		local row = new("Frame", { Size = UDim2.new(1, 0, 0, 34), BackgroundColor3 = C.bg }, uiCard)
		round(row, 6) outline(row)
		text(row, { Size = UDim2.new(1, -120, 1, 0), Position = UDim2.fromOffset(10, 0), Text = "UI size", Font = BOLD, TextSize = 13 })
		local stepper = new("Frame", { Size = UDim2.fromOffset(98, 24), Position = UDim2.new(1, -106, 0.5, -12), BackgroundColor3 = C.card }, row)
		round(stepper, 6) outline(stepper)
		local minus = new("TextButton", { Size = UDim2.fromOffset(24, 24), BackgroundTransparency = 1, Text = "−", Font = BOLD, TextSize = 14, TextColor3 = C.sub }, stepper)
		local valL = text(stepper, { Size = UDim2.new(1, -48, 1, 0), Position = UDim2.fromOffset(24, 0), Text = "", Font = BOLD, TextSize = 12, TextXAlignment = Enum.TextXAlignment.Center })
		local plus = new("TextButton", { Size = UDim2.fromOffset(24, 24), Position = UDim2.new(1, -24, 0, 0), BackgroundTransparency = 1, Text = "+", Font = BOLD, TextSize = 14, TextColor3 = C.sub }, stepper)
		local function setScale(s)
			cfg.uiScale = math.clamp(math.floor(s * 10 + 0.5) / 10, 0.5, 1.5)
			uiScale.Scale = cfg.uiScale
			valL.Text = math.floor(cfg.uiScale * 100 + 0.5) .. "%"
			save()
		end
		bind(minus.Activated:Connect(function() setScale((cfg.uiScale or 1) - 0.1) end))
		bind(plus.Activated:Connect(function() setScale((cfg.uiScale or 1) + 0.1) end))
		setScale(cfg.uiScale)
	end
	hint(uiCard, "Minimize (–) is remembered: after a teleport the panel comes back minimized.")
	local card2 = section(settingsPage, "Script", 3)
	hint(card2, "RightShift shows/hides the window. If Replay/Next teleports you, the macro reloads by itself.")
	button(card2, "Unload macro", "danger", function() getgenv().TD_UNLOAD() end)
end

selectTab("Main")
bind(closeBtn.Activated:Connect(function() getgenv().TD_UNLOAD() end))

local startTime = os.clock()
local function refresh()
	subtitle.Text = string.format("%s  ·  %s", tostring(G.gamemode or "Lobby"), cfg.mode == "auto" and "Auto" or "Recorded")
	statusLabel.Text = status
	statusDot.BackgroundColor3 = (not cfg.enabled or recording) and C.red or status:find("Error") and C.gold or C.on

	local n = 0
	for _ in pairs(myTowers()) do n += 1 end
	local phantoms = #myPhantoms()
	tiles.wave.Text = tostring(math.floor(wave()))
	tiles.cash.Text = "$" .. tostring(math.floor(cash()))
	tiles.towers.Text = tostring(n) .. (phantoms > 0 and (" +" .. phantoms .. "👻") or "")
	tiles.wins.Text = string.format("%d/%d", cfg.stats.wins, cfg.stats.matches)

	for id, r in pairs(unitRows) do
		r.capL.Text = string.format("%d / %d", countPlaced(id), math.min(r.u.cap, r.limit))
	end

	local rec = cfg.recordings[mapKey()]
	recState.Text = recording and "● Recording" or (cfg.mode == "recorded" and "Replaying" or "Stopped")
	recState.TextColor3 = recording and C.red or C.text
	recMap.Text = tostring(G.gamemode or "—")
	recCount.Text = recording and (#recSteps .. " (recording)") or tostring(rec and #rec or 0)
	recBtn.Text = recording and "⏹  Stop and save" or "⏺  Record"
	setRecColor(recording and C.red or C.accent)
	renderSaved()
	renderSteps()

	local t = math.floor(os.clock() - startTime)
	runtimeL.Text = string.format("%d:%02d:%02d", t // 3600, t // 60 % 60, t % 60)
	matchesL.Text = string.format("%d / %d", cfg.stats.wins, cfg.stats.matches)
end

getgenv().TD_UNLOAD = function()
	alive = false
	for _, c in ipairs(connections) do pcall(function() c:Disconnect() end) end
	pcall(function() screen:Destroy() end)
	getgenv().TD_UNLOAD = nil
end

task.spawn(function()
	while alive do
		local ok, e = pcall(refresh)
		if not ok then getgenv().TD_LASTERR = "panel: " .. tostring(e) end
		task.wait(0.5)
	end
end)

task.spawn(function()
	while alive do
		local ok, e = pcall(step)
		fixIdentity()
		if not ok then
			getgenv().TD_LASTERR = "loop: " .. tostring(e)
			status = "Error: " .. tostring(e)
			task.wait(1)
		end
		task.wait(0.3)
	end
end)

task.spawn(function()
	local warnedFull = false
	while alive do
		if cfg.autoFish and G.serverType == "Lobby" then
			local caught = gameCall(function() return G.data.recentFishCaught end) or 0
			local limit = gameCall(function() return G.Item.Gamepass.MoreFishing:IsOwnedBy(G.player) end) and 200 or 100
			if caught < limit then
				warnedFull = false
				fire("PlayerCatchFish")
			elseif not warnedFull then
				warnedFull = true
				notify("Fishing", string.format("Daily limit reached (%d/%d)", caught, limit))
			end
		end
		task.wait(5.5)
	end
end)

notify("Eze Hub loaded", "RightShift to hide the window")
