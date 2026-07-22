local HttpService = game:GetService("HttpService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Attrs = require(Shared:WaitForChild("Attrs"))
local NumberFormat = require(Shared:WaitForChild("NumberFormat"))
local PlayerMetricConfig = require(Shared:WaitForChild("PlayerMetricConfig"))
local XpConfig = require(Shared:WaitForChild("XpConfig"))
local GooSkinConfig = require(Shared:WaitForChild("GooSkinConfig"))
local SkinFeatureConfig = require(Shared:WaitForChild("SkinFeatureConfig"))

local ProfileStats = {}

local function formatDuration(totalSeconds)
	totalSeconds = math.max(0, math.floor(tonumber(totalSeconds) or 0))
	local hours = math.floor(totalSeconds / 3600)
	local minutes = math.floor(totalSeconds % 3600 / 60)
	local seconds = totalSeconds % 60

	if hours > 0 then
		return string.format("%dh %02dm", hours, minutes)
	elseif minutes > 0 then
		return string.format("%dm %02ds", minutes, seconds)
	end

	return tostring(seconds) .. "s"
end

function ProfileStats.bind(ctx)
	local player = ctx.player
	local body = ctx.body

	local function readMetric(attribute)
		local value = player:GetAttribute(attribute)
		return typeof(value) == "number" and math.max(0, value) or 0
	end

	local function setNumber(frameName, text)
		local frame = body:FindFirstChild(frameName, true)
		local label = frame
		if frame and not (frame:IsA("TextLabel") or frame:IsA("TextButton")) then
			label = frame:FindFirstChild("Number", true) or frame:FindFirstChild("Value", true)
		end
		if label and (label:IsA("TextLabel") or label:IsA("TextButton")) then
			label.Text = text
			return true
		end
		return false
	end

	local function setFirstNumber(frameNames, text)
		for _, frameName in ipairs(frameNames) do
			if setNumber(frameName, text) then
				return
			end
		end
	end

	local function getTopIncomeSource()
		local topLabel = "None yet"
		local topAmount = 0
		for _, incomeProfile in ipairs(PlayerMetricConfig.IncomeProfiles) do
			local amount = readMetric(incomeProfile.Attribute)
			if amount > topAmount then
				topAmount = amount
				topLabel = incomeProfile.Label
			end
		end
		return topLabel
	end

	local function countJsonDictionary(attribute)
		local encoded = player:GetAttribute(attribute)
		if type(encoded) ~= "string" or encoded == "" then
			return 0
		end

		local ok, decoded = pcall(HttpService.JSONDecode, HttpService, encoded)
		if not ok or type(decoded) ~= "table" then
			return 0
		end

		local count = 0
		for _, owned in pairs(decoded) do
			if owned then
				count += 1
			end
		end
		return count
	end

	local function render()
		if not ctx.isVisible() then
			return
		end

		local cps = tonumber(player:GetAttribute(Attrs.Cps)) or 0
		local realPlayTime = player:FindFirstChild("RealPlayTime")
		local playedSeconds = realPlayTime and math.max(0, realPlayTime.Value) or 0
		local manualClicks = readMetric(Attrs.ManualClicks)
		local lifetimeCookies = readMetric(Attrs.LifetimeCookiesEarned)
		local passiveCookies = readMetric(Attrs.BuildingCookiesEarned)
			+ readMetric(Attrs.AutoclickCookiesEarned)
			+ readMetric(Attrs.OfflineCookiesEarned)
		local xpInfo = XpConfig.GetLevelInfo(player:GetAttribute(Attrs.Xp), player:GetAttribute(Attrs.SelectedTitleId))
		local abbreviate = NumberFormat.abbreviate

		setFirstNumber({ "LifetimeCookies", "LifetimeCookiesEarned" }, abbreviate(lifetimeCookies))
		setFirstNumber({ "ManualClicks", "TotalClicks" }, abbreviate(manualClicks))
		setFirstNumber({ "ManualCookies", "ManualCookiesEarned" }, abbreviate(readMetric(Attrs.ManualCookiesEarned)))
		setFirstNumber(
			{ "BuildingCookies", "BuildingCookiesEarned" },
			abbreviate(readMetric(Attrs.BuildingCookiesEarned))
		)
		setFirstNumber(
			{ "AutoclickCookies", "AutoclickCookiesEarned" },
			abbreviate(readMetric(Attrs.AutoclickCookiesEarned))
		)
		setFirstNumber({ "OfflineCookies", "OfflineCookiesEarned" }, abbreviate(readMetric(Attrs.OfflineCookiesEarned)))
		setFirstNumber({ "RewardCookies", "RewardCookiesEarned" }, abbreviate(readMetric(Attrs.RewardCookiesEarned)))
		setFirstNumber({ "StolenCookies", "StolenCookiesEarned" }, abbreviate(readMetric(Attrs.StolenCookiesEarned)))
		setFirstNumber({ "OtherCookies", "OtherCookiesEarned" }, abbreviate(readMetric(Attrs.OtherCookiesEarned)))
		setFirstNumber({ "CookiesSpent" }, abbreviate(readMetric(Attrs.CookiesSpent)))
		setFirstNumber({ "CookiesLost", "CookiesLostToTheft" }, abbreviate(readMetric(Attrs.CookiesLostToTheft)))
		setFirstNumber({ "HighestCps", "BestCps" }, NumberFormat.rate(readMetric(Attrs.HighestCps)))
		setFirstNumber({ "GoldenEarned", "GoldenCookiesEarned" }, abbreviate(readMetric(Attrs.GoldenCookiesEarned)))
		setFirstNumber({ "GoldenSpent", "GoldenCookiesSpent" }, abbreviate(readMetric(Attrs.GoldenCookiesSpent)))
		setFirstNumber({ "BuildingsPlaced", "LifetimeBuildings" }, abbreviate(readMetric(Attrs.BuildingsPlaced)))
		setFirstNumber({ "WheelSpins" }, abbreviate(readMetric(Attrs.WheelSpins)))
		setFirstNumber({ "LoginStreak", "CurrentLoginStreak" }, abbreviate(player:GetAttribute(Attrs.LoginStreak)))
		setFirstNumber({ "BestLoginStreak" }, abbreviate(readMetric(Attrs.BestLoginStreak)))
		setFirstNumber({ "LongestSession" }, formatDuration(readMetric(Attrs.LongestSessionSeconds)))
		local gooUnlocked = math.max(0, countJsonDictionary(Attrs.OwnedGooSkinsJson) - 1)
		local gooUnlockable = math.max(0, #GooSkinConfig.Definitions - 1)
		local skinProgress = ("%d/%d unlocked"):format(gooUnlocked, gooUnlockable)
		if SkinFeatureConfig.BuildingSkinsEnabled then
			skinProgress = ("Goo %d/%d • Buildings %d"):format(
				gooUnlocked,
				gooUnlockable,
				countJsonDictionary(Attrs.OwnedSkinsJson)
			)
		end
		setFirstNumber({ "SkinsOwned" }, skinProgress)
		setFirstNumber(
			{ "AchievementsEarned", "AchievementCount" },
			tostring(countJsonDictionary(Attrs.AchievementsJson))
		)
		setFirstNumber({ "CookiesPerHour", "Cph" }, NumberFormat.rate(cps * 3600))
		setFirstNumber(
			{ "AverageClickRate", "AverageClicksPerMinute" },
			NumberFormat.rate(playedSeconds > 0 and manualClicks * 60 / playedSeconds or 0)
		)
		setFirstNumber(
			{ "PassiveShare" },
			lifetimeCookies > 0 and string.format("%.0f%%", passiveCookies / lifetimeCookies * 100) or "0%"
		)
		setFirstNumber({ "TopIncomeSource" }, getTopIncomeSource())
		setFirstNumber({ "PlayerLevel", "Level" }, tostring(xpInfo.level))
		setFirstNumber({ "TotalXp", "Xp" }, abbreviate(xpInfo.totalXp))
	end

	player:GetAttributeChangedSignal(Attrs.Xp):Connect(render)
	player:GetAttributeChangedSignal(Attrs.SelectedTitleId):Connect(render)
	player:GetAttributeChangedSignal(Attrs.LoginStreak):Connect(render)
	player:GetAttributeChangedSignal(Attrs.OwnedSkinsJson):Connect(render)
	player:GetAttributeChangedSignal(Attrs.OwnedGooSkinsJson):Connect(render)
	player:GetAttributeChangedSignal(Attrs.AchievementsJson):Connect(render)
	for _, attribute in ipairs(PlayerMetricConfig.PersistentAttributes) do
		player:GetAttributeChangedSignal(attribute):Connect(render)
	end

	return {
		refresh = render,
	}
end

return ProfileStats
