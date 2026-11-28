local VERSION = "1.0.0"
local CFG_FILE = "illegalsoccer_hub_cfg.json"
local LOG_FILE = "illegalsoccer_shotlog.txt"

local G = getgenv()
local TOKEN = {}
G.EzeISToken = TOKEN
if G.EzeIS and G.EzeIS.Unload then pcall(G.EzeIS.Unload) end
if not game:IsLoaded() then game.Loaded:Wait() end
if G.EzeISToken ~= TOKEN then return end

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local Http = game:GetService("HttpService")
local RS = game:GetService("ReplicatedStorage")
local LP = Players.LocalPlayer

local Mods = RS:WaitForChild("Modules")
local Cli = RS:WaitForChild("Client")
local Proto = require(Mods.Actions.ActionRemoteProtocol)
local Cmds = require(Mods.Actions.ActionCommands)
local AM = require(Mods.Actions.ActionMovement)
local Controls = require(Mods.Gameplay.Controls)
local CurvedKicks = require(Mods.CurvedKicks)
local Renderer = require(Cli.Gameplay.Ball.Renderer)
local SprintC = require(Cli.Gameplay.Player.Sprint)
local GKRole = require(Cli.Gameplay.Player.GoalkeeperRole)
local DodgeC = require(Cli.Gameplay.Actions.Dodge)
local Teams = require(Cli.Gameplay.ActorTeams)
local AEScript = Mods.Characters.AntiExploitSettings
if setthreadidentity then pcall(setthreadidentity, 8) end

local cfg = {
	silentAim = false, corner = "Away From Keeper", height = "Top", inset = 3,
	curve = false, curveAmount = 1, curveStyle = "Into Corner",
	aimbot = false,
	infStamina = false,
	speedOn = false, speed = 1.5, gkSpeedOn = false, gkSpeed = 1.5,
	autoDribble = false, dribbleRange = 14,
	reach = false, reachDist = 4.5,
	tackleAssist = false, tackleRange = 20,
	flickAssist = false, flickReach = 10,
}
pcall(function() for k, v in pairs(Http:JSONDecode(readfile(CFG_FILE))) do if cfg[k] ~= nil then cfg[k] = v end end end)
cfg.speed, cfg.gkSpeed = math.clamp(cfg.speed, 1, 3), math.clamp(cfg.gkSpeed, 1, 3)
cfg.reachDist = math.clamp(cfg.reachDist, 3, 5)
local function saveCfg() pcall(writefile, CFG_FILE, Http:JSONEncode(cfg)) end

local S = { conns = {}, restore = {}, cfg = cfg, aimed = 0, dribbles = 0, reaches = 0, tackles = 0, lastShot = "-", curveSign = 1 }
G.EzeIS = S
local function alive() return G.EzeIS == S end
local function conn(c) table.insert(S.conns, c) return c end
local function patch(tbl, key, make)
	local orig = tbl[key]
	tbl[key] = make(orig)
	table.insert(S.restore, function() tbl[key] = orig end)
end

local function myRoot()
	local c = LP.Character
	return c and c:FindFirstChild("HumanoidRootPart"), c
end

local function flat(v)
	local f = Vector3.new(v.X, 0, v.Z)
	return f.Magnitude > 1e-4 and f.Unit or nil
end

local function isGoalkeeper()
	local c = LP.Character
	if c and c:GetAttribute("ActiveGoalkeeper") == true then return true end
	local ok, r = pcall(GKRole.IsGoalkeeper)
	return ok and r == true
end

local function myTeam()
	local ok, t = pcall(Teams.GetCharacterTeamName, LP.Character)
	return ok and t or nil
end

local function otherCharacters()
	local list = {}
	local chars = workspace:FindFirstChild("Characters")
	if not chars then return list end
	local mine, team = LP.Character, myTeam()
	for _, folder in ipairs(chars:GetChildren()) do
		for _, m in ipairs(folder:GetChildren()) do
			local r = m ~= mine and m:IsA("Model") and m:FindFirstChild("HumanoidRootPart")
			if r then
				local ok, t = pcall(Teams.GetCharacterTeamName, m)
				local enemy = not (team and ok and t and t == team)
				table.insert(list, { model = m, root = r, enemy = enemy })
			end
		end
	end
	return list
end

local function goalParts()
	local list = {}
	local map = workspace:FindFirstChild("Map")
	local data = map and map:FindFirstChild("Data")
	if data then
		for _, t in ipairs(data:GetChildren()) do
			local g = t:FindFirstChild("Goal")
			if g and g:IsA("BasePart") then table.insert(list, g) end
		end
	end
	local lobby = workspace:FindFirstChild("Lobby")
	local pr = lobby and lobby:FindFirstChild("Practice")
	local pg = pr and pr:FindFirstChild("Goals")
	if pg then
		for _, d in ipairs(pg:GetDescendants()) do
			if d.Name == "Goal" and d:IsA("BasePart") then table.insert(list, d) end
		end
	end
	return list
