local VERSION = "1.0.0"

local G = getgenv()
local TOKEN = {}
G.PPHubToken = TOKEN
if G.PPHub and G.PPHub.Unload then pcall(G.PPHub.Unload) end
if not game:IsLoaded() then game.Loaded:Wait() end
if G.PPHubToken ~= TOKEN then return end

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local RS = game:GetService("ReplicatedStorage")
local LP = Players.LocalPlayer
local Pong = RS:WaitForChild("PongLegacy")
local Remotes = Pong:WaitForChild("Remotes")
local DeviceUI = require(Pong:WaitForChild("DeviceUI"))

local cfg = { autoHit = false, autoMove = false, autoServe = false, shot = "Topspin", power = 1, aim = 0.9, curve = 1, speed = 16,
	autoAbility = false, autoUlt = false, autoQueue = false, mode = "bot_bats", autoSpin = false }
local S = { conns = {}, status = "Idle", hits = 0, cfg = cfg }
G.PPHub = S
local function alive() return G.PPHub == S end

local fn = {}
local function findFns()
	fn = {}
	for _, f in pairs(getgc(false)) do
		if type(f) == "function" and islclosure(f) then
			local i = debug.getinfo(f)
			local src = tostring(i.source)
			if i.name == "beginCharge" and src:find("PongClient") then fn.begin = f
			elseif i.name == "finishCharge" and src:find("PongClient") then fn.finish = f
			elseif src:find("AutoMoveClient") and i.nups == 18 then fn.move = f end
		end
	end
	return fn.begin and fn.finish
end
findFns()

local function match() return fn.begin and debug.getupvalue(fn.begin, 2) end
local function charge() return fn.begin and debug.getupvalue(fn.begin, 1) end
local function mySide(m)
	if not m or type(m.userIds) ~= "table" then return 0 end
	if m.userIds[1] == LP.UserId then return 1 end
	if m.userIds[2] == LP.UserId then return 2 end
	if type(m.mates) == "table" then
		if m.mates[1] == LP.UserId then return 1 end
		if m.mates[2] == LP.UserId then return 2 end
	end
	return 0
end

local Config = require(Pong:WaitForChild("Config"))
local AUTOMOVE = Config.AUTO_MOVE
local moveDefaults = { react = AUTOMOVE.react, err = AUTOMOVE.err }
local fakeDevice = setmetatable({ isTouch = function() return true end }, { __index = DeviceUI })
local savedPref
local function setAutoMove(on)
	if not fn.move then return end
	if on then
		savedPref = debug.getupvalue(fn.move, 5)
		debug.setupvalue(fn.move, 5, nil)
		debug.setupvalue(fn.move, 4, fakeDevice)
		AUTOMOVE.react, AUTOMOVE.err = 0, 0
	else
		debug.setupvalue(fn.move, 4, DeviceUI)
		debug.setupvalue(fn.move, 5, savedPref)
		AUTOMOVE.react, AUTOMOVE.err = moveDefaults.react, moveDefaults.err
	end
end

local SPIN = { Topspin = 1, Drive = 0, Chop = -1 }
local function opponentX(m, side)
	local o = 3 - side
	local uid = m.userIds[o]
	local char
	if uid and uid ~= 0 then
		local p = Players:GetPlayerByUserId(uid)
		char = p and p.Character
	else
		local name = type(m.botModels) == "table" and m.botModels[o] or ""
		char = workspace:FindFirstChild(name ~= "" and name or "PongBot")
	end
	local hrp = char and char:FindFirstChild("HumanoidRootPart")
	local origin = typeof(m.origin) == "Vector3" and m.origin or Vector3.zero
	return hrp and hrp.Position.X - origin.X or 0
