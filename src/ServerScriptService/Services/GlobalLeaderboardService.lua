local DataStoreService = game:GetService("DataStoreService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local GlobalLeaderboardConfig = require(Shared:WaitForChild("GlobalLeaderboardConfig"))
local Net = require(Shared:WaitForChild("Net"))
local PlayerDataService = require(script.Parent.PlayerDataService)
local PlayerMetricsService = require(script.Parent.PlayerMetricsService)

local GlobalLeaderboardService = {}

local STORE_PREFIX = RunService:IsStudio() and "CG_GL_v1_Studio_" or "CG_GL_v1_"
local WRITE_INTERVAL_SECONDS = 60
local REQUEST_COOLDOWN_SECONDS = 15
local PAGE_SIZE = 100
local NAME_CACHE_SECONDS = 6 * 60 * 60
-- OrderedDataStore values are signed 64-bit integers, while ClickGame cookie totals are ordinary
-- doubles that can grow far beyond that range. Pack the base-10 exponent plus 13 significant
-- digits into a monotonic integer that remains exactly representable by a Luau number.
local SCORE_SEGMENT_SIZE = 10 ^ 13
local SCORE_MANTISSA_SCALE = 10 ^ 12
local SCORE_EXPONENT_OFFSET = 309

local storesByMetricId = {}
local lastWrittenByPlayer = setmetatable({}, { __mode = "k" })
local snapshotByPlayer = setmetatable({}, { __mode = "k" })
local requestAtByPlayer = setmetatable({}, { __mode = "k" })
local nameCacheByUserId = {}
local initialized = false

local function normalizeScore(value)
	value = tonumber(value) or 0
	if value ~= value or value == math.huge or value == -math.huge then
		return 0
	end
	return math.max(0, value)
end

local function encodeScore(value)
	value = normalizeScore(value)
	if value <= 0 then
		return 0
	end

	local exponent = math.floor(math.log(value) / math.log(10) + 1e-12)
	local normalized = value / (10 ^ exponent)
	local mantissa = math.floor(normalized * SCORE_MANTISSA_SCALE + 0.5)
	if mantissa >= SCORE_SEGMENT_SIZE then
		exponent += 1
		mantissa = SCORE_MANTISSA_SCALE
	end
	return (exponent + SCORE_EXPONENT_OFFSET) * SCORE_SEGMENT_SIZE + mantissa
end

local function decodeScore(value)
	value = math.max(0, math.floor(tonumber(value) or 0))
	if value == 0 then
		return 0
	end

	local segment = math.floor(value / SCORE_SEGMENT_SIZE)
	local mantissa = value - segment * SCORE_SEGMENT_SIZE
	local exponent = segment - SCORE_EXPONENT_OFFSET
	return mantissa / SCORE_MANTISSA_SCALE * (10 ^ exponent)
end

local function getMetricValue(player, definition)
	local data = PlayerDataService.Get(player)
	local persistent = type(data) == "table" and data.Persistent
	if type(persistent) ~= "table" then
		return nil
	end
	return normalizeScore(persistent[definition.Attribute])
end

local function writePlayerScores(player, force, allowProjectionFallback)
	local hasPlayerData = PlayerDataService.Get(player) ~= nil
	if
		(player.Parent ~= Players and not allowProjectionFallback)
		or (not hasPlayerData and not allowProjectionFallback)
	then
		return false, "Player data is still loading."
	end

	if hasPlayerData then
		PlayerMetricsService.FlushProjections(player)
	end
	local written = lastWrittenByPlayer[player]
	if not written then
		written = {}
		lastWrittenByPlayer[player] = written
	end

	local allSucceeded = true
	for _, definition in ipairs(GlobalLeaderboardConfig.Definitions) do
		local value = hasPlayerData and getMetricValue(player, definition)
			or normalizeScore(player:GetAttribute(definition.Attribute))
		local encodedValue = value ~= nil and encodeScore(value) or nil
		if encodedValue ~= nil and (force or written[definition.Id] ~= encodedValue) then
			local success, problem = pcall(function()
				storesByMetricId[definition.Id]:SetAsync(tostring(player.UserId), encodedValue)
			end)
			if success then
				written[definition.Id] = encodedValue
			else
				allSucceeded = false
				warn(
					("GlobalLeaderboardService: could not write %s for %s: %s"):format(
						definition.Id,
						player.Name,
						tostring(problem)
					)
				)
			end
		end
	end
	return allSucceeded
end

local function getPlayerName(userId)
	local cached = nameCacheByUserId[userId]
	local now = os.time()
	if cached and now - cached.cachedAt < NAME_CACHE_SECONDS then
		return cached.name
	end

	local success, name = pcall(Players.GetNameFromUserIdAsync, Players, userId)
	if not success or type(name) ~= "string" or name == "" then
		name = "User " .. tostring(userId)
	end
	nameCacheByUserId[userId] = {
		name = name,
		cachedAt = now,
	}
	return name
end

local function readMetricSnapshot(player, definition)
	local playerScore = getMetricValue(player, definition)
	if playerScore == nil then
		return nil, "Player data is still loading."
	end
	local encodedPlayerScore = encodeScore(playerScore)

	local success, pagesOrProblem = pcall(function()
		return storesByMetricId[definition.Id]:GetSortedAsync(false, PAGE_SIZE)
	end)
	if not success then
		return nil, tostring(pagesOrProblem)
	end

	local pages = pagesOrProblem
	local topEntries = {}
	local higherScoreCount = 0
	local reachedPlayerScore = false
	local scannedCount = 0

	while true do
		local page = pages:GetCurrentPage()
		for _, entry in ipairs(page) do
			local encodedScore = math.max(0, math.floor(tonumber(entry.value) or 0))
			scannedCount += 1
			if #topEntries < GlobalLeaderboardConfig.TopCount then
				local userId = tonumber(entry.key)
				table.insert(topEntries, {
					Rank = scannedCount,
					UserId = userId,
					Name = userId and getPlayerName(userId) or tostring(entry.key),
					EncodedScore = encodedScore,
					Score = decodeScore(encodedScore),
				})
			end

			if not reachedPlayerScore and encodedScore > encodedPlayerScore then
				higherScoreCount += 1
			else
				reachedPlayerScore = true
			end
		end

		if (reachedPlayerScore and #topEntries >= GlobalLeaderboardConfig.TopCount) or pages.IsFinished then
			break
		end

		local advanced, advanceProblem = pcall(function()
			pages:AdvanceToNextPageAsync()
		end)
		if not advanced then
			return nil, tostring(advanceProblem)
		end
	end

	local previousScore
	local competitionRank = 0
	for index, entry in ipairs(topEntries) do
		if previousScore == nil or entry.EncodedScore ~= previousScore then
			competitionRank = index
			previousScore = entry.EncodedScore
		end
		entry.Rank = competitionRank
		entry.EncodedScore = nil
	end

	return {
		Id = definition.Id,
		Top = topEntries,
		CurrentPlayer = {
			Rank = higherScoreCount + 1,
			UserId = player.UserId,
			Name = player.DisplayName,
			Score = playerScore,
		},
	}
end

local function buildSnapshot(player)
	local writeSucceeded = writePlayerScores(player, true)
	if not PlayerDataService.Get(player) then
		return {
			Success = false,
			Message = "Player data is still loading.",
		}
	end
	if not writeSucceeded then
		return {
			Success = false,
			Message = "Global rankings could not be updated.",
		}
	end

	local metrics = {}
	for _, definition in ipairs(GlobalLeaderboardConfig.Definitions) do
		local metricSnapshot, problem = readMetricSnapshot(player, definition)
		if not metricSnapshot then
			warn(
				("GlobalLeaderboardService: could not read %s for %s: %s"):format(
					definition.Id,
					player.Name,
					tostring(problem)
				)
			)
			return {
				Success = false,
				Message = "Global rankings are temporarily unavailable.",
			}
		end
		metrics[definition.Id] = metricSnapshot
	end

	return {
		Success = true,
		Metrics = metrics,
		UpdatedAt = os.time(),
	}
end

local function getSnapshot(player)
	local now = os.clock()
	local cached = snapshotByPlayer[player]
	if cached and now - (requestAtByPlayer[player] or 0) < GlobalLeaderboardConfig.RefreshSeconds then
		return cached
	end
	if now - (requestAtByPlayer[player] or -math.huge) < REQUEST_COOLDOWN_SECONDS then
		return cached or {
			Success = false,
			Message = "Global rankings are refreshing.",
		}
	end

	requestAtByPlayer[player] = now
	local snapshot = buildSnapshot(player)
	if snapshot.Success then
		snapshotByPlayer[player] = snapshot
	end
	return snapshot
end

local function startWriteLoop()
	task.spawn(function()
		while true do
			task.wait(WRITE_INTERVAL_SECONDS)
			for _, player in ipairs(Players:GetPlayers()) do
				task.spawn(writePlayerScores, player, false)
			end
		end
	end)
end

function GlobalLeaderboardService.Init()
	if initialized then
		return
	end
	initialized = true

	for _, definition in ipairs(GlobalLeaderboardConfig.Definitions) do
		storesByMetricId[definition.Id] = DataStoreService:GetOrderedDataStore(STORE_PREFIX .. definition.StoreSuffix)
	end

	Net.onInvoke(Net.Names.GetGlobalLeaderboards, getSnapshot)

	Players.PlayerRemoving:Connect(function(player)
		-- PlayerDataService registered its leave listener first and may already have released the
		-- active profile. Its final snapshot flushes metric attributes before that release, so the
		-- projection fallback preserves the last second without allowing pre-load zero writes.
		writePlayerScores(player, true, true)
		lastWrittenByPlayer[player] = nil
		snapshotByPlayer[player] = nil
		requestAtByPlayer[player] = nil
	end)

	startWriteLoop()
	print("GlobalLeaderboardService initialized")
end

return GlobalLeaderboardService