end

local function pickGoal(origin)
	local look = flat(workspace.CurrentCamera.CFrame.LookVector)
	if not look then return end
	local team = myTeam()
	local best, bestDot
	for _, g in ipairs(goalParts()) do
		local to = g.Position - origin
		local d = flat(to)
		if d and to.Magnitude < 260 and not (team and g.Parent and g.Parent.Name == team) then
			local dot = d:Dot(look)
			if dot > 0.3 and (not bestDot or dot > bestDot) then best, bestDot = g, dot end
		end
	end
	return best
end

local function aimTarget(origin)
	local g = pickGoal(origin)
	if not g then return end
	local cf, sz = g.CFrame, g.Size
	local wAxis, wHalf, dAxis, dHalf
	if sz.X >= sz.Z then
		wAxis, wHalf, dAxis, dHalf = cf.RightVector, sz.X / 2, cf.LookVector, sz.Z / 2
	else
		wAxis, wHalf, dAxis, dHalf = cf.LookVector, sz.Z / 2, cf.RightVector, sz.X / 2
	end
	local toO = origin - cf.Position
	local n = toO:Dot(dAxis) >= 0 and dAxis or -dAxis
	local mouth = cf.Position + n * dHalf
	local inset = math.clamp(cfg.inset, 0.5, wHalf - 1)
	local y = cfg.height == "Top" and (cf.Position.Y + sz.Y / 2 - inset) or (cf.Position.Y - sz.Y / 2 + 1.5)
	local lateral = toO:Dot(wAxis)
	local s = lateral >= 0 and -1 or 1
	if cfg.corner == "Near Corner" then
		s = -s
	elseif cfg.corner == "Away From Keeper" then
		for _, o in ipairs(otherCharacters()) do
			local rel = o.root.Position - mouth
			if o.enemy and math.abs(rel:Dot(n)) < 14 and math.abs(rel:Dot(wAxis)) < wHalf + 4 then
				s = rel:Dot(wAxis) >= 0 and -1 or 1
				break
			end
		end
	end
	local inner = mouth - n * math.min(3, dHalf)
	local p = Vector3.new(inner.X, y, inner.Z) + wAxis * s * (wHalf - inset)
	return p, wAxis * s, n
end

local function shotOrigin()
	local bp = Renderer.GetPosition()
	local root = myRoot()
	if bp and root and (bp - root.Position).Magnitude < 12 then return bp end
	return root and (root.Position - Vector3.new(0, 2, 0) + root.CFrame.LookVector * 2)
end

local function curveFor(origin, target, cornerVec)
	if not cfg.curve or not CurvedKicks.IsEnabled() then return 0 end
	local d = flat(target - origin)
	if not d then return 0 end
	local right = d:Cross(Vector3.yAxis)
	local side = cornerVec:Dot(right) >= 0 and 1 or -1
	local style = cfg.curveStyle == "Into Corner" and 1 or -1
	return math.clamp(cfg.curveAmount, 0, 1) * side * style
end

local ChargePathVelocity = require(Mods.Actions.ChargePathVelocity)
local ShootShared = require(Mods.Actions.Shoot)
local Physics = require(Mods.Ball.Physics)
local ChargePathPreview = require(Cli.Gameplay.Actions.ChargePathPreview)

local function chargeSeconds()
	local o = S.chargeObj
	if o then
		local ok, s = pcall(function() return o.GetChargeSecondsFromPower(o.GetCurrentPower()) end)
		if ok and type(s) == "number" and s > 0 then return s end
	end
	return 0.4
end

local function reportedVelocity()
	local o = S.chargeObj
	if o and o.GetReportedVelocity then
		local ok, v = pcall(o.GetReportedVelocity)
		if ok and typeof(v) == "Vector3" then return v end
	end
	local root = myRoot()
	local v = root and root.AssemblyLinearVelocity or Vector3.zero
	return Vector3.new(v.X, 0, v.Z)
end

local function q(f, ...)
	if not f then return false end
	local ok, r = pcall(f, ...)
	return ok and r == true
end

local function shotKind()
	local o = S.chargeObj
	if o and q(o.IsHeadbuttCharge) then return "header" end
	if o and q(o.IsBicycleKickCharge) then return "bicycle" end
	if S.shootClient and q(S.shootClient.IsVolleyCharging) then return "volley" end
	return "ground"
end

local function launchVelocity(char, secs, ray, start, vel0, curve, bw)
	if S.velFn then
		if S.setClientCurve then S.setClientCurve(curve) end
		local ok, v = pcall(S.velFn, char, secs, ray, start, vel0)
		if ok and typeof(v) == "Vector3" then return v end
	end
	return ChargePathVelocity.GetLaunchVelocity(char, secs, Cmds.PassTypes.Shot, ray, start, vel0, flat(ray.Direction), nil, nil, bw, nil, curve)
