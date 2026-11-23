local VERSION = "1.8.1"
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
	local v0, s0 = v, spin
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
		if np.Y <= 0 and v.Y < 0 then

			local ok, tt, hit = pcall(Keeper.plane, start, v0, s0, gx < 0 and Match.WEST or Match.EAST, 0)
			if ok and tt and hit then return hit.Z, math.max(hit.Y, 0.8), tt, dir, true end
			return nil
		end
		pos, t = np, t + DT
	end
	return nil
end

local function solve(start, gx, tz, ty, launch)
	local yaw = math.atan2(tz - start.Z, gx - start.X)
	local pitch, best = 0, nil
	for _ = 1, 22 do
		local z, y, _, _, rolled = fly(start, gx, yaw, pitch, launch)
		if not z then
			pitch += 5
			if pitch > 45 then return best end
		elseif rolled and ty < 3 then
			local ez = z - tz
			local err = math.abs(ez)
			if not best or err < best.err then best = { yaw = yaw, pitch = pitch, err = err, rolled = true } end
			if err < 0.12 then break end
			local z1 = fly(start, gx, yaw + 0.004, pitch, launch)
			if not z1 or math.abs(z1 - z) < 1e-6 then break end
			yaw -= math.clamp(ez / ((z1 - z) / 0.004), -0.25, 0.25)
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

local function findWorld()
	local w = S.world
	if w then
		local ok, has = pcall(function() for _ in w:query(Comp.CHARACTER) do return true end end)
		if ok and has then return w end
	end
	S.world = nil
	if os.clock() - (S.worldScanAt or 0) < 3 then return nil end
	S.worldScanAt = os.clock()
	local fallback
	for _, t in ipairs(getgc(true)) do
		if type(t) == "table" and rawget(t, "entity_index") ~= nil and rawget(t, "query") ~= nil then
			local ok, ball, char = pcall(function()
				local b, c = false, false
				for _ in t:query(Comp.FOOTBALL) do b = true break end
				for _ in t:query(CComp.OWNED) do c = true break end
				return b, c
			end)
			if ok and char then
				if ball then S.world = t return t end
				fallback = fallback or t
			end
		end
	end
	S.world = fallback
	return fallback
end

local function myEntity(w)
	for e in w:query(CComp.OWNED) do
		if w:has(e, Comp.CHARACTER) then return e end
	end
end

local function entPos(w, e)
	return w:get(e, CComp.render_position) or w:get(e, Comp.position)
end

local function myPos()
	local w = findWorld()
	if not w then return nil end
	local me = myEntity(w)
	return me and entPos(w, me), me, w
end

local function isEnemy(model)
	local w = S.world
	if not w then return nil end
	local p = model:GetPivot().Position
	local best, bd
	for e in w:query(Comp.CHARACTER) do
		local q = entPos(w, e)
		if q then
			local d = ((q - p) * Vector3.new(1, 0, 1)).Magnitude
			if d < 4 and (not bd or d < bd) then best, bd = e, d end
		end
	end
	if not best then return nil end
	local me = myEntity(w)
	if best == me then return false end
	local ms, es = me and w:get(me, Comp.side), w:get(best, Comp.side)
	if ms and es then return ms ~= es end
	return nil
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

local function logShot(line)
	pcall(appendfile, "ssp_shotlog.txt", os.date("%H:%M:%S ") .. line .. string.char(10))
end

