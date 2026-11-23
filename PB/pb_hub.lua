local VERSION = "1.4.3"
local CFG_FILE = "pg_hub_cfg.json"

local G = getgenv()
local TOKEN = {}
G.PGHubToken = TOKEN
if G.PGHub and G.PGHub.Unload then pcall(G.PGHub.Unload) end
if not game:IsLoaded() then game.Loaded:Wait() end
if G.PGHubToken ~= TOKEN then return end

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local Http = game:GetService("HttpService")
local Stats = game:GetService("Stats")
local RS = game:GetService("ReplicatedStorage")
local LP = Players.LocalPlayer
local Remotes = RS:WaitForChild("Aero"):WaitForChild("AeroRemoteServices")
local ShootRemote = Remotes.InputService.Shoot
local MeterSvc = Remotes.MeterService

local cfg = {
	green = false, timingMs = 0, fullOffset = 1.467, autoCal = false, meterCal3 = {},
	speed = false, speedMult = 1.3, infStamina = false, alwaysSprint = false,
	magnet = false, magnetRange = 25,
	autoShoot = false, shootRange = 25, antiContest = false, openDist = 6,
	dribbleGlide = false, gatherGlide = false, shotGlide = false, glideSpeed = 14, dribbleGlideSpeed = 7,
	ankle = false, ankleRange = 12, combo = "Crossover, Spin, StepBack", loopCombo = false,
	block = false, blockRange = 15, blockDelay = 170, steal = false, stealRange = 6,
	guard = false, guardHoldG = false, guardMode = "Tight", guardDist = 4, guardRange = 15,
	selfLob = false, lobRange = 15,
	fov = false, fovValue = 80, fullbright = false, noPost = false, antiAfk = false,
}
pcall(function() for k, v in pairs(Http:JSONDecode(readfile(CFG_FILE))) do cfg[k] = v end end)
for _, k in ipairs({ "green", "speed", "infStamina", "alwaysSprint", "magnet", "autoShoot", "dribbleGlide", "gatherGlide", "shotGlide", "ankle", "loopCombo", "block", "steal", "guard", "selfLob", "fov", "fullbright", "noPost", "antiAfk" }) do cfg[k] = false end
if type(cfg.meterCal3) ~= "table" then cfg.meterCal3 = {} end
local function saveCfg() pcall(writefile, CFG_FILE, Http:JSONEncode(cfg)) end

local S = { conns = {}, status = "Idle", last = "No shot yet", cfg = cfg }
G.PGHub = S
local function alive() return G.PGHub == S end
local function conn(c) table.insert(S.conns, c) return c end

local function myChar() return workspace.Characters:FindFirstChild(LP.Name) end

local CharCtrl
for _, t in ipairs(getgc(true)) do
	if type(t) == "table" and type(rawget(t, "Get")) == "function" and type(rawget(t, "loadCharacter")) == "function" then
		CharCtrl = t
		break
	end
end

local function A(model, key)
	if not model then return nil end
	if CharCtrl then
		local ok, map = pcall(CharCtrl.Get, CharCtrl)
		local st = ok and map and map[model]
		if st and st.attributes and st.attributes[key] ~= nil then return st.attributes[key] end
	end
	return model:GetAttribute(key)
end

local function hasBall(model)
	local b = A(model, "Basketball")
	return b ~= nil and b ~= false
end

