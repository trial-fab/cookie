-- Closed non-economic client-observation vocabulary for the replacement.

local ALLOWED = table.freeze({
	StatsEyeEnabled = true,
	BuildViewOpened = true,
	UpgradeNudgeActivated = true,
	BoostShopApproached = true,
})

local UiObservations = {}

function UiObservations.IsAllowed(value)
	return ALLOWED[value] == true
end

function UiObservations.All()
	local result = {}
	for value in pairs(ALLOWED) do
		table.insert(result, value)
	end
	table.sort(result)
	return result
end

return table.freeze(UiObservations)
