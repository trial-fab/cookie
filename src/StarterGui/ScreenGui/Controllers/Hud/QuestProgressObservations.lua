-- QuestProgressObservations — reports the arc's two UI-only facts to the server.
--
-- Building Stats and Build View leave no canonical server trace (neither is a persisted
-- setting), so they are the one narrow case where the client tells the server something
-- happened. The server allowlists and rate-limits these, and none of them authorizes
-- anything economic.
--
-- Facts are reported whenever they happen, not only while their step is tracked: a player
-- who explored Build View before the quest asked is credited rather than made to repeat it.
--
-- Reporting is deliberately NOT once-per-session. This controller starts as soon as the
-- ScreenGui replicates, which can be before the server has built this player's quest
-- state, and a report that arrives then is dropped. A one-shot send would strand the
-- player on a step whose fact was already true -- toggling the control off and on again
-- would not even retry, because the fact never changed. So a fact is re-asserted whenever
-- the tracked step is the one waiting for it.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Attrs = require(ReplicatedStorage.Shared.Attrs)

local QuestProgressObservations = {}

local STATS_EYE_TOGGLE = "StatsEyeToggle"
local STATS_EYE_ATTRIBUTE = "StatsLocked"

function QuestProgressObservations.bind(screenGui, report)
	local connections = {}
	local isTrue = {}
	local awaiting = nil

	local function connect(signal, callback)
		table.insert(connections, signal:Connect(callback))
	end

	local function setTruth(key, value)
		value = value == true
		local changed = isTrue[key] ~= value
		isTrue[key] = value
		-- Report on the rising edge, so acting early still banks the fact, and re-report
		-- while this is the step being waited on, so a dropped report recovers.
		if value and (changed or awaiting == key) then
			report(key)
		end
	end

	local function watchStatsEye(toggle)
		local function check()
			setTruth("StatsEyeEnabled", toggle:GetAttribute(STATS_EYE_ATTRIBUTE))
		end
		connect(toggle:GetAttributeChangedSignal(STATS_EYE_ATTRIBUTE), check)
		check()
	end

	local existing = screenGui:FindFirstChild(STATS_EYE_TOGGLE, true)
	if existing then
		watchStatsEye(existing)
	else
		-- The toggle is Studio-authored deep inside the store; bind late rather than
		-- assuming it is present the frame this controller starts.
		local pending
		pending = screenGui.DescendantAdded:Connect(function(descendant)
			if descendant.Name == STATS_EYE_TOGGLE then
				pending:Disconnect()
				watchStatsEye(descendant)
			end
		end)
		table.insert(connections, pending)
	end

	local function checkBuildView()
		setTruth("BuildViewOpened", screenGui:GetAttribute(Attrs.BuildModeActive))
	end
	connect(screenGui:GetAttributeChangedSignal(Attrs.BuildModeActive), checkBuildView)
	checkBuildView()

	return {
		-- Called with the observation key the tracked step is waiting for, or nil.
		setAwaiting = function(key)
			if awaiting == key then
				return
			end
			awaiting = key
			if key and isTrue[key] then
				report(key)
			end
		end,
		destroy = function()
			for _, connection in ipairs(connections) do
				connection:Disconnect()
			end
			table.clear(connections)
		end,
	}
end

return QuestProgressObservations
