local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ServerScriptService = game:GetService("ServerScriptService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Services = ServerScriptService:WaitForChild("Services")
local CookieService = require(Services:WaitForChild("CookieService"))
local PlayerDataService = require(Services:WaitForChild("PlayerDataService"))
local UpgradeService = require(Services:WaitForChild("UpgradeService"))
local GoldenCookieService = require(Services:WaitForChild("GoldenCookieService"))
local PlayerMetricsService = require(Services:WaitForChild("PlayerMetricsService"))
local WheelService = require(Services:WaitForChild("WheelService"))
local SheetService = require(Services:WaitForChild("SheetService"))
local Net = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Net"))

local TestCommandService = {}

local function isAllowed(player)
	return RunService:IsStudio() or player.UserId == game.CreatorId
end

-- Resolve a player from a chat token: exact Name/DisplayName match first, then a
-- case-insensitive prefix match (so "!gc bob 50" finds "Bobby"). "all" / "everyone"
-- is handled by the caller, not here.
local function findPlayer(nameText)
	nameText = string.lower(nameText)
	local prefixMatch
	for _, p in ipairs(Players:GetPlayers()) do
		local name = string.lower(p.Name)
		local display = string.lower(p.DisplayName)
		if name == nameText or display == nameText then
			return p
		end
		if not prefixMatch
			and (string.sub(name, 1, #nameText) == nameText or string.sub(display, 1, #nameText) == nameText)
		then
			prefixMatch = p
		end
	end
	return prefixMatch
end

local function parseAmount(text)
	local amountText, suffix = string.match(string.lower(text), "^%s*(%-?[%d%.]+)%s*([kmb]?)%s*$")
	local amount = tonumber(amountText)
	if not amount then
		return nil
	end

	if suffix == "k" then
		amount *= 1000
	elseif suffix == "m" then
		amount *= 1000000
	elseif suffix == "b" then
		amount *= 1000000000
	end

	return math.floor(amount)
end

local function handleCommand(player, message)
	if not isAllowed(player) then
		return
	end

	local amountText = string.match(message, "^!cookies%s+(.+)$")
	if amountText then
		local amount = parseAmount(amountText)
		if amount then
			CookieService.SetCookies(player, amount)
			PlayerDataService.Save(player, true)
			print("Set cookies for", player.Name, "to", amount)
		end
		return
	end

	amountText = string.match(message, "^!addcookies%s+(.+)$")
	if amountText then
		local amount = parseAmount(amountText)
		if amount then
			CookieService.AddCookies(player, amount, PlayerMetricsService.CookieSources.Admin)
			PlayerDataService.Save(player, true)
			print("Added cookies for", player.Name, amount)
		end
	end

	if message == "!refreshgear" then
		UpgradeService.SyncPlayerUpgrades(player)
		print("Refreshed gear for", player.Name)
		return
	end

	-- !gc <amount>            → grant to self
	-- !gc <name> <amount>     → grant to the named player (prefix match)
	-- !gc all <amount>        → grant to everyone
	local gcArgs = string.match(message, "^!gc%s+(.+)$")
	if gcArgs then
		local nameText, amountPart = string.match(gcArgs, "^(%S+)%s+(.+)$")
		-- A leading token that isn't itself a number means a target was named.
		if nameText and parseAmount(nameText) == nil then
			local amount = parseAmount(amountPart)
			if not amount then
				return
			end

			if string.lower(nameText) == "all" or string.lower(nameText) == "everyone" then
				for _, target in ipairs(Players:GetPlayers()) do
					GoldenCookieService.AddGoldenCookies(target, amount, "test")
				end
				print("Granted golden cookies to all players", amount)
				return
			end

			local target = findPlayer(nameText)
			if not target then
				print("!gc: no player matching", nameText)
				return
			end

			GoldenCookieService.AddGoldenCookies(target, amount, "test")
			print("Granted golden cookies to", target.Name, amount)
			return
		end

		local amount = parseAmount(gcArgs)
		if amount then
			GoldenCookieService.AddGoldenCookies(player, amount, "test")
			print("Granted golden cookies to", player.Name, amount)
		end
		return
	end

	if message == "!spin" then
		local result = WheelService.Spin(player)
		print("Spin result for", player.Name, ":", game:GetService("HttpService"):JSONEncode(result))
		return
	end

	-- Plot strip test harness: drive the same grow/trim logic as a real join/leave.
	if message == "!addplot" then
		SheetService.DebugAddPlot()
		return
	end
	if message == "!removeplot" then
		SheetService.DebugRemovePlot()
		return
	end
end

local function connectPlayer(player)
	player.Chatted:Connect(function(message)
		handleCommand(player, message)
	end)
end

function TestCommandService.Init()
	for _, player in ipairs(Players:GetPlayers()) do
		connectPlayer(player)
	end

	Players.PlayerAdded:Connect(connectPlayer)

	-- Debug plot panel (client UI) -> add/remove a plot via the real grow/trim logic.
	Net.on(Net.Names.DebugPlot, function(player, action)
		if not isAllowed(player) then
			return
		end
		if action == "add" then
			SheetService.DebugAddPlot()
		elseif action == "remove" then
			SheetService.DebugRemovePlot()
		end
	end)

	print("TestCommandService initialized")
end

return TestCommandService