end
local lastAway, curveSign, shotFor = 1, 1, nil
local function setShot(m, side, c)
	local ox = opponentX(m, side)
	local away = ox > 1 and -1 or ox < -1 and 1 or -lastAway
	if shotFor ~= c then
		shotFor, lastAway, curveSign = c, away, -curveSign
	end
	local rightX = side == 1 and -1 or 1
	S.shot = { away * rightX * cfg.aim, SPIN[cfg.shot] or 1, curveSign * cfg.curve }
	debug.setupvalue(fn.begin, 5, { S.shot[3], S.shot[2], S.shot[1], cfg.power })
end

local swipeHooks = {}
local function hookSwipe()
	if not fn.finish or #swipeHooks > 0 or fn.swipeTried then return end
	fn.swipeTried = true
	local orig = debug.getupvalue(fn.finish, 2)
	if type(orig) ~= "function" then return end
	local function swipe(...)
		local c = charge()
		if S.shot and c and (cfg.autoHit or cfg.autoServe) then return S.shot[1], S.shot[2], S.shot[3] end
		return orig(...)
	end
	for _, f in pairs(getgc(false)) do
		if type(f) == "function" and islclosure(f) and tostring(debug.getinfo(f).source):find("PongClient$") then
			for i = 1, debug.getinfo(f).nups or 0 do
				if debug.getupvalue(f, i) == orig then
					debug.setupvalue(f, i, swipe)
					table.insert(swipeHooks, { f, i, orig })
				end
			end
		end
	end
end
local function unhookSwipe()
	for _, h in ipairs(swipeHooks) do pcall(debug.setupvalue, h[1], h[2], h[3]) end
	swipeHooks = {}
end
S.setAutoMove = setAutoMove

local function center() return workspace.CurrentCamera.ViewportSize * Vector2.new(0.5, 0.62) end
local releasing, serveAt, lastDash = false, 0, 0

local lastSpecial, lastUlt = 0, 0
table.insert(S.conns, RunService.Heartbeat:Connect(function()
	if not (cfg.autoHit or cfg.autoServe or cfg.autoAbility or cfg.autoUlt or cfg.speed > 16) then return end
	if not fn.begin or not pcall(debug.getupvalue, fn.begin, 1) then
		if not findFns() then S.status = "Waiting for game scripts" return end
		unhookSwipe()
	end
	hookSwipe()
	local m = match()
	local side = mySide(m)
	if side == 0 then S.status = "Not in a match" return end
	local c = charge()

	local hum = LP.Character and LP.Character:FindFirstChildOfClass("Humanoid")
	if hum and cfg.speed > 16 and hum.WalkSpeed < cfg.speed then hum.WalkSpeed = cfg.speed end

	if m.phase == "rally" and m.lastHitter ~= side then
		local now = workspace:GetServerTimeNow()
		local ready = type(m.specialReadyAt) == "table" and m.specialReadyAt[side] or math.huge
		if cfg.autoAbility and now >= ready and os.clock() - lastSpecial > 1 then
			lastSpecial = os.clock()
			Remotes.UseSpecial:FireServer()
		end
		local ult = type(m.ult) == "table" and m.ult[side] or 0
		if cfg.autoUlt and ult >= 100 and os.clock() - lastUlt > 1 then
			lastUlt = os.clock()
			Remotes.UseUltimate:FireServer()
		end
	end

	if m.phase == "rally" and cfg.autoHit then
		if c and not c.serve and c.autoDone and not releasing then
			releasing = true
			task.delay(0.03, function()
				local cc = charge()
				if cc and cc.autoDone then pcall(fn.finish) S.hits += 1 end
				releasing = false
			end)
		elseif not c and m.lastHitter ~= side then
			pcall(fn.begin, center(), "gamepad")
			local nc = charge()
			if nc then pcall(setShot, m, side, nc) end
		elseif c and not c.serve and not c.autoDone then
			pcall(setShot, m, side, c)
			local armed = type(m.armed) == "table" and type(m.armed[side]) == "table" and next(m.armed[side]) ~= nil
			local t = debug.getupvalue(fn.finish, 7)
			local hrp = LP.Character and LP.Character:FindFirstChild("HumanoidRootPart")
			if armed and type(t) == "table" and hrp and os.clock() - c.start > 0.3 then
				local ok, reach = pcall(function()
					local ball = t.ballAt(workspace:GetServerTimeNow() + t.lead)
					return ball.Z * Config.sideSign(side) > 0 and t.canReach(side, t.L(hrp.Position), ball, Config.HIT_TOLERANCE * 0.5)
				end)
				if ok and reach then pcall(fn.finish) end
			end
		end
		if cfg.autoMove and fn.move and m.lastHitter ~= side and os.clock() - lastDash > 1.2 then
			local target = debug.getupvalue(fn.move, 7)
			local hrp = LP.Character and LP.Character:FindFirstChild("HumanoidRootPart")
			if typeof(target) == "Vector3" and hrp and Vector3.new(target.X - hrp.Position.X, 0, target.Z - hrp.Position.Z).Magnitude > 9 then
				lastDash = os.clock()
				pcall(DeviceUI.controls.dash)
			end
		end
		S.status = m.lastHitter ~= side and "Returning ball" or "Waiting for opponent"
	elseif m.phase == "serve" and m.serverSide == side and cfg.autoServe then
		local hrp = LP.Character and LP.Character:FindFirstChild("HumanoidRootPart")
		local origin = typeof(m.origin) == "Vector3" and m.origin or Vector3.zero
		if hrp and hum and not c and not Config.inServeZone(side, hrp.Position - origin, m) then
			local z = Config.sideSign(side) * (Config.SERVE_ZONE.minDepth + Config.extraL(m) + 4)
			hum:MoveTo(origin + Vector3.new(0, hrp.Position.Y - origin.Y, z))
			S.status = "Walking behind the table to serve"
			return
		end
		if not c and os.clock() - serveAt > 1.5 then
			serveAt = os.clock()
			pcall(fn.begin, center(), "gamepad")
			local nc = charge()
			if nc then pcall(setShot, m, side, nc) end
			task.delay(0.6, function()
				local cc = charge()
				if cc and cc.serve then pcall(fn.finish) end
			end)
		end
		S.status = "Serving"
	else
		S.status = "Phase: " .. tostring(m.phase)
	end
end))

