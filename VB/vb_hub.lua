local VERSION = "1.1.0"
local CFG_FILE = "vb_hub_cfg.json"

local G = getgenv()
local TOKEN = {}
G.EzeVBToken = TOKEN
if G.EzeVB and G.EzeVB.Unload then pcall(G.EzeVB.Unload) end
if not game:IsLoaded() then game.Loaded:Wait() end
if G.EzeVBToken ~= TOKEN then return end

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local Http = game:GetService("HttpService")
local RS = game:GetService("ReplicatedStorage")
local LP = Players.LocalPlayer

local Remotes = RS:WaitForChild("VBRemotes")
local InputR = Remotes:WaitForChild("Input")
local IC = require(RS:WaitForChild("VBClient"):WaitForChild("InputCtl"))
local Config = require(RS:WaitForChild("VB"):WaitForChild("Config"))
local BallMath = require(RS.VB:WaitForChild("BallMath"))

local cfg = { silentAim = false, aimServe = true, lineInset = 0.3, coverRadius = 7, curve = true, curveWidth = 10, curveBack = 12, autoSpike = false, minCloseness = 0.6 }
pcall(function() for k, v in pairs(Http:JSONDecode(readfile(CFG_FILE))) do if cfg[k] ~= nil then cfg[k] = v end end end)
local function saveCfg() pcall(writefile, CFG_FILE, Http:JSONEncode(cfg)) end

local S = { conns = {}, cfg = cfg, aimed = 0, autoSwings = 0, lastSpot = "-", lastLand = "-" }
G.EzeVB = S
local function alive() return G.EzeVB == S end
local function conn(c) table.insert(S.conns, c) return c end

local function geo()
	local M = IC.Match
	if not M or not M.origin then return end
	return M, M.origin, M.myTeam == 1 and 1 or -1, M.depth or 33.5, (M.width or 37.5) / 2
end

local function enemies(o, side, depth, hw)
	local list = {}
	local function scan(parent)
		for _, m in ipairs(parent:GetChildren()) do
			local r = m ~= LP.Character and m:IsA("Model") and m:FindFirstChild("HumanoidRootPart")
			if r then
				local d = r.Position - o
				if d.X * side > -1 and math.abs(d.X) < depth + 12 and math.abs(d.Z) < hw + 12 and math.abs(d.Y) < 40 then
					table.insert(list, Vector2.new(d.X * side, d.Z))
				end
			end
		end
	end
	scan(workspace)
	local vc = workspace:FindFirstChild("VBCharacters")
	if vc then scan(vc) end
	return list
end

local function lineSpots(depth, hw, inset)
	local spots = {}
	local ex, sz = depth - inset, hw - inset
	for z = -sz, sz + 0.01, 1 do table.insert(spots, Vector2.new(ex, z)) end
	for x = 8, ex, 1 do
		table.insert(spots, Vector2.new(x, sz))
		table.insert(spots, Vector2.new(x, -sz))
	end
	return spots
end

local function gapTo(foes, p)
	local gap = 60
	for _, e in ipairs(foes) do
		local d = (e - p).Magnitude
		if d < gap then gap = d end
	end
	return gap
end

local function computeSpot()
	local M, o, side, depth, hw = geo()
	local root = LP.Character and LP.Character:FindFirstChild("HumanoidRootPart")
	if not M or not root then S.spot = nil return end
	local foes = enemies(o, side, depth, hw)
	local ex, sz = depth - cfg.lineInset, hw - cfg.lineInset
	local mySide = root.Position.Z >= o.Z and 1 or -1
	local best, kind
	for _, z in ipairs({ mySide * sz, -mySide * sz }) do
		local c = Vector2.new(ex, z)
		if gapTo(foes, c) >= cfg.coverRadius then best, kind = c, "corner" break end
	end
	if not best then
		local bestScore
		for _, p in ipairs(lineSpots(depth, hw, cfg.lineInset)) do
			local score = gapTo(foes, p) + p.X * 0.01
			if not bestScore or score > bestScore then best, bestScore = p, score end
		end
		kind = "line"
	end
	local out = best.Y >= 0 and 1 or -1
	S.spot = Vector3.new(o.X + best.X * side, o.Y, o.Z + best.Y)
	S.curveFrom = Vector3.new(o.X + (best.X - cfg.curveBack) * side, o.Y, o.Z + best.Y + out * cfg.curveWidth)
	S.lastSpot = string.format("%s (depth %.1f, side %.1f)", kind, best.X, best.Y)
