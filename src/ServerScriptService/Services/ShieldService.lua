local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local CookieService = require(ServerScriptService.Services.CookieService)
local PlayerDataService = require(ServerScriptService.Services.PlayerDataService)
local PlayerMetricsService = require(ServerScriptService.Services.PlayerMetricsService)
local SheetService = require(ServerScriptService.Services.SheetService)
local Net = require(ReplicatedStorage.Shared.Net)
local PvpConfig = require(ReplicatedStorage.Shared.PvpConfig)

local ShieldService = {}

local DEFAULT_SHIELD_SECONDS = 600
local PURCHASED_SHIELD_SECONDS = 300
local SHIELD_COST_RATIO = 0.5
local ENABLED_SHIELD_TRANSPARENCY = 0.8

local activeLoops = {}
local shieldConnections = {}

local function getRun(player)
	local data = player and PlayerDataService.GetDomain7Data(player)
	local run = type(data) == "table" and data.Run
	return type(run) == "table" and run or nil
end

local function getSheetShieldEnabled(player)
	local sheet = SheetService.GetPlayerSheet(player)
	if not sheet then
		return nil
	end

	local shieldEnabled = sheet:FindFirstChild("ShieldEnabled")
	if shieldEnabled and shieldEnabled:IsA("BoolValue") then
		return shieldEnabled
	end

	return nil
end

local function setShieldVisual(sheet, enabled)
	local mainShield = sheet:FindFirstChild("MainShield")
	if not mainShield then
		return
	end

	for _, descendant in ipairs(mainShield:GetDescendants()) do
		if descendant:IsA("BasePart") then
			descendant.Transparency = enabled and ENABLED_SHIELD_TRANSPARENCY or 1
			descendant.CanCollide = enabled
			descendant.CanTouch = enabled
		elseif descendant:IsA("ParticleEmitter") or descendant:IsA("Beam") or descendant:IsA("Trail") then
			descendant.Enabled = enabled
		end
	end

	if mainShield:IsA("BasePart") then
		mainShield.Transparency = enabled and ENABLED_SHIELD_TRANSPARENCY or 1
		mainShield.CanCollide = enabled
		mainShield.CanTouch = enabled
	end
end

local function connectSheetShield(sheet)
	local shieldEnabled = sheet:FindFirstChild("ShieldEnabled")
	if not shieldEnabled or not shieldEnabled:IsA("BoolValue") then
		return
	end

	if shieldConnections[sheet] then
		shieldConnections[sheet]:Disconnect()
	end

	setShieldVisual(sheet, shieldEnabled.Value)
	shieldConnections[sheet] = shieldEnabled.Changed:Connect(function()
		setShieldVisual(sheet, shieldEnabled.Value)
	end)
end

function ShieldService.SetEnabled(player, enabled)
	if not getRun(player) then
		return false
	end
	local shieldEnabled = getSheetShieldEnabled(player)
	if not shieldEnabled then
		return false
	end

	shieldEnabled.Value = enabled
	return true
end

function ShieldService.SetTime(player, seconds)
	local run = getRun(player)
	local shieldTime = player:FindFirstChild("ShieldTime")
	seconds = tonumber(seconds)
	if
		not run
		or not shieldTime
		or not shieldTime:IsA("IntValue")
		or not seconds
		or seconds ~= seconds
		or seconds == math.huge
		or seconds == -math.huge
	then
		return false
	end

	run.ShieldTime = math.max(0, math.floor(seconds))
	shieldTime.Value = run.ShieldTime
	return true
end

function ShieldService.GetTime(player)
	local run = getRun(player)
	return run and (tonumber(run.ShieldTime) or 0) or nil
end

function ShieldService.GetPurchaseCost(player)
	local cookies = CookieService.GetCookies(player)
	if cookies == nil then
		return 0
	end

	return math.max(0, math.floor(cookies * SHIELD_COST_RATIO))
end

function ShieldService.ToggleShield(player)
	local shieldEnabled = getSheetShieldEnabled(player)
	local shieldTime = ShieldService.GetTime(player)
	if not shieldEnabled or shieldTime == nil then
		return false, "Shield is not ready."
	end

	if shieldEnabled.Value then
		shieldEnabled.Value = false
		return true, "Shield disabled."
	end

	local cost = ShieldService.GetPurchaseCost(player)
	if cost > 0 then
		local paid = CookieService.AddCookies(player, -cost, PlayerMetricsService.CookieSources.Shield)
		if not paid then
			return false, "Not enough cookies."
		end
	end

	if not ShieldService.SetTime(player, PURCHASED_SHIELD_SECONDS) then
		return false, "Shield is not ready."
	end
	shieldEnabled.Value = true
	return true, "Shield enabled."
end

function ShieldService.StartTimer(player)
	if not getRun(player) then
		return false
	end
	activeLoops[player] = (activeLoops[player] or 0) + 1
	local loopId = activeLoops[player]

	task.spawn(function()
		while player.Parent and activeLoops[player] == loopId do
			local shieldTime = ShieldService.GetTime(player)
			if shieldTime == nil then
				break
			end

			if shieldTime > 0 then
				local remaining = shieldTime - 1
				if not ShieldService.SetTime(player, remaining) then
					break
				end

				if remaining <= 0 then
					ShieldService.SetEnabled(player, false)
				end
			end

			task.wait(1)
		end
	end)
	return true
end

function ShieldService.SetupPlayer(player)
	-- PVP paused (Shared.PvpConfig): leave the shield off and unwired.
	if not PvpConfig.IsActive() then
		return
	end

	local shieldTime = ShieldService.GetTime(player)
	if shieldTime ~= nil and shieldTime <= 0 then
		ShieldService.SetTime(player, DEFAULT_SHIELD_SECONDS)
	end

	local sheet = SheetService.GetPlayerSheet(player)
	if sheet then
		connectSheetShield(sheet)
	end

	ShieldService.SetEnabled(player, true)
	ShieldService.StartTimer(player)
end

function ShieldService.CleanupPlayer(player)
	activeLoops[player] = nil
end

local function setupRemotes()
	Net.on(Net.Names.ToggleShield, function(player)
		ShieldService.ToggleShield(player)
	end)
end

function ShieldService.Init()
	local cookieSheetsFolder = workspace:WaitForChild("CookieSheets")

	-- PVP paused (Shared.PvpConfig): hide every plot shield and skip all wiring
	-- (no per-sheet connection, no ChildAdded watcher, no ToggleShield remote).
	if not PvpConfig.IsActive() then
		for _, sheet in ipairs(cookieSheetsFolder:GetChildren()) do
			setShieldVisual(sheet, false)
		end
		cookieSheetsFolder.ChildAdded:Connect(function(sheet)
			task.wait()
			setShieldVisual(sheet, false)
		end)
		print("ShieldService: PVP paused, shields hidden")
		return
	end

	for _, sheet in ipairs(cookieSheetsFolder:GetChildren()) do
		connectSheetShield(sheet)
	end

	cookieSheetsFolder.ChildAdded:Connect(function(sheet)
		task.wait()
		connectSheetShield(sheet)
	end)

	Players.PlayerRemoving:Connect(function(player)
		ShieldService.CleanupPlayer(player)
	end)

	setupRemotes()
	print("ShieldService initialized")
end

return ShieldService
