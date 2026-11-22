local VERSION = "1.5.4"
local CFG_FILE = "ssp_aim_cfg.json"

local G = getgenv()
local TOKEN = {}
G.SSPAimToken = TOKEN
if G.SSPAim and G.SSPAim.Unload then pcall(G.SSPAim.Unload) end
if not game:IsLoaded() then game.Loaded:Wait() end

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local Http = game:GetService("HttpService")
local UIS = game:GetService("UserInputService")
local RS = game:GetService("ReplicatedStorage")
local LP = Players.LocalPlayer

local Shot = require(RS.shared.play.shot)
local Ball = require(RS.shared.ball.ballistics)
local Match = require(RS.shared.match)
local Clock = require(RS.shared.util.clock)
local Look = require(RS.client.input.look)
local Power = require(RS.client.play.power)
local Charge = require(RS.client.play.charge)
local KickLead = require(RS.client.play.kick_lead)
local Actions = require(RS.client.input.actions)
local Volley = require(RS.client.play.volley)
local VStrike = require(RS.shared.play.volley_strike)
local Comp = require(RS.shared.components)
local CComp = require(RS.client.ccomponents)
local Keeper = require(RS.shared.keeper)
local Present = require(RS.client.ball.present)
local Control = require(RS.client.input.control)
if setthreadidentity then pcall(setthreadidentity, 8) end

local cfg = {
	aim = false, curve = true, height = "Auto", showTarget = false, range = 220, margin = 2.2,
	volley = false, dribble = false, dribbleRange = 10, tackle = false, tackleRange = 16,
	save = false, gkPosition = false,
}
pcall(function() for k, v in pairs(Http:JSONDecode(readfile(CFG_FILE))) do cfg[k] = v end end)
local function saveCfg() pcall(writefile, CFG_FILE, Http:JSONEncode(cfg)) end
if (cfg.cfgVersion or 0) < 2 then
	cfg.range, cfg.cfgVersion = math.max(cfg.range or 0, 220), 2
	saveCfg()
end
if cfg.cfgVersion < 3 then
	cfg.margin, cfg.cfgVersion = math.max(cfg.margin or 0, 2.2), 3
	saveCfg()
end
if cfg.cfgVersion < 4 then
	cfg.tackleRange, cfg.cfgVersion = math.max(cfg.tackleRange or 0, 16), 4
	saveCfg()
end

if G.SSPAimToken ~= TOKEN then return end
local S = { conns = {}, sol = nil, status = "Idle", track = {} }
G.SSPAim = S
local function alive() return G.SSPAim == S end

local UP = Vector3.new(0, 1, 0)
local DT = Ball.FIXED_DT
local HALF_W = Match.GOAL_HALF_WIDTH
local BAR = Match.CROSSBAR

local function ballPos()
	local b = workspace.physics_objects:FindFirstChild("squish")
	if b then return b.Position end
	local s = workspace.physics_objects:FindFirstChild("ball_shadow")
	return s and s.Position + Vector3.new(0, 0.8, 0)
end

local origFire = Shot.fire

local SIDE_WALL = Match.TOUCH_LINE - 0.8
local function fly(start, gx, yaw, pitch, launch, walls)
	local p = math.rad(pitch)
	local dir = Vector3.new(math.cos(yaw) * math.cos(p), math.sin(p), math.sin(yaw) * math.cos(p))
	local v, spin = launch(dir)
	local pos, t = start, 0
	local sx = math.sign(gx - start.X)
	while t < 4 do
		v, spin = Ball.integrate(v, spin, DT, false)
		local np = pos + v * DT

		if walls and (math.abs(np.Z) > SIDE_WALL or (math.abs(gx - np.X) < 1.2 and math.abs(np.Z) > HALF_W - 0.35)) then
			return false
		end
		if (np.X - gx) * sx >= 0 then
			local a = (gx - pos.X) / (np.X - pos.X)
			local hit = pos + (np - pos) * a
			return hit.Z, hit.Y, t + DT * a, dir
		end
		if np.Y <= 0 and v.Y < 0 then return nil end
		pos, t = np, t + DT
	end
	return nil
end

local function solve(start, gx, tz, ty, launch)
	local yaw = math.atan2(tz - start.Z, gx - start.X)
	local pitch, best = 0, nil
	for _ = 1, 22 do
		local z, y = fly(start, gx, yaw, pitch, launch)
		if not z then
			pitch += 5
			if pitch > 45 then return best end
		else
			local ez, ey = z - tz, y - ty
			local err = math.sqrt(ez * ez + ey * ey)
			if not best or err < best.err then best = { yaw = yaw, pitch = pitch, err = err } end
			if err < 0.12 then break end
			local z1, y1 = fly(start, gx, yaw + 0.004, pitch, launch)
			local z2, y2 = fly(start, gx, yaw, pitch + 0.25, launch)
			if not z1 or not z2 then pitch += 2 continue end
			local a, b = (z1 - z) / 0.004, (z2 - z) / 0.25
			local c, d = (y1 - y) / 0.004, (y2 - y) / 0.25
			local det = a * d - b * c
			if math.abs(det) < 1e-9 then break end
			local dyaw = (d * ez - b * ey) / det
			local dpitch = (a * ey - c * ez) / det
			yaw -= math.clamp(dyaw, -0.25, 0.25)
			pitch = math.clamp(pitch - math.clamp(dpitch, -8, 8), -60, 45)
		end
	end
	if best then
		if fly(start, gx, best.yaw, best.pitch, launch, true) == false then return nil end
		local p = math.rad(best.pitch)
		best.dir = Vector3.new(math.cos(best.yaw) * math.cos(p), math.sin(p), math.sin(best.yaw) * math.cos(p))
	end
	return best
end

local function shotLaunch(curve, charge, power, forced)
	local tpl = S.fireArgs and os.clock() - S.fireAt < (forced and 1 or 0.3) and S.fireArgs
	local mult = S.curveMult or 1
	return function(dir)
		local u, spd, spin
		if tpl then
			local a = table.clone(tpl)
			a[1], a[3] = dir, curve * mult
			if forced then a[2], a[4] = charge, power end
			u, spd, spin = origFire(table.unpack(a, 1, tpl.n))
		else
			u, spd, spin = origFire(dir, charge, curve, power)
		end
		return u * spd, spin
	end
end

local function volleyLaunch(m, side)
	return function(dir)
		local r = VStrike.strike(dir, m.spot, side, 1, false, nil, m.index, m.facing, false)
		return r.velocity, r.spin
	end
end

local function focusOf(uid)
	local f = workspace.focus:FindFirstChild(tostring(uid))
	return f and f.Position
end

local function teamOf(model)
	local p = model:GetPivot().Position
	local best, bd
	for _, f in ipairs(workspace.focus:GetChildren()) do
		local d = (f.Position - p).Magnitude
		if d < 5 and (not bd or d < bd) then best, bd = f, d end
	end
	local pl = best and Players:GetPlayerByUserId(tonumber(best.Name) or 0)
	return pl, pl and pl.Team
end

local function isEnemy(model)
	local pl, team = teamOf(model)
	if pl == LP then return false end
	if team == nil or LP.Team == nil then return nil end
	return team ~= LP.Team
end

local function humanoids()
	local out = {}
	for _, m in ipairs(workspace.physics_objects:GetChildren()) do
		if m.Name == "humanoid" and m:IsA("Model") then table.insert(out, m) end
	end
	return out
end

local function keeperNear(goal, ball)
	local best, bd
	for _, m in ipairs(humanoids()) do
		local p = m:GetPivot().Position
		if (p - ball).Magnitude > 4 and isEnemy(m) ~= false then
			local d = (Vector3.new(p.X, 0, p.Z) - goal).Magnitude
			if d < 22 and (not bd or d < bd) then best, bd = m, d end
		end
	end
	return best
end

local function pickGoal(ball)
	local look = S.intent or workspace.CurrentCamera.CFrame.LookVector
	local flat = Vector3.new(look.X, 0, look.Z)
	flat = flat.Magnitude > 1e-3 and flat.Unit or Vector3.new(1, 0, 0)
	local best, bd, dist
	for _, side in ipairs({ Match.WEST, Match.EAST }) do
		local g = Match.goal_of(side)
		local to = Vector3.new(g.X - ball.X, 0, -ball.Z)
		local dot = flat:Dot(to.Unit)
		if not bd or dot > bd then best, bd, dist = g, dot, to.Magnitude end
	end
	if bd < 0 then return nil, "Kick toward a goal to aim" end
	if dist > cfg.range then return nil, ("Goal %d studs away (max %d)"):format(dist, cfg.range) end
	return best
end

local function corners(ball, gx, keeper, volley)

	local bias = (volley and G.SSPVolleyBias) or (not volley and G.SSPAimBias) or { y = 0, z = 0 }
	local zIn = math.clamp(HALF_W - cfg.margin - bias.z - (volley and 0.6 or 0), HALF_W - 5, HALF_W - 1.6)
	local zs = { zIn, -zIn }
	local ys = {}
	if volley then

		if cfg.height ~= "Low" then table.insert(ys, math.clamp(BAR - 2.6 - bias.y, BAR - 4.5, BAR - 1.8)) end
		table.insert(ys, math.clamp(4 - bias.y, 3, 5))
		if cfg.height == "Low" then table.insert(ys, 1.6) end
	else
		if cfg.height ~= "Low" then table.insert(ys, math.clamp(BAR - 2 - bias.y, BAR - 4, BAR - 1.4)) end
		if cfg.height ~= "High" then table.insert(ys, math.clamp(1.6 - bias.y, 1.1, 3.5)) end
	end
	local list = {}
	local kp
	if keeper then
		local tr = S.track[keeper]
		local vel = tr and tr.vel or Vector3.zero
		local tArrive = math.abs(gx - ball.X) / 80
		kp = keeper:GetPivot().Position + vel * math.min(tArrive, 1.2)
	end
	for _, z in ipairs(zs) do
		for _, y in ipairs(ys) do
			local score
			if kp then
				score = Vector2.new(z - kp.Z, (y - math.max(kp.Y - 2, 0)) * 1.3).Magnitude
			else
				score = math.abs(z - ball.Z) + y * 0.2
			end
			table.insert(list, { z = z, y = y, score = score })
		end
	end

	local wing = math.abs(ball.Z) > 4 and math.sign(ball.Z) or 0
	table.sort(list, function(a, b)
		if wing ~= 0 then
			local fa, fb = math.sign(a.z) ~= wing, math.sign(b.z) ~= wing
			if fa ~= fb then return fa end
		end
		if volley and a.y ~= b.y then return a.y > b.y end
		return a.score > b.score
	end)
	return list
end

local function watchShot(sol, biasKey, label)
	task.spawn(function()
		local t0, prev = os.clock(), ballPos()
		while os.clock() - t0 < 4 and alive() do
			task.wait()
			local p = ballPos()
			if p and prev and (p.X - sol.target.X) * (prev.X - sol.target.X) <= 0 and (p - prev).Magnitude < 20 then
				local a = (sol.target.X - prev.X) / (p.X - prev.X)
				local hit = prev + (p - prev) * a
				S.last = ("%s: target z %.1f y %.1f | crossed z %.1f y %.1f"):format(label, sol.target.Z, sol.target.Y, hit.Z, hit.Y)
				local ey = hit.Y - sol.target.Y
				local ez = math.abs(hit.Z) - math.abs(sol.target.Z)
				if math.abs(ey) < 3 and math.abs(ez) < 4 then
					local b = G[biasKey] or { y = 0, z = 0 }
					b.y = math.clamp(b.y * 0.7 + ey * 0.3, -1.5, 1.5)
					b.z = math.clamp(b.z * 0.7 + ez * 0.3, -2, 2)
					G[biasKey] = b
				end
				return
			end
			prev = p
		end
	end)
end

local function compute(force)
	local charging, start = Charge.get()
	if not cfg.aim or not (charging or force) then return nil end
	local ball = ballPos()
	if not ball then return nil end
	local goal, why = pickGoal(ball)
	if not goal then S.status = why return nil end
	local gx = goal.X
	local prog = force and 1 or Shot.progress(start, Clock.server())
	local power = force and force.power or (Power.armed() and prog >= Shot.POWER_MIN_CHARGE)
	local keeper = keeperNear(goal, ball)
	local lead = S.lead and os.clock() - S.lead.at < 0.3 and S.lead.start
	local from = lead or ball
	for _, c in ipairs(corners(from, gx, keeper)) do
		local tries = cfg.curve and { 1, -1 } or { 0 }
		local found
		for _, cv in ipairs(tries) do
			local s = solve(from, gx, c.z, c.y, shotLaunch(cv, prog, power, force ~= nil))
			if s and s.err < 0.6 then
				s.curve = cv
				local straightZ = from.Z + math.tan(s.yaw) * (gx - from.X)
				s.outside = math.abs(straightZ) > math.abs(c.z)
				if not found or (s.outside and not found.outside) then found = s end
			end
		end
		if found then
			found.target = Vector3.new(gx, c.y, c.z)
			found.keeper = keeper ~= nil
			found.charge = prog
			S.status = ("Aiming %s %s corner | curve %+d | charge %d%%%s"):format(
				c.y > 3 and "top" or "low", (c.z > 0) == (gx > 0) and "left" or "right",
				found.curve, prog * 100, keeper and " | keeper read" or "")
			return found
		end
	end
	S.status = "Too weak to reach a corner - charge more"
	return nil
end

