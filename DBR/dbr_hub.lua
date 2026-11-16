--[[
	DBR Hub - Dragon Ball Rage
	Stat farm (optimal world, safe farm, auto Zenkai, auto transform), auto quests,
	Halloween event (lanterns, Corruptkin, pumpkins), Dragon Ball finder.
	Re-running unloads the previous copy. After a world teleport it reloads itself.
	Based on afy's Dragon Ball Rage AutoFarm, with Ki Blasts updated to the new packet system.
]]

local VERSION = "1.0.0"
local FILE, CFG_FILE = "dbr_farm.lua", "dbr_farm_cfg.json"
-- raw URL used to reload after teleports when the script is not saved locally (set after publishing)
local SOURCE_URL = "https://raw.githubusercontent.com/mechupacristopher-creator/lua/main/DBR/dbr_hub.lua"

local G = getgenv()
-- claim the slot before any yield: after a teleport both queue_on_teleport and autoexec start a copy at once
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
if setthreadidentity then pcall(setthreadidentity, 8) end -- game requires drop the thread identity

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

-- ===== saved config =====
local cfg = {
	farm = false, type = "Auto", zenkai = true, world = true, safe = true, transform = true, small = true,
	quests = false, dragon = false, halloween = false,
	skills = true, retreatAt = 35, resumeAt = 80, bossRange = 100,
	antiAfk = true, reconnect = true,
}
pcall(function() for k, v in pairs(Http:JSONDecode(readfile(CFG_FILE))) do cfg[k] = v end end)
local function saveCfg() pcall(writefile, CFG_FILE, Http:JSONEncode(cfg)) end
-- no safe farm on Earth: quests, lanterns and pumpkins happen on the ground there
local function safeHold() if cfg.safe and game.PlaceId ~= EARTH then return SAFE_CF end end

if G.DBRFarmToken ~= TOKEN then return end -- a newer copy started while this one was loading
local S = { pumpkin = false, conns = {}, status = "Idle", fast = false, charging = false }
G.DBRFarm = S
local function alive() return G.DBRFarm == S end
local function stat(n) local v = Stats:FindFirstChild(n) return v and v.Value or 0 end
local function zenkai() return stat("ZenkaiBoost") end
local function cap() local ok, v = pcall(StatUtils.GetMaxStatsFromPlayer, StatUtils, LP) return ok and v or StatUtils.MaxStats end
local function fmt(n) return ("%.1fM"):format(n / 1e6) end
local function anyOn() return cfg.farm or cfg.dragon or cfg.quests or cfg.halloween end

-- ===== teleports =====
local function queueReload()
	if not queue_on_teleport then return end
	local src = ('if isfile and isfile("%s") then loadstring(readfile("%s"))() elseif "%s" ~= "" then loadstring(game:HttpGet("%s"))() end')
		:format(FILE, FILE, SOURCE_URL, SOURCE_URL)
	pcall(queue_on_teleport, src)
end

