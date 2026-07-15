-- Shared contract for player preferences that persist across sessions. Values are stored under
-- Persistent.Settings using these attribute names as stable keys, mirrored onto the Player by
-- SettingsService, and copied onto the ScreenGui by SettingsPersistence.
local Attrs = require(script.Parent.Attrs)

local SettingsConfig = {}

SettingsConfig.Attributes = {
	Attrs.ReducedMotionEnabled,
	Attrs.MusicEnabled,
	Attrs.SfxEnabled,
	Attrs.PlacementControlsEnabled,
	Attrs.UpgradeRemindersEnabled,
	Attrs.AutoBuildMode,
}

SettingsConfig.AttributeSet = {}
for _, attribute in ipairs(SettingsConfig.Attributes) do
	SettingsConfig.AttributeSet[attribute] = true
end

function SettingsConfig.IsPersisted(attribute)
	return type(attribute) == "string" and SettingsConfig.AttributeSet[attribute] == true
end

return SettingsConfig