local function computeVolley(m)
	local goal, why = pickGoal(m.spot)
	if not goal then S.status = "Volley: " .. why return nil end
	local gx = goal.X
	local side = Match.other(gx < 0 and Match.WEST or Match.EAST)
	local keeper = keeperNear(goal, m.spot)
	local launch = volleyLaunch(m, side)
	for _, c in ipairs(corners(m.spot, gx, keeper, true)) do
		local s = solve(m.spot, gx, c.z, c.y, launch)
		if s and s.err < 0.8 then
			s.curve = 0
			s.target = Vector3.new(gx, c.y, c.z)
			S.status = ("Volley -> %s %s corner%s"):format(c.y > 3 and "top" or "low",
				(c.z > 0) == (gx > 0) and "left" or "right", keeper and " | keeper read" or "")
			return s
		end
	end
	S.status = "Volley: no corner reachable from this touch"
	return nil
end

local function volleySol()
	if not cfg.volley or Charge.get() then return nil end
	local ok, m = pcall(Volley.offer)
	if not ok or m == nil then return nil end
	local c = S.vcache
	if c and c.m == m and os.clock() - c.at < 0.1 then return c.sol end
	local ok2, sol = pcall(computeVolley, m)
	sol = ok2 and sol or nil
	S.vcache = { m = m, at = os.clock(), sol = sol }
	if sol then S.vsol, S.vsolAt = sol, os.clock() end
	return sol
end

local Contest = require(RS.shared.play.contest)
local Cooldown = require(RS.client.play.cooldown)
local PRESS_DELAY = 0.03

local function tackleReady()
	local ok, left = pcall(Cooldown.remaining, "tackle")
	return not ok or (left or 0) <= 0
end

local function fireContest(dir, now)
	S.tackleDir = dir
	S.steerUntil = now + PRESS_DELAY + 0.11
	S.pressAt, S.pressUntil = now + PRESS_DELAY, now + PRESS_DELAY + 0.06
	S.lastTackle = now
end

local function interceptDir(me, target, vel)
	local reach = Contest.TACKLE_REACH * 0.8
	local v0, v1, win = Contest.SLIDE_SPEED, Contest.SLIDE_END, Contest.TACKLE_WINDOW
	local lead = PRESS_DELAY + Contest.TACKLE_STARTUP + 0.03
	local travelled, step = 0, 0.02
	for tau = 0, win, step do
		local tt = lead + tau
		local p = target + vel * tt
		local to = (p - me) * Vector3.new(1, 0, 1)
		if to.Magnitude <= travelled + reach then
			return to.Magnitude > 0.05 and to.Unit or nil, to.Magnitude, tt
		end
		travelled += (v0 + (v1 - v0) * (tau / win)) * step
	end
	return nil
end

local function findWorld()
	local w = S.world
	if w then
		local ok, has = pcall(function() for _ in w:query(Comp.FOOTBALL) do return true end end)
		if ok and has then return w end
	end
	S.world = nil
	for _, t in ipairs(getgc(true)) do
		if type(t) == "table" and rawget(t, "entity_index") ~= nil and rawget(t, "query") ~= nil then
			local ok, has = pcall(function() for _ in t:query(Comp.FOOTBALL) do return true end end)
			if ok and has then S.world = t return t end
		end
	end
end

local function myEntity(w)
	for e in w:query(CComp.OWNED) do
		if w:has(e, Comp.CHARACTER) then return e end
	end
end

local function keeperStep(now)
	if not (cfg.save or cfg.gkPosition or cfg.tackle) then S.gkMove, S.isKeeper = nil, false return end
	if now - (S.worldCheck or 0) > 2 or not S.world then S.worldCheck = now findWorld() end
	local w = S.world
	if not w then S.gkMove = nil return end
	local ok, err = pcall(function()
		local me = myEntity(w)
		S.isKeeper = me ~= nil and w:has(me, Comp.GOALKEEPER)
		if not S.isKeeper or not (cfg.save or cfg.gkPosition) then
			S.gkMove = nil
			if not S.isKeeper then S.gkStatus = "Not keeper right now" end
			return
		end
		local side = w:get(me, Comp.side)
		if side ~= Match.WEST and side ~= Match.EAST then S.gkMove = nil return end
		local mePos = focusOf(LP.UserId)
		if not mePos then return end
		local goal = Match.goal_of(side)
		local depth = math.clamp(math.abs(mePos.X - goal.X), 0.5, 12)
		local ball
		for e in w:query(Comp.FOOTBALL) do ball = e break end
		if not ball then S.gkMove = nil return end
		local bp, bv, bs = Present.now(w, ball)

		if not bp then bp, bv, bs = ballPos(), Vector3.zero, Vector3.zero end
		if not bp then S.gkMove, S.gkStatus = nil, "Can't find the ball" return end
		bv, bs = bv or Vector3.zero, bs or Vector3.zero
		local holder = w:target(ball, Comp.HELD_BY, 0)
		local towardGoal = (goal.X - bp.X) * bv.X > 0 and bv.Magnitude > 12
		local t, hit
		if not holder and towardGoal then t, hit = Keeper.plane(bp, bv, bs, side, depth) end
		if t and hit and math.abs(hit.Z) < HALF_W + 2.5 and hit.Y < BAR + 2 then
			local flat = Vector3.new(hit.X - mePos.X, 0, hit.Z - mePos.Z)
			local d = flat.Magnitude
			S.gkStatus = ("Shot incoming: %.2fs, %.1f studs %s, height %.1f"):format(t, d, hit.Z > mePos.Z and "+z" or "-z", hit.Y)
			local needCatch = d < 2.5 and hit.Y < Keeper.CATCH_RISE
			if cfg.save and not needCatch and now - (S.lastDive or 0) > 0.8 and tackleReady() then
				local needed = d / Keeper.DIVE_SPEED + Keeper.DIVE_REACTION + 0.06
				if t <= needed and d > 0.3 then
					S.gkMove = nil
					fireContest(flat.Unit, now)
					S.lastDive = now
					S.gkStatus = ("Dived %.1f studs toward the ball (%.2fs before it crossed)"):format(d, t)
					return
				end
			end
			if cfg.gkPosition then
				local dz = hit.Z - mePos.Z
				S.gkMove = math.abs(dz) > 0.6 and Vector3.new(0, 0, math.sign(dz)) or nil
			end
			return
		end
		if not cfg.gkPosition then S.gkMove = nil return end

		local lineX = goal.X - math.sign(goal.X) * depth
		local k = (lineX - bp.X) / (goal.X - bp.X)
		local coverZ = bp.Z + (0 - bp.Z) * math.clamp(k, 0, 1)
		coverZ = math.clamp(coverZ, -(HALF_W - 1.5), HALF_W - 1.5)
		local target = Vector3.new(lineX, mePos.Y, coverZ)
		local to = (target - mePos) * Vector3.new(1, 0, 1)
		S.gkMove = to.Magnitude > 0.8 and to.Unit * math.clamp(to.Magnitude / 4, 0.35, 1) or nil
		S.gkStatus = ("Positioning: covering z %.1f"):format(coverZ)
	end)
	if not ok then S.gkMove, S.gkStatus = nil, "Keeper error: " .. tostring(err) end
end

local HOOKED = { Look.kick, Look.aim, Look.camera, Power.curve, Power.bend, Shot.fire, KickLead.aim, Actions.pressed, Control.move, Control.throttle }
if restorefunction and isfunctionhooked then
	for _, f in ipairs(HOOKED) do
		if isfunctionhooked(f) then pcall(restorefunction, f) end
	end
end
do
	local function st() return getgenv().SSPAim end
	local oldKick
	oldKick = hookfunction(Look.kick, function(...)
		local r = oldKick(...)
		local s = st()
		if not s or r == nil then return r end
		s.intent = r
		if s.sol then return s.sol.dir end
		local v = s.volleySol()
		if v then return v.dir end
		return r
	end)
	local oldAim
	oldAim = hookfunction(Look.aim, function(...)
		local r = oldAim(...)
		local s = st()
		if not s or r == nil then return r end
		local v = s.volleySol()
		if v then return v.dir end
		return r
	end)
	local function curveHook(old)
		return function(...)
			local s = st()
			local r
			if s and s.sol then r = s.sol.curve else r = old(...) end
			if s then s.curveOut = r end
			return r
		end
	end
	local oldCurve
	oldCurve = hookfunction(Power.curve, curveHook(function(...) return oldCurve(...) end))
	local oldBend
	oldBend = hookfunction(Power.bend, curveHook(function(...) return oldBend(...) end))
	local oldFire
	oldFire = hookfunction(Shot.fire, function(...)
		local s = st()
		if s and Charge.get() then
			local a = table.pack(...)
			s.fireArgs, s.fireAt = a, os.clock()
			if s.curveOut and s.curveOut ~= 0 and type(a[3]) == "number" and a[3] ~= 0 then
				s.curveMult = a[3] / s.curveOut
			end
		end
		return oldFire(...)
	end)
	origFire = oldFire
	local oldLead
	oldLead = hookfunction(KickLead.aim, function(start, ...)
		local s = st()
		if s and typeof(start) == "Vector3" then s.lead = { start = start, at = os.clock() } end
		return oldLead(start, ...)
	end)
	local oldPressed
	oldPressed = hookfunction(Actions.pressed, function(name, ...)
		local s = st()
		if name == "dribble" and s and s.dribbleUntil and os.clock() < s.dribbleUntil then return true end
		if name == "tackle" and s and s.pressAt then
			local now = os.clock()
			if now >= s.pressAt and now < s.pressUntil then return true end
		end
		return oldPressed(name, ...)
	end)

	local function steering(s) return s and s.tackleDir and s.steerUntil and os.clock() < s.steerUntil end
	local oldMove
	oldMove = hookfunction(Control.move, function(...)
		local r = oldMove(...)
		local s = st()
		if steering(s) then return s.tackleDir end
		if s and s.gkMove and (typeof(r) ~= "Vector3" or r.Magnitude < 0.1) then return s.gkMove end
		return r
	end)

	local oldThrottle
	oldThrottle = hookfunction(Control.throttle, function(...)
		local r = oldThrottle(...)
		local s = st()
		if s and s.gkMove and (type(r) ~= "number" or r < 0.1) then return math.min(s.gkMove.Magnitude, 1) end
		return r
	end)
	local oldCamera
	oldCamera = hookfunction(Look.camera, function(...)
		local s = st()
		if steering(s) then return s.tackleDir end
		return oldCamera(...)
	end)
end
S.volleySol, S.computeVolley, S.solve, S.shotLaunch, S.corners = volleySol, computeVolley, solve, shotLaunch, corners

local marker = Instance.new("Part")
marker.Name = "SSPAimTarget"
marker.Shape = Enum.PartType.Ball
marker.Size = Vector3.new(1.2, 1.2, 1.2)
marker.Anchored, marker.CanCollide, marker.CanQuery, marker.CanTouch = true, false, false, false
marker.Material = Enum.Material.Neon
marker.Color = Color3.fromRGB(176, 8, 8)
marker.Transparency = 1
marker.Parent = workspace
S.marker = marker

local lastSolve = 0
table.insert(S.conns, RunService.Heartbeat:Connect(function(dt)
	for _, m in ipairs(humanoids()) do
		local p = m:GetPivot().Position
		local tr = S.track[m]
		if tr then tr.vel = tr.vel:Lerp((p - tr.pos) / math.max(dt, 1 / 240), 0.3) tr.pos = p
		else S.track[m] = { pos = p, vel = Vector3.zero } end
	end
	if cfg.dribble and os.clock() - (S.lastDrib or 0) > 0.25 then
		local me, ball = focusOf(LP.UserId), ballPos()
		if me and ball and (ball - me).Magnitude < 4.5 then
			for _, m in ipairs(humanoids()) do
				if isEnemy(m) ~= false then
					local d = (m:GetPivot().Position - me) * Vector3.new(1, 0, 1)
					local dist = d.Magnitude
					if dist > 0.5 and dist < cfg.dribbleRange then
						local tr = S.track[m]
						local closing = tr and -tr.vel:Dot(d.Unit) or 0
						if dist < 5 or closing > 8 then
							S.dribbleUntil, S.lastDrib = os.clock() + 0.05, os.clock()
							S.dribbleStatus = ("Auto dribble fired (enemy %.0f studs, closing %.0f)"):format(dist, closing)
							break
						end
					end
				end
			end
		end
	end
	do
		local me = focusOf(LP.UserId)
		if me then
			local prev = S.mePos
			S.meVel = prev and (S.meVel or Vector3.zero):Lerp((me - prev) / math.max(dt, 1 / 240), 0.3) or Vector3.zero
			S.mePos = me
		end
		keeperStep(os.clock())
		local okv, started = pcall(Volley.get)
		if okv and started and S.vsol then S.volleyAt, S.volleySolUsed = os.clock(), S.vsol end
		local bp = ballPos()
		if bp and S.ballPrevPos and S.volleySolUsed and os.clock() - (S.volleyAt or 0) < 0.8 then
			local vel = (bp - S.ballPrevPos) / math.max(dt, 1 / 240)
			local tx = S.volleySolUsed.target.X
			if vel.Magnitude > 35 and (tx - bp.X) * vel.X > 0 then
				watchShot(S.volleySolUsed, "SSPVolleyBias", "Last volley")
				S.volleySolUsed = nil
			end
		end
		S.ballPrevPos = bp

		if cfg.tackle and not S.isKeeper and me and os.clock() - (S.lastTackle or 0) > 0.3 then
			local ball = ballPos()
			local carrier, cd
			if ball and ball.Y < 3 then
				for _, m in ipairs(humanoids()) do
					local p = m:GetPivot().Position
					local fd = ((p - ball) * Vector3.new(1, 0, 1)).Magnitude
					if fd < 3.5 and (not cd or fd < cd) then carrier, cd = m, fd end
				end
			end
			if carrier and isEnemy(carrier) ~= false then
				local tr = S.track[carrier]
				local cp = carrier:GetPivot().Position
				local now0 = ((cp - me) * Vector3.new(1, 0, 1)).Magnitude
				if now0 <= cfg.tackleRange and tackleReady() then
					local dir, dist, tt = interceptDir(me, cp, (tr and tr.vel or Vector3.zero) * Vector3.new(1, 0, 1))
					if dir then
						fireContest(dir, os.clock())
						S.tackleStatus = ("Locked on: slid %.1f studs to intercept (%.2fs ahead)"):format(dist, tt)
					else
						S.tackleStatus = ("Tracking carrier %.1f studs away - out of slide reach"):format(now0)
					end
				end
			end
		end
	end
	local charging = Charge.get()
	if charging then S.releasedAt, S.powerSolved = nil, false end
	if S.sol and not charging and cfg.aim then
		S.releasedAt = S.releasedAt or os.clock()

		if Power.rooted(Clock.mono()) then
			S.powerHold = os.clock() + 0.35
			if not S.powerSolved then
				S.powerSolved = true
				local ok, res = pcall(compute, { power = true })
				if ok and res then S.sol = res end
			end
		end

		local pending = os.clock() - S.releasedAt < 0.2
		if pending or (S.powerHold and os.clock() < S.powerHold) then
			S.status = "Power shot windup: holding aim on " .. ((S.sol.target.Y > 3) and "top" or "low") .. " corner"
			return
		end
	end
	if not (cfg.aim and charging) then
		if S.sol then watchShot(S.sol, "SSPAimBias", "Last shot") end
		S.sol = nil
		marker.Transparency = 1
		return
	end
	local now = os.clock()
	if now - lastSolve >= 0.05 then
		lastSolve = now
		local ok, res = pcall(compute)
		S.sol = ok and res or nil
		if not ok then S.status = "Error: " .. tostring(res) end
	end
	if S.sol and cfg.showTarget then
		marker.Position, marker.Transparency = S.sol.target, 0.2
	else
		marker.Transparency = 1
	end
end))

