-- Shared ownership-gate interpretation for server validation and Store visibility.
local UpgradeRequirement = {}

function UpgradeRequirement.GetRequiredId(requirement)
	if type(requirement) ~= "table" then
		return nil
	end

	local requiredId = requirement.Upgrade or requirement.Building or requirement.TargetBuilding
	return type(requiredId) == "string" and requiredId or nil
end

function UpgradeRequirement.GetRequiredCount(requirement)
	if type(requirement) ~= "table" then
		return 0
	end

	return math.max(0, math.floor(tonumber(requirement.Count) or 1))
end

function UpgradeRequirement.IsMet(requirement, getOwnedCount)
	local requiredId = UpgradeRequirement.GetRequiredId(requirement)
	local requiredCount = UpgradeRequirement.GetRequiredCount(requirement)
	if not requiredId or requiredCount <= 0 then
		return true
	end

	return math.max(0, tonumber(getOwnedCount(requiredId)) or 0) >= requiredCount
end

function UpgradeRequirement.ShouldShowInStore(upgradeId, config, getOwnedCount)
	if
		type(config) == "table"
		and config.HideWhenOwned == true
		and math.max(0, tonumber(getOwnedCount(upgradeId)) or 0) > (config.InitialCount or 0)
	then
		return false
	end

	local requirement = type(config) == "table" and config.UnlockRequirement or nil
	if type(requirement) ~= "table" or requirement.HideUntilOwned ~= true then
		return true
	end

	return UpgradeRequirement.IsMet(requirement, getOwnedCount)
end

return UpgradeRequirement