local qState = "idle"
table.insert(S.conns, Remotes.QueueStatus.OnClientEvent:Connect(function(a)
	if type(a) == "table" and a.state then qState = a.state end
end))

task.spawn(function()
	while alive() do
		if cfg.autoQueue then
			local m = match()
			local inMatch = mySide(m) ~= 0 and m.phase ~= "matchover" and m.phase ~= "gameover"
			if not inMatch and (qState == "idle" or qState == "found") then
				local ok, r = pcall(function() return Remotes.Queue:InvokeServer("join", cfg.mode) end)
				if ok and type(r) == "table" and r.ok then qState = "searching" end
			end
		end
		if cfg.autoSpin then
			local ok, p = pcall(function() return Remotes.GetProfile:InvokeServer() end)
			if ok and type(p) == "table" then
				if (p.wheelSpins or 0) > 0 then pcall(function() Remotes.Progress:InvokeServer("wheel") end) end
				if (p.spinStyle or 0) > 0 then pcall(function() Remotes.GachaSpin:InvokeServer("style", false) end) end
			end
		end
		task.wait(5)
	end
end)

local Library = loadstring(game:HttpGet("https://raw.githubusercontent.com/mechupacristopher-creator/lua/main/lib/eze_ui.lua"))()
if not alive() then pcall(function() Library:Unload() end) return end

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
local playTab = win:Tab({ name = "Auto Play", icon = "lucide:gamepad-2" })
local play = playTab:Section({ name = "Auto Play", side = "left" })
play:Toggle({ name = "Auto Hit", default = false, NoSave = true, Callback = function(v)
	cfg.autoHit = v
	if not v then local c = charge() if c and not c.serve then pcall(fn.finish) end end
end })
play:Toggle({ name = "Auto Move", default = false, NoSave = true, Callback = function(v) cfg.autoMove = v setAutoMove(v) end })
play:Toggle({ name = "Auto Serve", default = false, NoSave = true, Callback = function(v) cfg.autoServe = v end })
play:Slider({ name = "Move Speed (16 = normal)", min = 16, max = 30, default = 16, decimals = 0, NoSave = true, Callback = function(v) cfg.speed = v end })
play:Label({ name = "Auto Hit returns every ball at full power. Auto Move walks you to where the ball will land; move yourself to take over." })

