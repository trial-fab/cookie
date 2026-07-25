-- Focused, server-authored onboarding funnel analytics.
local AnalyticsService = game:GetService("AnalyticsService")
local RunService = game:GetService("RunService")

local QuestAnalyticsService = {}

local function log(player, eventName, value, fields)
	if RunService:IsStudio() then
		return
	end
	local ok, problem = pcall(function()
		AnalyticsService:LogCustomEvent(player, eventName, value or 1, fields or {})
	end)
	if not ok then
		warn(("Quest analytics %s failed: %s"):format(eventName, tostring(problem)))
	end
end

function QuestAnalyticsService.RecordStepStarted(player, arcId, questId, stepId, resumed)
	log(player, resumed and "QuestStepResumed" or "QuestStepStarted", 1, {
		ArcId = arcId,
		QuestId = questId,
		StepId = stepId,
	})
end

function QuestAnalyticsService.RecordStepCompleted(player, arcId, questId, stepId, elapsedSeconds)
	log(player, "QuestStepCompleted", 1, {
		ArcId = arcId,
		QuestId = questId,
		StepId = stepId,
		ElapsedSeconds = tostring(math.max(0, math.floor(tonumber(elapsedSeconds) or 0))),
	})
end

function QuestAnalyticsService.RecordQuestCompleted(player, arcId, questId)
	log(player, "QuestCompleted", 1, {
		ArcId = arcId,
		QuestId = questId,
	})
	log(player, "FirstQuestCompleted", 1, {
		ArcId = arcId,
		QuestId = questId,
	})
end

function QuestAnalyticsService.RecordRewardGranted(player, arcId, questId, amount)
	log(player, "QuestRewardGranted", amount, {
		ArcId = arcId,
		QuestId = questId,
		Amount = tostring(math.max(0, math.floor(tonumber(amount) or 0))),
	})
end

function QuestAnalyticsService.Init() end

return QuestAnalyticsService