end

local function simCross(char, start, cam, aim, curve, secs, vel0, bw, target, n, baseRay)
	local ray = baseRay and table.clone(baseRay) or { IsAirborne = false }
	ray.Origin, ray.Direction, ray.CameraCFrame = cam, (aim - cam).Unit, CFrame.lookAt(cam, aim)
	ray.TargetPosition, ray.ClientHit = nil, nil
	local c = curve
	local vel = launchVelocity(char, secs, ray, start, vel0, c, bw)
	if typeof(vel) ~= "Vector3" then return end
	local spin = ShootShared.GetSpin(char, vel, vel0, c, secs)
	local st = Physics.NewState(start, vel, Physics.BallRadius, 0, spin)
	local prev, pd = start, (start - target):Dot(n)
	local closest, closestD = start, pd
	local s = st
	for i = 1, 55 do
		s = Physics.GetStateAtTime(s, i * 0.08, bw)
		local p = s and s.Position
		if not p then break end
		local d = (p - target):Dot(n)
		if d <= 0 then return prev:Lerp(p, pd / (pd - d)), true, vel end
		if d < closestD then closest, closestD = p, d end
		prev, pd = p, d
	end
	return closest, false, vel
end

local function shotStart(origin)
	local char = LP.Character
	local start = origin
	if S.startFn and S.charging then
		local ok, p = pcall(S.startFn, char)
		if ok and typeof(p) == "Vector3" then start = p end
	end
	local kind = shotKind()
	if kind == "volley" or kind == "bicycle" then
		local okV, contact = pcall(function()
			local st = Renderer.GetMovementState()
			if type(st) ~= "table" then return nil end
			local arr = S.chargeObj and S.chargeObj.GetVolleyArrivalTime and S.chargeObj.GetVolleyArrivalTime()
			arr = arr or st.VolleyArriveAt
			local now = workspace:GetServerTimeNow()
			if type(arr) ~= "number" or arr - now < 0.05 then return Renderer.GetPosition() end
			local at = Physics.GetStateAtTime(st, arr, ChargePathPreview.GetChargeBoundaryWorld(LP))
			return at and at.Position
		end)
		if okV and typeof(contact) == "Vector3" then start = contact end
	end
	return start, kind
end

local function solvePlan(secsOverride, startOverride)
	local origin = shotOrigin()
	if not origin then return end
	local target, cornerVec, n = aimTarget(origin)
	if not target then return end
	local char = LP.Character
	local start = startOverride or shotStart(origin)
	local baseRay = S.lastRay
	local cam = baseRay and typeof(baseRay.Origin) == "Vector3" and baseRay.Origin or workspace.CurrentCamera.CFrame.Position
	local secs, vel0 = secsOverride or chargeSeconds(), reportedVelocity()
	local bw = ChargePathPreview.GetChargeBoundaryWorld(LP)
	local kind = shotKind()
	local base = kind == "header" and 0 or curveFor(start, target, cornerVec)
	local warm = S.warm
	if warm and ((warm.target - target).Magnitude > 3 or warm.base ~= base) then warm = nil end
	local scales = { 1, 0.6, 0.3, 0 }
	local first = warm and table.find(scales, warm.scale) or 1
	local u = n:Cross(Vector3.yAxis)
	u = u.Magnitude > 1e-3 and u.Unit or Vector3.xAxis
	local function toPlane(v) return Vector2.new(v:Dot(u), v.Y) end
	local budget = 18
	local best
	for si = first, #scales do
		local scale = scales[si]
		local curve = base * scale
		if si == first or base ~= 0 then
			local aim = (warm and si == first) and (target + warm.offset) or target
			local J = { 1.4, 0, 0, 1.4 }
			local prevAim, prevE
			for _ = 1, 8 do
				if budget <= 0 then break end
				budget -= 1
				local hit, crossed, launchVel = simCross(char, start, cam, aim, curve, secs, vel0, bw, target, n, baseRay)
				if not hit then break end
				local e3 = target - hit
				e3 = e3 - n * e3:Dot(n)
				local e = toPlane(e3)
				local err = crossed and e.Magnitude or math.huge
				if not best or err < best.err then
					best = { aim = aim, curve = curve, target = target, n = n, origin = start, err = err, cam = cam, kind = kind, scale = scale, vel = launchVel, secs = secs }
				end
				if err < 0.4 then break end
				if prevAim and crossed then
					local da = toPlane(aim - prevAim)
					local dh = prevE - e
					local predicted = Vector2.new(J[1] * dh.X + J[2] * dh.Y, J[3] * dh.X + J[4] * dh.Y)
					local denom = dh:Dot(dh)
					if denom > 1e-4 then
						local corr = (da - predicted) / denom
						J = { J[1] + corr.X * dh.X, J[2] + corr.X * dh.Y, J[3] + corr.Y * dh.X, J[4] + corr.Y * dh.Y }
					end
				end
				prevAim, prevE = aim, e
				local step = Vector2.new(J[1] * e.X + J[2] * e.Y, J[3] * e.X + J[4] * e.Y)
				if step.Magnitude > 30 then step = step.Unit * 30 end
				aim = aim + u * step.X + Vector3.yAxis * step.Y
			end
			if best and best.err < 1.5 and best.scale == scale then
				S.warm = { target = target, base = base, scale = scale, offset = best.aim - target }
				return best
			end
		end
		if base == 0 or budget <= 0 then break end
	end
	S.warm = nil
	if best and best.err < 5 then return best end
	if best then best.aim, best.curve = target, 0 end
	return best
