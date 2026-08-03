-- Generic bridge from the pure queue to focused visual owners. It contains no
-- step IDs and creates no UI; Stage D/E supply renderer/guide/reward implementations.

local QuestProgressPresentationVisualAdapters = {}

local function asynchronous(owner, methodName, context, done)
	local method = owner and owner[methodName]
	if type(method) ~= "function" then
		return false
	end
	return method(context, done)
end

function QuestProgressPresentationVisualAdapters.new(config)
	config = config or {}
	local renderer = config.Renderer
	local guides = config.Guides
	local strike = config.Strike
	local rewards = config.Rewards
	local passive = config.Passive
	return {
		StopGuide = function(context, done)
			-- GuideKinds is a stateful owner: invoke its methods with the owner so
			-- active target cancellation and refresh state stay attached to it.
			if not (guides and type(guides.Stop) == "function") then
				done("unavailable")
				return false
			end
			return guides:Stop(context, done)
		end,
		RenderEvent = function(context)
			if renderer and type(renderer.RenderEvent) == "function" then
				renderer.RenderEvent(context)
			end
		end,
		Strike = function(context, done)
			return asynchronous(strike, "Play", context, done)
		end,
		RenderCurrent = function(context)
			-- Remove the overlay before swapping the copy. Both operations are
			-- synchronous, but this ordering also prevents a layout callback from
			-- observing a new instruction beneath the outgoing strike geometry.
			if strike and type(strike.Reset) == "function" then
				strike.Reset(context)
			end
			if renderer and type(renderer.RenderCurrent) == "function" then
				renderer.RenderCurrent(context)
			end
		end,
		StartGuide = function(context, done)
			if not (guides and type(guides.Start) == "function") then return false end
			return guides:Start(context, done)
		end,
		BeginCompletion = function(context)
			if renderer and type(renderer.BeginCompletion) == "function" then
				renderer.BeginCompletion(context)
			end
		end,
		EndCompletion = function(context)
			if renderer and type(renderer.EndCompletion) == "function" then
				renderer.EndCompletion(context)
			end
		end,
		PresentReward = function(context, done)
			return asynchronous(rewards, "Present", context, done)
		end,
		PresentPassive = function(context, done)
			return asynchronous(passive, "Present", context, done)
		end,
	}
end

return QuestProgressPresentationVisualAdapters
