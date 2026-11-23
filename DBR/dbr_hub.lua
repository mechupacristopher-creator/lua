local VERSION = "1.1.0"
local FILE, CFG_FILE = "dbr_farm.lua", "dbr_farm_cfg.json"

local SOURCE_URL = "https://raw.githubusercontent.com/mechupacristopher-creator/lua/main/DBR/dbr_hub.lua"

local G = getgenv()

local TOKEN = {}
G.DBRFarmToken = TOKEN
if G.DBRFarm and G.DBRFarm.Unload then pcall(G.DBRFarm.Unload) end
if not game:IsLoaded() then game.Loaded:Wait() end

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local Http = game:GetService("HttpService")
local TeleportService = game:GetService("TeleportService")
local GuiService = game:GetService("GuiService")
local UIS = game:GetService("UserInputService")
local VirtualUser = game:GetService("VirtualUser")
local RS = game:GetService("ReplicatedStorage")
local LP = Players.LocalPlayer
local Stats = LP:WaitForChild("Stats")
local Network = require(RS.Modules.Library.Network)
local StatUtils = require(RS.Modules.Shared.StatUtils)
local Constants = require(RS:WaitForChild("Constants"))
local KiPackets = require(RS.Modules.Network.Packets.KiBlastPackets)
local KiUtil = require(RS.Modules.Shared.KiBlastUtil)
local ScaleUtil = require(RS.Modules.Library.CharacterScaleUtils)
local Quests = require(RS.Modules.Quests.Quests)
local QuestData = require(RS.Modules.Quests.QuestDataHandler)
local peek = require(RS.Modules.Library.Fusion).peek
local EventBus = require(RS.Modules.Library.EventBus)
if setthreadidentity then pcall(setthreadidentity, 8) end

local EARTH, YARDRAT = 71315343, 1357512648
local STATS = { "Attack", "Agility", "Defense", "Ki" }
local NAMES = { Auto = "Auto", Attack = "Strength", Agility = "Agility", Defense = "Defense", Ki = "Ki" }
local TYPES = { "Auto", "Attack", "Agility", "Defense", "Ki" }
local WORLDS = {
	{ name = "Time Chamber",    place = 1362482151,  allStats = 1250000, Attack = 2,   Agility = 2,   Defense = 2,   Ki = 2 },
	{ name = "Gravity Chamber", place = 3371469539,  zenkai = 6,         Attack = 3,   Agility = 6,   Defense = 0.5, Ki = 0.5 },
	{ name = "Hell",            place = 15669378828, zenkai = 3,         Attack = 0.5, Agility = 0.5, Defense = 4,   Ki = 1.5 },
	{ name = "Beerus Planet",   place = 3336119605,  zenkai = 5,         Attack = 0.5, Agility = 0.5, Defense = 3,   Ki = 3 },
	{ name = "Earth",           place = EARTH,                           Attack = 1,   Agility = 1,   Defense = 1,   Ki = 1 },
}
local SAFE_CF = CFrame.new(0, 10000, 0)

local cfg = {
	farm = false, type = "Auto", zenkai = true, world = true, safe = true, transform = true, small = true,
	quests = false, dragon = false, halloween = false,
	skills = true, retreatAt = 35, resumeAt = 80, bossRange = 100, bossFarm = false,
	antiAfk = true, reconnect = true,
}
pcall(function() for k, v in pairs(Http:JSONDecode(readfile(CFG_FILE))) do cfg[k] = v end end)
local function saveCfg() pcall(writefile, CFG_FILE, Http:JSONEncode(cfg)) end

local function safeHold() if cfg.safe and game.PlaceId ~= EARTH then return SAFE_CF end end

if G.DBRFarmToken ~= TOKEN then return end
local S = { pumpkin = false, conns = {}, status = "Idle", fast = false, charging = false, loadedAt = os.clock() }
G.DBRFarm = S
local function alive() return G.DBRFarm == S end
local function stat(n) local v = Stats:FindFirstChild(n) return v and v.Value or 0 end
local function zenkai() return stat("ZenkaiBoost") end
local function cap() local ok, v = pcall(StatUtils.GetMaxStatsFromPlayer, StatUtils, LP) return ok and v or StatUtils.MaxStats end
local function fmt(n) return ("%.1fM"):format(n / 1e6) end
local function anyOn() return cfg.farm or cfg.dragon or cfg.quests or cfg.halloween end

local function queueReload()
	if not queue_on_teleport then return end
	local src = ('getgenv().EzeDiscordShown = true if isfile and isfile("%s") then loadstring(readfile("%s"))() elseif "%s" ~= "" then loadstring(game:HttpGet("%s"))() end')
		:format(FILE, FILE, SOURCE_URL, SOURCE_URL)
	pcall(queue_on_teleport, src)
end

local badServers, lastHop, lastTp = {}, nil, 0
local function smallestEarthServer()
	local root = RS:FindFirstChild("_servers")
	local list = root and root:FindFirstChild(tostring(EARTH))
	local mine, best = root and root:GetAttribute("code"), nil
	for _, sv in ipairs(list and list:GetChildren() or {}) do
		local n = sv:GetAttribute("plrCount") or 0
		local same = sv.Name == game.JobId or (mine and sv:GetAttribute("code") == mine)
		if not same and n >= 1 and not badServers[sv.Name] and (not best or n < (best:GetAttribute("plrCount") or 99)) then best = sv end
	end
	return best