end

local planCache, planAt = nil, 0
local function getPlan(fresh, secs)
	if not (cfg.silentAim or cfg.aimbot) then return nil end
	local curSecs = secs or chargeSeconds()
	local age = os.clock() - planAt
	local need = fresh or not planCache or age > 0.1
	if not need and planCache.secs and math.abs(planCache.secs - curSecs) > 0.015 then need = true end
	local curStart
	if not need and not secs then
		local origin = shotOrigin()
		curStart = origin and shotStart(origin)
		if curStart and planCache.origin and (curStart - planCache.origin).Magnitude > 0.5 then need = true end
	end
	if need then
		local ok, p = pcall(solvePlan, curSecs, curStart)
		planCache, planAt = ok and p or nil, os.clock()
		if S.setClientCurve then S.setClientCurve(planCache and planCache.curve or 0) end
	end
	return planCache
end
S.getPlan = getPlan

local function logLine(s)
	pcall(function()
		if appendfile and isfile and isfile(LOG_FILE) then appendfile(LOG_FILE, s .. "\n") else writefile(LOG_FILE, s .. "\n") end
	end)
end

local function watchShot(origin, target, n, curve)
	task.spawn(function()
		local t0 = os.clock()
		local mid, best, bestD
		local d = flat(target - origin)
		local right = d and d:Cross(Vector3.yAxis)
		local total = d and (target - origin):Dot(d) or 0
		while os.clock() - t0 < 3 and alive() do
			task.wait()
			local p = Renderer.GetPosition()
			if p and d then
				local along = (p - origin):Dot(d)
				if not mid and along >= total * 0.5 then mid = (p - origin):Dot(right) - (target - origin):Dot(right) * 0.5 end
				local dist = (p - target).Magnitude
				if not bestD or dist < bestD then best, bestD = p, dist end
			end
		end
		local msg
		if best then
			local off = best - target
			local short = (best - target):Dot(n)
			msg = string.format("%s, closest %.1f studs (side %.1f, h %.1f), curve %s", short > 1 and string.format("stopped %.0f studs before the target (save/post?)", short) or "reached target depth", bestD, off:Dot(right), off.Y, curve and string.format("%.2f", curve) or "none")
		else
			msg = "no ball data"
		end
		S.lastShot = msg
		logLine(os.date("%H:%M:%S ") .. msg)
	end)
end

local function aimedRay(ray, plan)
	if not cfg.silentAim or type(ray) ~= "table" or not plan then return ray end
	local cam = typeof(ray.Origin) == "Vector3" and ray.Origin or workspace.CurrentCamera.CFrame.Position
	local new = table.clone(ray)
	new.Direction = (plan.aim - cam).Unit
	new.CameraCFrame = CFrame.lookAt(cam, plan.aim)
	new.TargetPosition = nil
	new.ClientHit = nil
	return new
end

local function activeCurve()
	local plan = getPlan()
	return plan and plan.curve
end

S.shootClient = require(Cli.Gameplay.Actions.Shoot)

local function hookCharge()
	local chargeObj, curveFn, velFn, startFn
	for _, f in ipairs(getgc(false)) do
		if type(f) == "function" and islclosure(f) and debug.info(f, "s") == "ReplicatedStorage.Client.Gameplay.Actions.Shoot" then
			local n = debug.info(f, "n")
			if n == "IsCharging" then chargeObj = debug.getupvalue(f, 1) end
			if n == "GetCurve" then curveFn = f end
			if n == "GetVelocity" then velFn = f end
			if n == "getReleaseStartPosition" then startFn = f end
		end
	end
	if type(chargeObj) ~= "table" or not rawget(chargeObj, "GetChargeAimRay") or not curveFn then return false end
	S.chargeObj, S.velFn, S.startFn = chargeObj, velFn, startFn
	local function setClientCurve(c)
		if c then pcall(debug.setupvalue, curveFn, 1, c) end
	end
	S.setClientCurve = setClientCurve
	patch(chargeObj, "GetChargeAimRay", function(orig)
		return function(...)
			local ray = orig(...)
			if not alive() or type(ray) ~= "table" or not cfg.silentAim then return ray end
			S.lastRay = ray
			local plan = getPlan()
			local ok2, r = pcall(aimedRay, ray, plan)
			return ok2 and r or ray
		end
	end)
	patch(chargeObj, "GetLockedCurve", function(orig)
		return function(...)
			if alive() then
				local ok, c = pcall(activeCurve)
				if ok and c then return c end
			end
			return orig(...)
		end
	end)
	return true
