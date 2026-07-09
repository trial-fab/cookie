-- StoreMultiPlace — the "Multi-Place" preference toggle.
-- Owning the Multi-Place upgrade lets the player drop several copies of a building in one
-- placement session; this module owns whether that mode is currently enabled. The preference
-- is mirrored onto both the player (persistent) and the ScreenGui (for other controllers to
-- read) via Attrs.MultiPlaceEnabled.
--
-- Extracted from StoreController's main chunk to keep it under Luau's 200-local cap. Per the
-- Store convention, the orchestrator calls these through `ctx.multiPlace.*` — it does NOT
-- re-alias them as top-level locals (that would spend the register budget the split freed).
--
-- ctx deps: player, screenGui, getOwnedCount.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Attrs = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Attrs"))

local UPGRADE_ID = "Multi-Place"

local StoreMultiPlace = {}

function StoreMultiPlace.new(ctx)
	local player = ctx.player
	local screenGui = ctx.screenGui
	local getOwnedCount = ctx.getOwnedCount

	local function isUpgradeId(upgradeId)
		return upgradeId == UPGRADE_ID
	end

	local function isOwned()
		return getOwnedCount(UPGRADE_ID) > 0
	end

	local function getPreference()
		local playerValue = player:GetAttribute(Attrs.MultiPlaceEnabled)
		if type(playerValue) == "boolean" then
			return playerValue
		end

		local guiValue = screenGui:GetAttribute(Attrs.MultiPlaceEnabled)
		if type(guiValue) == "boolean" then
			return guiValue
		end

		return nil
	end

	local function setPreference(enabled)
		enabled = enabled == true
		player:SetAttribute(Attrs.MultiPlaceEnabled, enabled)
		screenGui:SetAttribute(Attrs.MultiPlaceEnabled, enabled)
	end

	local function isEnabled()
		if not isOwned() then
			return false
		end

		local value = getPreference()
		if value == nil then
			return true
		end

		return value == true
	end

	local function setEnabled(enabled)
		if not isOwned() then
			screenGui:SetAttribute(Attrs.MultiPlaceEnabled, false)
			return
		end

		setPreference(enabled)
	end

	return {
		UPGRADE_ID = UPGRADE_ID,
		isUpgradeId = isUpgradeId,
		isOwned = isOwned,
		getPreference = getPreference,
		setPreference = setPreference,
		isEnabled = isEnabled,
		setEnabled = setEnabled,
	}
end

return StoreMultiPlace