local Monolith = (function()

local uis = game:GetService("UserInputService")
local tween_service = game:GetService("TweenService")
local http_service = game:GetService("HttpService")
local gui_service = game:GetService("GuiService")

local function get_ui_parent()
    local success, parent = pcall(function() return gethui and gethui() end)
    if success and parent then return parent end
    success, parent = pcall(function() return game:GetService("CoreGui") end)
    if success and parent then return parent end
    return game:GetService("Players").LocalPlayer:WaitForChild("PlayerGui")
end

local library = {
    font = Font.new("rbxassetid://12187375716", Enum.FontWeight.Regular, Enum.FontStyle.Normal)
}
library.__index = library

local connections = {}
local function track_connection(conn)
    if conn then table.insert(connections, conn) end
    return conn
end

function library:Unload()

    for _, conn in ipairs(connections) do
        if conn then conn:Disconnect() end
    end
    table.clear(connections)

    local parent = get_ui_parent()
    if parent:FindFirstChild("MonolithUI") then parent.MonolithUI:Destroy() end
    if parent:FindFirstChild("MonolithNotifs") then parent.MonolithNotifs:Destroy() end

    print("Monolith Library Unloaded Successfully")
end

local function global_cleanup()
    local parent = get_ui_parent()
    if parent:FindFirstChild("MonolithUI") then parent.MonolithUI:Destroy() end
    if parent:FindFirstChild("MonolithNotifs") then parent.MonolithNotifs:Destroy() end
end

global_cleanup()

local dim2 = UDim2.new
local dim = UDim.new
local rgb = Color3.fromRGB
local ui_parent = get_ui_parent()

local Theme = {
    MainBG = rgb(15, 15, 15),
    SidebarBG = rgb(18, 18, 18),
    TopbarBG = rgb(18, 18, 18),
    SectionBG = rgb(22, 22, 22),
    ElementBG = rgb(30, 30, 30),
    HoverBG = rgb(40, 40, 40),
    Accent = rgb(100, 150, 255),
    Text = rgb(240, 240, 240),
    MutedText = rgb(150, 150, 150),
    Outline = rgb(45, 45, 45)
}

function library:tween(obj, props, time)
    local t = tween_service:Create(obj, TweenInfo.new(time or 0.2, Enum.EasingStyle.Quint, Enum.EasingDirection.Out), props)
    t:Play()
    return t
end

function library:create(class, props)
    local ins = Instance.new(class)
    for k, v in pairs(props) do ins[k] = v end
    return ins
end

function library:draggify(frame, drag_area)
    local dragging, startPos, startInput
    (drag_area or frame).InputBegan:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
            if frame:GetAttribute("PositionLocked") then return end
            dragging = true; startInput = input.Position; startPos = frame.Position
        end
    end)

    track_connection(uis.InputChanged:Connect(function(input)
        if dragging and (input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch) then
            if frame:GetAttribute("PositionLocked") then dragging = false return end
            local delta = input.Position - startInput
            frame.Position = dim2(startPos.X.Scale, startPos.X.Offset + delta.X, startPos.Y.Scale, startPos.Y.Offset + delta.Y)
        end
    end))

    track_connection(uis.InputEnded:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then dragging = false end
    end))
end

local notif_screen = library:create("ScreenGui", {Parent = ui_parent, Name = "MonolithNotifs"})
local notif_container = library:create("Frame", {
    Parent = notif_screen,
    Size = dim2(0, 300, 1, 0),
    Position = dim2(1, -310, 0, 0),
    BackgroundTransparency = 1
})
library:create("UIListLayout", {
    Parent = notif_container,
    Padding = dim(0, 10),
    VerticalAlignment = Enum.VerticalAlignment.Bottom,
    HorizontalAlignment = Enum.HorizontalAlignment.Right
})
library:create("UIPadding", {Parent = notif_container, PaddingBottom = dim(0, 20), PaddingRight = dim(0, 10)})

local Icons
task.spawn(function()
    pcall(function()
        Icons = loadstring(game:HttpGet("https://raw.githubusercontent.com/Footagesus/Icons/main/Main-v2.lua"))()
        if Icons then Icons.SetIconsType("lucide") end
    end)
end)

local function get_icon(iconName, color)
    if not iconName then return nil end
    local isAsset = iconName:match("^rbxassetid://") or iconName:match("^%d+$")
    if isAsset then
        local img = Instance.new("ImageLabel")
        img.BackgroundTransparency = 1
        img.Image = iconName:match("^%d+$") and "rbxassetid://"..iconName or iconName
        img.ImageColor3 = color or Color3.fromRGB(255, 255, 255)
        return img
    end
    local holder = Instance.new("Frame")
    holder.BackgroundTransparency = 1
    task.spawn(function()
        local waited = 0
        while not Icons and waited < 5 do task.wait(0.1); waited = waited + 0.1 end
        if Icons then
            local iconStr = iconName:gsub("^lucide:", "")
            local ok, iconObj = pcall(function() return Icons.Image({ Icon = iconStr, Colors = {color or Color3.fromRGB(255, 255, 255)} }) end)
            if ok and iconObj and iconObj.IconFrame then
                iconObj.IconFrame.BackgroundTransparency = 1
                iconObj.IconFrame.Size = UDim2.new(1, 0, 1, 0)
                iconObj.IconFrame.Parent = holder
            end
        end
    end)
    return holder
end

local function color_icon(iconInstance, color)
    if not iconInstance then return end
    for _, v in pairs(iconInstance:GetDescendants()) do
        if v:IsA("ImageLabel") then
            tween_service:Create(v, TweenInfo.new(0.15), {ImageColor3 = color}):Play()
        end
    end
end

local function PremiumOverlay(parent)
    local overlay = library:create("Frame", { Parent = parent, Size = dim2(1, 0, 1, 0), BackgroundColor3 = Theme.MainBG, BackgroundTransparency = 0.3, ZIndex = 10 })
    library:create("UICorner", {Parent = overlay, CornerRadius = dim(0, 6)})
    local lock = get_icon("lucide:lock", Theme.Accent)
    if lock then lock.Parent = overlay; lock.AnchorPoint = Vector2.new(0.5, 0.5); lock.Position = dim2(0.5, 0, 0.5, 0); lock.Size = dim2(0, 16, 0, 16); lock.ZIndex = 11 end
    library:create("TextButton", { Parent = overlay, Size = dim2(1, 0, 1, 0), BackgroundTransparency = 1, Text = "", ZIndex = 12 })
end