end
task.spawn(function()
	while alive() and not S.chargeHooked do
		S.chargeHooked = hookCharge()
		if not S.chargeHooked then task.wait(3) end
	end
end)

local function isShotCommand(cmd)
	if type(cmd) ~= "table" or cmd.PassType ~= Cmds.PassTypes.Shot then return false end
	return cmd.Kind == Cmds.Kinds.Kick or (cmd.Kind == Cmds.Kinds.Tackle and cmd.Mode == Cmds.Modes.Volley)
end

local function rewrite(cmd, phase)
	if not isShotCommand(cmd) then return end
	local plan
	if phase == "Release" then
		local secs = type(cmd.ChargeSeconds) == "number" and cmd.ChargeSeconds or nil
		if planCache and os.clock() - planAt < 0.25 and (not secs or not planCache.secs or math.abs(planCache.secs - secs) <= 0.015) then
			plan = planCache
		else
			plan = getPlan(true, secs)
		end
	else
		plan = getPlan()
	end
	if not plan then return end
	if cfg.silentAim then
		if type(cmd.AimDirection) == "table" then cmd.AimDirection = aimedRay(cmd.AimDirection, plan) end
		local kd = flat(plan.aim - plan.origin)
		if kd and typeof(cmd.KickDirection) == "Vector3" then cmd.KickDirection = kd end
	end
	cmd.Curve = plan.curve ~= 0 and plan.curve or nil
	if phase == "Release" then
		S.aimed += 1
		watchShot(plan.origin, plan.target, plan.n, cmd.Curve)
		local relAt = workspace:GetServerTimeNow()
		task.spawn(function()
			for _ = 1, 90 do
				task.wait()
				local st = Renderer.GetMovementState()
				if type(st) == "table" and st.StartedAt and st.StartedAt >= relAt - 0.3 and typeof(st.InitialVelocity) == "Vector3" and st.InitialVelocity.Magnitude > 5 then
					logLine(string.format("  debug %s err %.2f secs %.2f | predicted start %s vel %s | server start %s vel %s | cmd secs %s", tostring(plan.kind), plan.err, plan.secs or -1, tostring(plan.origin), tostring(plan.vel), tostring(st.InitialPosition), tostring(st.InitialVelocity), tostring(cmd.ChargeSeconds)))
					return
				end
			end
			logLine("  debug: no launch seen, kind " .. tostring(plan.kind))
		end)
	end
end

for _, name in ipairs({ "Start", "Update", "LockAim", "Release", "Send" }) do
	patch(Proto, name, function(orig)
		return function(cmd, ...)
			if alive() then
				if type(cmd) == "table" and cmd.Kind == Cmds.Kinds.RainbowFlick then S.flickUntil, S.flickSnapped = os.clock() + 2.2, false logLine(os.date("%H:%M:%S ") .. "flick detected (" .. name .. ")") end
				pcall(rewrite, cmd, name)
				if isShotCommand(cmd) then
					if name == "Start" then S.charging = true elseif name == "Release" then S.charging = false end
				end
			end
			return orig(cmd, ...)
		end
	end)
end
patch(Proto, "Cancel", function(orig)
	return function(...)
		S.charging = false
		return orig(...)
	end
end)

local AIMBOT_BIND = "EzeISAimbot"
RunService:BindToRenderStep(AIMBOT_BIND, Enum.RenderPriority.Camera.Value + 2, function()
	if not cfg.aimbot or not S.charging then return end
	local plan = getPlan()
	if not plan then return end
	if S.setClientCurve then S.setClientCurve(plan.curve) end
	local cam = workspace.CurrentCamera
	cam.CFrame = CFrame.lookAt(cam.CFrame.Position, plan.aim)
end)
table.insert(S.restore, function() pcall(RunService.UnbindFromRenderStep, RunService, AIMBOT_BIND) end)

local function applyStamina()
	pcall(SprintC.SetUnlimitedStamina, "EzeHub", cfg.infStamina and alive())
end
table.insert(S.restore, function() pcall(SprintC.SetUnlimitedStamina, "EzeHub", false) end)

patch(AM, "GetBaseWalkSpeed", function(orig)
	return function(char, ...)
		local v = orig(char, ...)
		if alive() and char ~= nil and char == LP.Character then
			if isGoalkeeper() then
				if cfg.gkSpeedOn then return v * cfg.gkSpeed end
			elseif cfg.speedOn then
				return v * cfg.speed
			end
		end
		return v
	end
end)

