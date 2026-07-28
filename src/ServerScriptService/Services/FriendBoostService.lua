-- FriendBoostService: the server half of the Friend Boost. Publishes a live production and
-- manual-click multiplier for every friend who is in this server because of this player.
--
-- WHY ATTRIBUTION AND NOT FRIENDSHIP. Roblox exposes no follower list to a game server (there is
-- no API, and HttpService cannot reach roblox.com), and a plain `IsFriendsWith` check would pay
-- out for a friend request accepted in the player list ten seconds ago. What Roblox DOES expose
-- is how a player got here: `GetJoinData().ReferredByPlayerId` for an accepted invite link -- the
-- one InviteController's envelope sends -- and `Player.FollowUserId` for a profile follow-join.
-- Both mean "this person came for you", which is a stronger claim than friendship and, unlike
-- friendship, cannot be manufactured from inside the server.
--
-- The link is symmetric while both are present. Whoever brought whom, the two of them are playing
-- together, so both sides count it; otherwise the player who accepted the invite gets nothing for
-- accepting it. Each other player is counted at most once, so a mutual link (A follows B in, then
-- A leaves and rejoins following B) is still one friend rather than two.
--
-- Session state only. Nothing here is persisted or restored: the boost lasts exactly as long as
-- the friend is in the server. That is also why OfflineEarningsService prices its away-time window
-- with the boost explicitly removed -- the friend was not there for any of it.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local FriendBoostAnalyticsService = require(ServerScriptService.Services.FriendBoostAnalyticsService)
local Attrs = require(ReplicatedStorage.Shared.Attrs)
local DevTuning = require(ReplicatedStorage.Shared.DevTuning.DevTuning)
local FriendBoostConfig = require(ReplicatedStorage.Shared.FriendBoostConfig)

local FriendBoostService = {}

-- player -> { UserId = number, Source = "Invite" | "Follow" }: who brought them here.
local broughtByPlayer = setmetatable({}, { __mode = "k" })
-- player -> the multiplier currently published for them.
local multiplierByPlayer = setmetatable({}, { __mode = "k" })
-- A player is still inside Players:GetPlayers() throughout PlayerRemoving, so without an explicit
-- mark every remaining player would recount the leaver and keep a boost that just ended.
local departingPlayers = setmetatable({}, { __mode = "k" })
local changedCallbacks = {}

local function readAttribution(player)
	-- An accepted invite link is the explicit case and outranks a profile follow-join, so a player
	-- who did both is attributed to the invite that actually brought them.
	local ok, joinData = pcall(function()
		return player:GetJoinData()
	end)
	local referredBy = ok and type(joinData) == "table" and tonumber(joinData.ReferredByPlayerId) or nil
	if referredBy and referredBy > 0 and referredBy ~= player.UserId then
		return { UserId = referredBy, Source = "Invite" }
	end

	local followUserId = tonumber(player.FollowUserId) or 0
	if followUserId > 0 and followUserId ~= player.UserId then
		return { UserId = followUserId, Source = "Follow" }
	end

	return nil
end

local function isLinked(player, other)
	local mine = broughtByPlayer[player]
	if mine and mine.UserId == other.UserId then
		return true
	end

	local theirs = broughtByPlayer[other]
	return theirs ~= nil and theirs.UserId == player.UserId
end

-- Counts PLAYERS, not links, which is what makes a mutual link worth one friend instead of two.
local function countFriends(player)
	local count = 0
	for _, other in ipairs(Players:GetPlayers()) do
		if other ~= player and not departingPlayers[other] and isLinked(player, other) then
			count += 1
		end
	end

	return count
end

local function computeMultiplier(friendCount)
	return FriendBoostConfig.ComputeMultiplier(
		DevTuning.get("FriendBoost.PercentPerFriend"),
		DevTuning.get("FriendBoost.MaxFriends"),
		friendCount
	)
end

local function publish(player)
	if player.Parent ~= Players or departingPlayers[player] then
		return
	end

	local friendCount = countFriends(player)
	local multiplier = computeMultiplier(friendCount)
	local previous = multiplierByPlayer[player]
	if previous == multiplier and player:GetAttribute(Attrs.FriendBoostCount) == friendCount then
		return
	end

	multiplierByPlayer[player] = multiplier
	player:SetAttribute(Attrs.FriendBoostCount, friendCount)
	player:SetAttribute(Attrs.FriendBoostMultiplier, multiplier)

	if multiplier ~= (previous or 1) then
		FriendBoostAnalyticsService.RecordBoostChanged(player, friendCount, multiplier)
	end

	for _, callback in ipairs(changedCallbacks) do
		task.spawn(callback, player)
	end
end

-- One player arriving or leaving changes the count for everyone linked to them, so this always
-- runs over the whole server rather than over the one player who moved.
local function publishAll()
	for _, player in ipairs(Players:GetPlayers()) do
		publish(player)
	end
end

local function onPlayerAdded(player)
	local attribution = readAttribution(player)
	broughtByPlayer[player] = attribution
	departingPlayers[player] = nil
	-- Seed both attributes before anything can read them so a client never has to distinguish
	-- "no boost" from "not published yet".
	player:SetAttribute(Attrs.FriendBoostCount, 0)
	player:SetAttribute(Attrs.FriendBoostMultiplier, 1)

	if attribution then
		FriendBoostAnalyticsService.RecordJoinAttributed(player, attribution.Source)
	end

	publishAll()
end

local function onPlayerRemoving(player)
	departingPlayers[player] = true
	broughtByPlayer[player] = nil
	multiplierByPlayer[player] = nil
	publishAll()
end

-- The canonical live multiplier. Server callers use this rather than the replicated attribute so
-- production math never depends on a value that has already been out to a client and back.
function FriendBoostService.GetMultiplier(player)
	return multiplierByPlayer[player] or 1
end

function FriendBoostService.GetFriendCount(player)
	local count = player and player:GetAttribute(Attrs.FriendBoostCount)
	return type(count) == "number" and count or 0
end

-- Notified with the affected player whenever a published multiplier changes. ProductionService
-- uses it to refresh CpS immediately instead of leaving the HUD stale until the next tick.
function FriendBoostService.OnChanged(callback)
	table.insert(changedCallbacks, callback)
end

function FriendBoostService.Init()
	Players.PlayerAdded:Connect(onPlayerAdded)
	Players.PlayerRemoving:Connect(onPlayerRemoving)

	for _, player in ipairs(Players:GetPlayers()) do
		onPlayerAdded(player)
	end

	-- Retuning the payout has to move everyone who is already here, not just the next arrival.
	DevTuning.observe("FriendBoost.PercentPerFriend", publishAll)
	DevTuning.observe("FriendBoost.MaxFriends", publishAll)

	print("FriendBoostService initialized")
end

return FriendBoostService