local function BootSequence(windowFrame, windowName)
    local main = library:create("Frame", {
        Parent = windowFrame, Size = dim2(1, 0, 1, 0), BackgroundColor3 = rgb(0, 0, 0),
        ZIndex = 1000, BorderSizePixel = 0
    })
    local logo = library:create("TextLabel", {
        Parent = main, Text = windowName, Position = dim2(0.5, 0, 0.4, 0), AnchorPoint = Vector2.new(0.5, 0.5),
        Size = dim2(0, 200, 0, 50), BackgroundTransparency = 1, TextColor3 = Theme.Text,
        FontFace = library.font, TextSize = 32, TextTransparency = 1, ZIndex = 1001
    })
    local barBg = library:create("Frame", {
        Parent = main, Size = dim2(0, 200, 0, 4), Position = dim2(0.5, 0, 0.6, 0), AnchorPoint = Vector2.new(0.5, 0.5),
        BackgroundColor3 = Theme.Outline, BorderSizePixel = 0, ZIndex = 1001
    })
    library:create("UICorner", {Parent = barBg})
    local barFill = library:create("Frame", {
        Parent = barBg, Size = dim2(0, 0, 1, 0), BackgroundColor3 = Theme.Accent, BorderSizePixel = 0, ZIndex = 1002
    })
    library:create("UICorner", {Parent = barFill})
    local status = library:create("TextLabel", {
        Parent = main, Text = "Initializing...", Position = dim2(0.5, 0, 0.65, 0), AnchorPoint = Vector2.new(0.5, 0.5),
        Size = dim2(0, 200, 0, 20), BackgroundTransparency = 1, TextColor3 = Theme.MutedText,
        FontFace = library.font, TextSize = 14, TextTransparency = 1, ZIndex = 1001
    })

    return coroutine.wrap(function()
        library:tween(logo, {TextTransparency = 0}, 1)
        task.wait(0.5)
        library:tween(status, {TextTransparency = 0}, 0.5)
        local steps = {"Loading Core...", "Fetching Assets...", "Applying Theme...", "Finalizing..."}
        for i, step in ipairs(steps) do
            status.Text = step
            library:tween(barFill, {Size = dim2(i/ #steps, 0, 1, 0)}, 0.5)
            task.wait(0.6)
        end
        library:tween(logo, {TextTransparency = 1}, 0.5)
        library:tween(status, {TextTransparency = 1}, 0.5)
        library:tween(barFill, {BackgroundTransparency = 1}, 0.3)
        library:tween(barBg, {BackgroundTransparency = 1}, 0.3)
        task.wait(0.5)
        local fadeOut = library:tween(main, {BackgroundTransparency = 1}, 1)
        fadeOut.Completed:Connect(function() main:Destroy() end)
        task.wait(1)
    end)
end

function library:window(props)
    local win = { items = {}, tabs = {}, _toggleRegistry = {}, _elementRegistry = {}, _tabOrder = 0 }

    function win:SetElementValue(name, value)
        local el = self._elementRegistry[name]
        if not el then return end
        if el.set then el:set(value) elseif el.set_value then el:set_value(value) end
    end
    local screen = library:create("ScreenGui", {Parent = ui_parent, Name = "MonolithUI", ResetOnSpawn = false})
    local main = library:create("Frame", {
        Parent = screen, Size = dim2(0, 650, 0, 450), Position = dim2(0.5, -325, 0.5, -225),
        BackgroundColor3 = Theme.MainBG, BorderSizePixel = 0
    })
    library:create("UICorner", {Parent = main, CornerRadius = dim(0, 8)})
    library:create("UIStroke", {Parent = main, Color = Theme.Outline, Thickness = 1})

    local window_bottom_glow = library:create("Frame", {
        Parent = main, Size = dim2(1, 0, 0, 120), Position = dim2(0, 0, 1, 0), AnchorPoint = Vector2.new(0, 1),
        BackgroundColor3 = Theme.Accent, BorderSizePixel = 0, ZIndex = 0
    })
    library:create("UICorner", {Parent = window_bottom_glow, CornerRadius = dim(0, 8)})
    library:create("UIGradient", {
        Parent = window_bottom_glow, Rotation = 90,
        Transparency = NumberSequence.new({
            NumberSequenceKeypoint.new(0, 1),
            NumberSequenceKeypoint.new(1, 0.85)
        })
    })

    local topbar = library:create("Frame", { Parent = main, Size = dim2(1, 0, 0, 40), BackgroundColor3 = Theme.TopbarBG, BorderSizePixel = 0 })
    library:create("UICorner", {Parent = topbar, CornerRadius = dim(0, 8)})
    local topbar_filler = library:create("Frame", {Parent = topbar, Size = dim2(1, 0, 0, 10), Position = dim2(0, 0, 1, -10), BackgroundColor3 = Theme.TopbarBG, BorderSizePixel = 0})
    library:create("Frame", {Parent = topbar, Size = dim2(1, 0, 0, 1), Position = dim2(0, 0, 1, 0), BackgroundColor3 = Theme.Outline, BorderSizePixel = 0})
    library:draggify(main, topbar)

    library:create("TextLabel", {
        Parent = topbar,
        Size = dim2(0, 200, 0, 24),
        Position = dim2(0, 12, 0.5, 0),
        AnchorPoint = Vector2.new(0, 0.5),
        BackgroundTransparency = 1,
        Text = "eze's",
        TextColor3 = Theme.Text,
        FontFace = Font.new("rbxassetid://12187375716", Enum.FontWeight.Bold, Enum.FontStyle.Normal),
        TextSize = 18,
        TextXAlignment = Enum.TextXAlignment.Left
    })

    local minBtn = library:create("TextButton", { Parent = topbar, Size = dim2(0, 30, 0, 24), Position = dim2(1, -70, 0.5, -12), BackgroundColor3 = Theme.TopbarBG, Text = "", AutoButtonColor = false })
    library:create("UICorner", {Parent = minBtn, CornerRadius = dim(0, 4)})
    local minIconObj = get_icon("lucide:minus", Theme.MutedText)
    if minIconObj then minIconObj.Size = dim2(0, 14, 0, 14); minIconObj.Position = dim2(0.5, 0, 0.5, 0); minIconObj.AnchorPoint = Vector2.new(0.5, 0.5); minIconObj.Parent = minBtn end

    local closeBtn = library:create("TextButton", { Parent = topbar, Size = dim2(0, 30, 0, 24), Position = dim2(1, -36, 0.5, -12), BackgroundColor3 = Theme.TopbarBG, Text = "", AutoButtonColor = false })
    library:create("UICorner", {Parent = closeBtn, CornerRadius = dim(0, 4)})
    local closeIconObj = get_icon("lucide:x", Theme.MutedText)
    if closeIconObj then closeIconObj.Size = dim2(0, 14, 0, 14); closeIconObj.Position = dim2(0.5, 0, 0.5, 0); closeIconObj.AnchorPoint = Vector2.new(0.5, 0.5); closeIconObj.Parent = closeBtn end

    minBtn.MouseEnter:Connect(function() library:tween(minBtn, {BackgroundColor3 = Theme.HoverBG}, 0.15); color_icon(minIconObj, Theme.Text) end)
    minBtn.MouseLeave:Connect(function() library:tween(minBtn, {BackgroundColor3 = Theme.TopbarBG}, 0.15); color_icon(minIconObj, Theme.MutedText) end)
    closeBtn.MouseEnter:Connect(function() library:tween(closeBtn, {BackgroundColor3 = rgb(200, 50, 50)}, 0.15); color_icon(closeIconObj, Theme.Text) end)
    closeBtn.MouseLeave:Connect(function() library:tween(closeBtn, {BackgroundColor3 = Theme.TopbarBG}, 0.15); color_icon(closeIconObj, Theme.MutedText) end)
    closeBtn.MouseButton1Click:Connect(function() screen:Destroy() end)

    local sidebar = library:create("ScrollingFrame", {
        Parent = main, Position = dim2(0, 0, 0, 41), Size = dim2(0, 140, 1, -41),
        BackgroundColor3 = Theme.SidebarBG, BorderSizePixel = 0,
        ScrollBarThickness = 2, ScrollBarImageColor3 = Theme.Outline,
        CanvasSize = dim2(0, 0, 0, 0), AutomaticCanvasSize = Enum.AutomaticSize.Y, ZIndex = 1
    })
    library:create("UIStroke", {
        Parent = sidebar, Color = Theme.Outline, Thickness = 1, ApplyStrokeMode = Enum.ApplyStrokeMode.Border
    })
    local page_holder = library:create("Frame", { Parent = main, Position = dim2(0, 141, 0, 41), Size = dim2(1, -141, 1, -41), BackgroundTransparency = 1 })
    library:create("UIListLayout", {Parent = sidebar, Padding = dim(0, 5), HorizontalAlignment = Enum.HorizontalAlignment.Center, SortOrder = Enum.SortOrder.LayoutOrder})
    library:create("UIPadding", {Parent = sidebar, PaddingTop = dim(0, 10)})

    local resizeHandle = library:create("TextButton", { Parent = main, Size = dim2(0, 20, 0, 20), Position = dim2(1, -20, 1, -20), BackgroundTransparency = 1, Text = "↘", TextColor3 = Theme.MutedText, TextSize = 14, FontFace = library.font, ZIndex = 100 })
    local resizing, rStartPos, rStartSize
    resizeHandle.InputBegan:Connect(function(input) if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then resizing = true; rStartPos = input.Position; rStartSize = main.Size end end)
    track_connection(uis.InputChanged:Connect(function(input) if resizing and (input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch) then local delta = input.Position - rStartPos; main.Size = dim2(0, math.max(450, rStartSize.X.Offset + delta.X), 0, math.max(300, rStartSize.Y.Offset + delta.Y)) end end))
    track_connection(uis.InputEnded:Connect(function(input) if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then resizing = false end end))

    local isMinimized = false
    local savedSize = main.Size
    minBtn.MouseButton1Click:Connect(function()
        isMinimized = not isMinimized
        if isMinimized then

            savedSize = main.Size; resizeHandle.Visible = false; sidebar.Visible = false; page_holder.Visible = false; topbar_filler.Visible = false; window_bottom_glow.Visible = false
            library:tween(main, {Size = dim2(0, savedSize.X.Offset, 0, 40)}, 0.25)
        else
            topbar_filler.Visible = true
            local t = library:tween(main, {Size = savedSize}, 0.25)
            t.Completed:Connect(function() if not isMinimized then sidebar.Visible = true; page_holder.Visible = true; resizeHandle.Visible = true; window_bottom_glow.Visible = true end end)
        end
    end)

    win.toggle_menu = function(a, b)
        local state = (type(a) == "boolean") and a or b; if state == nil then state = not main.Visible end; main.Visible = state
    end

    win.toggle_lock = function(state)
        win._isLocked = (state == nil) and not win._isLocked or state
        main:SetAttribute("PositionLocked", win._isLocked)
        return win._isLocked
    end

    local toggleKey = Enum.KeyCode.RightControl
    track_connection(uis.InputBegan:Connect(function(input, gpe)
        if not gpe and input.KeyCode == toggleKey then win.toggle_menu() end
    end))

    function win:GetConfigData()
        local data = {}
        for key, el in pairs(self._elementRegistry) do
            if not el.NoSave and type(el.get_value) == "function" then
                local ok, v = pcall(function() return el:get_value() end)
                if ok and v ~= nil then data[key] = v end
            end
        end
        return data
    end

    function win:LoadConfigData(data)
        if type(data) ~= "table" then return end
        _G.IsLoadingConfig = true

        local deferred = {}
        for name, value in pairs(data) do

            local el = self._elementRegistry[name] or self._legacyRegistry[name]
            if el and type(el.set) == "function" then
                if el._isColor then
                    pcall(function() el:set(value) end)
                else
                    table.insert(deferred, {el = el, value = value, name = name})
                end
            end
        end

        for _, item in ipairs(deferred) do
            local success, err = pcall(function() item.el:set(item.value) end)
            if not success then
                warn("[Config Error] '" .. tostring(item.name) .. "': " .. tostring(err))
            end
            if item.el.refresh then pcall(function() item.el:refresh() end) end
        end

        if self.RefreshMobileButtonStates then self:RefreshMobileButtonStates() end

        task.spawn(function()
            task.wait(0.2)
            _G.IsLoadingConfig = false
        end)
    end

    if props.Loading then
        local bootCoroutine = BootSequence(main, props.name or "Nebula UI")
        bootCoroutine()
    end

    function win:Tab(props)
        local tabColor = props.GlowColor or props.glowcolor or props.Color or props.color or Theme.Accent

        local tab = { name = props.name or props.Name or "Tab" }
        win._tabOrder = win._tabOrder + 1

        win._legacyRegistry = win._legacyRegistry or {}
        local function register_element(sec, name, api)
            local secName = (sec and sec._name) or "Global"
            local key = tab.name .. "::" .. secName .. "::" .. tostring(name)
            api._configKey  = key
            api._configName = name
            win._elementRegistry[key] = api

            if win._legacyRegistry[name] == nil then
                win._legacyRegistry[name] = api
            end
            return key
        end

        local btn = library:create("TextButton", { Parent = sidebar, Size = dim2(1, -16, 0, 32), BackgroundColor3 = Theme.MainBG, Text = "", AutoButtonColor = false, LayoutOrder = props._layoutOrder or win._tabOrder })
        library:create("UICorner", {Parent = btn, CornerRadius = dim(0, 6)}); library:create("UIStroke", {Parent = btn, Color = Theme.Outline, Thickness = 1})
        local tIcon = get_icon(props.Icon or props.icon or "lucide:folder", Theme.MutedText)
        if tIcon then tIcon.Size = dim2(0, 16, 0, 16); tIcon.Position = dim2(0, 10, 0.5, 0); tIcon.AnchorPoint = Vector2.new(0, 0.5); tIcon.Parent = btn end
        local tOff = tIcon and 34 or 10
        local tLabel = library:create("TextLabel", { Parent = btn, Text = tab.name, Size = dim2(1, -tOff, 1, 0), Position = dim2(0, tOff, 0, 0), BackgroundTransparency = 1, TextColor3 = Theme.MutedText, TextXAlignment = Enum.TextXAlignment.Left, FontFace = library.font, TextSize = 13 })

        local tab_glow = library:create("Frame", {
            Parent = btn, Size = dim2(0.2, 0, 0, 2), Position = dim2(0.5, 0, 1, 0), AnchorPoint = Vector2.new(0.5, 1),
            BackgroundColor3 = tabColor, BorderSizePixel = 0, BackgroundTransparency = 1, ZIndex = 2
        })

        local tab_grad = Instance.new("UIGradient")
        tab_grad.Rotation = 0
        tab_grad.Transparency = NumberSequence.new({
            NumberSequenceKeypoint.new(0, 1),
            NumberSequenceKeypoint.new(0.5, 0),
            NumberSequenceKeypoint.new(1, 1)
        })
        tab_grad.Parent = tab_glow

        local page = library:create("ScrollingFrame", { Parent = page_holder, Size = dim2(1, 0, 1, 0), BackgroundTransparency = 1, Visible = false, ScrollBarThickness = 0, AutomaticCanvasSize = Enum.AutomaticSize.Y })
        library:create("UIListLayout", {Parent = page, FillDirection = Enum.FillDirection.Horizontal, Padding = dim(0, 15), SortOrder = Enum.SortOrder.LayoutOrder})
        library:create("UIPadding", {Parent = page, PaddingLeft = dim(0, 15), PaddingRight = dim(0, 15), PaddingTop = dim(0, 15), PaddingBottom = dim(0, 15)})

        local left_col = library:create("Frame", { Parent = page, Size = dim2(0.5, -8, 0, 0), BackgroundTransparency = 1, AutomaticSize = Enum.AutomaticSize.Y })
        library:create("UIListLayout", {Parent = left_col, Padding = dim(0, 10)})
        local right_col = library:create("Frame", { Parent = page, Size = dim2(0.5, -8, 0, 0), Position = dim2(0.5, 8, 0, 0), BackgroundTransparency = 1, AutomaticSize = Enum.AutomaticSize.Y })
        library:create("UIListLayout", {Parent = right_col, Padding = dim(0, 10)})

        if #win.tabs == 0 and not props._noAutoSelect then
            page.Visible = true; tLabel.TextColor3 = Theme.Text; btn.BackgroundColor3 = Theme.ElementBG; color_icon(tIcon, Theme.Text)

            tab_glow.BackgroundTransparency = 0
            tab_glow.Size = dim2(0.7, 0, 0, 2)
            window_bottom_glow.BackgroundColor3 = tabColor
        end
        table.insert(win.tabs, {btn = btn, page = page, label = tLabel, icon = tIcon, glow = tab_glow, color = tabColor})

        btn.MouseButton1Click:Connect(function()
            for _, t in pairs(win.tabs) do
                t.page.Visible = false; t.label.TextColor3 = Theme.MutedText; color_icon(t.icon, Theme.MutedText)
                library:tween(t.btn, {BackgroundColor3 = Theme.MainBG}, 0.15)

                library:tween(t.glow, {BackgroundTransparency = 1, Size = dim2(0.2, 0, 0, 2)}, 0.15)
            end
            page.Visible = true; tLabel.TextColor3 = Theme.Text; color_icon(tIcon, Theme.Text)
            library:tween(btn, {BackgroundColor3 = Theme.ElementBG}, 0.15)

            library:tween(tab_glow, {BackgroundTransparency = 0, Size = dim2(0.7, 0, 0, 2)}, 0.15)
            library:tween(window_bottom_glow, {BackgroundColor3 = tabColor}, 0.3)
        end)

        local section_api = {}
        function section_api:Label(p)
            local l = library:create("TextLabel", { Parent = p.Parent or self.elements, Size = dim2(1, 0, 0, 20), BackgroundTransparency = 1, Text = p.name or p.Name or "Label", TextColor3 = Theme.MutedText, FontFace = library.font, TextSize = 13, TextXAlignment = Enum.TextXAlignment.Left, TextWrapped = true, AutomaticSize = Enum.AutomaticSize.Y })
            return { instance = l, set = function(txt) l.Text = txt end }
        end
        function section_api:Button(p)
            local b = library:create("TextButton", {
                Parent = p.Parent or self.elements,
                Size = dim2(1, 0, 0, 32),
                BackgroundColor3 = Theme.ElementBG,
                Text = "  " .. (p.name or p.Name or "Button"),
                TextColor3 = Theme.Text,
                TextXAlignment = Enum.TextXAlignment.Left,
                FontFace = library.font,
                TextSize = 13,
                AutoButtonColor = false
            })
            library:create("UICorner", {Parent = b, CornerRadius = dim(0, 6)})
            library:create("UIStroke", {Parent = b, Color = Theme.Outline, Thickness = 1})

            local clickIcon = get_icon("lucide:mouse-pointer-click", Theme.MutedText)
            if clickIcon then
                clickIcon.Size = dim2(0, 16, 0, 16)
                clickIcon.Position = dim2(1, -26, 0.5, 0)
                clickIcon.AnchorPoint = Vector2.new(0, 0.5)
                clickIcon.Parent = b
            end

            if p.Premium or p.premium then PremiumOverlay(b) end

            b.MouseEnter:Connect(function()
                if clickIcon then color_icon(clickIcon, Theme.Text) end
            end)
            b.MouseLeave:Connect(function()
                if clickIcon then color_icon(clickIcon, Theme.MutedText) end
            end)

            b.MouseButton1Click:Connect(function()
                library:tween(b, {BackgroundColor3 = Theme.HoverBG}, 0.1)
                task.wait(0.1)
                library:tween(b, {BackgroundColor3 = Theme.ElementBG}, 0.1)
                if p.Callback then p.Callback() end
            end)
            return {}
        end
        function section_api:Toggle(p)
            local tog = { enabled = p.default or false, NoSave = p.NoSave or p.nosave }
            local boundKey = nil
            local pickingBind = false
            local sec = self

            local holder = library:create("Frame", { Parent = p.Parent or self.elements, Size = dim2(1, 0, 0, 0), BackgroundTransparency = 1, AutomaticSize = Enum.AutomaticSize.Y })
            library:create("UIListLayout", {Parent = holder, Padding = dim(0, 6)})
            local btn = library:create("TextButton", { Parent = holder, Size = dim2(1, 0, 0, 32), BackgroundColor3 = Theme.ElementBG, Text = "  " .. (p.name or p.Name or "Toggle"), TextColor3 = Theme.Text, TextXAlignment = Enum.TextXAlignment.Left, FontFace = library.font, TextSize = 13, AutoButtonColor = false })
            library:create("UICorner", {Parent = btn, CornerRadius = dim(0, 6)}); library:create("UIStroke", {Parent = btn, Color = Theme.Outline, Thickness = 1})
            if p.Premium or p.premium then PremiumOverlay(btn) end
            local indicator = library:create("Frame", { Parent = btn, Size = dim2(0, 16, 0, 16), Position = dim2(1, -24, 0.5, -8), BackgroundColor3 = tog.enabled and Theme.Accent or Theme.MainBG })
            library:create("UICorner", {Parent = indicator, CornerRadius = dim(0, 4)}); library:create("UIStroke", {Parent = indicator, Color = Theme.Outline, Thickness = 1})
            local container = library:create("Frame", { Parent = holder, Size = dim2(1, 0, 0, 0), BackgroundTransparency = 1, Visible = tog.enabled, AutomaticSize = Enum.AutomaticSize.Y })
            library:create("UIListLayout", {Parent = container, Padding = dim(0, 6)}); library:create("UIPadding", {Parent = container, PaddingLeft = dim(0, 14)})

            local bindBtn = library:create("TextButton", { Parent = btn, Size = dim2(0, 28, 0, 18), Position = dim2(1, -56, 0.5, -9), BackgroundColor3 = Theme.MainBG, Text = "—", TextColor3 = Theme.MutedText, FontFace = library.font, TextSize = 10, AutoButtonColor = false, ZIndex = 2 })
            library:create("UICorner", {Parent = bindBtn, CornerRadius = dim(0, 4)}); library:create("UIStroke", {Parent = bindBtn, Color = Theme.Outline, Thickness = 1})

            bindBtn.MouseButton1Click:Connect(function()
                pickingBind = true
                bindBtn.Text = "..."
                bindBtn.TextColor3 = Theme.Accent
            end)

            track_connection(uis.InputBegan:Connect(function(input, gpe)
                if pickingBind and input.UserInputType == Enum.UserInputType.Keyboard then
                    pickingBind = false
                    if input.KeyCode == Enum.KeyCode.Backspace or input.KeyCode == Enum.KeyCode.Escape then
                        boundKey = nil; bindBtn.Text = "—"; bindBtn.TextColor3 = Theme.MutedText
                    else
                        boundKey = input.KeyCode; bindBtn.Text = boundKey.Name; bindBtn.TextColor3 = Theme.Text
                    end
                    return
                end
                if not gpe and boundKey and input.KeyCode == boundKey then
                    tog:set(not tog.enabled)
                end
            end))

            btn.MouseButton1Click:Connect(function() tog:set(not tog.enabled) end)

            function tog:Slider(np) np = np or {}; np.Parent = container; return sec:Slider(np) end
            function tog:Dropdown(np) np = np or {}; np.Parent = container; return sec:Dropdown(np) end
            function tog:Colorpicker(np) np = np or {}; np.Parent = container; return sec:Colorpicker(np) end
            function tog:Keybind(np) np = np or {}; np.Parent = container; return sec:Keybind(np) end

            function tog:get_value()
                return { State = self.enabled, Key = boundKey and boundKey.Name or nil }
            end

            function tog:set(val)
                local finalState
                local t = type(val)

                if t == "boolean" then finalState = val
                elseif t == "number" then finalState = val ~= 0
                elseif t == "string" then
                    local l = val:lower()
                    finalState = (l == "true" or l == "1" or l == "on" or l == "yes")
                elseif t == "table" then
                    if val.State ~= nil then finalState = val.State == true
                    elseif val.enabled ~= nil then finalState = val.enabled == true
                    elseif val.Value ~= nil then finalState = val.Value == true
                    else finalState = self.enabled end

                    if val.Key then
                        local s, k = pcall(function() return Enum.KeyCode[val.Key] end)
                        if s and k then
                            boundKey = k; bindBtn.Text = boundKey.Name; bindBtn.TextColor3 = Theme.Text
                        end
                    end
                elseif val == nil then finalState = self.enabled
                else finalState = val and true or false end

                self.enabled = finalState
                container.Visible = finalState

                indicator.BackgroundColor3 = finalState and Theme.Accent or Theme.MainBG
                library:tween(indicator, {BackgroundColor3 = finalState and Theme.Accent or Theme.MainBG}, 0.2)

                if p.Callback then task.spawn(function() p.Callback(finalState) end) end
            end

            function tog:refresh()
                container.Visible = self.enabled
                indicator.BackgroundColor3 = self.enabled and Theme.Accent or Theme.MainBG
            end

            local elName = p.name or p.Name or "Toggle"
            local key = register_element(self, elName, tog)
            table.insert(win._toggleRegistry, { name = elName, key = key, api = tog })
            if win.RefreshMobileList then win:RefreshMobileList() end
            return tog
        end

        function section_api:Slider(p)
            local min, max, default = p.min or 0, p.max or 100, p.default or p.min or 0
            local decimals = p.decimals or 1; local current_val = default
            local s = library:create("Frame", { Parent = p.Parent or self.elements, Size = dim2(1, 0, 0, 50), BackgroundColor3 = Theme.ElementBG })
            library:create("UICorner", {Parent = s, CornerRadius = dim(0, 6)}); library:create("UIStroke", {Parent = s, Color = Theme.Outline, Thickness = 1})
            if p.Premium or p.premium then PremiumOverlay(s) end
            local lbl = library:create("TextLabel", { Parent = s, Text = "  " .. (p.name or p.Name or "Slider"), Size = dim2(1, 0, 0, 25), BackgroundTransparency = 1, TextColor3 = Theme.Text, TextXAlignment = Enum.TextXAlignment.Left, FontFace = library.font, TextSize = 13 })
            local val_box = library:create("TextBox", { Parent = s, Text = string.format("%."..decimals.."f", default), Size = dim2(0, 50, 0, 25), Position = dim2(1, -55, 0, 0), BackgroundTransparency = 1, TextColor3 = Theme.Accent, TextXAlignment = Enum.TextXAlignment.Right, FontFace = library.font, TextSize = 13, ClearTextOnFocus = false })
            local bar_bg = library:create("Frame", { Parent = s, Size = dim2(1, -20, 0, 6), Position = dim2(0, 10, 0, 32), BackgroundColor3 = Theme.MainBG })
            library:create("UICorner", {Parent = bar_bg, CornerRadius = dim(1, 0)})
            local pct_default = math.clamp((default - min) / (max - min), 0, 1)
            local fill = library:create("Frame", { Parent = bar_bg, Size = dim2(pct_default, 0, 1, 0), BackgroundColor3 = Theme.Accent })
            library:create("UICorner", {Parent = fill, CornerRadius = dim(1, 0)})
            local knob = library:create("Frame", { Parent = fill, Size = dim2(0, 14, 0, 14), Position = dim2(1, -7, 0.5, -7), BackgroundColor3 = Theme.Text })
            library:create("UICorner", {Parent = knob, CornerRadius = dim(1, 0)})
            local dragging = false
            local function update_slider(input_x)
                local pct = math.clamp((input_x - bar_bg.AbsolutePosition.X) / bar_bg.AbsoluteSize.X, 0, 1)
                local value = min + ((max - min) * pct); current_val = value; fill.Size = dim2(pct, 0, 1, 0)
                val_box.Text = string.format("%." .. decimals .. "f", value)
                if p.Callback then p.Callback(value) end
            end
            val_box.FocusLost:Connect(function()
                local num = tonumber(val_box.Text)
                if num then num = math.clamp(num, min, max); current_val = num; fill.Size = dim2((num - min) / (max - min), 0, 1, 0); val_box.Text = string.format("%." .. decimals .. "f", num)
                    if p.Callback then p.Callback(num) end
                else val_box.Text = string.format("%." .. decimals .. "f", current_val) end
            end)
            bar_bg.InputBegan:Connect(function(i) if i.UserInputType == Enum.UserInputType.MouseButton1 or i.UserInputType == Enum.UserInputType.Touch then dragging = true; update_slider(i.Position.X) end end)
            knob.InputBegan:Connect(function(i) if i.UserInputType == Enum.UserInputType.MouseButton1 or i.UserInputType == Enum.UserInputType.Touch then dragging = true end end)
            track_connection(uis.InputEnded:Connect(function(i) if i.UserInputType == Enum.UserInputType.MouseButton1 or i.UserInputType == Enum.UserInputType.Touch then dragging = false end end))
            track_connection(uis.InputChanged:Connect(function(input) if dragging and (input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch) then update_slider(input.Position.X) end end))

            local api = {
                NoSave = p.NoSave or p.nosave,
                get_value = function(self) return current_val end,
                set = function(self, val)
                    val = math.clamp(tonumber(val) or min, min, max); current_val = val; fill.Size = dim2((val - min) / (max - min), 0, 1, 0); val_box.Text = string.format("%." .. decimals .. "f", val)
                    if p.Callback then task.spawn(function() p.Callback(val) end) end
                end
            }
            register_element(self, p.name or p.Name or "Slider", api)
            return api
        end

        function section_api:Textbox(p)
            local bg = library:create("Frame", { Parent = p.Parent or self.elements, Size = dim2(1, 0, 0, 32), BackgroundColor3 = Theme.ElementBG })
            library:create("UICorner", {Parent = bg, CornerRadius = dim(0, 6)}); library:create("UIStroke", {Parent = bg, Color = Theme.Outline, Thickness = 1})
            if p.Premium or p.premium then PremiumOverlay(bg) end
            local box = library:create("TextBox", { Parent = bg, Size = dim2(1, -16, 1, 0), Position = dim2(0, 8, 0, 0), BackgroundTransparency = 1, Text = "", PlaceholderText = p.placeholder or p.Placeholder or (p.name or "Textbox"), TextColor3 = Theme.Text, PlaceholderColor3 = Theme.MutedText, FontFace = library.font, TextSize = 13, TextXAlignment = Enum.TextXAlignment.Left })
            box.FocusLost:Connect(function() if p.Callback then p.Callback(box.Text) end end)
            local api = {
                NoSave = p.NoSave or p.nosave,
                get_value = function(self) return box.Text end,
                set = function(self, text)
                    box.Text = tostring(text)
                    if p.Callback then task.spawn(function() p.Callback(box.Text) end) end
                end
            }
            register_element(self, p.name or p.Name or "Textbox", api)
            return api
        end

        function section_api:Dropdown(p)
            local isMulti = p.multi or p.Multi
            local selected = isMulti and (p.default or {}) or (p.default or (p.items and p.items[1]) or "None")
            local open = false
            local holder = library:create("Frame", { Parent = p.Parent or self.elements, Size = dim2(1, 0, 0, 0), BackgroundTransparency = 1, AutomaticSize = Enum.AutomaticSize.Y })
            library:create("UIListLayout", {Parent = holder, Padding = dim(0, 4), SortOrder = Enum.SortOrder.LayoutOrder})
            local function get_val_str() return isMulti and (#selected > 0 and table.concat(selected, ", ") or "None") or selected end
            local btn = library:create("TextButton", { Parent = holder, LayoutOrder = 1, Size = dim2(1, 0, 0, 32), BackgroundColor3 = Theme.ElementBG, Text = "  " .. (p.Name or p.name or "Dropdown") .. " : " .. get_val_str(), TextColor3 = Theme.Text, TextXAlignment = Enum.TextXAlignment.Left, FontFace = library.font, TextSize = 13, AutoButtonColor=false })
            library:create("UICorner", {Parent = btn, CornerRadius = dim(0, 6)}); library:create("UIStroke", {Parent = btn, Color = Theme.Outline, Thickness = 1})
            if p.Premium or p.premium then PremiumOverlay(btn) end
            local container = library:create("Frame", { Parent = holder, LayoutOrder = 2, Size = dim2(1, 0, 0, 0), BackgroundTransparency = 1, Visible = false, AutomaticSize = Enum.AutomaticSize.Y })
            library:create("UIListLayout", {Parent = container, Padding = dim(0, 4), SortOrder = Enum.SortOrder.LayoutOrder}); library:create("UIPadding", {Parent = container, PaddingLeft = dim(0, 8)})
            local searchBox = library:create("TextBox", { Parent = container, LayoutOrder = 1, Size = dim2(1, 0, 0, 28), BackgroundColor3 = Theme.MainBG, TextColor3 = Theme.Text, PlaceholderText = "Search...", PlaceholderColor3 = Theme.MutedText, FontFace = library.font, TextSize = 12, TextXAlignment = Enum.TextXAlignment.Left, Text = "" })
            library:create("UICorner", {Parent = searchBox, CornerRadius = dim(0, 4)}); library:create("UIPadding", {Parent = searchBox, PaddingLeft = dim(0, 8)})
            local itemBtns = {}
            local function updateItems()
                for _, iBtn in pairs(itemBtns) do
                    local isSel = isMulti and table.find(selected, iBtn.name) or (selected == iBtn.name)
                    iBtn.btn.BackgroundColor3 = isSel and Theme.Accent or Theme.HoverBG; iBtn.btn.TextColor3 = isSel and Theme.MainBG or Theme.MutedText
                end
                btn.Text = "  " .. (p.Name or p.name or "Dropdown") .. " : " .. get_val_str()
            end
            btn.MouseButton1Click:Connect(function() open = not open; container.Visible = open end)
            local function build_items(itemList)
                for _, iBtn in pairs(itemBtns) do iBtn.btn:Destroy() end; itemBtns = {}
                if not isMulti and not table.find(itemList, selected) then selected = itemList[1] or "None"; if p.Callback then p.Callback(selected) end end
                for index, item in pairs(itemList or {}) do
                    local ibtn = library:create("TextButton", { Parent = container, LayoutOrder = index + 1, Size = dim2(1, 0, 0, 26), BackgroundColor3 = Theme.HoverBG, Text = "  " .. item, TextColor3 = Theme.MutedText, TextXAlignment = Enum.TextXAlignment.Left, FontFace = library.font, TextSize = 12, AutoButtonColor = false })
                    library:create("UICorner", {Parent = ibtn, CornerRadius = dim(0, 6)}); table.insert(itemBtns, {btn = ibtn, name = item})
                    ibtn.MouseButton1Click:Connect(function()
                        if isMulti then local idx = table.find(selected, item); if idx then table.remove(selected, idx) else table.insert(selected, item) end else selected = item; open = false; container.Visible = false end
                        updateItems(); if p.Callback then p.Callback(selected) end
                    end)
                end
                updateItems()
            end
            build_items(p.items or {})
            searchBox:GetPropertyChangedSignal("Text"):Connect(function() local q = searchBox.Text:lower(); for _, iBtn in pairs(itemBtns) do iBtn.btn.Visible = (q == "" or iBtn.name:lower():find(q) ~= nil) end end)

            local api = {
                NoSave = p.NoSave or p.nosave,
                get_value = function(self) return selected end,
                set_items = function(self, new_items) build_items(new_items) end,
                set = function(self, val)
                    selected = val; updateItems(); if p.Callback then task.spawn(function() p.Callback(selected) end) end
                end,
            }
            register_element(self, p.Name or p.name or "Dropdown", api)
            return api
        end

        function section_api:Colorpicker(p)
            local open = false; local color = p.default or rgb(255, 0, 0); local h, s, v = color:ToHSV()
            local holder = library:create("Frame", { Parent = p.Parent or self.elements, Size = dim2(1, 0, 0, 0), BackgroundTransparency = 1, AutomaticSize = Enum.AutomaticSize.Y })
            library:create("UIListLayout", {Parent = holder, Padding = dim(0, 4)})
            local btn = library:create("TextButton", { Parent = holder, Size = dim2(1, 0, 0, 32), BackgroundColor3 = Theme.ElementBG, Text = "  " .. (p.Name or p.name or "Colorpicker"), TextColor3 = Theme.Text, TextXAlignment = Enum.TextXAlignment.Left, FontFace = library.font, TextSize = 13, AutoButtonColor=false })
            library:create("UICorner", {Parent = btn, CornerRadius = dim(0, 6)}); library:create("UIStroke", {Parent = btn, Color = Theme.Outline, Thickness = 1})
            if p.Premium or p.premium then PremiumOverlay(btn) end
            local disp = library:create("Frame", { Parent = btn, Size = dim2(0, 20, 0, 16), Position = dim2(1, -28, 0.5, -8), BackgroundColor3 = color })
            library:create("UICorner", {Parent = disp, CornerRadius = dim(0, 4)})
            local container = library:create("Frame", { Parent = holder, Size = dim2(1, 0, 0, 130), BackgroundTransparency = 1, Visible = false })
            local wheelBg = library:create("Frame", {Parent = container, Size = dim2(1, 0, 1, 0), BackgroundColor3 = Theme.SectionBG})
            library:create("UICorner", {Parent = wheelBg, CornerRadius = dim(0, 6)})
            local wheel = library:create("ImageButton", { Parent = wheelBg, Size = dim2(0, 100, 0, 100), Position = dim2(0, 10, 0, 10), BackgroundTransparency = 1, Image = "rbxassetid://6020299385" })
            local pickerDot = library:create("ImageLabel", { Parent = wheel, Size = dim2(0, 12, 0, 12), AnchorPoint = Vector2.new(0.5, 0.5), BackgroundTransparency = 1, Image = "rbxassetid://3678860011" })
            local valSlider = library:create("TextButton", { Parent = wheelBg, Size = dim2(0, 15, 0, 100), Position = dim2(0, 120, 0, 10), BackgroundColor3 = rgb(255, 255, 255), Text = "", AutoButtonColor = false })
            library:create("UICorner", {Parent = valSlider, CornerRadius = dim(0, 4)})
            local valGrad = library:create("UIGradient", { Parent = valSlider, Rotation = 90, Color = ColorSequence.new{ColorSequenceKeypoint.new(0, Color3.fromHSV(h,s,1)), ColorSequenceKeypoint.new(1, rgb(0,0,0))} })
            local valIndicator = library:create("Frame", { Parent = valSlider, Size = dim2(1, 4, 0, 4), Position = dim2(0.5, 0, 1-v, 0), AnchorPoint = Vector2.new(0.5, 0.5), BackgroundColor3 = Theme.Text, BorderSizePixel = 0 })

            btn.MouseButton1Click:Connect(function() open = not open; container.Visible = open end)
            local function update_color()
                color = Color3.fromHSV(h, s, v); disp.BackgroundColor3 = color; valGrad.Color = ColorSequence.new{ColorSequenceKeypoint.new(0, Color3.fromHSV(h,s,1)), ColorSequenceKeypoint.new(1, rgb(0,0,0))}
                if p.Callback then p.Callback(color) end
            end

            local angle = (h * math.pi * 2) - (math.pi / 2); pickerDot.Position = dim2(0.5 + math.cos(angle) * 0.5 * s, 0, 0.5 + math.sin(angle) * 0.5 * s, 0)
            local draggingWheel, draggingVal = false, false; local inset = gui_service:GetGuiInset()
            wheel.InputBegan:Connect(function(i) if i.UserInputType == Enum.UserInputType.MouseButton1 or i.UserInputType == Enum.UserInputType.Touch then draggingWheel = true end end)
            valSlider.InputBegan:Connect(function(i) if i.UserInputType == Enum.UserInputType.MouseButton1 or i.UserInputType == Enum.UserInputType.Touch then draggingVal = true end end)
            track_connection(uis.InputEnded:Connect(function(i) if i.UserInputType == Enum.UserInputType.MouseButton1 or i.UserInputType == Enum.UserInputType.Touch then draggingWheel = false; draggingVal = false end end))
            track_connection(uis.InputChanged:Connect(function(input)
                if input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch then
                    local mLoc = uis:GetMouseLocation(); local correctedMouse = Vector2.new(mLoc.X, mLoc.Y - inset.Y)
                    if draggingWheel then
                        local offset = correctedMouse - (wheel.AbsolutePosition + (wheel.AbsoluteSize / 2)); local rad = wheel.AbsoluteSize.X / 2
                        if offset.Magnitude > rad then offset = offset.Unit * rad end
                        pickerDot.Position = dim2(0.5 + (offset.X / wheel.AbsoluteSize.X), 0, 0.5 + (offset.Y / wheel.AbsoluteSize.Y), 0)
                        local angle = math.atan2(-offset.Y, offset.X); h = (angle / (math.pi * 2)) + 0.5; h = h % 1; s = offset.Magnitude / rad; update_color()
                    elseif draggingVal then
                        local clampedY = math.clamp(correctedMouse.Y - valSlider.AbsolutePosition.Y, 0, valSlider.AbsoluteSize.Y)
                        valIndicator.Position = dim2(0.5, 0, 0, clampedY); v = 1 - (clampedY / valSlider.AbsoluteSize.Y); update_color()
                    end
                end
            end))

            local api = {
                _isColor = true, NoSave = p.NoSave or p.nosave,
                get_value = function(self) return {R = color.R, G = color.G, B = color.B} end,
                set = function(self, new_color)
                    if type(new_color) == "table" then new_color = Color3.new(new_color.R, new_color.G, new_color.B) end
                    h, s, v = new_color:ToHSV(); update_color()
                    local angle = (h * math.pi * 2) - (math.pi / 2); pickerDot.Position = dim2(0.5 + math.cos(angle) * 0.5 * s, 0, 0.5 + math.sin(angle) * 0.5 * s, 0)
                    valIndicator.Position = dim2(0.5, 0, 0, (1-v) * (valSlider.AbsoluteSize.Y > 0 and valSlider.AbsoluteSize.Y or 100))
                end
            }
            register_element(self, p.Name or p.name or "Colorpicker", api)
            return api
        end

        function section_api:Keybind(p)
            local key = p.default or Enum.KeyCode.Unknown
            local btn = library:create("TextButton", { Parent = p.Parent or self.elements, Size = dim2(1, 0, 0, 32), BackgroundColor3 = Theme.ElementBG, Text = "  " .. (p.Name or p.name or "Keybind") .. " : [" .. key.Name .. "]", TextColor3 = Theme.Text, TextXAlignment = Enum.TextXAlignment.Left, FontFace = library.font, TextSize = 13, AutoButtonColor=false })
            library:create("UICorner", {Parent = btn, CornerRadius = dim(0, 6)}); library:create("UIStroke", {Parent = btn, Color = Theme.Outline, Thickness = 1})
            if p.Premium or p.premium then PremiumOverlay(btn) end
            local picking = false
            btn.MouseButton1Click:Connect(function() picking = true; btn.Text = "  " .. (p.Name or p.name or "Keybind") .. " : [...]" end)
            track_connection(uis.InputBegan:Connect(function(input, gpe)
                if picking and input.UserInputType == Enum.UserInputType.Keyboard then
                    picking = false; key = input.KeyCode; btn.Text = "  " .. (p.Name or p.name or "Keybind") .. " : [" .. key.Name .. "]"
                    if p.Callback then p.Callback(key) end
                end
            end))
            local api = {
                NoSave = p.NoSave or p.nosave,
                get_value = function(self) return key.Name end,
                set = function(self, new_key)
                    if type(new_key) == "string" then local s, k = pcall(function() return Enum.KeyCode[new_key] end); if s and k then key = k end
                    elseif typeof(new_key) == "EnumItem" then key = new_key end
                    btn.Text = "  " .. (p.Name or p.name or "Keybind") .. " : [" .. key.Name .. "]"
                    if p.Callback then task.spawn(function() p.Callback(key) end) end
                end
            }
            register_element(self, p.Name or p.name or "Keybind", api)
            return api
        end

        function section_api:Status(p)
            local holder = library:create("Frame", { Parent = p.Parent or self.elements, Size = dim2(1, 0, 0, 0), BackgroundTransparency = 1, AutomaticSize = Enum.AutomaticSize.Y })
            library:create("UIListLayout", {Parent = holder, Padding = dim(0, 4)})
            library:create("TextLabel", { Parent = holder, Text = "  " .. (p.Name or p.name or "Status"), Size = dim2(1, 0, 0, 20), BackgroundTransparency = 1, TextColor3 = Theme.Accent, FontFace = library.font, TextSize = 13, TextXAlignment = Enum.TextXAlignment.Left })
            local stat_api = {}
            function stat_api:AddStatus(txt)
                local lbl = library:create("TextLabel", { Parent = holder, Text = "  " .. txt, Size = dim2(1, 0, 0, 16), BackgroundTransparency = 1, TextColor3 = Theme.MutedText, FontFace = library.font, TextSize = 12, TextXAlignment = Enum.TextXAlignment.Left })
                return { set = function(self, newTxt) lbl.Text = "  " .. newTxt end }
            end
            return stat_api
        end

        function section_api:List(p)
            local list_api = { items = {} }
            local holder = library:create("Frame", { Parent = p.Parent or self.elements, Size = dim2(1, 0, 0, 0), BackgroundTransparency = 1, AutomaticSize = Enum.AutomaticSize.Y })
            library:create("UIListLayout", {Parent = holder, Padding = dim(0, 4), SortOrder = Enum.SortOrder.LayoutOrder})
            library:create("TextLabel", { Parent = holder, Text = "  " .. (p.Name or p.name or "List"), Size = dim2(1, 0, 0, 20), BackgroundTransparency = 1, TextColor3 = Theme.Accent, FontFace = library.font, TextSize = 13, TextXAlignment = Enum.TextXAlignment.Left })
            function list_api:Add(name)
                local itemBtn = library:create("Frame", { Parent = holder, Size = dim2(1, 0, 0, 28), BackgroundColor3 = Theme.ElementBG, LayoutOrder = #list_api.items })
                library:create("UICorner", {Parent = itemBtn, CornerRadius = dim(0, 4)})
                library:create("TextLabel", { Parent = itemBtn, Text = "  " .. name, Size = dim2(1, -40, 1, 0), BackgroundTransparency = 1, TextColor3 = Theme.Text, FontFace = library.font, TextSize = 12, TextXAlignment = Enum.TextXAlignment.Left })
                table.insert(list_api.items, itemBtn)
                local up = library:create("TextButton", {Parent = itemBtn, Size = dim2(0, 20, 1, 0), Position = dim2(1, -40, 0, 0), BackgroundTransparency = 1, Text = "▲", TextColor3 = Theme.MutedText})
                local dn = library:create("TextButton", {Parent = itemBtn, Size = dim2(0, 20, 1, 0), Position = dim2(1, -20, 0, 0), BackgroundTransparency = 1, Text = "▼", TextColor3 = Theme.MutedText})
                local function swap(dir)
                    local idx = table.find(list_api.items, itemBtn)
                    if idx and list_api.items[idx + dir] then
                        local other = list_api.items[idx + dir]; list_api.items[idx] = other; list_api.items[idx + dir] = itemBtn; itemBtn.LayoutOrder = idx + dir; other.LayoutOrder = idx
                        if p.Callback then local res = {}; for _, v in ipairs(list_api.items) do table.insert(res, v:FindFirstChildOfClass("TextLabel").Text:gsub("^%s+", "")) end; p.Callback(res) end
                    end
                end
                up.MouseButton1Click:Connect(function() swap(-1) end); dn.MouseButton1Click:Connect(function() swap(1) end)
                return itemBtn
            end
            if p.items then for _, v in ipairs(p.items) do list_api:Add(v) end end
            return list_api
        end

        function tab:Section(props)
            local s = {}
            s._name = props.name or props.Name or "Section"
            local parent_col = (string.lower(props.side or "left") == "right") and right_col or left_col

            local wrapper = library:create("Frame", { Parent = parent_col, Size = dim2(1, 0, 0, 0), BackgroundTransparency = 1, AutomaticSize = Enum.AutomaticSize.Y })
            library:create("UIListLayout", {Parent = wrapper, Padding = dim(0, 6), SortOrder = Enum.SortOrder.LayoutOrder})

            local header_frame = library:create("Frame", { Parent = wrapper, Size = dim2(1, 0, 0, 22), BackgroundTransparency = 1, LayoutOrder = 1 })
            library:create("UIListLayout", { Parent = header_frame, FillDirection = Enum.FillDirection.Horizontal, Padding = dim(0, 6), VerticalAlignment = Enum.VerticalAlignment.Center, HorizontalAlignment = Enum.HorizontalAlignment.Center })

            local s_icon = props.icon or props.Icon
            if s_icon then
                local icon_obj = get_icon(s_icon, Theme.Accent)
                if icon_obj then icon_obj.Parent = header_frame; icon_obj.Size = dim2(0, 18, 0, 18) end
            end

            library:create("TextLabel", { Parent = header_frame, Text = props.name or props.Name or "Section", Size = dim2(0, 0, 1, 0), AutomaticSize = Enum.AutomaticSize.X, BackgroundTransparency = 1, TextColor3 = Theme.Accent, FontFace = library.font, TextSize = 16, TextXAlignment = Enum.TextXAlignment.Center })

            s.elements = library:create("Frame", { Parent = wrapper, Size = dim2(1, 0, 0, 0), BackgroundColor3 = Theme.SectionBG, AutomaticSize = Enum.AutomaticSize.Y, LayoutOrder = 2 })
            library:create("UICorner", {Parent = s.elements, CornerRadius = dim(0, 8)})
            library:create("UIStroke", {Parent = s.elements, Color = Theme.Outline, Thickness = 1})
            library:create("UIListLayout", {Parent = s.elements, Padding = dim(0, 8)})
            library:create("UIPadding", { Parent = s.elements, PaddingTop = dim(0, 10), PaddingBottom = dim(0, 10), PaddingLeft = dim(0, 10), PaddingRight = dim(0, 10) })

            setmetatable(s, { __index = section_api })
            return s
        end

        function tab:ViewportSection(props)
            props = props or {}
            local v = {}
            v._name = props.name or props.Name or "Viewport"

            local run_service = game:GetService("RunService")
            local parent_col = (string.lower(props.side or "left") == "right") and right_col or left_col
            local height = tonumber(props.height or props.Height or props.size or props.Size) or 160
            if height < 40 then height = 40 end

            local wrapper = library:create("Frame", { Parent = parent_col, Size = dim2(1, 0, 0, 0), BackgroundTransparency = 1, AutomaticSize = Enum.AutomaticSize.Y })
            library:create("UIListLayout", { Parent = wrapper, Padding = dim(0, 6), SortOrder = Enum.SortOrder.LayoutOrder })

            local show_header = (props.hide_title ~= true and props.HideTitle ~= true)
            if show_header then
                local header_frame = library:create("Frame", { Parent = wrapper, Size = dim2(1, 0, 0, 22), BackgroundTransparency = 1, LayoutOrder = 1 })
                library:create("UIListLayout", { Parent = header_frame, FillDirection = Enum.FillDirection.Horizontal, Padding = dim(0, 6), VerticalAlignment = Enum.VerticalAlignment.Center, HorizontalAlignment = Enum.HorizontalAlignment.Center })

                local v_icon = props.icon or props.Icon
                if v_icon then
                    local icon_obj = get_icon(v_icon, Theme.Accent)
                    if icon_obj then icon_obj.Parent = header_frame; icon_obj.Size = dim2(0, 18, 0, 18) end
                end

                library:create("TextLabel", { Parent = header_frame, Text = v._name, Size = dim2(0, 0, 1, 0), AutomaticSize = Enum.AutomaticSize.X, BackgroundTransparency = 1, TextColor3 = Theme.Accent, FontFace = library.font, TextSize = 16, TextXAlignment = Enum.TextXAlignment.Center })
            end

            local holder = library:create("Frame", {
                Parent = wrapper, Size = dim2(1, 0, 0, height), BackgroundColor3 = props.background or Theme.SectionBG,
                LayoutOrder = 2, ClipsDescendants = true, BorderSizePixel = 0
            })
            library:create("UICorner", { Parent = holder, CornerRadius = dim(0, 8) })
            library:create("UIStroke", { Parent = holder, Color = Theme.Outline, Thickness = 1 })

            local vpf = library:create("ViewportFrame", {
                Parent = holder,
                Size = dim2(1, 0, 1, 0),
                BackgroundTransparency = 1,
                BorderSizePixel = 0,
                Ambient = props.ambient or props.Ambient or rgb(190, 190, 190),
                LightColor = props.light_color or props.LightColor or rgb(255, 255, 255),
                LightDirection = props.light_direction or props.LightDirection or Vector3.new(-1, -1, -1),
                ZIndex = 2
            })

            local world = Instance.new("WorldModel")
            world.Parent = vpf

            local cam = Instance.new("Camera")
            cam.FieldOfView = tonumber(props.fov or props.FOV or props.FieldOfView) or 70
            cam.Parent = vpf
            vpf.CurrentCamera = cam

            local placeholder = library:create("TextLabel", {
                Parent = holder, Size = dim2(1, -20, 1, 0), Position = dim2(0, 10, 0, 0), BackgroundTransparency = 1,
                Text = props.placeholder or "No objects", TextColor3 = Theme.MutedText, FontFace = library.font,
                TextSize = 12, TextWrapped = true, ZIndex = 3
            })

            local objects = {}

            local orbit = {
                yaw = math.rad(tonumber(props.yaw) or 35),
                pitch = math.rad(tonumber(props.pitch) or 20),
                dist = tonumber(props.distance or props.Distance) or 12,
                center = props.center or Vector3.new(0, 0, 0)
            }

            local function apply_orbit()
                local cp = math.cos(orbit.pitch)
                local dir = Vector3.new(cp * math.sin(orbit.yaw), math.sin(orbit.pitch), cp * math.cos(orbit.yaw))
                cam.CFrame = CFrame.new(orbit.center + dir * orbit.dist, orbit.center)
            end
            apply_orbit()

            local function collect_parts(inst, out)
                if inst:IsA("BasePart") then table.insert(out, inst) end
                for _, d in ipairs(inst:GetDescendants()) do
                    if d:IsA("BasePart") then table.insert(out, d) end
                end
            end

            local function compute_bounds()
                local min_v, max_v
                for _, obj in ipairs(objects) do
                    if typeof(obj) == "Instance" and obj.Parent then
                        local parts = {}
                        collect_parts(obj, parts)
                        for _, part in ipairs(parts) do
                            local pos, sz = part.Position, part.Size
                            local lo = pos - sz / 2
                            local hi = pos + sz / 2
                            if not min_v then
                                min_v, max_v = lo, hi
                            else
                                min_v = Vector3.new(math.min(min_v.X, lo.X), math.min(min_v.Y, lo.Y), math.min(min_v.Z, lo.Z))
                                max_v = Vector3.new(math.max(max_v.X, hi.X), math.max(max_v.Y, hi.Y), math.max(max_v.Z, hi.Z))
                            end
                        end
                    end
                end
                if not min_v then return nil end
                return (min_v + max_v) / 2, (max_v - min_v)
            end

            local function refresh_placeholder()
                placeholder.Visible = (#objects == 0)
            end

            function v:Focus(padding)
                local center, size = compute_bounds()
                if not center then return self end
                local radius = math.max(size.Magnitude / 2, 0.5)
                local half_fov = math.rad(cam.FieldOfView / 2)
                orbit.center = center
                orbit.dist = (radius / math.max(math.tan(half_fov), 0.01)) * (tonumber(padding) or 1.25)
                apply_orbit()
                return self
            end
            v.Fit = v.Focus

            function v:Add(obj, opts)
                opts = opts or {}
                if typeof(obj) == "table" then
                    local added = {}
                    for _, o in ipairs(obj) do table.insert(added, self:Add(o, opts)) end
                    return added
                end
                if typeof(obj) ~= "Instance" then return nil end

                local target = obj
                local should_clone = opts.clone
                if should_clone == nil then should_clone = (obj.Parent ~= nil) end
                if should_clone then
                    local ok, copy = pcall(function()
                        obj.Archivable = true
                        return obj:Clone()
                    end)
                    if ok and copy then target = copy end
                end

                if opts.cframe and (target:IsA("BasePart") or target:IsA("Model")) then
                    pcall(function()
                        if target:IsA("Model") then target:PivotTo(opts.cframe) else target.CFrame = opts.cframe end
                    end)
                end

                target.Parent = world
                table.insert(objects, target)
                refresh_placeholder()

                if props.auto_focus ~= false and opts.focus ~= false then self:Focus() end
                return target
            end
            v.Insert = v.Add
            v.AddObject = v.Add

            function v:AddMany(list, opts)
                return self:Add(list, opts)
            end

            function v:Remove(obj)
                for i = #objects, 1, -1 do
                    if objects[i] == obj then
                        table.remove(objects, i)
                        pcall(function() obj:Destroy() end)
                    end
                end
                refresh_placeholder()
                return self
            end

            function v:Clear()
                for i = #objects, 1, -1 do
                    local o = objects[i]
                    objects[i] = nil
                    pcall(function() o:Destroy() end)
                end
                refresh_placeholder()
                return self
            end

            function v:GetObjects() return objects end
            function v:Count() return #objects end

            function v:SetHeight(new_height, animate)
                new_height = math.max(tonumber(new_height) or height, 40)
                height = new_height
                if animate then
                    library:tween(holder, { Size = dim2(1, 0, 0, new_height) }, 0.2)
                else
                    holder.Size = dim2(1, 0, 0, new_height)
                end
                return self
            end
            v.set_height = v.SetHeight
            function v:GetHeight() return height end

            function v:SetCamera(cframe, fov)
                if typeof(cframe) == "CFrame" then cam.CFrame = cframe end
                if tonumber(fov) then cam.FieldOfView = tonumber(fov) end
                return self
            end
            function v:GetCamera() return cam end

            function v:SetDistance(d)
                orbit.dist = math.max(tonumber(d) or orbit.dist, 0.1)
                apply_orbit()
                return self
            end

            function v:SetAngles(yaw_deg, pitch_deg)
                if tonumber(yaw_deg) then orbit.yaw = math.rad(yaw_deg) end
                if tonumber(pitch_deg) then orbit.pitch = math.clamp(math.rad(pitch_deg), -1.5, 1.5) end
                apply_orbit()
                return self
            end

            function v:SetVisible(state)
                wrapper.Visible = state and true or false
                return self
            end

            local spin_conn
            function v:SetAutoRotate(enabled, speed)
                speed = tonumber(speed) or 0.6
                if spin_conn then spin_conn:Disconnect(); spin_conn = nil end
                if enabled then
                    spin_conn = run_service.RenderStepped:Connect(function(dt)
                        orbit.yaw = orbit.yaw + speed * dt
                        apply_orbit()
                    end)
                    track_connection(spin_conn)
                end
                return self
            end

            if props.rotatable ~= false then
                local dragging, last_pos = false, nil
                vpf.InputBegan:Connect(function(input)
                    if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
                        dragging = true; last_pos = input.Position
                    end
                end)
                track_connection(uis.InputEnded:Connect(function(input)
                    if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
                        dragging = false
                    end
                end))
                track_connection(uis.InputChanged:Connect(function(input)
                    if dragging and last_pos and (input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch) then
                        local delta = input.Position - last_pos
                        last_pos = input.Position
                        orbit.yaw = orbit.yaw - delta.X * 0.01
                        orbit.pitch = math.clamp(orbit.pitch + delta.Y * 0.01, -1.4, 1.4)
                        apply_orbit()
                    end
                end))

                local hovering = false
                vpf.MouseEnter:Connect(function() hovering = true end)
                vpf.MouseLeave:Connect(function() hovering = false end)
                track_connection(uis.InputChanged:Connect(function(input)
                    if hovering and input.UserInputType == Enum.UserInputType.MouseWheel then
                        orbit.dist = math.clamp(orbit.dist - input.Position.Z * (orbit.dist * 0.12), 0.5, 5000)
                        apply_orbit()
                    end
                end))
            end

            function v:Destroy()
                if spin_conn then pcall(function() spin_conn:Disconnect() end) end
                self:Clear()
                wrapper:Destroy()
            end

            v.instance = vpf
            v.viewport = vpf
            v.holder = holder
            v.world = world
            v.camera = cam
            v.wrapper = wrapper

            refresh_placeholder()
            if props.auto_rotate or props.AutoRotate then v:SetAutoRotate(true, props.rotate_speed) end
            if props.objects then v:Add(props.objects) end

            return v
        end
        tab.Viewport = tab.ViewportSection

        return tab
    end

do

    local function retint(old_color, new_color)
        local epsilon = 0.008
        local function matches(c)
            return math.abs(c.R - old_color.R) < epsilon
               and math.abs(c.G - old_color.G) < epsilon
               and math.abs(c.B - old_color.B) < epsilon
        end
        for _, v in ipairs(screen:GetDescendants()) do
            if v:IsA("GuiObject") and matches(v.BackgroundColor3) then
                library:tween(v, { BackgroundColor3 = new_color }, 0.3)
            end
            if (v:IsA("TextLabel") or v:IsA("TextButton") or v:IsA("TextBox")) and matches(v.TextColor3) then
                library:tween(v, { TextColor3 = new_color }, 0.3)
            end
            if v:IsA("UIStroke") and matches(v.Color) then
                library:tween(v, { Color = new_color }, 0.3)
            end
            if (v:IsA("ImageLabel") or v:IsA("ImageButton")) and matches(v.ImageColor3) then
                library:tween(v, { ImageColor3 = new_color }, 0.3)
            end
        end
    end

    local defaultTheme = {}
    for k, v in pairs(Theme) do defaultTheme[k] = v end

    local st = win:Tab({ name = "UI Settings", icon = "lucide:settings-2", _layoutOrder = 999999, _noAutoSelect = true })

    local colorSection = st:Section({ name = "Colors", side = "left" })

    colorSection:Colorpicker({
        name = "Accent Color",
        default = Theme.Accent,
        Callback = function(color)
            local old = Theme.Accent
            Theme.Accent = color
            retint(old, color)
        end
    })

    colorSection:Colorpicker({
        name = "Main Background",
        default = Theme.MainBG,
        Callback = function(color)
            local old = Theme.MainBG
            Theme.MainBG = color
            retint(old, color)
        end
    })

    colorSection:Colorpicker({
        name = "Sidebar Color",
        default = Theme.SidebarBG,
        Callback = function(color)
            local old = Theme.SidebarBG
            Theme.SidebarBG = color
            retint(old, color)
        end
    })

    colorSection:Colorpicker({
        name = "Element Color",
        default = Theme.ElementBG,
        Callback = function(color)
            local old = Theme.ElementBG
            Theme.ElementBG = color
            retint(old, color)
        end
    })

    colorSection:Colorpicker({
        name = "Text Color",
        default = Theme.Text,
        Callback = function(color)
            local old = Theme.Text
            Theme.Text = color
            retint(old, color)
        end
    })

    local controlSection = st:Section({ name = "Controls", side = "right" })

    controlSection:Keybind({
        name = "Toggle Menu",
        default = Enum.KeyCode.RightControl,
        Callback = function(key)
            toggleKey = key
        end
    })

    controlSection:Slider({
        name = "UI Opacity",
        min = 0,
        max = 100,
        default = 100,
        decimals = 0,
        Callback = function(val)
            local t = 1 - (val / 100)
            library:tween(main, { BackgroundTransparency = t }, 0.2)
        end
    })

    local miscSection = st:Section({ name = "Miscellaneous", side = "right" })

    miscSection:Button({
        name = "Reset Colors to Default",
        Callback = function()
            for k, v in pairs(defaultTheme) do
                local old = Theme[k]
                if typeof(old) == "Color3" then
                    Theme[k] = v
                    retint(old, v)
                end
            end
            library:create_notification({ name = "Theme reset to defaults.", duration = 3 })
        end
    })

    miscSection:Button({
        name = "Close Menu",
        Callback = function()
            win.toggle_menu(false)
        end
    })

    local mobileSection = st:Section({ name = "Mobile", side = "left" })
    local activeFloatingBtns = {}

    local function createFloatingButton(toggleName, toggleApi)
        local floatGui = library:create("ScreenGui", { Parent = ui_parent, Name = "MobileBtn_" .. toggleName, ResetOnSpawn = false, ZIndexBehavior = Enum.ZIndexBehavior.Sibling })
        local floatBtn = library:create("TextButton", {
            Parent = floatGui, Size = dim2(0, 52, 0, 52),
            Position = dim2(0, 20, 0.5, -26 + (#activeFloatingBtns * 60)),
            BackgroundColor3 = toggleApi.enabled and Theme.Accent or Theme.ElementBG,
            Text = "", AutoButtonColor = false
        })
        library:create("UICorner", { Parent = floatBtn, CornerRadius = dim(1, 0) })
        library:create("UIStroke", { Parent = floatBtn, Color = Theme.Outline, Thickness = 1.5 })

        local abbrev = string.sub(toggleName, 1, 3):upper()
        local floatLabel = library:create("TextLabel", {
            Parent = floatBtn, Size = dim2(1, 0, 1, 0), BackgroundTransparency = 1,
            Text = abbrev, TextColor3 = toggleApi.enabled and Theme.MainBG or Theme.Text,
            FontFace = library.font, TextSize = 12, TextTruncate = Enum.TextTruncate.AtEnd
        })

        local dragging, dragStart, startPos = false, nil, nil
        local hasMoved = false
        floatBtn.InputBegan:Connect(function(input)
            if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
                dragging = true; hasMoved = false
                dragStart = input.Position; startPos = floatBtn.Position
            end
        end)
        track_connection(uis.InputChanged:Connect(function(input)
            if dragging and (input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch) then
                local delta = input.Position - dragStart
                if delta.Magnitude > 4 then hasMoved = true end
                floatBtn.Position = dim2(startPos.X.Scale, startPos.X.Offset + delta.X, startPos.Y.Scale, startPos.Y.Offset + delta.Y)
            end
        end))
        track_connection(uis.InputEnded:Connect(function(input)
            if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
                if dragging and not hasMoved then

                    toggleApi:set(not toggleApi.enabled)
                    library:tween(floatBtn, { BackgroundColor3 = toggleApi.enabled and Theme.Accent or Theme.ElementBG }, 0.15)
                    floatLabel.TextColor3 = toggleApi.enabled and Theme.MainBG or Theme.Text
                end
                dragging = false
            end
        end))

        return {
            gui = floatGui,
            destroy = function() floatGui:Destroy() end,
            sync = function()
                floatBtn.BackgroundColor3 = toggleApi.enabled and Theme.Accent or Theme.ElementBG
                floatLabel.TextColor3 = toggleApi.enabled and Theme.MainBG or Theme.Text
            end
        }
    end

    function win:RefreshMobileButtonStates()
        for name, entry in pairs(activeFloatingBtns) do
            if entry.sync then entry.sync() end
        end
    end

    local function refreshMobileButtons(selectedNames)

        for name, entry in pairs(activeFloatingBtns) do
            if not table.find(selectedNames, name) then
                entry.destroy()
                activeFloatingBtns[name] = nil
            end
        end

        for _, name in ipairs(selectedNames) do
            if not activeFloatingBtns[name] then
                for _, reg in ipairs(win._toggleRegistry) do
                    if reg.name == name then
                        activeFloatingBtns[name] = createFloatingButton(name, reg.api)
                        break
                    end
                end
            end
        end
    end

    local mobileDropdown = mobileSection:Dropdown({
        name = "Mobile Buttons",
        multi = true,
        items = {},
        default = {},
        Callback = function(selected) refreshMobileButtons(selected) end
    })

    function win:RefreshMobileList()
        local names, seen = {}, {}
        for _, reg in ipairs(win._toggleRegistry) do
            local label = reg.name
            if seen[label] then label = reg.key end
            seen[reg.name] = true
            table.insert(names, label)
        end
        mobileDropdown:set_items(names)
    end
end

return win
end

function library:create_notification(props)
    local name = props.name or props.Name or "Notification"
    local duration = props.duration or 4

    local notif = library:create("Frame", {
        Parent = notif_container,
        Size = dim2(1, 0, 0, 40),
        BackgroundColor3 = Theme.ElementBG,
        BackgroundTransparency = 1
    })
    library:create("UICorner", {Parent = notif, CornerRadius = dim(0, 6)})
    local stroke = library:create("UIStroke", {Parent = notif, Color = Theme.Outline, Thickness = 1, Transparency = 1})

    local title = library:create("TextLabel", {
        Parent = notif,
        Size = dim2(1, -20, 1, 0),
        Position = dim2(0, 10, 0, 0),
        BackgroundTransparency = 1,
        Text = name,
        TextColor3 = Theme.Text,
        FontFace = library.font,
        TextSize = 13,
        TextXAlignment = Enum.TextXAlignment.Left,
        TextTransparency = 1
    })

    library:tween(notif, {BackgroundTransparency = 0}, 0.3)
    library:tween(stroke, {Transparency = 0}, 0.3)
    library:tween(title, {TextTransparency = 0}, 0.3)

    task.delay(duration, function()
        local fade = library:tween(notif, {BackgroundTransparency = 1}, 0.5)
        library:tween(stroke, {Transparency = 1}, 0.5)
        library:tween(title, {TextTransparency = 1}, 0.5)
        fade.Completed:Connect(function()
            notif:Destroy()
        end)
    end)
end

return library, library
end)()

local function setCfg(key)
	return function(v)
		if cfg[key] ~= v then cfg[key] = v saveCfg() end
	end
end

local win = Monolith:window({ name = "Eze Hub" })
local screen = (gethui and gethui() or game:GetService("CoreGui")):FindFirstChild("MonolithUI")
S.gui = screen

local function toggle(sec, name, key)
	sec:Toggle({ name = name, default = cfg[key], NoSave = true, Callback = setCfg(key) })
end

local function slider(sec, name, min, max, key)
	sec:Slider({ name = name, min = min, max = max, default = cfg[key], decimals = 0, NoSave = true,
		Callback = function(v) setCfg(key)(math.floor(v + 0.5)) end })
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

local aimTab = win:Tab({ name = "Aim", icon = "lucide:crosshair" })
local shots = aimTab:Section({ name = "Silent Aim", side = "left" })
toggle(shots, "Silent Aim (shots)", "aim")
toggle(shots, "Max Curve", "curve")
shots:Dropdown({ name = "Corner Height", items = { "Auto", "High", "Low" }, default = cfg.height, NoSave = true, Callback = setCfg("height") })
slider(shots, "Max Distance", 40, 230, "range")
toggle(shots, "Show Target", "showTarget")
toggle(shots, "Silent Aim (Bicycle / Volley)", "volley")
local aimStatus = aimTab:Section({ name = "Status", side = "right" })
liveLabel(aimStatus, function() return S.status or "Idle" end)
liveLabel(aimStatus, function() return S.last or "No shot yet" end)

local playTab = win:Tab({ name = "Dribble", icon = "lucide:footprints" })
local drib = playTab:Section({ name = "Auto Dribble", side = "left" })
toggle(drib, "Auto Dribble", "dribble")
slider(drib, "Trigger Range", 5, 20, "dribbleRange")
liveLabel(drib, function() return S.dribbleStatus or "Dodges when an opponent rushes you with the ball" end)
local tack = playTab:Section({ name = "Auto Tackle", side = "right" })
toggle(tack, "Auto Tackle", "tackle")
slider(tack, "Lock-on Range", 6, 20, "tackleRange")
liveLabel(tack, function() return S.tackleStatus or "Locks onto the ball carrier and slides only when the hit is certain" end)

local gkTab = win:Tab({ name = "Keeper", icon = "lucide:shield" })
local gk = gkTab:Section({ name = "Auto Keeper", side = "left" })
toggle(gk, "Auto Save (dive)", "save")
toggle(gk, "Auto Position (experimental)", "gkPosition")
gk:Label({ name = "Works when you're the goalkeeper. Dives at the last moment toward where the ball (curve included) will cross your line." })
local gkStat = gkTab:Section({ name = "Status", side = "right" })
liveLabel(gkStat, function() return S.gkStatus or "Waiting" end)

local miscTab = win:Tab({ name = "Misc", icon = "lucide:info" })
local info = miscTab:Section({ name = "Info", side = "left" })
info:Label({ name = "Shoot as usual: the shot is re-aimed at the corner farthest from the keeper, with max curve, and the height is solved for your charge." })
info:Label({ name = "Toggle the UI with RightControl." })
local actions = miscTab:Section({ name = "Script", side = "right" })
actions:Button({ name = "Unload Script", Callback = function() S.Unload() end })

function S.Unload()
	S.sol = nil
	if G.SSPAim == S then G.SSPAim = nil end
	for _, c in ipairs(S.conns) do c:Disconnect() end
	if S.marker then S.marker:Destroy() end
	pcall(function() Monolith:Unload() end)
end

if screen then
	table.insert(S.conns, screen.AncestryChanged:Connect(function(_, parent)
		if parent == nil and G.SSPAim == S then S.Unload() end
	end))
end

Monolith:create_notification({ name = "Eze Hub loaded - RightControl to toggle", duration = 4 })
