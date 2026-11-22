local VERSION = "1.2.0"
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
if setthreadidentity then pcall(setthreadidentity, 8) end

local cfg = {
	aim = false, curve = true, height = "Auto", showTarget = false, range = 220, margin = 2,
	volley = false, dribble = false, dribbleRange = 10, tackle = false, tackleRange = 8,
}
pcall(function() for k, v in pairs(Http:JSONDecode(readfile(CFG_FILE))) do cfg[k] = v end end)
local function saveCfg() pcall(writefile, CFG_FILE, Http:JSONEncode(cfg)) end
if (cfg.cfgVersion or 0) < 2 then
	cfg.range, cfg.cfgVersion = math.max(cfg.range or 0, 220), 2
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

local function fly(start, gx, yaw, pitch, launch)
	local p = math.rad(pitch)
	local dir = Vector3.new(math.cos(yaw) * math.cos(p), math.sin(p), math.sin(yaw) * math.cos(p))
	local v, spin = launch(dir)
	local pos, t = start, 0
	local sx = math.sign(gx - start.X)
	while t < 4 do
		v, spin = Ball.integrate(v, spin, DT, false)
		local np = pos + v * DT
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
		local p = math.rad(best.pitch)
		best.dir = Vector3.new(math.cos(best.yaw) * math.cos(p), math.sin(p), math.sin(best.yaw) * math.cos(p))
	end
	return best
end

local function shotLaunch(curve, charge, power)
	local tpl = S.fireArgs and os.clock() - S.fireAt < 0.3 and S.fireArgs
	local mult = S.curveMult or 1
	return function(dir)
		local u, spd, spin
		if tpl then
			local a = table.clone(tpl)
			a[1], a[3] = dir, curve * mult
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

local function corners(ball, gx, keeper)
	local zs = { HALF_W - cfg.margin, -(HALF_W - cfg.margin) }
	local ys = {}
	if cfg.height ~= "Low" then table.insert(ys, BAR - 1.6) end
	if cfg.height ~= "High" then table.insert(ys, 1.6) end
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
	table.sort(list, function(a, b) return a.score > b.score end)
	return list
end

local function compute()
	local charging, start = Charge.get()
	if not (cfg.aim and charging) then return nil end
	local ball = ballPos()
	if not ball then return nil end
	local goal, why = pickGoal(ball)
	if not goal then S.status = why return nil end
	local gx = goal.X
	local prog = Shot.progress(start, Clock.server())
	local power = Power.armed() and prog >= Shot.POWER_MIN_CHARGE
	local keeper = keeperNear(goal, ball)
	local lead = S.lead and os.clock() - S.lead.at < 0.3 and S.lead.start
	local from = lead or ball
	for _, c in ipairs(corners(from, gx, keeper)) do
		local tries = cfg.curve and { 1, -1 } or { 0 }
		local found
		for _, cv in ipairs(tries) do
			local s = solve(from, gx, c.z, c.y, shotLaunch(cv, prog, power))
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
	for _, c in ipairs(corners(m.spot, gx, keeper)) do
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

local HOOKED = { Look.kick, Look.aim, Look.camera, Power.curve, Power.bend, Shot.fire, KickLead.aim, Actions.pressed }
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
		if name == "tackle" and s and s.tackleUntil and os.clock() < s.tackleUntil then return true end
		return oldPressed(name, ...)
	end)
	local oldCamera
	oldCamera = hookfunction(Look.camera, function(...)
		local s = st()
		if s and s.tackleUntil and os.clock() < s.tackleUntil and s.tackleDir then return s.tackleDir end
		return oldCamera(...)
	end)