end

local VISITED_FILE = "dbr_visited.json"
local visited = {}
pcall(function() visited = Http:JSONDecode(readfile(VISITED_FILE)) end)
if game.PlaceId == EARTH then
	visited[game.JobId] = os.time()
	for id, t in pairs(visited) do if os.time() - t > 1800 then visited[id] = nil end end
	pcall(writefile, VISITED_FILE, Http:JSONEncode(visited))
end

local function freshEarthServer()
	local root = RS:FindFirstChild("_servers")
	local list = root and root:FindFirstChild(tostring(EARTH))
	local mine, pool = root and root:GetAttribute("code"), {}
	for _, sv in ipairs(list and list:GetChildren() or {}) do
		local n = sv:GetAttribute("plrCount") or 0
		local same = sv.Name == game.JobId or (mine and sv:GetAttribute("code") == mine)

		if not same and n >= 2 and not badServers[sv.Name] and not visited[sv.Name] then table.insert(pool, sv) end
	end
	if #pool == 0 then return nil end
	table.sort(pool, function(a, b) return (a:GetAttribute("plrCount") or 99) < (b:GetAttribute("plrCount") or 99) end)
	return pool[math.random(1, math.min(5, #pool))]
end

local function hopSmallest()
	local best = game.PlaceId == EARTH and smallestEarthServer()
	if not best then return false end
	lastHop = best.Name
	queueReload()
	task.spawn(pcall, Network.InvokeServer, Network, "TeleportToServer", EARTH, best.Name)
	return true
end
table.insert(S.conns, TeleportService.TeleportInitFailed:Connect(function(plr)
	if plr ~= LP or not lastHop then return end
	badServers[lastHop], lastHop = true, nil
	task.wait(3)
	if not alive() then return end
	if cfg.dragon then
		lastTp = 0
	else
		hopSmallest()
	end
end))

local function travel(place, otherServer)
	if os.clock() - lastTp < 20 then return end
	lastTp = os.clock()
	queueReload()

	local best
	if otherServer and place == EARTH and game.PlaceId == EARTH then
		best = freshEarthServer()
		lastHop = best and best.Name
	elseif cfg.small and not cfg.farm and place == EARTH then
		best = smallestEarthServer()
	end
	task.spawn(function()
		if best then
			pcall(Network.InvokeServer, Network, "TeleportToServer", place, best.Name)
		elseif place == EARTH and (otherServer or place == game.PlaceId) then

			pcall(TeleportService.Teleport, TeleportService, EARTH)
		else
			pcall(Network.InvokeServer, Network, "TeleportToWorld", place)
		end
	end)
end

local function bestWorld(st)
	local z, best = zenkai(), nil
	for _, w in ipairs(WORLDS) do
		local ok = (not w.zenkai or z >= w.zenkai)
		if w.allStats then for _, n in ipairs(STATS) do if stat(n) < w.allStats then ok = false end end end
		if ok and (not best or w[st] > best[st]) then best = w end
	end
	return best
end

local function pickStat()
	local c = cap()
	if cfg.type ~= "Auto" and stat(cfg.type) < c then return cfg.type end
	for _, n in ipairs(STATS) do if stat(n) < c then return n end end
end

local kiSeq = 1000000 + math.random(1, 100000)
local function kiBlast(char, root, targetPos)
	kiSeq += 1
	local hand = (kiSeq % 2 == 0) and "Left" or "Right"
	pcall(KiPackets.packets.request.send, {
		seq = kiSeq,
		hand = KiUtil.HandToId(hand),
		origin = KiUtil.GetFirePos(char, hand, ScaleUtil.GetScaleFromCharacter(char)),
		target = targetPos or (root.Position + root.CFrame.LookVector * 500),
	})
end
local function setFast(on)
	if S.fast ~= on then S.fast = on pcall(Network.FireServer, Network, "FastFlight", on) end
end
local function stopCharge(state)
	S.charging = false
	local ch = state and state:FindFirstChild("Charging")
	if ch and ch.Value then pcall(Network.FireServer, Network, "ChargeEnergy", false) end
end

local nextQuestReq, flightAngle, skipUntil, waitSince = 0, 0, {}, {}
local nextAct, nextTransform, nextCharge, nextPrompt, nextKi = 0, 0, 0, 0, 0

local function chargeIfNeeded(state, now)
	local en, mx = state and state:FindFirstChild("Energy"), state and state:FindFirstChild("MaxEnergy")
	local pct = (en and mx and mx.Value > 0) and en.Value / mx.Value * 100 or 100
	if pct < 20 then S.charging = true elseif pct > 90 then S.charging = false end
	if S.charging then
		local ch = state and state:FindFirstChild("Charging")
		if not (ch and ch.Value) and now > nextCharge then
			nextCharge = now + 2
			task.spawn(pcall, Network.InvokeServer, Network, "ChargeEnergy", true)
		end
		return true, pct
	end
	stopCharge(state)
	return false, pct
end

local function dragonData()
	local v = Stats:FindFirstChild("DragonBalls")
	if not v then return end
	local have, full = {}, true
	for _, part in ipairs(v.Value:split(";")) do
		local n = tonumber(part:split("=")[1])
		if n then have[n] = true end
	end
	for n = 1, 7 do if not have[n] then full = false end end
	return have, full
end
local function findBall(have)
	for _, m in ipairs(workspace.Map:GetChildren()) do
		local n = m:GetAttribute("BallNum")
		if n and m:GetAttribute("SpawnPos") and not have[n] then return m end
	end
end

local target
local function hp(m)
	if not (m and m.Parent) then return false end
	local h = m:GetAttribute("Health")
	if h then return h > 0 end
	local hum = m:FindFirstChildOfClass("Humanoid")
	return hum ~= nil and hum.Health > 0
end

local function findNPC(names, from)
	local npcs = workspace:FindFirstChild("Map") and workspace.Map:FindFirstChild("NPCs")
	local best, bd = nil, math.huge
	for _, m in ipairs(npcs and npcs:GetChildren() or {}) do
		local ok = (names == "any" and m.Name ~= "Dummy") or (type(names) == "table" and names[m.Name])
		if ok and hp(m) then
			local d = (m:GetPivot().Position - from).Magnitude

			if d < bd and d < 15000 then best, bd = m, d end
		end
	end
	return best
end
local function pumpkinTarget(from)
	local best, bd, map = nil, math.huge, workspace:FindFirstChild("Map")
	if not map then return end
	local list = {}
	local f = map:FindFirstChild("Pumpkin")
	if f then for _, m in ipairs(f:GetChildren()) do table.insert(list, m) end end
	local npcs = map:FindFirstChild("NPCs")
	if npcs then for _, m in ipairs(npcs:GetChildren()) do if m.Name:lower():find("pumpkin") then table.insert(list, m) end end end
	for _, m in ipairs(list) do
		if hp(m) then
			local d = (m:GetPivot().Position - from).Magnitude
			if d < bd then best, bd = m, d end
		end
	end
	return best
end

table.insert(S.conns, RunService.Heartbeat:Connect(function(dt)
	if not alive() then return end
	local root = LP.Character and LP.Character:FindFirstChild("HumanoidRootPart")
	if not root then return end
	if S.pumpkin or S.attack then
		if S.pumpkin then
			if not hp(target) then target = pumpkinTarget(root.Position) end
		else
			target = S.attack
		end
		if not hp(target) then return end
		local p = target:GetPivot().Position
		local flat = Vector3.new(root.Position.X - p.X, 0, root.Position.Z - p.Z)
		local pos = p + (flat.Magnitude > 0.1 and flat.Unit or Vector3.new(0, 0, 1)) * 3
		root.CFrame = CFrame.lookAt(pos, Vector3.new(p.X, pos.Y, p.Z))
	elseif S.ranged and hp(S.ranged) then

		local p = S.ranged:GetPivot().Position
		S.orbit = (S.orbit or 0) + dt * (S.rangedBoss and 1 or 0.6)
		local pos = p + Vector3.new(math.cos(S.orbit), 0, math.sin(S.orbit)) * (S.rangedR or 35) + Vector3.new(0, S.rangedBoss and 30 or 15, 0)
		root.CFrame = CFrame.lookAt(pos, p)
	elseif S.hold then
		root.CFrame = S.hold
	else
		return
	end
	root.AssemblyLinearVelocity = Vector3.zero
end))

table.insert(S.conns, LP.Idled:Connect(function()
	if not cfg.antiAfk then return end
	pcall(function() VirtualUser:CaptureController() VirtualUser:ClickButton2(Vector2.new()) end)
end))
pcall(function()
	table.insert(S.conns, GuiService.ErrorMessageChanged:Connect(function()
		if not (cfg.reconnect and anyOn()) then return end
		local okm, m = pcall(function()
			if setthreadidentity then setthreadidentity(8) end
			return GuiService:GetErrorMessage()
		end)
		local msg = okm and tostring(m or ""):lower() or ""

		if (okm and msg == "") or msg:find("teleport") then return end
		task.wait(2)
		queueReload()

		pcall(TeleportService.Teleport, TeleportService, EARTH)
	end))
end)

local SKILL_LOOKUP = RS.Skills.Client.ClientSkillLookUp
local skillHow = {}
local function howToCast(key)
	if skillHow[key] ~= nil then return skillHow[key] end
	local mod
	for _, cat in ipairs({ "Beams", "Energy" }) do mod = mod or SKILL_LOOKUP:FindFirstChild(cat) and SKILL_LOOKUP[cat]:FindFirstChild(key) end
	if not mod then skillHow[key] = false return false end
	local ok, src = pcall(decompile, mod)
	local how = { cast = true }
	if ok and type(src) == "string" then
		local q = '"' .. key:gsub("%p", "%%%0") .. '"'
		for _, stage in ipairs({ "Start", "Run", "charge" }) do
			if src:find("FireServer%(" .. q .. ", \"" .. stage .. "\"") then how = { stage = stage } break end
		end
		if not how.stage and src:find("FireServer%(" .. q .. "%)") then how = { plain = true } end
		local fire = src:match("FireServer%(" .. q .. ", \"([Ff]ire)\"")
		if fire then how.fire, how.fireCF = fire, src:find("FireServer%(" .. q .. ", \"[Ff]ire\", cframe") ~= nil end
	end
	skillHow[key] = how
	return how
end
local function fireSkill(key, how, root, targetPos)
	if how.cast then pcall(Network.FireServer, Network, "CastSkill", { Key = key })
	elseif how.plain then pcall(Network.FireServer, Network, key)
	else pcall(Network.FireServer, Network, key, how.stage) end
	if how.fire then
		task.delay(0.8, function()
			local aim = how.fireCF and CFrame.lookAt(root.Position, targetPos) or targetPos
			pcall(Network.FireServer, Network, key, how.fire, aim)
		end)
	end
end

local nextSkill, skillIdx, retreatSince, nextLock = 0, 0, nil, 0

local function kiSkillTools()
	local list = {}
	for _, where in ipairs({ LP:FindFirstChild("Backpack"), LP.Character }) do
		for _, t in ipairs(where and where:GetChildren() or {}) do
			local key = t:IsA("Tool") and t:GetAttribute("Key")
			if key and howToCast(key) then table.insert(list, t) end
		end
	end
	table.sort(list, function(a, b) return a.Name < b.Name end)
	return list
end
local function castNextSkill(now, root, targetPos)
	if now < nextSkill then return end
	local tools = kiSkillTools()
	for _, t in ipairs(tools) do if t:GetAttribute("CooldownTime") == -1 then return end end
	local serverNow = workspace:GetServerTimeNow()
	for _ = 1, #tools do
		skillIdx = skillIdx % #tools + 1
		local t = tools[skillIdx]
		local cd = t:GetAttribute("CooldownTime")
		if cd == nil or (cd ~= -1 and cd <= serverNow) then
			nextSkill = now + 0.3
			local key = t:GetAttribute("Key")
			fireSkill(key, howToCast(key), root, targetPos)
			return
		end
	end
end

local BOSS_NAMES = { "Gogeta", "Janemba", "Brola", "Piccolo", "Goku", "Carl", "Beast", "Guz", "Maz", "Garuri", "Fluffy Knight",
	"Corruptkin", "Corruptkin Ablaze", "Pumpkin Monstrosity", "Reaper" }
local BOSS_SET = {}
for _, n in ipairs(BOSS_NAMES) do BOSS_SET[n] = true end

local function rangedAttack(root, state, m, now, boss)

	local lt = boss and state and state:FindFirstChild("LockedTarget")
	local lockedModel = lt and lt.Value and lt.Value.Parent
	if lockedModel and lockedModel ~= m and BOSS_SET[lockedModel.Name] and hp(lockedModel) then m = lockedModel end
	setFast(false)
	S.hold, S.attack, S.ranged = nil, nil, m
	S.rangedR, S.rangedBoss = boss and cfg.bossRange or 35, boss
	if boss then
		local hum = root.Parent:FindFirstChildOfClass("Humanoid")
		local pct = hum and hum.MaxHealth > 0 and hum.Health / hum.MaxHealth * 100 or 100
		if pct < cfg.retreatAt and not retreatSince then retreatSince = now end
		if retreatSince and (pct >= cfg.resumeAt or now - retreatSince > 30) then retreatSince = nil end
		if retreatSince then
			S.ranged = nil
			S.hold = CFrame.new(m:GetPivot().Position + Vector3.new(150, 120, 150))
			return ("retreating (%d%% HP)"):format(pct)
		end

		if now > nextLock then
			nextLock = now + 1
			pcall(function()
				local machine = EventBus:Invoke("GetPlayerMachine")
				local part = m:FindFirstChild("HumanoidRootPart") or m.PrimaryPart
				if machine and part and not (machine.lockOnTarget and machine.lockOnTarget:IsDescendantOf(m)) then
					machine:SetLockTarget(part, true)
				end
			end)
		end
		if cfg.skills then castNextSkill(now, root, m:GetPivot().Position) end
	end
	if chargeIfNeeded(state, now) then return "charging Ki" end
	if now > nextKi then
		nextKi = now + 0.15
		kiBlast(root.Parent, root, m:GetPivot().Position)
	end
	return (boss and "skills + Ki on " or "Ki blasts on ") .. m.Name
end

local HW_BOSSES = { Corruptkin = true, ["Corruptkin Ablaze"] = true, ["Pumpkin Monstrosity"] = true, Reaper = true }
local HW_KEYS = { "FindLanterns", "EventSkill", "FindShop", "DragonBallWish", "DailyRewards", "EarnExp", "DefeatEnemies", "DestroyPumpkins",
	"BannerRolls", "LightLanterns", "EvilPumpkins", "Corruptkin", "HellsEmissary", "AllChallenges", "WeekendLanterns", "WeekendCorruptkin", "WeekendPumpkins", "HarvestKing" }
local nextClaim, lampTries, lampSkip = 0, {}, {}
local function halloweenStep(root, now, state)
	if now > nextClaim then
		nextClaim = now + 30
		task.spawn(function()
			for _, k in ipairs(HW_KEYS) do pcall(Network.FireServer, Network, "ClaimBannerChallenge", "Halloween2025", k) task.wait(0.2) end
		end)
	end
	if game.PlaceId ~= EARTH then S.status = "Halloween: travelling to Earth" travel(EARTH) return true end
	local boss = findNPC(HW_BOSSES, root.Position)
	if boss and boss.Name == "Pumpkin Monstrosity" then
		setFast(false) stopCharge(state)
		S.hold, S.attack = nil, boss
		S.status = "Halloween: punching Pumpkin Monstrosity (Ki immune)"
		return true
	end
	if boss then S.status = "Halloween: " .. rangedAttack(root, state, boss, now, true) return true end
	local lanterns = workspace.Map:FindFirstChild("Lanterns")
	for _, lamp in ipairs(lanterns and lanterns:GetChildren() or {}) do
		local prox, rp = lamp:FindFirstChildWhichIsA("ProximityPrompt", true), lamp:FindFirstChild("RootPart")

		if prox and prox.Enabled and rp and now > (lampSkip[lamp] or 0) then
			setFast(false) stopCharge(state)
			S.hold = CFrame.new(rp.Position + Vector3.new(0, 3, 4))
			if now > nextPrompt then
				nextPrompt = now + 0.6
				lampTries[lamp] = (lampTries[lamp] or 0) + 1
				if lampTries[lamp] > 4 then lampTries[lamp], lampSkip[lamp] = 0, now + 600 end
				task.delay(0.3, function() if prox.Enabled then pcall(fireproximityprompt, prox) end end)
			end
			S.status = "Halloween: lighting lantern"
			return true
		end
	end
	local t = pumpkinTarget(root.Position)
	if t then
		setFast(false) stopCharge(state)
		S.hold, S.attack = nil, t
		S.status = "Halloween: smashing " .. t.Name
		return true
	end
	return false
end

local function questStep(root, now, state, have, dragonStep)
	local ok, d = pcall(peek, QuestData.Data)
	if not ok or type(d) ~= "table" then return false end
	local done, prog, list = {}, d.QuestProgress or {}, {}
	for _, q in ipairs(d.CompletedQuests or {}) do done[q] = true end
	if d.DailyQuest and not done[d.DailyQuest] then table.insert(list, d.DailyQuest) end
	for _, q in ipairs(d.WeeklyQuests or {}) do if not done[q] then table.insert(list, q) end end

	for _, key in ipairs(list) do
		local q = Quests[key]
		local r = q and q.Requirements
		if r and now > (skipUntil[key] or 0) then
			if key == d.DailyQuest and d.CurrentQuest ~= key and now > nextQuestReq then
				nextQuestReq = now + 5
				pcall(Network.FireServer, Network, "RequestDailyQuest")
			end
			local label = ("%s (%s/%s)"):format(q.Name or key, tostring(prog[key] or 0), tostring(r.Count or "?"))
			local names, place
			if r.Type == "Kill" then names, place = { [r.Target] = true }, (r.Target == "Yardrat" and YARDRAT or EARTH)
			elseif r.Type == "KillAny" then names, place = "any", EARTH
			elseif r.Type == "KillTargets" then
				names, place = {}, EARTH
				for _, n in ipairs(r.Targets or {}) do names[n] = true end
			end

			if names then
				local boss = r.Type == "KillTargets"
				if game.PlaceId == place then
					local m = findNPC(names, root.Position)
					if m then
						waitSince[key] = nil

						S.status = ("Quest: %s - %s"):format(label, rangedAttack(root, state, m, now, boss or r.Count == 1))
						return true
					end

					if not boss then
						waitSince[key] = waitSince[key] or now
						if now - waitSince[key] < 60 then
							S.hold = safeHold()
							S.status = ("Quest: %s - waiting for spawn"):format(label)
							return true
						end
						waitSince[key], skipUntil[key] = nil, now + 300
					end
				elseif not boss then
					S.status = ("Quest: %s - travelling"):format(label)
					travel(place)
					return true
				end
			elseif r.Type == "Collect" and r.Target == "DragonBall" and have then
				dragonStep("Quest Dragon Ball")
				return true
			elseif r.Type == "Flight" then

				stopCharge(state)
				setFast(true)
				flightAngle += 0.02
				S.flightBase = S.flightBase or safeHold() or CFrame.new(root.Position + Vector3.new(0, 100, 0))
				S.hold = S.flightBase * CFrame.new(math.cos(flightAngle) * 400, 0, math.sin(flightAngle) * 400)
				S.status = "Quest: " .. label
				return true
			end
		end
	end
	return false
end

local transformingUntil = 0
local function farmStep(char, root)
	local now = os.clock()
	local state = char:FindFirstChild("State")
	S.hold = safeHold()
	S.attack, S.ranged = nil, nil

	if cfg.transform and state and now > nextTransform then
		local sel, act = Stats:FindFirstChild("SelectedMode"), state:FindFirstChild("ActiveMode")
		local base = function(v) return v == "" or v == "Base" end
		if sel and not base(sel.Value) and act and base(act.Value) then

			S.tfFails = (S.tfFails or 0) + 1
			if S.tfFails > 3 then
				S.tfFails, nextTransform = 0, now + 60
			else
				nextTransform, transformingUntil = now + 5, now + 3
				stopCharge(state) setFast(false)
				S.tfQuick = not S.tfQuick
				task.spawn(pcall, Network.InvokeServer, Network, "Transform", S.tfQuick and "Quick" or "Normal")
			end
		elseif act and not base(act.Value) then
			S.tfFails = 0
		end
	end
	if now < transformingUntil then
		local act = state and state:FindFirstChild("ActiveMode")
		if act and act.Value ~= "" and act.Value ~= "Base" then transformingUntil = 0 end
		stopCharge(state)
		S.status = "Transforming..."
		return
	end

	local have, full = dragonData()
	local function dragonStep(label)
		setFast(false) stopCharge(state)
		S.hold = nil
		if game.PlaceId ~= EARTH then S.status = label .. ": travelling to Earth" travel(EARTH) return end
		local ball = findBall(have)
		if ball then
			root.CFrame = ball:GetPivot() + Vector3.new(0, -5, 0)
			if now > nextPrompt then
				nextPrompt = now + 1
				task.delay(0.5, function()
					local prox = ball.Parent and ball:FindFirstChildWhichIsA("ProximityPrompt", true)
					if prox then pcall(fireproximityprompt, prox) end
				end)
			end
			S.status = label .. ": grabbing ball " .. tostring(ball:GetAttribute("BallNum"))
		else

			local left = 10 - (os.clock() - S.loadedAt)
			if left > 0 then
				S.status = ("%s: none here, hopping in %ds (turn off Dragon Ball Finder to stop)"):format(label, math.ceil(left))
				return
			end
			S.status = label .. ": hopping server"
			travel(EARTH, true)
		end
	end
	if cfg.dragon and have and not full then dragonStep("Dragon Balls") return end
	if cfg.quests and questStep(root, now, state, have, dragonStep) then return end
	if cfg.halloween and halloweenStep(root, now, state) then return end
	if not cfg.farm then
		S.hold = nil
		S.status = (cfg.quests or cfg.halloween) and "Nothing to do right now" or "Dragon Balls: you have all 7"
		return
	end

	local st = pickStat()
	if not st then
		setFast(false) stopCharge(state)
		if not cfg.zenkai then S.status = "All stats capped (Auto Zenkai off)" return end
		local z = zenkai()
		if z >= Constants.Training.MaxZenkai then S.status = "Max Zenkai reached" return end
		if z < Constants.Training.DragonBallZenkaiLimit then
			local ok, can = pcall(StatUtils.CanPlayerZenkai, StatUtils, LP)
			if ok and can then
				S.status = "Zenkai boosting..."
				pcall(Network.InvokeServer, Network, "RequestZenkaiBoost")
				task.wait(2)
			end
		elseif full then
			if game.PlaceId ~= EARTH then S.status = "Zenkai: travelling to Earth for the wish" travel(EARTH) return end
			local center = workspace.Map:FindFirstChild("Pedestal") and workspace.Map.Pedestal:FindFirstChild("Center")
			if center then
				S.hold = center.CFrame + Vector3.new(0, -5, 0)
				task.wait(0.5)
				local prox = center:FindFirstChildWhichIsA("ProximityPrompt", true)
				if prox then pcall(fireproximityprompt, prox) end
				pcall(Network.FireServer, Network, "SelectWish", "ZenkaiBoost")
				S.status = "Zenkai: making the wish"
				task.wait(2)
			end
		else
			S.status = "Zenkai: needs all 7 Dragon Balls (enable the finder)"
		end
		return
	end

	if cfg.world then
		local w = bestWorld(st)
		if w and w.place ~= game.PlaceId then
			setFast(false) stopCharge(state)
			S.status = ("Travelling to %s (%s)"):format(w.name, NAMES[st])
			travel(w.place)
			return
		end
	end

	if cfg.bossFarm then
		local boss = findNPC(BOSS_SET, root.Position)
		if boss then
			if boss.Name == "Pumpkin Monstrosity" then
				stopCharge(state) setFast(false)
				S.hold, S.attack = nil, boss
				S.status = "Boss: punching Pumpkin Monstrosity"
			else
				S.status = "Boss: " .. rangedAttack(root, state, boss, now, true)
			end
			return
		end
	end

	local energy = state and state:FindFirstChild("Energy")
	local maxE = state and state:FindFirstChild("MaxEnergy")
	local pct = (energy and maxE and maxE.Value > 0) and energy.Value / maxE.Value * 100 or 100

	if st == "Attack" or st == "Agility" then
		stopCharge(state)
		setFast(true)
		pcall(Network.FireServer, Network, "Combat")
	else
		setFast(false)
		if not chargeIfNeeded(state, now) then
			if st == "Defense" and now > nextAct then
				nextAct = now + 0.35
				pcall(Network.FireServer, Network, "DefenseTrain")
			elseif st == "Ki" and now > nextAct then
				nextAct = now + 0.15
				kiBlast(char, root)
			end
		end
	end
	S.status = ("%s%s  %s / %s  (%d%% energy)"):format(S.charging and "Charging - " or "", NAMES[st], fmt(stat(st)), fmt(cap()), pct)
end

local nextMelee = 0
local function melee(m)
	if not hp(m) or os.clock() < nextMelee then return end
	nextMelee = os.clock() + 0.12
	pcall(Network.FireServer, Network, "Combat")
	task.delay(0.06, function()
		if hp(m) then pcall(Network.FireServer, Network, "Combat", "Hit", m, m:GetPivot().Position) end
	end)
end

task.spawn(function()
	while alive() do
		local char = LP.Character
		local root = char and char:FindFirstChild("HumanoidRootPart")
		if root then
			if S.pumpkin then
				S.hold, S.attack, S.ranged = nil, nil, nil
				melee(target)
				S.status = "Pumpkins: " .. (target and target.Name or "none left, waiting for respawns")
			elseif anyOn() then
				local ok, err = pcall(farmStep, char, root)
				if not ok then S.status = "Error: " .. tostring(err) S.attack, S.ranged = nil, nil end
				melee(S.attack)
			else
				setFast(false) stopCharge(char:FindFirstChild("State"))
				S.hold, S.attack, S.ranged = nil, nil, nil
				S.status = "Idle"
			end
		end
		task.wait()
	end
end)

task.spawn(function()
	while alive() do
		task.wait(5)
		if cfg.small and not cfg.farm and game.PlaceId == EARTH and #Players:GetPlayers() > 6 and os.clock() - S.loadedAt > 20 then
			local best = smallestEarthServer()
			if best and (best:GetAttribute("plrCount") or 99) <= 3 then
				S.status = ("Hopping to a small server (%d players)"):format(best:GetAttribute("plrCount"))
				hopSmallest()
				task.wait(60)
			end
		end
	end
end)

local UI_URL = "https://raw.githubusercontent.com/mechupacristopher-creator/lua/main/lib/eze_ui.lua"
local guiParent = (gethui and gethui()) or game:GetService("CoreGui")

for _, o in ipairs(guiParent:GetChildren()) do if o.Name == "DBRFarm" or o.Name == "DBRHub" or o.Name == "EzeHub" then o:Destroy() end end

local Library = loadstring(game:HttpGet(UI_URL))()
local win = Library:window({ name = "Eze Hub" })
S.gui = guiParent:FindFirstChild("MonolithUI")

local toggles = {}
local function refreshAll()
	for _, t in ipairs(toggles) do
		local v = t.get() and true or false
		if t.api.enabled ~= v then t.api.enabled = v t.api:refresh() end
	end
end
local function changed() saveCfg() refreshAll() end

local function Toggle(sec, text, get, set)
	local api = sec:Toggle({ name = text, default = get(), NoSave = true, Callback = function(v)
		if (get() and true or false) ~= v then set(v) changed() end
	end })
	table.insert(toggles, { api = api, get = get })
end
local function cfgToggle(sec, text, key) Toggle(sec, text, function() return cfg[key] end, function(v) cfg[key] = v end) end

local function modeToggle(sec, text, key)
	Toggle(sec, text, function() return cfg[key] end, function(v) cfg[key] = v if v then S.pumpkin = false end end)
end

local function Slider(sec, text, min, max, key)
	sec:Slider({ name = text, min = min, max = max, default = cfg[key], decimals = 0, NoSave = true, Callback = function(v)
		v = math.floor(v + 0.5)
		if cfg[key] ~= v then cfg[key] = v saveCfg() end
	end })
end

local function Paragraph(sec, getText)
	local l = sec:Label({ name = "" })
	l.instance.RichText = true
	task.spawn(function()
		while alive() do
			local ok, txt = pcall(getText)
			l.instance.Text = ok and txt or l.instance.Text
			task.wait(0.3)
		end
	end)
end

local home = win:Tab({ name = "Home", icon = "lucide:home" })
local status = home:Section({ name = "Status", side = "left" })
Paragraph(status, function()
	local c, parts = cap(), {}
	for _, n in ipairs(STATS) do
		local v = stat(n)
		table.insert(parts, ("%s: <font color=\"#ffffff\">%s</font>%s"):format(NAMES[n], fmt(v), v >= c and " ✓" or ""))
	end
	local w
	for _, x in ipairs(WORLDS) do if x.place == game.PlaceId then w = x.name end end
	return ("<b><font color=\"#ffffff\">%s</font></b>\n\n%s\n\nCap: %s  |  Zenkai: %d  |  World: %s")
		:format(S.status, table.concat(parts, "\n"), fmt(c), zenkai(), w or "?")
end)
local spawned = home:Section({ name = "Spawned", side = "right" })
local WATCH = table.clone(BOSS_NAMES)
table.insert(WATCH, "Pumpkin Creature")
Paragraph(spawned, function()
	local map, lines = workspace:FindFirstChild("Map"), {}
	if not map then return "Map not loaded" end
	local balls = {}
	for _, m in ipairs(map:GetChildren()) do
		local n = m:GetAttribute("BallNum")
		if n then table.insert(balls, n) end
	end
	table.sort(balls)
	table.insert(lines, #balls > 0 and ("<font color=\"#ffb000\">Dragon Balls: %s</font>"):format(table.concat(balls, ", ")) or "Dragon Balls: none")
	local npcs = map:FindFirstChild("NPCs")
	for _, name in ipairs(WATCH) do
		for _, m in ipairs(npcs and npcs:GetChildren() or {}) do
			if m.Name == name and hp(m) then
				local h = m:GetAttribute("Health") or (m:FindFirstChildOfClass("Humanoid") and m:FindFirstChildOfClass("Humanoid").Health) or 0
				local hs = h >= 1e6 and fmt(h) or ("%.0fk"):format(h / 1e3)
				table.insert(lines, ("<font color=\"#ff5050\">%s</font>  %s HP"):format(name, hs))
			end
		end
	end
	local pumpkins = 0
	local pf = map:FindFirstChild("Pumpkin")
	for _, m in ipairs(pf and pf:GetChildren() or {}) do if hp(m) then pumpkins += 1 end end
	table.insert(lines, "Pumpkins: " .. pumpkins)
	return table.concat(lines, "\n")
end)
local info = home:Section({ name = "Info", side = "right" })
info:Label({ name = "Toggle the UI with RightControl or the minimize button. Settings are saved and the script reloads itself after teleports." })

local farming = win:Tab({ name = "Farming", icon = "lucide:dumbbell" })
local statFarm = farming:Section({ name = "Stat Farm", side = "left" })
modeToggle(statFarm, "Auto Farm Stats", "farm")
do
	local labels, byLabel = {}, {}
	for _, t in ipairs(TYPES) do table.insert(labels, NAMES[t]) byLabel[NAMES[t]] = t end
	statFarm:Dropdown({ name = "Stat to Train", items = labels, default = NAMES[cfg.type], NoSave = true, Callback = function(label)
		local t = byLabel[label]
		if t and cfg.type ~= t then cfg.type = t saveCfg() end
	end })
end
cfgToggle(statFarm, "Auto Zenkai", "zenkai")
cfgToggle(statFarm, "Auto Transform", "transform")
cfgToggle(statFarm, "Kill Bosses While Farming", "bossFarm")
local world = farming:Section({ name = "World", side = "right" })
cfgToggle(world, "Teleport to Best World", "world")
cfgToggle(world, "Safe Farm (sky)", "safe")
cfgToggle(world, "Prefer Small Servers (Earth only)", "small")

local questsTab = win:Tab({ name = "Quests", icon = "lucide:scroll-text" })
local questSec = questsTab:Section({ name = "Quests", side = "left" })
modeToggle(questSec, "Auto Quests (daily + weekly)", "quests")
modeToggle(questSec, "Dragon Ball Finder", "dragon")

local event = win:Tab({ name = "Event", icon = "lucide:sparkles" })
local halloween = event:Section({ name = "Halloween", side = "left" })
modeToggle(halloween, "Auto Halloween Event", "halloween")
Toggle(halloween, "Pumpkin Farm", function() return S.pumpkin end, function(v)
	S.pumpkin = v
	target = nil
	if v then cfg.farm, cfg.dragon, cfg.quests, cfg.halloween = false, false, false, false end
end)
halloween:Label({ name = "Lights lanterns, fights Corruptkin / Ablaze, smashes pumpkins and claims challenge rewards." })

local combat = win:Tab({ name = "Combat", icon = "lucide:swords" })
local bosses = combat:Section({ name = "Bosses", side = "left" })
cfgToggle(bosses, "Use Ki Skills (no melee)", "skills")
Slider(bosses, "Boss Distance", 40, 150, "bossRange")
local safeMode = combat:Section({ name = "Safe Mode", side = "right" })
Slider(safeMode, "Retreat at Health %", 10, 90, "retreatAt")
Slider(safeMode, "Back at Health %", 20, 100, "resumeAt")

local misc = win:Tab({ name = "Misc", icon = "lucide:settings" })
local miscSec = misc:Section({ name = "Misc", side = "left" })
cfgToggle(miscSec, "Anti-AFK", "antiAfk")
cfgToggle(miscSec, "Auto Reconnect", "reconnect")
local server = misc:Section({ name = "Server", side = "right" })
server:Button({ name = "Hop to Smallest Server (Earth)", Callback = function() if not hopSmallest() then S.status = "Server hop only works on Earth" end end })
server:Button({ name = "Unload Script", Callback = function() S.Unload() end })

function S.Unload()
	if S.unloaded then return end
	S.unloaded = true
	G.DBRFarm = nil
	setFast(false)
	stopCharge(LP.Character and LP.Character:FindFirstChild("State"))
	for _, c in ipairs(S.conns) do c:Disconnect() end
	pcall(function() Library:Unload() end)
end

if S.gui then
	table.insert(S.conns, S.gui.AncestryChanged:Connect(function(_, parent)
		if parent == nil and not S.unloaded then
			cfg.farm, cfg.dragon, cfg.quests, cfg.halloween = false, false, false, false
			saveCfg()
			S.Unload()
		end
	end))
end
