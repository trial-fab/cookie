-- Server authority for the central Ancient Core's one-time cookie activation.
--
-- The physical hub is shared, but its presentation is per player. This service owns only the
-- durable run flag and purchase validation; HubOrbAnimation renders the matching local state.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Attrs = require(ReplicatedStorage.Shared.Attrs)
local HubCoreConfig = require(ReplicatedStorage.Shared.HubCoreConfig)
local Net = require(ReplicatedStorage.Shared.Net)
local PlayerMetricConfig = require(ReplicatedStorage.Shared.PlayerMetricConfig)
local CookieService = require(script.Parent.CookieService)
local HubCoreAnalyticsService = require(script.Parent.HubCoreAnalyticsService)
local PlayerDataService = require(script.Parent.PlayerDataService)
local PlayerMetricsService = require(script.Parent.PlayerMetricsService)

local HubCoreService = {}

local function getData(player)
	local data = player and PlayerDataService.GetDomain7Data(player)
	if type(data) ~= "table" or type(data.Run) ~= "table" or type(data.Persistent) ~= "table" then
		return nil
	end
	return data
end

local function findDormantCore()
	local hub = Workspace:FindFirstChild("HubPlazaDraft")
	local leaderboard = hub and hub:FindFirstChild("LeaderboardSystem")
	local orbItems = leaderboard and leaderboard:FindFirstChild("OrbItems")
	local core = orbItems and orbItems:FindFirstChild("OrbCore")
	return core and core:IsA("BasePart") and core or nil
end

local function isPlayerNearCore(player)
	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	local core = findDormantCore()
	if not (root and root:IsA("BasePart") and core) then
		return false
	end
	return (root.Position - core.Position).Magnitude <= HubCoreConfig.MaxActivationDistance
end

function HubCoreService.Activate(player)
	local data = getData(player)
	if not data then
		return false, "Your data is still loading."
	end

	local run = data.Run
	if run.HubCoreActivated == true then
		return true, "Ancient Core already activated.", true
	end
	if data.Persistent.StoryStep ~= HubCoreConfig.RequiredStoryStep then
		return false, "Finish Chapter 1 first."
	end
	if not isPlayerNearCore(player) then
		return false, "Move closer to the Ancient Core."
	end

	local cost = HubCoreConfig.ActivationCostCookies
	local cookies = CookieService.GetCookies(player)
	if cookies == nil then
		return false, "Your data is still loading."
	end
	if cookies < cost then
		return false, ("You need %d cookies."):format(cost)
	end

	-- This entire spend-and-grant block is yield-free. A second invoke cannot pass the duplicate
	-- or balance checks until this one has published the canonical flag.
	if not CookieService.AddCookies(player, -cost, PlayerMetricConfig.CookieSources.PendingPurchase) then
		return false, "Your data is still loading."
	end
	run.HubCoreActivated = true
	player:SetAttribute(Attrs.HubCoreActivated, true)
	PlayerMetricsService.RecordCookiesSpent(player, cost)

	local remaining = CookieService.GetCookies(player) or 0
	HubCoreAnalyticsService.RecordActivated(player, cost, remaining)
	return true, "Ancient Core activated.", false
end

function HubCoreService.Init()
	Net.onInvoke(Net.Names.ActivateHubCore, function(player)
		local success, message, alreadyActivated = HubCoreService.Activate(player)
		return {
			success = success,
			message = message,
			alreadyActivated = alreadyActivated == true,
			activated = player:GetAttribute(Attrs.HubCoreActivated) == true,
			cookies = CookieService.GetCookies(player),
		}
	end)

	print("HubCoreService initialized")
end

return HubCoreService