end
S.volleySol, S.computeVolley, S.solve, S.shotLaunch = volleySol, computeVolley, solve, shotLaunch

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
		if cfg.tackle and me and os.clock() - (S.lastTackle or 0) > 0.3 then
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
				local aimAt = carrier:GetPivot().Position + (tr and tr.vel or Vector3.zero) * 0.15
				local to = (aimAt - me) * Vector3.new(1, 0, 1)
				local dist = to.Magnitude
				local mv = (S.meVel or Vector3.zero) * Vector3.new(1, 0, 1)
				local lined = mv.Magnitude < 2 or mv.Unit:Dot(to.Unit) > 0.82
				if dist > 0.5 and dist < cfg.tackleRange and lined then
					S.tackleDir = to.Unit
					S.tackleUntil, S.lastTackle = os.clock() + 0.05, os.clock()
					S.tackleStatus = ("Auto tackle fired (carrier %.0f studs)"):format(dist)
				end
			end
		end
	end
	local charging = Charge.get()
	if S.sol and not charging and cfg.aim then

		if Power.rooted(Clock.mono()) then S.powerHold = os.clock() + 0.35 end
		if S.powerHold and os.clock() < S.powerHold then
			S.status = "Power shot windup: holding aim on " .. ((S.sol.target.Y > 3) and "top" or "low") .. " corner"
			return
		end
	end
	if not (cfg.aim and charging) then
		if S.sol and not S.watching then
			local sol = S.sol
			S.watching = true
			task.spawn(function()
				local t0, prev = os.clock(), ballPos()
				while os.clock() - t0 < 4 and alive() do
					task.wait()
					local p = ballPos()
					if p and prev and (p.X - sol.target.X) * (prev.X - sol.target.X) <= 0 and (p - prev).Magnitude < 20 then
						local a = (sol.target.X - prev.X) / (p.X - prev.X)
						local hit = prev + (p - prev) * a
						S.last = ("Last shot: target z %.1f y %.1f | crossed z %.1f y %.1f"):format(sol.target.Z, sol.target.Y, hit.Z, hit.Y)
						break
					end
					prev = p
				end
				S.watching = false
			end)
		end
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
for _, o in ipairs(guiParent:GetChildren()) do if o.Name == "EzeHubSSP" then o:Destroy() end end
local gui = new("ScreenGui", { Name = "EzeHubSSP", ResetOnSpawn = false, ZIndexBehavior = Enum.ZIndexBehavior.Sibling }, guiParent)
S.gui = gui

local win = new("Frame", { Size = UDim2.fromOffset(600, 380), Position = UDim2.new(0.5, -300, 0.5, -190), BackgroundColor3 = C.bg }, gui)
corner(win, 10)
new("UIStroke", { Color = Color3.fromRGB(45, 45, 45) }, win)

local top = new("Frame", { Size = UDim2.new(1, 0, 0, 44), BackgroundTransparency = 1 }, win)
new("TextLabel", {
	Text = "Eze Hub | Street Soccer Pro | " .. VERSION, Font = Enum.Font.GothamMedium, TextSize = 16, TextColor3 = C.text,
	BackgroundTransparency = 1, Position = UDim2.fromOffset(18, 0), Size = UDim2.new(1, -120, 1, 0), TextXAlignment = Enum.TextXAlignment.Left,
}, top)
local closeBtn = new("TextButton", { Text = "✕", Font = Enum.Font.GothamBold, TextSize = 18, TextColor3 = C.text, BackgroundTransparency = 1,
	Size = UDim2.fromOffset(36, 36), Position = UDim2.new(1, -42, 0, 4) }, top)
local minBtn = new("TextButton", { Text = "—", Font = Enum.Font.GothamBold, TextSize = 16, TextColor3 = C.text, BackgroundTransparency = 1,
	Size = UDim2.fromOffset(36, 36), Position = UDim2.new(1, -80, 0, 4) }, top)

do
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

local pill = new("TextButton", { Text = "Eze Hub", Font = Enum.Font.GothamBold, TextSize = 14, TextColor3 = C.text, BackgroundColor3 = C.accent,
	Size = UDim2.fromOffset(110, 34), Position = UDim2.new(0, 16, 0.5, -17), Visible = false }, gui)
corner(pill, 8)
local function setOpen(open) win.Visible, pill.Visible = open, not open end
minBtn.MouseButton1Click:Connect(function() setOpen(false) end)
pill.MouseButton1Click:Connect(function() setOpen(true) end)
table.insert(S.conns, UIS.InputBegan:Connect(function(i, gp)
	if not gp and i.KeyCode == Enum.KeyCode.RightControl then setOpen(not win.Visible) end
end))

local side = new("Frame", { Size = UDim2.new(0, 160, 1, -110), Position = UDim2.fromOffset(12, 48), BackgroundTransparency = 1 }, win)
new("UIListLayout", { Padding = UDim.new(0, 8), SortOrder = Enum.SortOrder.LayoutOrder }, side)
local pagesHolder = new("Frame", { Size = UDim2.new(1, -196, 1, -56), Position = UDim2.fromOffset(184, 48), BackgroundTransparency = 1 }, win)

do
	local prof = new("Frame", { Size = UDim2.fromOffset(160, 46), Position = UDim2.new(0, 12, 1, -56), BackgroundColor3 = C.item }, win)
	corner(prof, 8)
	local img = new("ImageLabel", { Size = UDim2.fromOffset(34, 34), Position = UDim2.fromOffset(6, 6), BackgroundColor3 = C.box }, prof)
	corner(img, 17)
	task.spawn(function()
		local ok, url = pcall(Players.GetUserThumbnailAsync, Players, LP.UserId, Enum.ThumbnailType.HeadShot, Enum.ThumbnailSize.Size48x48)
		if ok then img.Image = url end
	end)
	new("TextLabel", { Text = LP.DisplayName, Font = Enum.Font.GothamMedium, TextSize = 14, TextColor3 = C.text, BackgroundTransparency = 1,
		Position = UDim2.fromOffset(48, 0), Size = UDim2.new(1, -54, 1, 0), TextXAlignment = Enum.TextXAlignment.Left, TextTruncate = Enum.TextTruncate.AtEnd }, prof)
