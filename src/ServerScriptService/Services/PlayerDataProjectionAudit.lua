-- Yield-free safety harness for persistence domains that have been converted to Data-first
-- ownership. Converted Player attributes are replication projections only: compare them with
-- canonical Profile.Data before saves, but never mutate Data from this module.
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local HttpService = game:GetService("HttpService")

local Attrs = require(ReplicatedStorage.Shared.Attrs)
local PlayerMetricConfig = require(ReplicatedStorage.Shared.PlayerMetricConfig)
local SettingsConfig = require(ReplicatedStorage.Shared.SettingsConfig)

local PlayerDataProjectionAudit = {}

-- Weak Player keys naturally scope warning deduplication to one player/profile session.
local warnedFieldsByPlayer = setmetatable({}, { __mode = "k" })
local storyProjectionReadyByPlayer = setmetatable({}, { __mode = "k" })
local domain3ProjectionReadyByPlayer = setmetatable({}, { __mode = "k" })
local domain4ProjectionReadyByPlayer = setmetatable({}, { __mode = "k" })
local domain5ProjectionReadyByPlayer = setmetatable({}, { __mode = "k" })
local domain6ProjectionReadyByPlayer = setmetatable({}, { __mode = "k" })
local domain7ProjectionReadyByPlayer = setmetatable({}, { __mode = "k" })

local STORY_FIELDS = {
	{ field = "IntroSeen", attribute = Attrs.IntroSeen },
	{ field = "StoryChapter", attribute = Attrs.StoryChapter },
	{ field = "StoryStep", attribute = Attrs.StoryStep },
	{ field = "StoryHealingClicks", attribute = Attrs.StoryHealingClicks },
	{ field = "MixerUnlocked", attribute = Attrs.MixerUnlocked },
}

local DOMAIN_3_FIELDS = {
	{ field = "LoginStreak", attribute = Attrs.LoginStreak },
	{ field = "LastLoginDay", attribute = Attrs.LastLoginDay },
	{ field = "LastSeenTimestamp", attribute = Attrs.LastSeenTimestamp },
}

local DOMAIN_4_FIELDS = {
	{ field = "GoldenCookies", attribute = Attrs.GoldenCookies },
	{ field = "Gems", attribute = Attrs.Gems },
	{ field = "Xp", attribute = Attrs.Xp },
}

local DOMAIN_5_JSON_FIELDS = {
	{ field = "OwnedSkins", attribute = Attrs.OwnedSkinsJson },
	{ field = "EquippedSkins", attribute = Attrs.EquippedSkinsJson },
	{ field = "OwnedGooSkins", attribute = Attrs.OwnedGooSkinsJson },
	{ field = "Achievements", attribute = Attrs.AchievementsJson },
	{ field = "UnlockedBuildings", attribute = Attrs.UnlockedBuildingsJson },
}

local function valuesEqual(left, right, visited)
	if typeof(left) ~= typeof(right) then
		return false
	end
	if typeof(left) ~= "table" then
		return left == right
	end

	visited = visited or {}
	local rightByLeft = visited[left]
	if rightByLeft and rightByLeft[right] then
		return true
	end
	rightByLeft = rightByLeft or {}
	visited[left] = rightByLeft
	rightByLeft[right] = true

	for key, value in pairs(left) do
		if right[key] == nil or not valuesEqual(value, right[key], visited) then
			return false
		end
	end
	for key in pairs(right) do
		if left[key] == nil then
			return false
		end
	end
	return true
end

local function compareKeys(left, right)
	local leftType, rightType = typeof(left), typeof(right)
	if leftType ~= rightType then
		return leftType < rightType
	end
	if leftType == "number" then
		return left < right
	end
	return tostring(left) < tostring(right)
end

local formatValue

local function formatTable(value, seen)
	if seen[value] then
		return "<cycle>"
	end
	seen[value] = true

	local keys = {}
	for key in pairs(value) do
		table.insert(keys, key)
	end
	table.sort(keys, compareKeys)

	local parts = {}
	for _, key in ipairs(keys) do
		local keyText = typeof(key) == "string" and string.format("%q", tostring(key)) or tostring(key)
		table.insert(parts, ("[%s]=%s"):format(keyText, formatValue(value[key], seen)))
	end
	seen[value] = nil
	return "{" .. table.concat(parts, ", ") .. "}"
end

formatValue = function(value, seen)
	local valueType = typeof(value)
	if valueType == "string" then
		return string.format("%q (%s)", value, valueType)
	end
	if valueType == "table" then
		return formatTable(value, seen or {}) .. " (table)"
	end
	return string.format("%s (%s)", tostring(value), valueType)