local FAKE_DRIBBLE = { KeyCode = Enum.KeyCode.Unknown, UserInputType = Enum.UserInputType.Keyboard, UserInputState = Enum.UserInputState.Change, Position = Vector3.zero }
patch(Controls, "IsInput", function(orig)
	return function(name, input, ...)
		if input == FAKE_DRIBBLE then return name == "Dribble" end
		return orig(name, input, ...)
	end
end)

local SlideTackle = require(Mods.Actions.SlideTackle)
local lastDribbleTry = 0

local function tackleThreat(o, root)
	if not o.enemy or not SlideTackle.GetSlidingUntil(o.model) then return false end
	local rel = root.Position - o.root.Position
	local flatRel = Vector3.new(rel.X, 0, rel.Z)
	local dist = flatRel.Magnitude
	if dist > cfg.dribbleRange then return false end
	if dist < 3 then return true end
	local v = o.root.AssemblyLinearVelocity
	local dir = flat(v.Magnitude > 4 and v or o.root.CFrame.LookVector)
	return dir ~= nil and dir:Dot(flatRel.Unit) > 0.5
end

local function tryDribble(force)
	if not cfg.autoDribble or os.clock() - lastDribbleTry < 0.1 then return end
	if Renderer.GetOwnedUserId() ~= LP.UserId then return end
	local root = myRoot()
	if not root then return end
	for _, o in ipairs(otherCharacters()) do
		if (force == nil or force == o.model) and tackleThreat(o, root) then
			lastDribbleTry = os.clock()
			local before = LP.Character and LP.Character:GetAttribute("Dribbling")
			pcall(DodgeC.HandleInputBegan, FAKE_DRIBBLE, false)
			task.defer(function()
				if LP.Character and LP.Character:GetAttribute("Dribbling") and not before then S.dribbles += 1 end
			end)
			return
		end
	end
end

conn(SlideTackle.SlidingUntilChanged.Event:Connect(function(char)
	if typeof(char) == "Instance" and char ~= LP.Character then tryDribble(char) end
end))
conn(RunService.Heartbeat:Connect(function() tryDribble(nil) end))

local SlideInput = require(Cli.Gameplay.Actions.SlideTackleInput)
local CharCtl = require(Mods.Characters.CharacterControllers)
local Actors = require(Mods.Characters.Actors)

local function tackleAimDir()
	local uid = Renderer.GetOwnedUserId()
	if not uid or uid == LP.UserId then return end
	local ok, ch = pcall(function() return Actors.GetCharacter(Actors.GetByUserId(uid)) end)
	local r = ok and ch and ch:FindFirstChild("HumanoidRootPart")
	local root = myRoot()
	if not r or not root then return end
	local team = myTeam()
	local okT, theirs = pcall(Teams.GetCharacterTeamName, ch)
	if team and okT and theirs == team then return end
	local rel = r.Position - root.Position
	if Vector3.new(rel.X, 0, rel.Z).Magnitude > cfg.tackleRange then return end
	local v = r.AssemblyLinearVelocity
	local pred = r.Position + Vector3.new(v.X, 0, v.Z) * 0.4
	return flat(pred - root.Position)
end

patch(CharCtl, "GetMoveCommand", function(orig)
	return function(char, ...)
		if S.forceMove and char ~= nil and char == LP.Character then return S.forceMove end
		return orig(char, ...)
	end
end)
patch(SlideInput, "HandleInputBegan", function(orig)
	return function(input, gp, ...)
		if alive() and cfg.tackleAssist and not gp then
			local ok, isTackle = pcall(Controls.IsInput, "Tackle", input)
			if ok and isTackle then
				local okD, dir = pcall(tackleAimDir)
				S.forceMove = okD and dir or nil
				if S.forceMove then S.tackles += 1 end
			end
		end
		local res = table.pack(pcall(orig, input, gp, ...))
		S.forceMove = nil
		if not res[1] then error(res[2], 0) end
		return table.unpack(res, 2, res.n)
	end
end)

S.flickUntil = 0
S.flickSnapped = false
S.flicks = 0
local FLICK_BIND = "EzeISFlickAssist"
local function flickContact(root)
	local st = Renderer.GetMovementState()
	if type(st) ~= "table" or st.Mode ~= "Airborne" then return end
	local bw = ChargePathPreview.GetChargeBoundaryWorld(LP)
	local now = workspace:GetServerTimeNow()
	local s = st
	local hipY = root.Position.Y
	for i = 1, 45 do
		s = Physics.GetStateAtTime(s, now + i * 0.04, bw)
		if not s then return end
		if s.Velocity.Y < 0 and s.Position.Y <= hipY + 1.5 then return s.Position, i * 0.04 end
	end