end

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

	function t.Toggle(text, key)
		local f = item()
		label(f, text)
		local box = new("TextButton", { Text = "", AutoButtonColor = false, Size = UDim2.fromOffset(30, 30), Position = UDim2.new(1, -40, 0.5, -15), BackgroundColor3 = C.box }, f)
		corner(box, 6)
		local tick = new("TextLabel", { Text = "✓", Font = Enum.Font.GothamBold, TextSize = 18, TextColor3 = C.text, BackgroundTransparency = 1, Size = UDim2.fromScale(1, 1) }, box)
		local function refresh() local on = cfg[key] box.BackgroundColor3 = on and C.accent or C.box tick.Visible = on end
		box.MouseButton1Click:Connect(function() cfg[key] = not cfg[key] changed() end)
		table.insert(refreshers, refresh)
		refresh()
	end

	function t.Dropdown(text, options, key)
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
			local o = new("TextButton", { Text = opt, Font = Enum.Font.Gotham, TextSize = 14, TextColor3 = C.text, AutoButtonColor = false,
				BackgroundColor3 = C.box, Size = UDim2.new(1, 0, 0, 30), LayoutOrder = i }, list)
			corner(o, 6)
			o.MouseButton1Click:Connect(function() cfg[key] = opt list.Visible = false changed() end)
		end
		valueBtn.MouseButton1Click:Connect(function() list.Visible = not list.Visible end)
		table.insert(refreshers, function() valueBtn.Text = cfg[key] end)
		valueBtn.Text = cfg[key]
	end

	function t.Slider(text, min, max, key)
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
			local a = (cfg[key] - min) / (max - min)
			fill.Size, knob.Position, val.Text = UDim2.fromScale(a, 1), UDim2.fromScale(a, 0.5), tostring(cfg[key])
		end
		local dragging = false
		local function apply(x)
			local a = math.clamp((x - bar.AbsolutePosition.X) / bar.AbsoluteSize.X, 0, 1)
			cfg[key] = math.floor(min + a * (max - min) + 0.5)
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
		task.spawn(function() while alive() do l.Text = getText() task.wait(0.15) end end)
	end

	return t
end

local aimTab = Tab("Aim", "◎")
aimTab.Section("Silent Aim")
aimTab.Toggle("Silent Aim (shots)", "aim")
aimTab.Toggle("Max Curve", "curve")
aimTab.Dropdown("Corner Height", { "Auto", "High", "Low" }, "height")
aimTab.Slider("Max Distance", 40, 230, "range")
aimTab.Toggle("Show Target", "showTarget")
aimTab.Toggle("Silent Aim (Bicycle / Volley)", "volley")
aimTab.Section("Status")
aimTab.Paragraph(function() return S.status .. (S.last and ("\n" .. S.last) or "") end)

local dribTab = Tab("Dribble", "➤")
dribTab.Section("Auto Dribble")
dribTab.Toggle("Auto Dribble", "dribble")
dribTab.Slider("Trigger Range", 5, 20, "dribbleRange")
dribTab.Paragraph(function()
	return "Uses the game's own dribble move when an opponent rushes you while you have the ball.\n" .. (S.dribbleStatus or "")
end)
dribTab.Section("Auto Tackle")
dribTab.Toggle("Auto Tackle", "tackle")
dribTab.Slider("Tackle Range", 4, 14, "tackleRange")
dribTab.Paragraph(function()
	return "Slide-tackles an opponent carrying the ball when they're in range and in your path (or you're standing still).\n" .. (S.tackleStatus or "")
end)

local misc = Tab("Misc", "⚙")
misc.Section("Info")
misc.Paragraph(function()
	return "Hold shoot as usual: the shot is re-aimed at the corner farthest from the keeper, with max curve, and the height is solved for your charge.\nToggle the UI with <b>RightControl</b>."
end)
misc.Button("Unload Script", function() S.Unload() end)

selectTab(tabs[1])

function S.Unload()
	S.sol = nil
	if G.SSPAim == S then G.SSPAim = nil end
	for _, c in ipairs(S.conns) do c:Disconnect() end
	if S.marker then S.marker:Destroy() end
	if S.gui then S.gui:Destroy() end
end

closeBtn.MouseButton1Click:Connect(function() S.Unload() end)