end

local function faceDir()
	local root = LP.Character and LP.Character:FindFirstChild("HumanoidRootPart")
	local spot = S.spot
	if not root or not spot then return end
	local d = Vector3.new(spot.X - root.Position.X, 0, spot.Z - root.Position.Z)
	return d.Magnitude > 0.1 and d.Unit or nil, root
end

conn(RunService.Heartbeat:Connect(function()
	if not cfg.silentAim then return end
	pcall(computeSpot)
	local dir, root = faceDir()
	S.dir = dir
	if IC.GetMode and IC.GetMode() ~= "ground" and not (IC.Serving and not IC.Tossed) then
		if dir then
			IC._airFacingXZ = dir
			root.CFrame = CFrame.lookAt(root.Position, root.Position + dir)
		end
	end
end))

local swung, peak = false, 0
local function swing()
	swung = true
	S.autoSwings += 1
	task.spawn(function()
		IC.PrimaryDown()
		task.wait()
		IC.PrimaryUp()
	end)
end

conn(RunService.Heartbeat:Connect(function()
	if not cfg.autoSpike or not IC.Enabled then return end
	local mode = IC.GetMode and IC.GetMode()
	if mode ~= "air" and mode ~= "serveAir" and mode ~= "serveToss" then swung, peak = false, 0 return end
	if swung then return end
	local ok, bi = pcall(IC.BallInfo)
	if not ok or type(bi) ~= "table" then return end
	if mode == "serveToss" then
		local char = LP.Character
		local root = char and char:FindFirstChild("HumanoidRootPart")
		local traj = bi.traj or IC._lastTossTraj
		if not root or not traj or not IC.Tossed then return end
		local mods = Config.ComputeTraitModifiers(char) or {}
		local reach, _, _, ideal = Config.GetServeReachBounds(mods, IC.Match and IC.Match.mode, IC.DeviceMode == "touch", IC.DeviceMode == "gamepad")
		local now = workspace:GetServerTimeNow()
		local rel = BallMath.PosAt(traj, now) - root.Position
		local nxt = BallMath.PosAt(traj, now + 1 / 30) - root.Position
		local flat = Vector3.new(rel.X, 0, rel.Z).Magnitude
		local off, nextOff = math.abs(rel.Y - ideal), math.abs(nxt.Y - ideal)
		if flat <= reach * 0.85 and off <= 1.1 and (nextOff >= off or nextOff > 1.1) then swing() end
		return
	end
	local close = tonumber(bi.reticleCloseness) or 0
	local ready = bi.reticleIdeal == true or (peak >= cfg.minCloseness and close < peak - 0.04)
	if mode == "serveAir" then
		local root = LP.Character and LP.Character:FindFirstChild("HumanoidRootPart")
		local traj = bi.traj or IC._lastTossTraj
		if not root or not traj then return end
		local H = Config.Hit
		local now = workspace:GetServerTimeNow()
		local function inReach(t)
			local r = BallMath.PosAt(traj, t) - root.Position
			return Vector3.new(r.X, 0, r.Z).Magnitude <= H.JumpServeReachH and r.Y >= H.JumpServeLow and r.Y <= H.JumpServeHigh
		end
		if not inReach(now) then return end
		ready = ready or not inReach(now + 1 / 30)
	end
	if ready then swing() end
	if close > peak then peak = close end
end))

local AIM_VERBS = { spike = true, spikeAim = true, spikeStart = true, curveAim = true }

