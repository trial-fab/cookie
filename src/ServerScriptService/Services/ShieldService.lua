local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local CookieService = require(ServerScriptService.Services.CookieService)
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

local function getCookiesValue(player)
	local leaderstats = player:FindFirstChild("leaderstats")
	if not leaderstats then
		return nil
	end

	return leaderstats:FindFirstChild("Cookies")
end

local function getShieldTime(player)
	local shieldTime = player:FindFirstChild("ShieldTime")
	if shieldTime and shieldTime:IsA("IntValue") then
		return shieldTime
	end

	return nil
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
	local shieldEnabled = getSheetShieldEnabled(player)
	if not shieldEnabled then
		return false
	end

	shieldEnabled.Value = enabled
	return true
end

function ShieldService.SetTime(player, seconds)
	local shieldTime = getShieldTime(player)
	if not shieldTime then
		return false
	end

	shieldTime.Value = math.max(0, math.floor(seconds))
	return true
end

function ShieldService.GetPurchaseCost(player)
	local cookies = getCookiesValue(player)
	if not cookies then
		return 0
	end

	return math.max(0, math.floor(cookies.Value * SHIELD_COST_RATIO))
end

function ShieldService.ToggleShield(player)
	local shieldEnabled = getSheetShieldEnabled(player)
	local shieldTime = getShieldTime(player)
	if not shieldEnabled or not shieldTime then
		return false, "Shield is not ready."
	end

	if shieldEnabled.Value then
		shieldEnabled.Value = false
		return true, "Shield disabled."
	end

	local cost = ShieldService.GetPurchaseCost(player)
	if cost > 0 then
		local paid = CookieService.AddCookies(player, -cost)
		if not paid then
			return false, "Not enough cookies."
		end
	end

	shieldTime.Value = PURCHASED_SHIELD_SECONDS
	shieldEnabled.Value = true
	return true, "Shield enabled."
end

function ShieldService.StartTimer(player)
	activeLoops[player] = (activeLoops[player] or 0) + 1
	local loopId = activeLoops[player]

	task.spawn(function()
		while player.Parent and activeLoops[player] == loopId do
			local shieldTime = getShieldTime(player)
			if not shieldTime then
				break
			end

			if shieldTime.Value > 0 then
				shieldTime.Value -= 1

				if shieldTime.Value <= 0 then
					ShieldService.SetEnabled(player, false)
				end
			end

			task.wait(1)
		end
	end)
end

function ShieldService.SetupPlayer(player)
	-- PVP paused (Shared.PvpConfig): leave the shield off and unwired.
	if not PvpConfig.IsActive() then
		return
	end

	local shieldTime = getShieldTime(player)
	if shieldTime and shieldTime.Value <= 0 then
		shieldTime.Value = DEFAULT_SHIELD_SECONDS
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