end

local function warnMismatch(player, field, expected, actual)
	if valuesEqual(expected, actual) then
		return
	end

	local warnedFields = warnedFieldsByPlayer[player]
	if not warnedFields then
		warnedFields = {}
		warnedFieldsByPlayer[player] = warnedFields
	end
	if warnedFields[field] then
		return
	end
	warnedFields[field] = true

	warn(
		("[PERSISTENCE PROJECTION MISMATCH] player=%s field=%s expected=%s actual=%s"):format(
			player.Name,
			field,
			formatValue(expected),
			formatValue(actual)
		)
	)
end

function PlayerDataProjectionAudit.MarkStoryProjectionReady(player)
	storyProjectionReadyByPlayer[player] = true
end

function PlayerDataProjectionAudit.MarkDomain3ProjectionReady(player)
	domain3ProjectionReadyByPlayer[player] = true
end

function PlayerDataProjectionAudit.MarkDomain4ProjectionReady(player)
	domain4ProjectionReadyByPlayer[player] = true
end

function PlayerDataProjectionAudit.MarkDomain5ProjectionReady(player)
	domain5ProjectionReadyByPlayer[player] = true
end

function PlayerDataProjectionAudit.MarkDomain6ProjectionReady(player)
	domain6ProjectionReadyByPlayer[player] = true
end

function PlayerDataProjectionAudit.MarkDomain7ProjectionReady(player)
	domain7ProjectionReadyByPlayer[player] = true
end

function PlayerDataProjectionAudit.ForgetPlayer(player)
	warnedFieldsByPlayer[player] = nil
	storyProjectionReadyByPlayer[player] = nil
	domain3ProjectionReadyByPlayer[player] = nil
	domain4ProjectionReadyByPlayer[player] = nil
	domain5ProjectionReadyByPlayer[player] = nil
	domain6ProjectionReadyByPlayer[player] = nil
	domain7ProjectionReadyByPlayer[player] = nil
end

local function readValueProjection(player, parentName, valueName, className)
	local parent = parentName and player:FindFirstChild(parentName) or player
	local value = parent and parent:FindFirstChild(valueName)
	if not value then
		return nil
	end
	if not value:IsA(className) then
		return {
			ProjectionClass = value.ClassName,
			ProjectionType = typeof(value),
		}
	end
	return value.Value
end

local function readUpgradeCountsProjection(player)
	local container = player:FindFirstChild("UpgradeCountData")
	if not container then
		return nil
	end
	if not container:IsA("Configuration") then
		return {
			ProjectionClass = container.ClassName,
			ProjectionType = typeof(container),
		}
	end

	local actual = {}
	for _, child in ipairs(container:GetChildren()) do
		local childValue
		if child:IsA("IntValue") then
			childValue = child.Value
		else
			childValue = {
				ProjectionClass = child.ClassName,
				ProjectionType = typeof(child),
			}
		end

		if actual[child.Name] == nil then
			actual[child.Name] = childValue
		else
			local previous = actual[child.Name]
			if type(previous) == "table" and previous.DuplicateProjectionChildren then
				table.insert(previous.DuplicateProjectionChildren, childValue)
			else
				actual[child.Name] = {
					DuplicateProjectionChildren = { previous, childValue },
				}
			end
		end
	end
	return actual
end

local function decodeJsonProjection(player, attribute)
	local encoded = player:GetAttribute(attribute)
	if typeof(encoded) ~= "string" then
		return encoded
	end
	local ok, decoded = pcall(HttpService.JSONDecode, HttpService, encoded)
	if not ok or type(decoded) ~= "table" then
		return encoded
	end
	return decoded
end

