-- PvpConfig — single master switch that pauses every PVP-facing feature for
-- launch (combat gear, defense buildings, the base shield, and the auto-equipped
-- StarterPack weapons). Nothing is deleted: config entries, templates, scripts
-- and saved player upgrade counts all stay intact, they're just not purchasable,
-- grantable or visible while paused.
--
-- To bring ALL PVP back in a future update, flip `Enabled` to true. No other
-- code change is required — every consumer reads this module.
local PvpConfig = {}

PvpConfig.Enabled = false

-- Upgrade IDs hidden while paused. Keys MUST match UpgradeConfig keys exactly.
-- Gravity Coil and Speed Coil are intentionally NOT listed (kept as movement/fun).
PvpConfig.PausedUpgrades = {
	-- Combat gear
	["Green Katana"] = true,
	["High Tech Pick Axe"] = true,
	["CPG - Cookie Powered Grenade"] = true,
	["Hot Potato"] = true,
	["Taco"] = true,
	["Health + 2"] = true,
	-- Defense buildings
	["Cookie Wall"] = true,
	["Cookie Stairs"] = true,
	["Cookie Incinerator"] = true,
	["Cookie Trap"] = true,
	["Spiked Wall"] = true,
	["Reinforced Deadly Wall"] = true,
}

-- StarterPack tools auto-given to every player on spawn; relocated out of
-- StarterPack while paused (see PvpService).
PvpConfig.PausedStarterTools = { "LinkedSword", "PickAxe" }

-- True when full PVP is live. When false, the PausedUpgrades/Shield/StarterPack
-- guards apply.
function PvpConfig.IsActive()
	return PvpConfig.Enabled == true
end

-- True when this specific upgrade is currently hidden/blocked.
function PvpConfig.IsUpgradePaused(upgradeId)
	return (not PvpConfig.Enabled) and PvpConfig.PausedUpgrades[upgradeId] == true
end

return PvpConfig