end
RunService:BindToRenderStep(FLICK_BIND, Enum.RenderPriority.Input.Value + 1, function()
	if not cfg.flickAssist or os.clock() > S.flickUntil then return end
	local owner = Renderer.GetOwnedUserId()
	if owner ~= nil and owner ~= LP.UserId then S.flickUntil = 0 return end
	local root, char = myRoot()
	local hum = char and char:FindFirstChildOfClass("Humanoid")
	if not root or not hum then return end
	local ok, target, tContact = pcall(flickContact, root)
	if not ok or not target then return end
	local d = Vector3.new(target.X - root.Position.X, 0, target.Z - root.Position.Z)
	local dist = d.Magnitude
	if dist > 1 then hum:Move(d.Unit, false) end
	local hs = hum:GetState()
	local airborne = hum.FloorMaterial == Enum.Material.Air or hs == Enum.HumanoidStateType.Jumping or hs == Enum.HumanoidStateType.Freefall
	if airborne and not S.flickSnapped and tContact <= 0.35 and dist > 2 and dist <= cfg.flickReach then
		S.flickSnapped = true
		S.flicks += 1
		logLine(os.date("%H:%M:%S ") .. string.format("flick reach: moved %.1f studs, contact in %.2fs", dist, tContact))
		pcall(AEScript.SetAttribute, AEScript, "LocalAntiExploitEnabled", false)
		local spot = Vector3.new(target.X, root.Position.Y, target.Z) - d.Unit * 1.5
		root.CFrame = CFrame.new(spot) * root.CFrame.Rotation
		task.delay(0.6, function()
			if alive() and not cfg.reach then pcall(AEScript.SetAttribute, AEScript, "LocalAntiExploitEnabled", true) end
		end)
	end
end)
table.insert(S.restore, function() pcall(RunService.UnbindFromRenderStep, RunService, FLICK_BIND) end)

local function setGuard()
	pcall(AEScript.SetAttribute, AEScript, "LocalAntiExploitEnabled", not (cfg.reach and alive()))
end
table.insert(S.restore, function() pcall(AEScript.SetAttribute, AEScript, "LocalAntiExploitEnabled", true) end)

local lastReach = 0
conn(RunService.Heartbeat:Connect(function()
	if not cfg.reach or os.clock() - lastReach < 1 then return end
	if Renderer.GetOwnedUserId() ~= nil or Renderer.IsHidden() then return end
	local root, char = myRoot()
	local hum = char and char:FindFirstChildOfClass("Humanoid")
	local bp = Renderer.GetPosition()
	if not root or not hum or not bp or hum.Health <= 0 then return end
	if char:GetAttribute("Ragdolled") or char:GetAttribute("Stunned") then return end
	local rel = bp - root.Position
	local f = Vector3.new(rel.X, 0, rel.Z)
	local dist = f.Magnitude
	local feetY = root.Position.Y - hum.HipHeight - root.Size.Y / 2
	if dist <= 2.4 or dist > cfg.reachDist or bp.Y - feetY > 5 or bp.Y < feetY - 2 then return end
	lastReach = os.clock()
	root.CFrame = root.CFrame + f.Unit * math.min(dist - 1.5, 2)
	S.reaches += 1
end))

S.corrections = 0
conn(RS.Remotes.Characters.MovementCorrection.OnClientEvent:Connect(function()
	S.corrections += 1
	local hum = LP.Character and LP.Character:FindFirstChildOfClass("Humanoid")
	logLine(os.date("%H:%M:%S ") .. string.format("server movement correction (walkspeed %.1f, speed hack %s, gk %s, reach %s)", hum and hum.WalkSpeed or -1, tostring(cfg.speedOn), tostring(cfg.gkSpeedOn), tostring(cfg.reach)))
end))

local Library = loadstring(game:HttpGet("https://raw.githubusercontent.com/mechupacristopher-creator/lua/main/lib/eze_ui.lua"))()
if not alive() then pcall(function() Library:Unload() end) return end
S.lib = Library

local MovementC = require(Cli.Gameplay.Player.Movement)
local function refreshSpeed()
	pcall(MovementC.SetMultiplier, "EzeHubRefresh", { WalkSpeed = 1 })
	pcall(MovementC.ClearMultiplier, "EzeHubRefresh")
end

local function setCfg(key, after)
	return function(v)
		if cfg[key] ~= v then cfg[key] = v saveCfg() end
		if after then after() end
	end
end
local function toggle(sec, name, key, after)
	return sec:Toggle({ name = name, default = cfg[key], Callback = setCfg(key, after) })
end
local function liveLabel(sec, getText)
	local l = sec:Label({ name = getText() })
	task.spawn(function()
		while alive() do
			pcall(l.set, getText())
			task.wait(0.3)
		end
	end)
end

local win = Library:window({ name = "Eze Hub" })