function PlayerDataProjectionAudit.Check(player, data)
	local persistent = type(data) == "table" and data.Persistent
	if type(persistent) ~= "table" then
		return
	end

	local buildViewNudgeDisabled = player:GetAttribute(Attrs.BuildViewNudgeDisabled)
	if typeof(buildViewNudgeDisabled) == "boolean" then
		warnMismatch(
			player,
			"Persistent.BuildViewNudgeDisabled",
			persistent.BuildViewNudgeDisabled,
			buildViewNudgeDisabled
		)
	end

	-- A profile can end after load but before StoryService.SetupPlayer projects these fields.
	-- Once setup marks the projection ready, compare unconditionally so nil and wrong types warn.
	if storyProjectionReadyByPlayer[player] then
		for _, definition in ipairs(STORY_FIELDS) do
			warnMismatch(
				player,
				"Persistent." .. definition.field,
				persistent[definition.field],
				player:GetAttribute(definition.attribute)
			)
		end
	end

	-- PlayerSetupService projects all three fields as one yield-free setup group, then marks
	-- readiness. This avoids warnings if a profile ends after load but before that projection.
	if domain3ProjectionReadyByPlayer[player] then
		for _, definition in ipairs(DOMAIN_3_FIELDS) do
			warnMismatch(
				player,
				"Persistent." .. definition.field,
				persistent[definition.field],
				player:GetAttribute(definition.attribute)
			)
		end
	end

	-- PlayerSetupService normalizes canonical XP/GC and projects both in one yield-free
	-- setup group before marking readiness. Thereafter nil and wrong types are mismatches.
	if domain4ProjectionReadyByPlayer[player] then
		for _, definition in ipairs(DOMAIN_4_FIELDS) do
			warnMismatch(
				player,
				"Persistent." .. definition.field,
				persistent[definition.field],
				player:GetAttribute(definition.attribute)
			)
		end
	end

	-- Domain 5 setup normalizes all canonical tables and publishes every JSON/string
	-- projection without yielding before marking readiness. Decode JSON and compare structure;
	-- dictionary key order is deliberately not part of the equality contract.
	if domain5ProjectionReadyByPlayer[player] then
		for _, definition in ipairs(DOMAIN_5_JSON_FIELDS) do
			warnMismatch(
				player,
				"Persistent." .. definition.field,
				persistent[definition.field],
				decodeJsonProjection(player, definition.attribute)
			)
		end
		warnMismatch(
			player,
			"Persistent.SelectedGooSkin",
			persistent.SelectedGooSkin,
			player:GetAttribute(Attrs.SelectedGooSkinId)
		)
	end


	-- PlayerMetricsService normalizes and publishes every configured scalar metric as one
	-- yield-free setup group, then PlayerSetupService marks readiness. snapshotPlayer flushes
	-- only legitimately dirty metric fields before this comparison, so unqueued mismatches remain
	-- observable and retain the existing typed, once-per-field-per-session diagnostics.
	if domain6ProjectionReadyByPlayer[player] then
		for _, attribute in ipairs(PlayerMetricConfig.PersistentAttributes) do
			warnMismatch(
				player,
				"Persistent." .. attribute,
				persistent[attribute],
				player:GetAttribute(attribute)
			)
		end
	end

	-- Domain 7 setup normalizes canonical Data, projects every scalar/count, completes metric
	-- setup, then opens this gate. Reset replaces and reprojects the entire Run in one yield-free
	-- turn, so readiness intentionally remains set across reset. The structural count comparison
	-- ignores dictionary iteration order while exposing missing, extra, duplicate, and wrong-class
	-- children in deterministic typed diagnostics.
	if domain7ProjectionReadyByPlayer[player] then
		local run = type(data.Run) == "table" and data.Run or {}
		warnMismatch(
			player,
			"Run.Cookies",
			run.Cookies,
			readValueProjection(player, "leaderstats", "Cookies", "NumberValue")
		)
		warnMismatch(
			player,
			"Run.ShieldTime",
			run.ShieldTime,
			readValueProjection(player, nil, "ShieldTime", "IntValue")
		)
		warnMismatch(
			player,
			"Run.CanBeStolenFrom",
			run.CanBeStolenFrom,
			readValueProjection(player, nil, "CanBeStolenFrom", "BoolValue")
		)
		warnMismatch(
			player,
			"Run.UpgradeCounts",
			type(run.UpgradeCounts) == "table" and run.UpgradeCounts or {},
			readUpgradeCountsProjection(player)
		)
		warnMismatch(
			player,
			"Persistent.RealPlayTime",
			persistent.RealPlayTime,
			readValueProjection(player, nil, "RealPlayTime", "IntValue")
		)
	end

	-- SettingsLoaded is raised only after every stored setting has been projected. Missing
	-- individual attributes are meaningful: nil means use the device-aware client default.
	if player:GetAttribute(Attrs.SettingsLoaded) ~= true then
		return
	end
	local settings = type(persistent.Settings) == "table" and persistent.Settings or {}
	for _, attribute in ipairs(SettingsConfig.StoredAttributes) do
		warnMismatch(player, "Persistent.Settings." .. attribute, settings[attribute], player:GetAttribute(attribute))
	end
end

return PlayerDataProjectionAudit