local shots = playTab:Section({ name = "Shots", side = "right" })
shots:Dropdown({ name = "Spin", items = { "Topspin", "Drive", "Chop" }, default = "Topspin", NoSave = true, Callback = function(v) cfg.shot = v end })
shots:Slider({ name = "Power", min = 0, max = 100, default = 100, decimals = 0, NoSave = true, Callback = function(v) cfg.power = v / 100 end })
shots:Slider({ name = "Aim Width", min = 0, max = 100, default = 90, decimals = 0, NoSave = true, Callback = function(v) cfg.aim = v / 100 end })
shots:Slider({ name = "Curve", min = 0, max = 100, default = 100, decimals = 0, NoSave = true, Callback = function(v) cfg.curve = v / 100 end })
shots:Label({ name = "Every shot goes to the corner away from your opponent and curves the other way each hit." })

local st = playTab:Section({ name = "Status", side = "right" })
liveLabel(st, function() return S.status end)

local ab = playTab:Section({ name = "Abilities", side = "left" })
ab:Toggle({ name = "Auto Ability (E)", default = false, NoSave = true, Callback = function(v) cfg.autoAbility = v end })
ab:Toggle({ name = "Auto Ultimate (F)", default = false, NoSave = true, Callback = function(v) cfg.autoUlt = v end })

local farmTab = win:Tab({ name = "Farm", icon = "lucide:repeat" })
local q = farmTab:Section({ name = "Queue", side = "left" })
q:Toggle({ name = "Auto Queue", default = false, NoSave = true, Callback = function(v) cfg.autoQueue = v end })
local MODES = { ["Bot Match"] = "bot_bats", ["1v1 Duel"] = "duel_bats", ["2v2 Team"] = "team_2v2", ["Mayhem"] = "team_mayhem" }
q:Dropdown({ name = "Mode", items = { "Bot Match", "1v1 Duel", "2v2 Team", "Mayhem" }, default = "Bot Match", NoSave = true, Callback = function(v) cfg.mode = MODES[v] or cfg.mode end })
local rw = farmTab:Section({ name = "Rewards", side = "right" })
rw:Toggle({ name = "Auto Use Free Spins", default = false, NoSave = true, Callback = function(v) cfg.autoSpin = v end })
rw:Button({ name = "Redeem Code RELEASE", Callback = function()
	local ok, r = pcall(function() return Remotes.RedeemCode:InvokeServer("RELEASE") end)
	local msg = ok and type(r) == "table" and (r.ok and "Code redeemed!" or tostring(r.err or r.msg or "Code failed")) or "Code failed"
	Library:create_notification({ name = msg, duration = 3 })
end })

local miscTab = win:Tab({ name = "Misc", icon = "lucide:info" })
local actions = miscTab:Section({ name = "Script", side = "left" })
actions:Label({ name = "v" .. VERSION .. " - RightControl toggles the UI" })
actions:Button({ name = "Unload Script", Callback = function() S.Unload() end })

function S.Unload()
	if G.PPHub == S then G.PPHub = nil end
	for _, c in ipairs(S.conns) do pcall(function() c:Disconnect() end) end
	if cfg.autoMove then pcall(setAutoMove, false) end
	pcall(unhookSwipe)
	local hum = LP.Character and LP.Character:FindFirstChildOfClass("Humanoid")
	if hum and cfg.speed > 16 and hum.WalkSpeed > 16 then hum.WalkSpeed = 16 end
	pcall(function() Library:Unload() end)
end

Library:create_notification({ name = "Eze Hub loaded - RightControl to toggle", duration = 4 })