local function charModels()
	if CharCtrl then
		local ok, map = pcall(CharCtrl.Get, CharCtrl)
		if ok and type(map) == "table" then
			local list = {}
			for model in pairs(map) do
				if typeof(model) == "Instance" and model.Parent then list[#list + 1] = model end
			end
			return list
		end
	end
	return workspace.Characters:GetChildren()
end

local pingMs = 60
local function readPing()
	local ok, v = pcall(function() return Stats.Network.ServerStatsItem["Data Ping"]:GetValue() end)
	if ok and v and v > 0 then pingMs = pingMs + (math.min(v, pingMs * 1.5) - pingMs) * 0.1 end
	return pingMs
end

local DEBUG = G.PGHubDebug == true
local LOG_FILE = "pg_hub_log.txt"
local function dbg(line)
	if not DEBUG then return end
	line = os.date("%H:%M:%S ") .. line
	print("[PGHub] " .. line)
	pcall(appendfile, LOG_FILE, line .. "\n")
end

local shot = nil
local lastShot = nil
local releasing = false

local function release(reason, est, lead)
	if not shot or shot.released then return end
	shot.released = true
	releasing = true
	ShootRemote:FireServer({ Shoot = false })
	releasing = false
	shot.relT, shot.reason, shot.relEst, shot.relLead, shot.relPing = os.clock() - shot.t0, reason, est, lead, pingMs
	S.last = string.format("Released %.0f ms before the top", (lead or 0) * 1000)
end

local function calKey(meterType, speed)
	return (meterType or "") .. ":" .. string.format("%.1f", tonumber(speed) or 0)
end

local function leadMs(meterType, speed)
	return readPing() * 0.4 + cfg.timingMs + (cfg.meterCal3[calKey(meterType, speed)] or 0)
end
S.leadMs = leadMs

local function check()
	if not shot or shot.released or not shot.rate then return end
	local est = shot.prev + shot.rate * (os.clock() - shot.tprev)
	shot.speed = shot.speed or tonumber(A(myChar(), "ShotSpeed")) or 1.8
	local lead = math.max(leadMs(shot.meterType, shot.speed), 0) / 1000
	local full = cfg.fullOffset
	shot.full = full
	if (full - est) / shot.rate <= lead then release("Auto release", est, lead) end
end

local TIMING = { "Very Early", "Early", "Slightly Early", "Good", "Perfect", "Slightly Late", "Late", "Very Late" }
local function logShot(s, timing, contest)
	if not DEBUG then return end
	local why
	if not s.relT then
		why = "script never released: " .. (s.rate and "meter never reached target" or "meter rate never measured (no meterOffset changes)")
	elseif timing and timing < 5 then
		why = "EARLY: released too soon -> lower lead (Timing Offset down)"
	elseif timing and timing > 5 then
		why = s.reason == "Auto release" and "LATE: released too late -> raise Timing Offset" or "LATE: meter peaked before target was reached"
	else
		why = "ok"
	end
	if s.calMs then why = why .. string.format(" | calibrated %s offset -> %d ms", calKey(s.meterType, s.speed), s.calMs) end
	local samples = {}
	for _, p in ipairs(s.samples) do samples[#samples + 1] = string.format("%.0f:%.3f", p[1] * 1000, p[2]) end
	dbg(string.format(
		"SHOT type=%s win=%s result=%s contest=%s%% green=%s | release=%s at %s ms (est %.3f / full %.3f, lead %s ms, ping %.0f, offset %d) | rate=%s speed=%s | userReleaseBlocked=%d | %s",
		tostring(s.meterType), tostring(s.win), timing and TIMING[timing] or "none", tostring(contest), tostring(s.green or false),
		tostring(s.reason or "none"), s.relT and string.format("%.0f", s.relT * 1000) or "-",
		s.relEst or -1, s.full or -1, s.relLead and string.format("%.0f", s.relLead * 1000) or "-", s.relPing or pingMs, cfg.timingMs,
		s.rate and string.format("%.3f/s", s.rate) or "-", tostring(s.speed), s.blocked, why))
	dbg("  samples(ms:offset) " .. table.concat(samples, " "))
end

local function onOffset(char)
	if not shot or shot.released then return end
	local o = char:GetAttribute("meterOffset")
	if typeof(o) ~= "Vector2" then return end
	local now = os.clock()
	local mag = math.max(math.abs(o.X), math.abs(o.Y))
	if DEBUG then table.insert(shot.samples, { now - shot.t0, mag }) end
	if shot.prev and mag < shot.prev - 1e-3 then
		release("Meter peaked (late)")
		return
	end
	if shot.prev and mag == shot.prev then return end
	if not shot.m0 then shot.m0 = mag end
	shot.steps = (shot.steps or -1) + 1
	shot.prev, shot.tprev = mag, now
	if shot.steps >= 3 then shot.rate = (mag - shot.m0) / shot.steps * 60 end
	check()
end

local function watchChar(char)
	conn(char:GetAttributeChangedSignal("meterOffset"):Connect(function() onOffset(char) end))
end

local function onRegister(model, meterType, win)
	if model ~= myChar() or not cfg.green then return end
	shot = { t0 = os.clock(), released = false, samples = {}, blocked = 0, meterType = meterType, win = win }
	lastShot = shot
	S.status = "Shot in progress"
end

local function onUnregister(model)
	if model ~= myChar() then return end
	shot = nil
	S.status = "Idle"
end

conn(MeterSvc.RegisterPacket.OnClientEvent:Connect(onRegister))
conn(MeterSvc.UnregisterPacket.OnClientEvent:Connect(onUnregister))
local IF = Remotes.InterfaceService
local lastGreenT = 0
conn(IF.ShowFeedback.OnClientEvent:Connect(function(model, contest, timing)
	if model ~= myChar() or not lastShot then return end
	local s = lastShot
	lastShot = nil
	timing = tonumber(timing)
	if timing and TIMING[timing] then
		S.last = TIMING[timing] .. (s.relLead and string.format(" - %.0f ms before the top", s.relLead * 1000) or "")
		if cfg.autoCal and s.relT and s.reason == "Auto release" and timing ~= 5 then
			local key = calKey(s.meterType, s.speed)
			local cur = cfg.meterCal3[key] or 0
			cur = math.clamp(cur + (timing - 5) * 3, -80, 80)
			cfg.meterCal3[key] = cur
			s.calMs = cur
			saveCfg()
		end
	end
	task.delay(0.4, function()
		s.green = os.clock() - lastGreenT < 1
		logShot(s, timing, contest and math.round(tonumber(contest) or 0))
	end)
end))
conn(IF.RunGreenEffect.OnClientEvent:Connect(function(model)
	if model == LP.Name or model == myChar() or model == LP then lastGreenT = os.clock() end
end))
dbg("---- loaded v" .. VERSION .. " ping " .. math.floor(readPing()) .. " offset " .. cfg.timingMs .. " full " .. cfg.fullOffset)
if myChar() then watchChar(myChar()) end
conn(workspace.Characters.ChildAdded:Connect(function(c) if c.Name == LP.Name then watchChar(c) end end))

task.spawn(function()
	while alive() do
		check()
		task.wait()
	end
end)

if not G.PGHubNC then
	G.PGHubNC = true
	local old
	old = hookmetamethod(game, "__namecall", function(self, ...)
		local H = getgenv().PGHub
		if H and H.onNamecall and not checkcaller() and getnamecallmethod() == "FireServer" and H.onNamecall(self, ...) then return end
		return old(self, ...)
	end)
end
local IS = Remotes.InputService
local sprintHeld = false
S.onNamecall = function(self, a)
	if self == IS.Sprint then
		sprintHeld = a == true
	elseif self == ShootRemote and type(a) == "table" and a.Shoot == false
		and cfg.green and shot ~= nil and not shot.released and not releasing then
		shot.blocked += 1
		return true
	end
	return false
end

local Proxy = workspace:WaitForChild("ProxyCharacter")
local MoveRemote = IS.MoveDirection
local Camera = workspace.CurrentCamera
local controls
pcall(function() controls = require(LP.PlayerScripts:WaitForChild("PlayerModule")):GetControls() end)
if setthreadidentity then pcall(setthreadidentity, 8) end

local function moveInput()
	local mv = controls and controls:GetMoveVector() or Vector3.zero
	if mv.Magnitude < 0.1 then return nil end
	local look = Camera.CFrame.LookVector * Vector3.new(1, 0, 1)
	local right = Camera.CFrame.RightVector * Vector3.new(1, 0, 1)
	if look.Magnitude < 0.01 then return nil end
	local d = right.Unit * mv.X + look.Unit * -mv.Z
	return d.Magnitude > 0.01 and d.Unit or nil
end

local GLIDE = { Dribbling = "dribbleGlide", Gathering = "gatherGlide", Shooting = "shotGlide" }
local rush = nil
conn(RunService.Stepped:Connect(function()
	local bv = Proxy:FindFirstChild("MovementVelocity")
	if not bv then return end
	if rush then
		if os.clock() > rush.untilT then
			rush = nil
			MoveRemote:FireServer(Vector3.zero)
		else
			bv.Velocity = rush.dir * 18
			return
		end
	end
	local char = myChar()
	if not char then return end
	local glideKey = GLIDE[A(char, "Action") or ""]
	if glideKey and cfg[glideKey] then
		local d = moveInput()
		if d then
			bv.MaxForce = Vector3.new(1e5, 0, 1e5)
			bv.Velocity = d * (glideKey == "dribbleGlide" and cfg.dribbleGlideSpeed or cfg.glideSpeed)
		end
		return
	end
	if not char:GetAttribute("CanMove") then return end
	local ws = math.min(char:GetAttribute("WalkSpeed") or 14, 14)
	local gTarget, gHandler, gVel
	if S.computeGuard then gTarget, gHandler, gVel = S.computeGuard() end
	S.guardTarget = gTarget
	if gTarget and not moveInput() then
		local off = (gTarget - Proxy.Position) * Vector3.new(1, 0, 1)
		local face = gHandler.HumanoidRootPart.Position * Vector3.new(1, 0, 1) + Vector3.new(0, gTarget.Y, 0)
		if cfg.guardMode == "Blatant" then
			Proxy.CFrame = CFrame.new(gTarget, face)
			local bp = Proxy:FindFirstChild("BodyPosition")
			if bp then bp.Position = gTarget end
			bv.Velocity = gVel
		else
			local cap = ws + 3.35
			local chase = off.Magnitude > 0.3 and off.Unit * math.min(off.Magnitude * 6, cap) or Vector3.zero
			local v = gVel + chase
			if v.Magnitude > cap then v = v.Unit * cap end
			if v.Magnitude > ws + 0.5 and not char:GetAttribute("Sprinting") and os.clock() - (S.guardSprintT or 0) > 0.5 then
				S.guardSprintT = os.clock()
				IS.Sprint:FireServer(true)
			end
			bv.Velocity = v
			if off.Magnitude > 6 and os.clock() - (S.guardLogT or 0) > 1 then
				S.guardLogT = os.clock()
				dbg(string.format("GUARD %s gap %.1f studs, moving %.1f studs/s", gHandler.Name, off.Magnitude, v.Magnitude))
			end
		end
		local gyro = Proxy:FindFirstChild("MovementGyro")
		if gyro and (face - gTarget).Magnitude > 0.1 then gyro.CFrame = CFrame.new(gTarget, face) end
		return
	end
	local mult = cfg.speed and cfg.speedMult or 1
	if cfg.infStamina and (sprintHeld or cfg.alwaysSprint) and (char:GetAttribute("Stamina") or 100) <= 0.25 and ws > 0 then
		mult *= (ws + 3.35) / ws
	end
	if mult == 1 then return end
	local v = bv.Velocity
	bv.Velocity = Vector3.new(v.X * mult, v.Y, v.Z * mult)
end))

local function looseBall(pos)
	local best, bd = nil, cfg.magnetRange
	for _, b in ipairs(workspace.Basketballs:GetChildren()) do
		if b:IsA("BasePart") and b:GetAttribute("Active") and not b:GetAttribute("MidShot") then
			local d = ((b.Position - pos) * Vector3.new(1, 0, 1)).Magnitude
			if d < bd then best, bd = b, d end
		end
	end
	return best
end

task.spawn(function()
	while alive() do
		local char = myChar()
		if cfg.magnet and not rush and char and not hasBall(char) and (A(char, "Action") or "") == "" then
			local b = looseBall(Proxy.Position)
			if b then
				local ballFlat = Vector3.new(b.Position.X, Proxy.Position.Y, b.Position.Z)
				local away = (Proxy.Position - ballFlat) * Vector3.new(1, 0, 1)
				local dir = away.Magnitude > 0.1 and -away.Unit or Proxy.CFrame.LookVector
				local start = ballFlat - dir * 3
				Proxy.CFrame = CFrame.new(start, start + dir)
				local bp = Proxy:FindFirstChild("BodyPosition")
				if bp then bp.Position = start end
				MoveRemote:FireServer(dir)
				rush = { dir = dir, untilT = os.clock() + 0.35 }
				dbg("MAGNET -> ball " .. tostring(b:GetAttribute("ID")) .. " dist " .. math.floor(away.Magnitude))
			end
		end
		task.wait(0.4)
	end
end)

local DribbleCfg
pcall(function() DribbleCfg = require(RS.Aero.Shared.Config.Game.Dribbling) end)
if setthreadidentity then pcall(setthreadidentity, 8) end
local MOVES = { "Crossover", "Hesitation", "BehindBack", "DoubleBehindBack", "DoubleCrossover", "Tween", "Spin", "HalfSpin", "StepBack", "SnatchBack", "Breakdown", "Combo", "SwitchHand" }

local function inputFor(move, hand)
	if move == "SwitchHand" then return "H" end
	if not DribbleCfg then return nil end
	local best
	for input, map in pairs(DribbleCfg.Input) do
		if type(map) == "table" and map[hand] == move and (not best or #input < #best) then best = input end
	end
	return best
end

local function doMove(move)
	local char = myChar()
	if not char then return false end
	local input = inputFor(move, char:GetAttribute("Hand") or "R")
	if not input then return false end
	IS.Dribble:FireServer(input, sprintHeld, moveInput() or Vector3.zero)
	return true
end

local function parseCombo()
	local list = {}
	for name in string.gmatch(cfg.combo or "", "[^,%s]+") do
		for _, m in ipairs(MOVES) do if m:lower() == name:lower() then list[#list + 1] = m end end
	end
	return list
end

local comboRunning = false
local function playCombo()
	if comboRunning then return end
	comboRunning = true
	task.spawn(function()
		repeat
			for _, m in ipairs(parseCombo()) do
				local char = myChar()
				if not alive() or not char or not hasBall(char) then break end
				doMove(m)
				task.wait(0.5)
			end
		until not (cfg.loopCombo and alive() and myChar() and hasBall(myChar()))
		comboRunning = false
	end)
end
S.playCombo = playCombo

local function others()
	local me = myChar()
	local myTeam = me and A(me, "Team") or 0
	local list = {}
	for _, c in ipairs(charModels()) do
		if c ~= me and c.Name ~= "InvisCharacter" and c:FindFirstChild("HumanoidRootPart") then
			local t = A(c, "Team")
			if myTeam == 0 or t ~= myTeam then list[#list + 1] = c end
		end
	end
	return list
end

local function flatDist(a, b) return ((a - b) * Vector3.new(1, 0, 1)).Magnitude end

local function nearestOpp(pos)
	local best, bd = nil, math.huge
	for _, c in ipairs(others()) do
		local d = flatDist(c.HumanoidRootPart.Position, pos)
		if d < bd then best, bd = c, d end
	end
	return best, bd
end

local function nearestGoal(pos)
	local best, bd = nil, math.huge
	for _, h in ipairs(workspace.Hoops:GetChildren()) do
		local g = h:FindFirstChild("Goal")
		if g then
			local d = flatDist(g.Position, pos)
			if d < bd then best, bd = g, d end
		end
	end
	return best, bd
end

local lastShootT, lastAnkleT, lastStealT = 0, 0, 0
local blockedShots = setmetatable({}, { __mode = "k" })
local fakeLogged = setmetatable({}, { __mode = "k" })
local meterSeen = setmetatable({}, { __mode = "k" })
conn(MeterSvc.RegisterPacket.OnClientEvent:Connect(function(model) if typeof(model) == "Instance" then meterSeen[model] = os.clock() end end))
conn(Remotes.GameplayService.Meter.OnClientEvent:Connect(function(on, model) if on and typeof(model) == "Instance" then meterSeen[model] = os.clock() end end))
task.spawn(function()
	while alive() do
		local me = myChar()
		local now = os.clock()
		if me then
			local pos = Proxy.Position
			local action = A(me, "Action") or ""
			local iHave = hasBall(me)
			if iHave and action == "" then
				local opp, od = nearestOpp(pos)
				if cfg.autoShoot and now - lastShootT > 1.5 then
					local _, gd = nearestGoal(pos)
					if gd <= cfg.shootRange and (not cfg.antiContest or od >= cfg.openDist) then
						lastShootT = now
						ShootRemote:FireServer({ Shoot = true, Input = "E" })
						if not cfg.green then task.delay(0.36, function() ShootRemote:FireServer({ Shoot = false }) end) end
						dbg(string.format("AUTOSHOOT goal %.1f studs, nearest opp %.1f", gd, od))
					end
				end
				if cfg.ankle and opp and od <= cfg.ankleRange and now - lastAnkleT > 1.2 and not comboRunning then
					lastAnkleT = now
					local pick = ({ "Crossover", "Spin", "BehindBack", "StepBack" })[math.random(1, 4)]
					doMove(pick)
					dbg("ANKLE " .. pick .. " vs " .. opp.Name .. string.format(" %.1f studs", od))
				end
			elseif not iHave then
				for _, c in ipairs(others()) do
					local d = flatDist(c.HumanoidRootPart.Position, pos)
					local ca = A(c, "Action") or ""
					if cfg.block and (ca == "Shooting" or ca == "Dunking" or ca == "ClutchShot") and d <= cfg.blockRange then
						local shotAt = meterSeen[c]
						local real = ca == "Dunking" or (shotAt and now - shotAt < 1.5) or A(c, "InAir") == true
						local key = tostring(A(c, "ShotStartTime") or shotAt or ca)
						if real and blockedShots[c] ~= key then
							blockedShots[c] = key
							task.delay(cfg.blockDelay / 1000, function()
								ShootRemote:FireServer({ Shoot = true, Input = "E", UseSpace = true })
								IS.Jump:FireServer()
								task.delay(0.2, function() ShootRemote:FireServer({ Shoot = false }) end)
							end)
							dbg(string.format("BLOCK %s %.1f studs (%s, meter=%s, inAir=%s)", c.Name, d, ca, tostring(shotAt ~= nil), tostring(A(c, "InAir"))))
						elseif not real and fakeLogged[c] ~= key then
							fakeLogged[c] = key
							dbg(string.format("FAKE ignored %s (%s, no meter, not in air)", c.Name, ca))
						end
					end
					if cfg.steal and hasBall(c) and d <= cfg.stealRange and now - lastStealT > 1 then
						lastStealT = now
						IS.Steal:FireServer()
						dbg("STEAL " .. c.Name .. string.format(" %.1f studs", d))
					end
				end
			end
		end
		task.wait(0.05)
	end
end)

local holdingG = false
local function setHoldG(on)
	if holdingG == on then return end
	holdingG = on
	IS.HoldG:FireServer({ HoldingG = on })
end

local guardPrev = setmetatable({}, { __mode = "k" })
function S.computeGuard()
	local me = myChar()
	if not cfg.guard or not me or hasBall(me) then return nil end
	local pos = Proxy.Position
	local best, bd = nil, cfg.guardRange
	for _, c in ipairs(others()) do
		if hasBall(c) then
			local d = flatDist(c.HumanoidRootPart.Position, pos)
			if d < bd then best, bd = c, d end
		end
	end
	if not best then return nil end
	local now = os.clock()
	local hp = best.HumanoidRootPart.Position
	local prev = guardPrev[best]
	local vel = Vector3.zero
	if prev and now > prev.t then vel = ((hp - prev.pos) / (now - prev.t)) * Vector3.new(1, 0, 1) end
	if vel.Magnitude > 25 then vel = vel.Unit * 25 end
	if prev and now - prev.t < 0.02 then
		vel = prev.vel
	else
		vel = prev and prev.vel:Lerp(vel, 0.35) or vel
		guardPrev[best] = { t = now, pos = hp, vel = vel }
	end
	local lead = pingMs / 2000 + 0.05
	local predicted = hp + vel * lead
	local goal = nearestGoal(predicted)
	if not goal then return nil end
	local toGoal = (goal.Position - predicted) * Vector3.new(1, 0, 1)
	if toGoal.Magnitude < 0.1 then return nil end
	local target = Vector3.new(predicted.X, pos.Y, predicted.Z) + toGoal.Unit * math.min(cfg.guardDist, toGoal.Magnitude)
	return target, best, vel
end

task.spawn(function()
	while alive() do
		if cfg.guard and cfg.guardHoldG then setHoldG(S.guardTarget ~= nil) elseif holdingG then setHoldG(false) end
		task.wait(0.05)
	end
end)

local lastLobT = 0
task.spawn(function()
	while alive() do
		local me = myChar()
		if cfg.selfLob and me and hasBall(me) and (A(me, "Action") or "") == "" and os.clock() - lastLobT > 2 then
			local g, gd = nearestGoal(Proxy.Position)
			local d = moveInput()
			if g and gd <= cfg.lobRange and gd > 4 and d and d:Dot(((g.Position - Proxy.Position) * Vector3.new(1, 0, 1)).Unit) > 0.6 then
				lastLobT = os.clock()
				IS.Clutch:FireServer(true)
				IS.Pass:FireServer({ Player = LP.Name, PassType = 4 })
				dbg(string.format("SELFLOB goal %.1f studs", gd))
			end
		end
		task.wait(0.05)
	end
end)

local lastSprintT = 0
task.spawn(function()
	while alive() do
		local me = myChar()
		if cfg.alwaysSprint and me and not me:GetAttribute("Sprinting") and moveInput() and os.clock() - lastSprintT > 0.5 then
			lastSprintT = os.clock()
			IS.Sprint:FireServer(true)
		end
		task.wait(0.1)
	end
end)

local Lighting = game:GetService("Lighting")
local lightBackup, postBackup = nil, {}
local function applyLighting()
	if cfg.fullbright then
		if not lightBackup then
			lightBackup = { Brightness = Lighting.Brightness, ClockTime = Lighting.ClockTime, FogEnd = Lighting.FogEnd, GlobalShadows = Lighting.GlobalShadows, Ambient = Lighting.Ambient }
		end
		Lighting.Brightness, Lighting.ClockTime, Lighting.FogEnd, Lighting.GlobalShadows, Lighting.Ambient = 2, 14, 1e5, false, Color3.new(1, 1, 1)
	elseif lightBackup then
		for k, v in pairs(lightBackup) do Lighting[k] = v end
		lightBackup = nil
	end
	for _, e in ipairs(Lighting:GetDescendants()) do
		if e:IsA("PostEffect") or e:IsA("Atmosphere") then
			if cfg.noPost then
				if postBackup[e] == nil and e:IsA("PostEffect") then postBackup[e] = e.Enabled e.Enabled = false end
			elseif postBackup[e] ~= nil then
				e.Enabled = postBackup[e]
				postBackup[e] = nil
			end
		end
	end
end
S.applyLighting = applyLighting

local defaultFov = Camera.FieldOfView
conn(RunService.RenderStepped:Connect(function()
	if cfg.fov then Camera.FieldOfView = cfg.fovValue end
	if cfg.fullbright then Lighting.ClockTime = 14 end
end))

local VirtualUser = game:GetService("VirtualUser")
conn(LP.Idled:Connect(function()
	if not cfg.antiAfk then return end
	pcall(function()
		VirtualUser:CaptureController()
		VirtualUser:ClickButton2(Vector2.new())
	end)
end))

local Library = loadstring(game:HttpGet("https://raw.githubusercontent.com/mechupacristopher-creator/lua/main/lib/eze_ui.lua"))()
if not alive() then pcall(function() Library:Unload() end) return end
S.lib = Library

local function setCfg(key)
	return function(v) if cfg[key] ~= v then cfg[key] = v saveCfg() end end
end

local function liveLabel(sec, getText)
	local l = sec:Label({ name = getText() })
	task.spawn(function()
		while alive() do
			pcall(l.set, getText())
			task.wait(0.2)
		end
	end)
end

local win = Library:window({ name = "Eze Hub" })

local shootTab = win:Tab({ name = "Shooting", icon = "lucide:crosshair" })
local ag = shootTab:Section({ name = "Auto Green", side = "left" })
S.greenToggle = ag:Toggle({ name = "Auto Green", default = false, Callback = setCfg("green") })
ag:Slider({ name = "Timing Offset (ms)", min = -80, max = 80, default = cfg.timingMs, decimals = 0,
	Callback = function(v) setCfg("timingMs")(math.floor(v + 0.5)) end })
ag:Label({ name = "Hold or tap E. Late? Raise the offset. Early? Lower it." })
local cal = shootTab:Section({ name = "Auto Calibrate", side = "left" })
cal:Toggle({ name = "Auto Calibrate", default = cfg.autoCal, Callback = setCfg("autoCal") })
cal:Label({ name = "Learns from every Early / Late result, separately for each meter." })
cal:Button({ name = "Reset Timing", Callback = function()
	cfg.meterCal3 = {}
	saveCfg()
	Library:create_notification({ name = "Timing reset", duration = 2 })
end })
local st = shootTab:Section({ name = "Status", side = "right" })
liveLabel(st, function() return S.status end)
liveLabel(st, function() return "Last shot: " .. S.last end)
liveLabel(st, function() return string.format("Ping %.0f ms - going %.0f ms early", pingMs, math.max(leadMs("Vertical", 1.8), 0)) end)

local function toggle(sec, name, key)
	return sec:Toggle({ name = name, default = false, Callback = setCfg(key) })
end
local function slider(sec, name, min, max, key, dec)
	return sec:Slider({ name = name, min = min, max = max, default = cfg[key], decimals = dec or 0, Callback = setCfg(key) })
end

local as = shootTab:Section({ name = "Auto Shoot", side = "right" })
toggle(as, "Auto Shoot", "autoShoot")
slider(as, "Range (studs)", 5, 40, "shootRange")
toggle(as, "Anti Contest", "antiContest")
slider(as, "Min Open Space (studs)", 2, 15, "openDist")
local sg = shootTab:Section({ name = "Shot Glide", side = "right" })
local sl = shootTab:Section({ name = "Auto Self Lob", side = "left" })
toggle(sl, "Auto Self Lob", "selfLob")
slider(sl, "Lob Range (studs)", 6, 25, "lobRange")
sl:Label({ name = "Throws yourself a lob when you drive at the rim. Jump to catch and dunk." })
toggle(sg, "Shot Glide", "shotGlide")
toggle(sg, "Gather Glide", "gatherGlide")
slider(sg, "Glide Speed", 4, 20, "glideSpeed")

local dribTab = win:Tab({ name = "Dribbling", icon = "lucide:footprints" })
local dg = dribTab:Section({ name = "Dribble", side = "left" })
toggle(dg, "Dribble Glide", "dribbleGlide")
slider(dg, "Dribble Glide Speed", 2, 14, "dribbleGlideSpeed")
toggle(dg, "Auto Ankle Breaker", "ankle")
slider(dg, "Ankle Range (studs)", 4, 20, "ankleRange")
local cb = dribTab:Section({ name = "Combos", side = "right" })
cb:Textbox({ name = "Combo", placeholder = cfg.combo, Callback = function(t) if t ~= "" then setCfg("combo")(t) end end })
cb:Label({ name = "Moves: " .. table.concat(MOVES, ", ") })
cb:Button({ name = "Play Combo", Callback = playCombo })
cb:Keybind({ name = "Combo Key", default = Enum.KeyCode[cfg.comboKey or "J"] or Enum.KeyCode.J, Callback = function(k) setCfg("comboKey")(k.Name) end })
toggle(cb, "Loop Combo", "loopCombo")
conn(game:GetService("UserInputService").InputBegan:Connect(function(input, gpe)
	if not gpe and input.KeyCode.Name == (cfg.comboKey or "J") then playCombo() end
end))

local defTab = win:Tab({ name = "Defense", icon = "lucide:shield" })
local bk = defTab:Section({ name = "Auto Block", side = "left" })
toggle(bk, "Auto Block", "block")
slider(bk, "Range (studs)", 5, 25, "blockRange")
slider(bk, "Block Delay (ms)", 0, 500, "blockDelay")
local stl = defTab:Section({ name = "Steal & Rebound", side = "right" })
toggle(stl, "Auto Steal", "steal")
slider(stl, "Steal Range (studs)", 3, 12, "stealRange")
local gd = defTab:Section({ name = "Auto Guard", side = "left" })
toggle(gd, "Auto Guard", "guard")
toggle(gd, "Auto Hold G", "guardHoldG")
gd:Dropdown({ name = "Mode", items = { "Tight", "Blatant" }, default = cfg.guardMode, Callback = setCfg("guardMode") })
slider(gd, "Distance (studs)", 2, 10, "guardDist")
slider(gd, "Guard Range (studs)", 6, 30, "guardRange")
gd:Label({ name = "Locks onto whoever has the ball, between them and the hoop. Tight never goes faster than a normal sprint. Blatant snaps to them (risky). Move yourself to take over. Pair with Auto Block: fakes are ignored." })
toggle(stl, "Auto Rebound", "magnet")
slider(stl, "Rebound Range (studs)", 5, 80, "magnetRange")

local plTab = win:Tab({ name = "Player", icon = "lucide:user" })
local mv = plTab:Section({ name = "Movement", side = "left" })
toggle(mv, "Speed Boost", "speed")
slider(mv, "Multiplier", 1, 2, "speedMult", 2)
toggle(mv, "Infinite Stamina", "infStamina")
toggle(mv, "Always Sprint", "alwaysSprint")
local cam = plTab:Section({ name = "Camera & World", side = "right" })
toggle(cam, "Custom FOV", "fov")
slider(cam, "Field of View", 40, 120, "fovValue")
cam:Toggle({ name = "Fullbright", default = false, Callback = function(v) setCfg("fullbright")(v) applyLighting() end })
cam:Toggle({ name = "Remove Post Effects", default = false, Callback = function(v) setCfg("noPost")(v) applyLighting() end })
toggle(cam, "Anti AFK", "antiAfk")

local miscTab = win:Tab({ name = "Misc", icon = "lucide:info" })
local actions = miscTab:Section({ name = "Script", side = "left" })
actions:Label({ name = "v" .. VERSION .. " - RightControl toggles the UI" })
actions:Button({ name = "Unload Script", Callback = function() S.Unload() end })

function S.Unload()
	if G.PGHub == S then G.PGHub = nil end
	for _, c in ipairs(S.conns) do pcall(function() c:Disconnect() end) end
	cfg.fullbright, cfg.noPost = false, false
	pcall(setHoldG, false)
	pcall(applyLighting)
	Camera.FieldOfView = defaultFov
	pcall(function() Library:Unload() end)
end

Library:create_notification({ name = "Eze Hub loaded - RightControl to toggle", duration = 4 })
