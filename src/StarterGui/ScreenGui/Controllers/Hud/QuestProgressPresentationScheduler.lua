-- Roblox task adapter for declared timing profiles and safety timeouts. Pure tests
-- inject a manual scheduler instead and never load this module.

local QuestProgressPresentationScheduler = {}

function QuestProgressPresentationScheduler:After(seconds, callback)
	local active = true
	task.delay(math.max(0, tonumber(seconds) or 0), function()
		if active then
			active = false
			callback()
		end
	end)
	return function()
		active = false
	end
end

return QuestProgressPresentationScheduler