local lastTp = 0
local function travel(place, otherServer)
	if os.clock() - lastTp < 20 then return end
	lastTp = os.clock()
	queueReload()
	local best
	if cfg.small then
		local root = RS:FindFirstChild("_servers")
		local list = root and root:FindFirstChild(tostring(place))
		local mine = root and root:GetAttribute("code")
		for _, sv in ipairs(list and list:GetChildren() or {}) do
			local n = sv:GetAttribute("plrCount") or 99
			local same = sv.Name == game.JobId or (mine and sv:GetAttribute("code") == mine)
			if not same and (not best or n < (best:GetAttribute("plrCount") or 99)) then best = sv end
		end
	end
	task.spawn(function()
		if best then
			pcall(Network.InvokeServer, Network, "TeleportToServer", place, best.Name)
		elseif otherServer or place == game.PlaceId then
			pcall(TeleportService.Teleport, TeleportService, place)
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

-- the chosen stat if it is below the cap, otherwise the first one that is
local function pickStat()
	local c = cap()
	if cfg.type ~= "Auto" and stat(cfg.type) < c then return cfg.type end
	for _, n in ipairs(STATS) do if stat(n) < c then return n end end
end

-- ===== training actions =====
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

-- charge Ki over the network below 20% until 90%; returns true while charging
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

-- ===== dragon balls =====
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

-- ===== targets =====
local target
local function hp(m)
	if not (m and m.Parent) then return false end
	local h = m:GetAttribute("Health")
	if h then return h > 0 end
	local hum = m:FindFirstChildOfClass("Humanoid")
	return hum ~= nil and hum.Health > 0
end
-- names = {Name=true} or "any" (any enemy)
local function findNPC(names, from)
	local npcs = workspace:FindFirstChild("Map") and workspace.Map:FindFirstChild("NPCs")
	local best, bd = nil, math.huge
	for _, m in ipairs(npcs and npcs:GetChildren() or {}) do
		local ok = (names == "any" and m.Name ~= "Dummy") or (type(names) == "table" and names[m.Name])
		if ok and hp(m) then
			local d = (m:GetPivot().Position - from).Magnitude
			if d < bd then best, bd = m, d end
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

-- ===== positioning every frame =====
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
		-- keep distance (close-range combos never end), stay above and orbit to dodge
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

-- ===== anti-AFK and reconnect =====
table.insert(S.conns, LP.Idled:Connect(function()
	if not cfg.antiAfk then return end
	pcall(function() VirtualUser:CaptureController() VirtualUser:ClickButton2(Vector2.new()) end)
end))
pcall(function()
	table.insert(S.conns, GuiService.ErrorMessageChanged:Connect(function()
		if not (cfg.reconnect and anyOn()) then return end
		task.wait(2)
		queueReload()
		pcall(TeleportService.Teleport, TeleportService, game.PlaceId)
	end))
end)

-- ===== bosses: skills, dodging, retreat =====
-- Ki skills = the game's "Energy" tab (ClientSkillLookUp.Beams + .Energy); .Combat (melee) is never used
local SKILL_LOOKUP = RS.Skills.Client.ClientSkillLookUp
local skillHow = {} -- key -> how the game fires it (read from its client module), false = not a Ki skill
local function howToCast(key)
	if skillHow[key] ~= nil then return skillHow[key] end
	local mod
	for _, cat in ipairs({ "Beams", "Energy" }) do mod = mod or SKILL_LOOKUP:FindFirstChild(cat) and SKILL_LOOKUP[cat]:FindFirstChild(key) end
	if not mod then skillHow[key] = false return false end
	local ok, src = pcall(decompile, mod)
	local how = { cast = true } -- default: CastSkill {Key=...} (beams and the generic energy skills)
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
	if how.fire then -- charge-then-release skills (Death Beam, Big Bang Attack)
		task.delay(0.8, function()
			local aim = how.fireCF and CFrame.lookAt(root.Position, targetPos) or targetPos
			pcall(Network.FireServer, Network, key, how.fire, aim)
		end)
	end
end

local nextSkill, skillIdx, retreatSince = 0, 0, nil
-- each skill's Tool (Backpack or equipped) has Key and CooldownTime (server time it is ready again; -1 while in use)
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
	for _, t in ipairs(tools) do if t:GetAttribute("CooldownTime") == -1 then return end end -- one is still running
	local serverNow = workspace:GetServerTimeNow()
	for _ = 1, #tools do
		skillIdx = skillIdx % #tools + 1
		local t = tools[skillIdx]
		local cd = t:GetAttribute("CooldownTime")
		if cd == nil or (cd ~= -1 and cd <= serverNow) then
			nextSkill = now + 0.3 -- give the server time to mark it as in use
			local key = t:GetAttribute("Key")
			fireSkill(key, howToCast(key), root, targetPos)
			return
		end
	end
end

-- ki blasts from range; against bosses also orbit, chain skills and retreat on low health
local function rangedAttack(root, state, m, now, boss)
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
		if cfg.skills then castNextSkill(now, root, m:GetPivot().Position) end
	end
	if chargeIfNeeded(state, now) then return "charging Ki" end
	if now > nextKi then
		nextKi = now + 0.15
		kiBlast(root.Parent, root, m:GetPivot().Position)
	end
	return (boss and "skills + Ki on " or "Ki blasts on ") .. m.Name
end

-- ===== Halloween 2025 =====
-- claims challenges, fights event bosses, lights lanterns and smashes pumpkins (on Earth)
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
	if boss and boss.Name == "Pumpkin Monstrosity" then -- immune to Ki: melee only
		setFast(false) stopCharge(state)
		S.hold, S.attack = nil, boss
		S.status = "Halloween: punching Pumpkin Monstrosity (Ki immune)"
		return true
	end
	if boss then S.status = "Halloween: " .. rangedAttack(root, state, boss, now, true) return true end
	local lanterns = workspace.Map:FindFirstChild("Lanterns")
	for _, lamp in ipairs(lanterns and lanterns:GetChildren() or {}) do
		local prox, rp = lamp:FindFirstChildWhichIsA("ProximityPrompt", true), lamp:FindFirstChild("RootPart")
		-- disabled prompt = on cooldown; lamps that don't light after 4 tries are skipped for 10 min (10 lamps, only 9 count)
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

-- ===== quests =====
-- Daily: accepted automatically (RequestDailyQuest). Weeklies progress on their own; we just do them.
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
						-- bosses (boss list or a "defeat X" of count 1, e.g. Carl): skills + dodging
						S.status = ("Quest: %s - %s"):format(label, rangedAttack(root, state, m, now, boss or r.Count == 1))
						return true
					end
					-- nothing alive: wait up to 60s for a respawn, then park this quest for 5 min
					if not boss then
						waitSince[key] = waitSince[key] or now
						if now - waitSince[key] < 60 then
							S.hold = safeHold()
							S.status = ("Quest: %s - waiting for spawn"):format(label)
							return true
						end
						waitSince[key], skipUntil[key] = nil, now + 300
					end
				elseif not boss then -- don't travel just for bosses that may not be there
					S.status = ("Quest: %s - travelling"):format(label)
					travel(place)
					return true
				end
			elseif r.Type == "Collect" and r.Target == "DragonBall" and have then
				dragonStep("Quest Dragon Ball")
				return true
			elseif r.Type == "Flight" then
				-- shortcut: circles with FastFlight on; not verified that the server counts this distance
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

-- ===== main farm step =====
local transformingUntil = 0
local function farmStep(char, root)
	local now = os.clock()
	local state = char:FindFirstChild("State")
	S.hold = safeHold()
	S.attack, S.ranged = nil, nil

	-- transform BEFORE anything else (quests included); "Base" or "" = not transformed
	if cfg.transform and state and now > nextTransform then
		local sel, act = Stats:FindFirstChild("SelectedMode"), state:FindFirstChild("ActiveMode")
		local base = function(v) return v == "" or v == "Base" end
		if sel and not base(sel.Value) and act and base(act.Value) then
			-- 3 failed tries in a row: back off 60s and keep farming instead of getting stuck
			S.tfFails = (S.tfFails or 0) + 1
			if S.tfFails > 3 then
				S.tfFails, nextTransform = 0, now + 60
			else
				nextTransform, transformingUntil = now + 5, now + 3
				stopCharge(state) setFast(false) -- the game blocks transforming while charging or fast flying
				S.tfQuick = not S.tfQuick -- alternate Quick (N key) and Normal (B key) in case one fails
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

	local energy = state and state:FindFirstChild("Energy")
	local maxE = state and state:FindFirstChild("MaxEnergy")
	local pct = (energy and maxE and maxE.Value > 0) and energy.Value / maxE.Value * 100 or 100

	if st == "Attack" or st == "Agility" then
		stopCharge(state)
		setFast(true)
		pcall(Network.FireServer, Network, "Combat") -- every frame: the server gives a bit more than at 10/s
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

-- ===== main loop =====
-- melee over the network (Combat + Hit): no key presses, so stuns don't break it
local nextMelee = 0
local function melee(m)
	if not hp(m) or os.clock() < nextMelee then return end
	nextMelee = os.clock() + 0.3
	pcall(Network.FireServer, Network, "Combat")
	task.delay(0.12, function()
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
				S.status = "Pumpkins: " .. (target and target.Name or "searching...")
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

--[[ ===================== UI ===================== ]]
local C = {
	bg = Color3.fromRGB(16, 16, 16), side = Color3.fromRGB(20, 20, 20), item = Color3.fromRGB(30, 30, 30),
	box = Color3.fromRGB(42, 42, 42), accent = Color3.fromRGB(176, 8, 8), text = Color3.fromRGB(235, 235, 235),
	dim = Color3.fromRGB(150, 150, 150),
}
local function new(class, props, parent)
	local o = Instance.new(class)
	for k, v in pairs(props) do o[k] = v end
	o.Parent = parent
	return o
end
local function corner(o, r) new("UICorner", { CornerRadius = UDim.new(0, r or 8) }, o) end

local guiParent = (gethui and gethui()) or game:GetService("CoreGui")
-- remove panels left behind by older copies (e.g. the old double load)
for _, o in ipairs(guiParent:GetChildren()) do if o.Name == "DBRFarm" or o.Name == "DBRHub" then o:Destroy() end end
local gui = new("ScreenGui", { Name = "DBRHub", ResetOnSpawn = false, ZIndexBehavior = Enum.ZIndexBehavior.Sibling }, guiParent)
S.gui = gui

local win = new("Frame", { Size = UDim2.fromOffset(640, 420), Position = UDim2.new(0.5, -320, 0.5, -210), BackgroundColor3 = C.bg }, gui)
corner(win, 10)
new("UIStroke", { Color = Color3.fromRGB(45, 45, 45) }, win)

-- title bar (drag handle)
local top = new("Frame", { Size = UDim2.new(1, 0, 0, 44), BackgroundTransparency = 1 }, win)
new("TextLabel", {
	Text = "DBR Hub | Version: " .. VERSION, Font = Enum.Font.GothamMedium, TextSize = 16, TextColor3 = C.text,
	BackgroundTransparency = 1, Position = UDim2.fromOffset(18, 0), Size = UDim2.new(1, -120, 1, 0), TextXAlignment = Enum.TextXAlignment.Left,
}, top)
local closeBtn = new("TextButton", { Text = "✕", Font = Enum.Font.GothamBold, TextSize = 18, TextColor3 = C.text, BackgroundTransparency = 1,
	Size = UDim2.fromOffset(36, 36), Position = UDim2.new(1, -42, 0, 4) }, top)
local minBtn = new("TextButton", { Text = "—", Font = Enum.Font.GothamBold, TextSize = 16, TextColor3 = C.text, BackgroundTransparency = 1,
	Size = UDim2.fromOffset(36, 36), Position = UDim2.new(1, -80, 0, 4) }, top)

do -- dragging
	local dragging, start, startPos
	top.InputBegan:Connect(function(i)
		if i.UserInputType == Enum.UserInputType.MouseButton1 or i.UserInputType == Enum.UserInputType.Touch then
			dragging, start, startPos = true, i.Position, win.Position
		end
	end)
	table.insert(S.conns, UIS.InputChanged:Connect(function(i)
		if dragging and (i.UserInputType == Enum.UserInputType.MouseMovement or i.UserInputType == Enum.UserInputType.Touch) then
			local d = i.Position - start
			win.Position = UDim2.new(startPos.X.Scale, startPos.X.Offset + d.X, startPos.Y.Scale, startPos.Y.Offset + d.Y)
		end
	end))
	table.insert(S.conns, UIS.InputEnded:Connect(function(i)
		if i.UserInputType == Enum.UserInputType.MouseButton1 or i.UserInputType == Enum.UserInputType.Touch then dragging = false end
	end))
end

-- minimized pill + RightControl to toggle
local pill = new("TextButton", { Text = "DBR Hub", Font = Enum.Font.GothamBold, TextSize = 14, TextColor3 = C.text, BackgroundColor3 = C.accent,
	Size = UDim2.fromOffset(110, 34), Position = UDim2.new(0, 16, 0.5, -17), Visible = false }, gui)
corner(pill, 8)
local function setOpen(open) win.Visible, pill.Visible = open, not open end
minBtn.MouseButton1Click:Connect(function() setOpen(false) end)
pill.MouseButton1Click:Connect(function() setOpen(true) end)
table.insert(S.conns, UIS.InputBegan:Connect(function(i, gp)
	if not gp and i.KeyCode == Enum.KeyCode.RightControl then setOpen(not win.Visible) end
end))

-- sidebar + pages
local side = new("Frame", { Size = UDim2.new(0, 170, 1, -56), Position = UDim2.fromOffset(12, 48), BackgroundTransparency = 1 }, win)
new("UIListLayout", { Padding = UDim.new(0, 8), SortOrder = Enum.SortOrder.LayoutOrder }, side)
local pagesHolder = new("Frame", { Size = UDim2.new(1, -206, 1, -56), Position = UDim2.fromOffset(194, 48), BackgroundTransparency = 1 }, win)

local refreshers, tabs = {}, {}
local function refreshAll() for _, f in ipairs(refreshers) do f() end end
local function changed() saveCfg() refreshAll() end

local function selectTab(t)
	for _, o in ipairs(tabs) do
		o.page.Visible = o == t
		o.btn.BackgroundColor3 = o == t and C.accent or C.item
	end
end

local function Tab(name, icon)
	local btn = new("TextButton", { Text = "", AutoButtonColor = false, BackgroundColor3 = C.item, Size = UDim2.new(1, 0, 0, 40), LayoutOrder = #tabs + 1 }, side)
	corner(btn, 8)
	new("TextLabel", { Text = icon .. "  |  " .. name, Font = Enum.Font.Gotham, TextSize = 15, TextColor3 = C.text, BackgroundTransparency = 1,
		Size = UDim2.new(1, -16, 1, 0), Position = UDim2.fromOffset(16, 0), TextXAlignment = Enum.TextXAlignment.Left }, btn)
	local page = new("ScrollingFrame", { Size = UDim2.fromScale(1, 1), BackgroundTransparency = 1, BorderSizePixel = 0, ScrollBarThickness = 3,
		ScrollBarImageColor3 = C.accent, CanvasSize = UDim2.new(), AutomaticCanvasSize = Enum.AutomaticSize.Y, Visible = false }, pagesHolder)
	new("UIListLayout", { Padding = UDim.new(0, 6), SortOrder = Enum.SortOrder.LayoutOrder }, page)
	new("UIPadding", { PaddingRight = UDim.new(0, 6) }, page)
	local t = { btn = btn, page = page, n = 0 }
	btn.MouseButton1Click:Connect(function() selectTab(t) end)
	table.insert(tabs, t)

	local function item(h)
		t.n += 1
		local f = new("Frame", { Size = UDim2.new(1, 0, 0, h or 40), BackgroundColor3 = C.item, LayoutOrder = t.n }, page)
		corner(f, 8)
		return f
	end
	local function label(parent, text)
		return new("TextLabel", { Text = text, Font = Enum.Font.Gotham, TextSize = 15, TextColor3 = C.text, BackgroundTransparency = 1,
			Size = UDim2.new(0.55, 0, 1, 0), Position = UDim2.fromOffset(14, 0), TextXAlignment = Enum.TextXAlignment.Left }, parent)
	end

	function t.Section(text)
		t.n += 1
		new("TextLabel", { Text = text, Font = Enum.Font.GothamBold, TextSize = 20, TextColor3 = C.text, BackgroundTransparency = 1,
			Size = UDim2.new(1, 0, 0, 34), TextXAlignment = Enum.TextXAlignment.Left, LayoutOrder = t.n }, page)
	end

	function t.Toggle(text, get, set)
		local f = item()
		label(f, text)
		local box = new("TextButton", { Text = "", AutoButtonColor = false, Size = UDim2.fromOffset(30, 30), Position = UDim2.new(1, -40, 0.5, -15), BackgroundColor3 = C.box }, f)
		corner(box, 6)
		local tick = new("TextLabel", { Text = "✓", Font = Enum.Font.GothamBold, TextSize = 18, TextColor3 = C.text, BackgroundTransparency = 1, Size = UDim2.fromScale(1, 1) }, box)
		local function refresh() local on = get() box.BackgroundColor3 = on and C.accent or C.box tick.Visible = on end
		box.MouseButton1Click:Connect(function() set(not get()) changed() end)
		table.insert(refreshers, refresh)
		refresh()
	end

	function t.Dropdown(text, options, display, get, set)
		local f = item()
		label(f, text)
		local valueBtn = new("TextButton", { Font = Enum.Font.GothamBold, TextSize = 16, TextColor3 = C.text, AutoButtonColor = false, BackgroundColor3 = C.box,
			Size = UDim2.new(0.4, 0, 0, 30), Position = UDim2.new(0.6, -10, 0.5, -15) }, f)
		corner(valueBtn, 6)
		local list = item(0)
		list.BackgroundTransparency = 1
		list.Visible = false
		new("UIListLayout", { Padding = UDim.new(0, 4), SortOrder = Enum.SortOrder.LayoutOrder }, list)
		list.AutomaticSize = Enum.AutomaticSize.Y
		for i, opt in ipairs(options) do
			local o = new("TextButton", { Text = display(opt), Font = Enum.Font.Gotham, TextSize = 14, TextColor3 = C.text, AutoButtonColor = false,
				BackgroundColor3 = C.box, Size = UDim2.new(1, 0, 0, 30), LayoutOrder = i }, list)
			corner(o, 6)
			o.MouseButton1Click:Connect(function() set(opt) list.Visible = false changed() end)
		end
		valueBtn.MouseButton1Click:Connect(function() list.Visible = not list.Visible end)
		table.insert(refreshers, function() valueBtn.Text = display(get()) end)
		valueBtn.Text = display(get())
	end

	function t.Slider(text, min, max, get, set)
		local f = item()
		label(f, text)
		local val = new("TextLabel", { Font = Enum.Font.GothamBold, TextSize = 16, TextColor3 = C.text, BackgroundTransparency = 1,
			Size = UDim2.fromOffset(40, 40), Position = UDim2.new(0.5, -10, 0, 0), TextXAlignment = Enum.TextXAlignment.Right }, f)
		local bar = new("Frame", { Size = UDim2.new(0.42, -24, 0, 8), Position = UDim2.new(0.58, 0, 0.5, -4), BackgroundColor3 = C.box }, f)
		corner(bar, 4)
		local fill = new("Frame", { BackgroundColor3 = C.accent, Size = UDim2.fromScale(0, 1) }, bar)
		corner(fill, 4)
		local knob = new("Frame", { Size = UDim2.fromOffset(18, 18), AnchorPoint = Vector2.new(0.5, 0.5), BackgroundColor3 = C.text, Position = UDim2.fromScale(0, 0.5) }, bar)
		corner(knob, 9)
		local function refresh()
			local a = (get() - min) / (max - min)
			fill.Size, knob.Position, val.Text = UDim2.fromScale(a, 1), UDim2.fromScale(a, 0.5), tostring(get())
		end
		local dragging = false
		local function apply(x)
			local a = math.clamp((x - bar.AbsolutePosition.X) / bar.AbsoluteSize.X, 0, 1)
			set(math.floor(min + a * (max - min) + 0.5))
			refresh()
		end
		bar.InputBegan:Connect(function(i)
			if i.UserInputType == Enum.UserInputType.MouseButton1 or i.UserInputType == Enum.UserInputType.Touch then dragging = true apply(i.Position.X) end
		end)
		table.insert(S.conns, UIS.InputChanged:Connect(function(i)
			if dragging and (i.UserInputType == Enum.UserInputType.MouseMovement or i.UserInputType == Enum.UserInputType.Touch) then apply(i.Position.X) end
		end))
		table.insert(S.conns, UIS.InputEnded:Connect(function(i)
			if dragging and (i.UserInputType == Enum.UserInputType.MouseButton1 or i.UserInputType == Enum.UserInputType.Touch) then dragging = false saveCfg() end
		end))
		table.insert(refreshers, refresh)
		refresh()
	end

	function t.Button(text, cb)
		local f = item()
		local b = new("TextButton", { Text = text, Font = Enum.Font.GothamMedium, TextSize = 15, TextColor3 = C.text, BackgroundTransparency = 1, Size = UDim2.fromScale(1, 1) }, f)
		b.MouseButton1Click:Connect(cb)
	end

	function t.Paragraph(getText)
		local f = item(0)
		f.AutomaticSize = Enum.AutomaticSize.Y
		local l = new("TextLabel", { Font = Enum.Font.Gotham, TextSize = 14, TextColor3 = C.dim, BackgroundTransparency = 1, RichText = true, TextWrapped = true,
			Size = UDim2.new(1, -28, 0, 0), AutomaticSize = Enum.AutomaticSize.Y, Position = UDim2.fromOffset(14, 0),
			TextXAlignment = Enum.TextXAlignment.Left, TextYAlignment = Enum.TextYAlignment.Top }, f)
		new("UIPadding", { PaddingTop = UDim.new(0, 10), PaddingBottom = UDim.new(0, 10) }, f)
		task.spawn(function() while alive() do l.Text = getText() task.wait(0.3) end end)
	end

	return t
end

local function cfgToggle(tab, text, key) tab.Toggle(text, function() return cfg[key] end, function(v) cfg[key] = v end) end
-- modes that move the character are exclusive with the pumpkin farm
local function modeToggle(tab, text, key)
	tab.Toggle(text, function() return cfg[key] end, function(v) cfg[key] = v if v then S.pumpkin = false end end)
end

-- Home
local home = Tab("Home", "⌂")
home.Section("Status")
home.Paragraph(function()
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
home.Section("Info")
home.Paragraph(function() return "Toggle the UI with <b>RightControl</b> or the minimize button.\nSettings are saved and the script reloads itself after teleports." end)

-- Farming
local farming = Tab("Farming", "⚒")
farming.Section("Stat Farm")
modeToggle(farming, "Auto Farm Stats", "farm")
farming.Dropdown("Stat to Train", TYPES, function(v) return NAMES[v] end, function() return cfg.type end, function(v) cfg.type = v end)
cfgToggle(farming, "Auto Zenkai", "zenkai")
cfgToggle(farming, "Auto Transform", "transform")
farming.Section("World")
cfgToggle(farming, "Teleport to Best World", "world")
cfgToggle(farming, "Safe Farm (sky)", "safe")
cfgToggle(farming, "Prefer Small Servers", "small")

-- Quests
local quests = Tab("Quests", "☰")
quests.Section("Quests")
modeToggle(quests, "Auto Quests (daily + weekly)", "quests")
modeToggle(quests, "Dragon Ball Finder", "dragon")

-- Event
local event = Tab("Event", "✦")
event.Section("Halloween")
modeToggle(event, "Auto Halloween Event", "halloween")
event.Toggle("Pumpkin Farm", function() return S.pumpkin end, function(v)
	S.pumpkin = v
	target = nil
	if v then cfg.farm, cfg.dragon, cfg.quests, cfg.halloween = false, false, false, false end
end)
event.Paragraph(function() return "Lights lanterns, fights Corruptkin / Ablaze, smashes pumpkins and claims challenge rewards." end)

-- Combat
local combat = Tab("Combat", "⚔")
combat.Section("Bosses")
cfgToggle(combat, "Use Ki Skills (no melee)", "skills")
combat.Slider("Boss Distance", 40, 150, function() return cfg.bossRange end, function(v) cfg.bossRange = v end)
combat.Section("Safe Mode")
combat.Slider("Retreat at Health %", 10, 90, function() return cfg.retreatAt end, function(v) cfg.retreatAt = v end)
combat.Slider("Back at Health %", 20, 100, function() return cfg.resumeAt end, function(v) cfg.resumeAt = v end)

-- Misc
local misc = Tab("Misc", "⚙")
misc.Section("Misc")
cfgToggle(misc, "Anti-AFK", "antiAfk")
cfgToggle(misc, "Auto Reconnect", "reconnect")
misc.Button("Unload Script", function() S.Unload() end)

selectTab(tabs[1])

function S.Unload()
	G.DBRFarm = nil
	setFast(false)
	stopCharge(LP.Character and LP.Character:FindFirstChild("State"))
	for _, c in ipairs(S.conns) do c:Disconnect() end
	if S.gui then S.gui:Destroy() end
end
-- closing stops everything (including auto-travel), not just hides the window
closeBtn.MouseButton1Click:Connect(function()
	cfg.farm, cfg.dragon, cfg.quests, cfg.halloween = false, false, false, false
	saveCfg()
	S.Unload()
end)