local oldNC
oldNC = hookmetamethod(game, "__namecall", newcclosure(function(self, ...)
	if self == InputR and alive() and not checkcaller() and getnamecallmethod() == "FireServer" then
		local verb, vec, opts = ...
		local spot = S.spot
		if cfg.silentAim and spot and typeof(vec) == "Vector3" and (AIM_VERBS[verb] or (cfg.aimServe and verb == "bump" and IC.Serving and IC.Tossed)) then
			if type(opts) == "table" and S.dir and verb ~= "bump" then opts.airFaceXZ = S.dir end
			if verb == "spike" or verb == "bump" then
				S.aimed += 1
				if cfg.curve and type(opts) == "table" and not opts.dumpSpike and S.curveFrom then opts.curveFrom = S.curveFrom end
			end
			return oldNC(self, verb, spot, opts, select(4, ...))
		end
	end
	return oldNC(self, ...)
end))

conn(Remotes:WaitForChild("Event").OnClientEvent:Connect(function(kind, data)
	if kind ~= "point" or type(data) ~= "table" or typeof(data.at) ~= "Vector3" then return end
	local M, o, side = geo()
	if not M then return end
	S.lastLand = string.format("depth %.1f, side %.1f (%s)", (data.at.X - o.X) * side, data.at.Z - o.Z, data.inCourt and "in" or "out")
end))

local Library = loadstring(game:HttpGet("https://raw.githubusercontent.com/mechupacristopher-creator/lua/main/lib/eze_ui.lua"))()
if not alive() then pcall(function() Library:Unload() end) return end
S.lib = Library

local function setCfg(key)
	return function(v) if cfg[key] ~= v then cfg[key] = v saveCfg() end end
end
local function toggle(sec, name, key)
	return sec:Toggle({ name = name, default = cfg[key], Callback = setCfg(key) })
end
local function liveLabel(sec, getText)
	local l = sec:Label({ name = getText() })
	task.spawn(function()
		while alive() do
			pcall(l.set, getText())
			task.wait(0.25)
		end
	end)
end

local win = Library:window({ name = "Eze Hub" })

local atk = win:Tab({ name = "Attack", icon = "lucide:crosshair" })
local sa = atk:Section({ name = "Silent Aim", side = "left" })
toggle(sa, "Silent Aim", "silentAim")
toggle(sa, "Aim Serves Too", "aimServe")
sa:Slider({ name = "Line Inset", min = 0, max = 3, default = cfg.lineInset, decimals = 1, Callback = setCfg("lineInset") })
sa:Slider({ name = "Corner Covered Radius", min = 2, max = 15, default = cfg.coverRadius, decimals = 1, Callback = setCfg("coverRadius") })
sa:Label({ name = "Hits the deep corner on your side, then the other corner. If both are covered it hits the open part of the white line. Raise Line Inset if balls land out." })
toggle(sa, "Curve Into Corners", "curve")
sa:Slider({ name = "Curve Width", min = 2, max = 20, default = cfg.curveWidth, decimals = 1, Callback = setCfg("curveWidth") })
sa:Label({ name = "Bends the ball out around the antenna and back into the target. Needs the Curve trait equipped." })
local st = atk:Section({ name = "Status", side = "right" })
toggle(st, "Auto Spike Timing", "autoSpike")
st:Label({ name = "Jump as usual. The hub swings at the best contact point for spikes and serves. For serves, just toss." })
st:Slider({ name = "Min Contact Quality", min = 0.2, max = 1, default = cfg.minCloseness, decimals = 2, Callback = setCfg("minCloseness") })
liveLabel(st, function() return "Target: " .. S.lastSpot end)
liveLabel(st, function() return "Last ball landed: " .. S.lastLand end)
liveLabel(st, function() return "Aimed hits: " .. S.aimed .. "  |  Auto swings: " .. S.autoSwings end)

local miscTab = win:Tab({ name = "Misc", icon = "lucide:info" })
local actions = miscTab:Section({ name = "Script", side = "left" })
actions:Label({ name = "v" .. VERSION .. " - RightControl toggles the UI" })
actions:Button({ name = "Unload Script", Callback = function() S.Unload() end })

function S.Unload()
	if G.EzeVB == S then G.EzeVB = nil end
	for _, c in ipairs(S.conns) do pcall(function() c:Disconnect() end) end
	pcall(function() Library:Unload() end)
end

Library:create_notification({ name = "Eze Hub loaded - RightControl to toggle", duration = 4 })
