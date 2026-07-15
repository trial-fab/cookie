-- Shared contract for player preferences that persist across sessions. Universal preferences use
-- their ScreenGui attribute name as the storage key. Placement Controls and Auto Build Mode use
-- separate PC/Mobile storage keys while keeping one logical ScreenGui attribute at runtime.
local Attrs = require(script.Parent.Attrs)

local SettingsConfig = {}

-- Sent through UpdateSetting so a reset stays ordered with any toggle changes the player makes
-- immediately afterward. This is an action name, not a persisted setting key.
SettingsConfig.ResetAllCommand = "__ResetAllSettings"

SettingsConfig.DeviceType = {
	PC = "PC",
	Mobile = "Mobile",
}

SettingsConfig.DeviceTypes = {
	SettingsConfig.DeviceType.PC,
	SettingsConfig.DeviceType.Mobile,
}

SettingsConfig.UniversalAttributes = {
	Attrs.ReducedMotionEnabled,
	Attrs.MusicEnabled,
	Attrs.SfxEnabled,
	Attrs.MultiPlaceEnabled,
	Attrs.UpgradeRemindersEnabled,
}

SettingsConfig.DeviceAttributes = {
	Attrs.PlacementControlsEnabled,
	Attrs.AutoBuildMode,
}

SettingsConfig.DeviceStorageAttributes = {
	[Attrs.PlacementControlsEnabled] = {
		[SettingsConfig.DeviceType.PC] = "PlacementControlsEnabled_PC",
		[SettingsConfig.DeviceType.Mobile] = "PlacementControlsEnabled_Mobile",
	},
	[Attrs.AutoBuildMode] = {
		[SettingsConfig.DeviceType.PC] = "AutoBuildMode_PC",
		[SettingsConfig.DeviceType.Mobile] = "AutoBuildMode_Mobile",
	},
}

-- Logical attributes observed on the ScreenGui.
SettingsConfig.Attributes = {
	Attrs.ReducedMotionEnabled,
	Attrs.MusicEnabled,
	Attrs.SfxEnabled,
	Attrs.PlacementControlsEnabled,
	Attrs.MultiPlaceEnabled,
	Attrs.UpgradeRemindersEnabled,
	Attrs.AutoBuildMode,
}

-- Physical keys mirrored onto the Player and written under Persistent.Settings.
SettingsConfig.StoredAttributes = {}
for _, attribute in ipairs(SettingsConfig.UniversalAttributes) do
	table.insert(SettingsConfig.StoredAttributes, attribute)
end
for _, attribute in ipairs(SettingsConfig.DeviceAttributes) do
	for _, deviceType in ipairs(SettingsConfig.DeviceTypes) do
		table.insert(SettingsConfig.StoredAttributes, SettingsConfig.DeviceStorageAttributes[attribute][deviceType])
	end
end

SettingsConfig.AttributeSet = {}
for _, attribute in ipairs(SettingsConfig.Attributes) do
	SettingsConfig.AttributeSet[attribute] = true
end

SettingsConfig.UniversalAttributeSet = {}
for _, attribute in ipairs(SettingsConfig.UniversalAttributes) do
	SettingsConfig.UniversalAttributeSet[attribute] = true
end

function SettingsConfig.IsPersisted(attribute)
	return type(attribute) == "string" and SettingsConfig.AttributeSet[attribute] == true
end

function SettingsConfig.IsDeviceSpecific(attribute)
	return type(attribute) == "string" and SettingsConfig.DeviceStorageAttributes[attribute] ~= nil
end

function SettingsConfig.IsValidDeviceType(deviceType)
	return deviceType == SettingsConfig.DeviceType.PC or deviceType == SettingsConfig.DeviceType.Mobile
end

function SettingsConfig.GetStorageAttribute(attribute, deviceType)
	if SettingsConfig.UniversalAttributeSet[attribute] then
		return attribute
	end
	local deviceStorage = SettingsConfig.DeviceStorageAttributes[attribute]
	return deviceStorage and deviceStorage[deviceType] or nil
end

function SettingsConfig.GetDeviceType(touchEnabled, mouseEnabled, studioPrefersTouch)
	if touchEnabled == true and (mouseEnabled ~= true or studioPrefersTouch == true) then
		return SettingsConfig.DeviceType.Mobile
	end
	return SettingsConfig.DeviceType.PC
end

return SettingsConfig