local function watchShot(sol, biasKey, label)
	task.spawn(function()
		local t0, prev = os.clock(), ballPos()
		local crossed = false
		while os.clock() - t0 < 4 and alive() do
			task.wait()
			local p = ballPos()
			if p and prev and (p.X - sol.target.X) * (prev.X - sol.target.X) <= 0 and (p - prev).Magnitude < 20 then
				local a = (sol.target.X - prev.X) / (p.X - prev.X)
				local hit = prev + (p - prev) * a
				S.last = ("%s: target z %.1f y %.1f | crossed z %.1f y %.1f"):format(label, sol.target.Z, sol.target.Y, hit.Z, hit.Y)
				crossed = true
				local inGoal = math.abs(hit.Z) < HALF_W - 0.79 and hit.Y < BAR - 0.79
				logShot(("  RESULT crossed z %.2f y %.2f (target z %.2f y %.2f, miss dz %.2f dy %.2f) %s"):format(hit.Z, hit.Y, sol.target.Z, sol.target.Y, hit.Z - sol.target.Z, hit.Y - sol.target.Y, inGoal and "IN" or "OUT/POST"))
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
		if not crossed then
			local p = ballPos()
			logShot(("  RESULT never reached the goal line (blocked, saved or wide) - ball last at %s"):format(p and ("x %.0f z %.0f y %.1f"):format(p.X, p.Z, p.Y) or "?"))
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
			found.power, found.from, found.leadFresh = power, from, lead ~= nil and lead ~= false
			found.tplAge = S.fireAt and os.clock() - S.fireAt or nil
			found.keeper = keeper ~= nil
			found.charge = prog
			S.status = ("Aiming %s %s corner | curve %+d | charge %d%%%s"):format(
				c.y > 3 and "top" or "low", (c.z > 0) == (gx > 0) and "left" or "right",
				found.curve, prog * 100, keeper and " | keeper read" or "")
			return found
		end
	end

	local kz = keeper and keeper:GetPivot().Position.Z or -from.Z
	local zs = { HALF_W - 3, -(HALF_W - 3), HALF_W - 5.5, -(HALF_W - 5.5), 0 }
	table.sort(zs, function(a, b) return math.abs(a - kz) > math.abs(b - kz) end)
	for _, z in ipairs(zs) do
		for _, y in ipairs({ 1.6, 4 }) do
			for _, cv in ipairs({ 0, 1, -1 }) do
				local s = solve(from, gx, z, y, shotLaunch(cv, prog, power, force ~= nil))
				if s and s.err < 0.8 then
					s.curve = cv
					s.target = Vector3.new(gx, y, z)
					s.power, s.from, s.leadFresh = power, from, lead ~= nil and lead ~= false
					s.tplAge = S.fireAt and os.clock() - S.fireAt or nil
					s.keeper, s.charge, s.fallback = keeper ~= nil, prog, true
					S.status = ("Aiming safe spot z %.1f%s | curve %+d | charge %d%%"):format(z, s.rolled and " (rolling)" or "", cv, prog * 100)
					return s
				end
			end
		end
	end
	S.status = "Too weak to reach the goal - charge more"
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
			s.spot = m.spot
			S.status = ("Volley -> %s %s corner%s"):format(c.y > 3 and "top" or "low",
				(c.z > 0) == (gx > 0) and "left" or "right", keeper and " | keeper read" or "")
			return s
		end
	end

	local kz = keeper and keeper:GetPivot().Position.Z or -m.spot.Z
	local zs = { HALF_W - 3.2, -(HALF_W - 3.2), HALF_W - 5.5, -(HALF_W - 5.5), 0 }
	table.sort(zs, function(a, b) return math.abs(a - kz) > math.abs(b - kz) end)
	for _, z in ipairs(zs) do
		for _, y in ipairs({ 4, BAR - 3, 1.6 }) do
			local s = solve(m.spot, gx, z, y, launch)
			if s and s.err < 0.8 then
				s.curve, s.fallback, s.spot = 0, true, m.spot
				s.target = Vector3.new(gx, y, z)
				S.status = ("Volley -> safe spot z %.1f height %.1f%s"):format(z, y, s.rolled and " (rolling)" or "")
				return s
			end
		end
	end
	S.status = "Volley: goal out of reach from this touch"
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

local SHOT_ACTIONS = { [2] = "charging", [3] = "shooting", [35] = "shooting", [36] = "shooting", [37] = "shooting", [14] = "volleying", [13] = "heading" }
local function aimOf(w, e)
	local q = w:get(e, Comp.rotation)
	if type(q) ~= "table" or not q.y or not q.w then return nil end
	local yaw = 2 * math.atan2(q.y, q.w)
	local f = Vector3.new(-math.sin(yaw), 0, -math.cos(yaw))
	local lk = w:get(e, Comp.look)
	local o = typeof(lk) == "Vector3" and lk.X or 0
	return (f * math.cos(o) + Vector3.new(f.Z, 0, -f.X) * math.sin(o)).Unit
end

local function readShooter(w, me, side, holder, bp, goal, lineX)
	local mySide = side
	local best, bestKind, bestD
	local now = Clock.server()
	for e in w:query(Comp.CHARACTER) do
		if e ~= me then
			local es = w:get(e, Comp.side)
			if es == nil or es ~= mySide then
				local act = w:get(e, Comp.action)
				local kind = type(act) == "table" and act.kind
				local fresh = type(act) == "table" and act.at and now - act.at < 1.5
				local label = (e == holder and "on the ball") or (fresh and SHOT_ACTIONS[kind])
				if label then
					local p = entPos(w, e)
					local d = p and ((p - bp) * Vector3.new(1, 0, 1)).Magnitude or math.huge
					if d < 8 and (not bestD or d < bestD) then best, bestKind, bestD = e, label, d end
				end
			end
		end
	end
	if not best then return nil end
	local dir = aimOf(w, best)
	if not dir or math.abs(dir.X) < 0.05 or (goal.X - bp.X) * dir.X <= 0 then
		return { kind = bestKind, onTarget = false }
	end
	local z = bp.Z + dir.Z * (lineX - bp.X) / dir.X
	return { kind = bestKind, z = z, onTarget = math.abs(z) < HALF_W + 3 }
end

local function keeperStep(now)
	if not (cfg.save or cfg.gkPosition or cfg.tackle) then S.gkMove, S.isKeeper = nil, false return end
	local w = findWorld()
	if not w then S.gkMove, S.gkStatus = nil, "Game data not found yet" return end
	local ok, err = pcall(function()
		local me = myEntity(w)
		S.isKeeper = me ~= nil and w:has(me, Comp.GOALKEEPER)
		if not S.isKeeper or not (cfg.save or cfg.gkPosition) then
			S.gkMove = nil
			if not S.isKeeper then S.gkStatus = "Not keeper right now" end
			return
		end
		local side = w:get(me, Comp.side)
		if side ~= Match.WEST and side ~= Match.EAST then S.gkMove, S.gkStatus = nil, "Not in a match (no team side)" return end
		local mePos = entPos(w, me)
		if not mePos then S.gkMove, S.gkStatus = nil, "Can't read your position" return end
		local goal = Match.goal_of(side)
		local depth = math.clamp(math.abs(mePos.X - goal.X), 0.5, 12)
		local ball
		for e in w:query(Comp.FOOTBALL) do ball = e break end
		if not ball then S.gkMove, S.gkStatus = nil, "No ball on the pitch" return end
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
		local lineX = goal.X - math.sign(goal.X) * depth
		local read = readShooter(w, me, side, holder, bp, goal, lineX)
		local readText = read and (read.z and ("Shooter %s, aiming z %.1f%s"):format(read.kind, read.z, read.onTarget and "" or " (off target)")
			or ("Shooter %s, not aiming at goal"):format(read.kind)) or "No shooter"
		if not cfg.gkPosition then S.gkMove, S.gkStatus = nil, "Ready | " .. readText return end

		local k = (lineX - bp.X) / (goal.X - bp.X)
		local coverZ = bp.Z + (0 - bp.Z) * math.clamp(k, 0, 1)
		if read and read.z and read.onTarget then coverZ = coverZ * 0.3 + read.z * 0.7 end
		coverZ = math.clamp(coverZ, -(HALF_W - 1.5), HALF_W - 1.5)
		local target = Vector3.new(lineX, mePos.Y, coverZ)
		local to = (target - mePos) * Vector3.new(1, 0, 1)

		S.gkMove = to.Magnitude > 1.2 and to.Unit * math.clamp(to.Magnitude / 5, 0.25, 1) or nil
		S.gkStatus = ("Covering z %.1f | %s"):format(coverZ, readText)
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
		local me, ball = myPos(), ballPos()
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
		local me = myPos()
		if me then
			local prev = S.mePos
			S.meVel = prev and (S.meVel or Vector3.zero):Lerp((me - prev) / math.max(dt, 1 / 240), 0.3) or Vector3.zero
			S.mePos = me
		end
		keeperStep(os.clock())
		local okv, started = pcall(Volley.get)
		if okv and started and started ~= S.lastVolley then
			S.lastVolley = started
			if S.vsol and os.clock() - (S.vsolAt or 0) < 0.5 then
				S.volleyAt, S.volleySolUsed = os.clock(), S.vsol
				local v = S.vsol
				logShot(("VOLLEY%s index %s target z %.1f y %.1f from x %.0f z %.0f y %.1f solveErr %.2f"):format(v.fallback and " (fallback spot)" or "",
					tostring(started.meeting and started.meeting.index), v.target.Z, v.target.Y, v.spot and v.spot.X or 0, v.spot and v.spot.Z or 0, v.spot and v.spot.Y or 0, v.err or -1))
			elseif cfg.volley then
				logShot("VOLLEY NOT AIMED: " .. tostring(S.status))
			end
		end
		if not (okv and started) then S.lastVolley = nil end
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
	if charging then S.wasCharging = true end
	if not (cfg.aim and charging) then
		if S.sol then
			local sol = S.sol
			logShot(("SHOT%s %s charge %d%% curve %+d target z %.1f y %.1f from x %.0f z %.0f (dist %.0f) solveErr %.2f lead %s tplAge %s curveMult %.2f bias y %.2f z %.2f"):format(
				sol.fallback and " (fallback spot)" or (sol.rolled and " (rolling)" or ""), sol.power and "POWER" or "normal", (sol.charge or 0) * 100, sol.curve or 0, sol.target.Z, sol.target.Y,
				sol.from and sol.from.X or 0, sol.from and sol.from.Z or 0, sol.from and math.abs(sol.target.X - sol.from.X) or 0, sol.err or -1,
				tostring(sol.leadFresh), sol.tplAge and ("%.2f"):format(sol.tplAge) or "none", S.curveMult or 1,
				(G.SSPAimBias or { y = 0 }).y, (G.SSPAimBias or { z = 0 }).z))
			watchShot(sol, "SSPAimBias", "Last shot")
		elseif S.wasCharging and cfg.aim then
			logShot("SHOT NOT AIMED: " .. tostring(S.status))
		end
		S.wasCharging = false
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

local Monolith = loadstring(game:HttpGet("https://raw.githubusercontent.com/mechupacristopher-creator/lua/main/lib/eze_ui.lua"))()

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
