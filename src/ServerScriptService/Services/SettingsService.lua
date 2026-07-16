-- Server-authoritative persistence bridge for the game's player-controlled boolean preferences.
-- PlayerDataService owns storage; this service validates client updates and mirrors loaded values
-- onto Player attributes so the owning client can hydrate its ScreenGui.
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Attrs = require(ReplicatedStorage.Shared.Attrs)
local Net = require(ReplicatedStorage.Shared.Net)
local SettingsConfig = require(ReplicatedStorage.Shared.SettingsConfig)

local SettingsService = {}

function SettingsService.SetupPlayer(player, persistent)
	persistent = type(persistent) == "table" and persistent or {}
	local settings = type(persistent.Settings) == "table" and persistent.Settings or {}

	for _, attribute in ipairs(SettingsConfig.StoredAttributes) do
		local value = settings[attribute]
		if type(value) == "boolean" then
			player:SetAttribute(attribute, value)
		else
			player:SetAttribute(attribute, nil)
		end
	end
	player:SetAttribute(Attrs.SettingsLoaded, true)
end

function SettingsService.Init()
	Net.on(Net.Names.UpdateSetting, function(player, attribute, value, deviceType)
		if player:GetAttribute(Attrs.SettingsLoaded) ~= true then
			return
		end
		if attribute == SettingsConfig.ResetAllCommand then
			-- For a reset, `value` carries the current device type so the other device's two
			-- preferences survive. Universal preferences are always cleared.
			if not SettingsConfig.IsValidDeviceType(value) then
				return
			end
			for _, persistedAttribute in ipairs(SettingsConfig.UniversalAttributes) do
				player:SetAttribute(persistedAttribute, nil)
			end
			for _, deviceAttribute in ipairs(SettingsConfig.DeviceAttributes) do
				local storageAttribute = SettingsConfig.GetStorageAttribute(deviceAttribute, value)
				if storageAttribute then
					player:SetAttribute(storageAttribute, nil)
				end
			end
			return
		end
		if not SettingsConfig.IsPersisted(attribute) or type(value) ~= "boolean" then
			return
		end

		local storageAttribute = SettingsConfig.GetStorageAttribute(attribute, deviceType)
		if not storageAttribute then
			return
		end
		player:SetAttribute(storageAttribute, value)
	end)

	print("SettingsService initialized")
end

return SettingsService
