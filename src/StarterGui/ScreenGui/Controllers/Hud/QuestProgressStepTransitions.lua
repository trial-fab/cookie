-- Owns the pacing between one tracked objective and the next.
--
-- Every step advance crosses out the objective the player just finished, holds it long
-- enough to read, and only then reveals the next one. This used to be a hardcoded list of
-- quest 1 step pairs, so every other quest changed its objective silently.
--
-- Two release rules exist:
--   * most steps hold for a fixed beat;
--   * a step whose completion is still being presented in the world holds until that
--     presentation reports itself finished, so the struck line and the presentation end
--     together instead of racing.

local QuestProgressStepTransitions = {}

local DEFAULT_HOLD_SECONDS = 2

-- Steps whose struck line waits on a presentation signal rather than a timer. The value is
-- the gate name the owner reports through gateOpened.
local GATED_STEPS = {
	unlock_mixer = "MixerUnlockPresented",
}

function QuestProgressStepTransitions.new(config)
	config = config or {}
	local onExpired = config.onExpired
	local isGateOpen = config.isGateOpen
	local holdSeconds = tonumber(config.holdSeconds) or DEFAULT_HOLD_SECONDS
	local held
	local generation = 0

	local function clear()
		if not held then
			return false
		end
		held = nil
		generation += 1
		return true
	end

	local function begin(previousQuest, nextQuest, description)
		generation += 1
		-- A gate that is already open cannot re-open, so fall back to the timed hold rather
		-- than waiting for a signal that will never arrive.
		local gate = GATED_STEPS[previousQuest.StepId]
		if gate and isGateOpen and isGateOpen(gate) then
			gate = nil
		end
		held = {
			QuestId = nextQuest.Id,
			StepId = previousQuest.StepId,
			TargetStepId = nextQuest.StepId,
			Description = description,
			-- The ring advances immediately; only the wording waits.
			Progress = nextQuest.Progress,
			Gate = gate,
		}
		if gate then
			return
		end

		local thisGeneration = generation
		task.delay(holdSeconds, function()
			if held and generation == thisGeneration then
				held = nil
				if onExpired then
					onExpired()
				end
			end
		end)
	end

	return {
		-- Called with the tracked quest before and after a snapshot. Returns the cue key to
		-- animate, or nil when this snapshot is not a step advance.
		observe = function(previousQuest, nextQuest, describeCompleted, alreadyStruck)
			if
				not (previousQuest and nextQuest)
				or previousQuest.Id ~= nextQuest.Id
				or previousQuest.StepId == nextQuest.StepId
				or previousQuest.Completed == true
				or nextQuest.Completed == true
			then
				return nil
			end
			-- A step that already struck in place has been sitting struck through its own
			-- world presentation -- the rubble morph, the healing celebration. Adding a timed
			-- hold on top of that makes the objective linger for roughly twice as long as
			-- every other step, so the next objective goes up straight away instead.
			if alreadyStruck and alreadyStruck(previousQuest.StepId) then
				return nil
			end
			begin(previousQuest, nextQuest, describeCompleted(previousQuest))
			return "step:" .. tostring(previousQuest.StepId)
		end,

		-- A step whose own instruction changed under the player -- the affordability line
		-- becoming a "now buy it" line. The half they just finished earns the same strike and
		-- hold a whole step gets, otherwise the wording swaps with nothing marking it done.
		holdWithinStep = function(previousQuest, nextQuest, description)
			begin(previousQuest, nextQuest, description)
			return "step:" .. tostring(previousQuest.StepId)
		end,

		-- Drop a hold the snapshot has moved past (quest switch, completion, or a step that
		-- advanced again before the hold expired). Returns true when something was dropped.
		reconcile = function(quest)
			if not held then
				return false
			end
			if
				not quest
				or quest.Id ~= held.QuestId
				or quest.Completed == true
				or quest.StepId ~= held.TargetStepId
			then
				return clear()
			end
			return false
		end,

		gateOpened = function(gate)
			if held and held.Gate == gate then
				return clear()
			end
			return false
		end,

		current = function()
			return held
		end,

		destroy = clear,
	}
end

return QuestProgressStepTransitions
