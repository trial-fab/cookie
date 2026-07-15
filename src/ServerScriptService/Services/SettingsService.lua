-- Server-authoritative persistence bridge for the Settings modal's boolean preferences.
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

	for _, attribute in ipairs(SettingsConfig.Attributes) do
		local value = settings[attribute]
		player:SetAttribute(attribute, type(value) == "boolean" and value or nil)
	end
	player:SetAttribute(Attrs.SettingsLoaded, true)
end

function SettingsService.Init()
	Net.on(Net.Names.UpdateSetting, function(player, attribute, value)
		if player:GetAttribute(Attrs.SettingsLoaded) ~= true then
			return
		end
		if not SettingsConfig.IsPersisted(attribute) or type(value) ~= "boolean" then
			return
		end

		player:SetAttribute(attribute, value)
	end)

	print("SettingsService initialized")
end

return SettingsService