local atk = win:Tab({ name = "Shooting", icon = "lucide:crosshair" })
local sa = atk:Section({ name = "Silent Aim", side = "left" })
toggle(sa, "Silent Aim", "silentAim")
sa:Dropdown({ name = "Corner", items = { "Away From Keeper", "Far Corner", "Near Corner" }, default = cfg.corner, Callback = setCfg("corner") })
sa:Dropdown({ name = "Height", items = { "Top", "Low" }, default = cfg.height, Callback = setCfg("height") })
sa:Slider({ name = "Corner Inset", min = 1, max = 8, default = cfg.inset, decimals = 1, Callback = setCfg("inset") })
sa:Label({ name = "Shots go to a corner of the goal you are facing, no matter where you aim." })
toggle(sa, "Goal Aimbot (camera)", "aimbot")
sa:Label({ name = "While you charge a shot, the camera locks onto the chosen corner." })

local cs = atk:Section({ name = "Curve", side = "right" })
toggle(cs, "Curve Into Corners", "curve")
cs:Slider({ name = "Curve Amount", min = 0.1, max = 1, default = cfg.curveAmount, decimals = 2, Callback = setCfg("curveAmount") })
cs:Dropdown({ name = "Curve Style", items = { "Into Corner", "Around Post" }, default = cfg.curveStyle, Callback = setCfg("curveStyle") })
cs:Label({ name = "The ball still ends in the corner, it just bends on the way. Works with Silent Aim or Goal Aimbot." })
liveLabel(cs, function() return "Last shot: " .. S.lastShot end)
liveLabel(cs, function() return "Aimed shots: " .. S.aimed end)

local pl = win:Tab({ name = "Player", icon = "lucide:user" })
local mv = pl:Section({ name = "Movement", side = "left" })
toggle(mv, "Infinite Stamina", "infStamina", applyStamina)
toggle(mv, "Walkspeed (Field Player)", "speedOn", refreshSpeed)
mv:Slider({ name = "Field Speed Multiplier", min = 1, max = 3, default = cfg.speed, decimals = 2, Callback = setCfg("speed", refreshSpeed) })
toggle(mv, "Walkspeed (Goalkeeper)", "gkSpeedOn", refreshSpeed)
mv:Slider({ name = "Goalkeeper Speed Multiplier", min = 1, max = 3, default = cfg.gkSpeed, decimals = 2, Callback = setCfg("gkSpeed", refreshSpeed) })
mv:Label({ name = "Tested: 1.5x had no pullbacks, 2x had about one per 40s. Higher gets pulled back more often." })

local bl = pl:Section({ name = "Ball", side = "right" })
toggle(bl, "Auto Dribble", "autoDribble")
bl:Slider({ name = "Tackle Detect Range", min = 5, max = 25, default = cfg.dribbleRange, decimals = 1, Callback = setCfg("dribbleRange") })
bl:Label({ name = "Dribbles the moment an opponent slide tackles toward you while you have the ball. Uses the game's own cooldown and stamina." })
toggle(bl, "Extended Ball Reach", "reach", setGuard)
bl:Slider({ name = "Reach Distance", min = 3, max = 5, default = cfg.reachDist, decimals = 1, Callback = setCfg("reachDist") })
bl:Label({ name = "Steps you up to 2 studs onto loose balls (once per second). The server decides who gets the ball, so this moves you instead of growing a hitbox. Can cause small pullbacks." })
toggle(bl, "Flick Volley Assist", "flickAssist")
bl:Slider({ name = "Flick Reach", min = 3, max = 16, default = cfg.flickReach, decimals = 1, Callback = setCfg("flickReach") })
bl:Label({ name = "After a flick, runs you toward where the ball drops and, just before it comes down, puts you right under it (up to Flick Reach studs) so the volley is in range. Only fires while both you and the ball are in the air. Big values can cause pullbacks." })
toggle(bl, "Tackle Reach Assist", "tackleAssist")
bl:Slider({ name = "Tackle Range", min = 8, max = 23, default = cfg.tackleRange, decimals = 1, Callback = setCfg("tackleRange") })
bl:Label({ name = "When you slide, it steers the slide at where the ball carrier will be, so tackles connect from the slide's full reach. The server checks slide length and hitbox, so those can't be made bigger." })
liveLabel(bl, function() return "Dribbles: " .. S.dribbles .. "  |  Reaches: " .. S.reaches .. "  |  Assisted tackles: " .. S.tackles .. "  |  Flick reaches: " .. S.flicks end)

local miscTab = win:Tab({ name = "Misc", icon = "lucide:info" })
local actions = miscTab:Section({ name = "Script", side = "left" })
actions:Label({ name = "v" .. VERSION .. " - RightControl toggles the UI" })
actions:Button({ name = "Unload Script", Callback = function() S.Unload() end })

function S.Unload()
	if G.EzeIS == S then G.EzeIS = nil end
	for _, c in ipairs(S.conns) do pcall(function() c:Disconnect() end) end
	for _, r in ipairs(S.restore) do pcall(r) end
	pcall(function() Library:Unload() end)
end

applyStamina()
setGuard()
Library:create_notification({ name = "Eze Hub loaded - RightControl to toggle", duration = 4 })
