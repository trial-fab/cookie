-- Client bridge between the SettingsController-owned ScreenGui attributes and the server-owned
-- Player attributes. Bind this only after SettingsController has seeded its device-aware defaults:
-- initialization must not turn an implicit mobile/desktop default into a saved preference.
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Attrs = require(Shared:WaitForChild("Attrs"))
local Net = require(Shared:WaitForChild("Net"))
local SettingsConfig = require(Shared:WaitForChild("SettingsConfig"))

local SettingsPersistence = {}

function SettingsPersistence.new(screenGui)
	local player = Players.LocalPlayer
	local applyingServerState = false
	local hydrated = false
	local pending = {}

	local function applyPlayerValue(attribute)
		local value = player:GetAttribute(attribute)
		if type(value) ~= "boolean" or screenGui:GetAttribute(attribute) == value then
			return
		end

		applyingServerState = true
		screenGui:SetAttribute(attribute, value)
		applyingServerState = false
	end

	local function send(attribute, value)
		Net.fireServer(Net.Names.UpdateSetting, attribute, value)
	end

	for _, attribute in ipairs(SettingsConfig.Attributes) do
		screenGui:GetAttributeChangedSignal(attribute):Connect(function()
			if applyingServerState then
				return
			end
			local value = screenGui:GetAttribute(attribute)
			if type(value) ~= "boolean" then
				return
			end
			if hydrated then
				send(attribute, value)
			else
				-- A player can interact while their DataStore load is still yielding. Preserve that
				-- explicit choice and send it after hydration instead of overwriting it with the save.
				pending[attribute] = value
			end
		end)

		player:GetAttributeChangedSignal(attribute):Connect(function()
			if hydrated and pending[attribute] == nil then
				applyPlayerValue(attribute)
			end
		end)
	end

	local function hydrate()
		if hydrated or player:GetAttribute(Attrs.SettingsLoaded) ~= true then
			return
		end

		for _, attribute in ipairs(SettingsConfig.Attributes) do
			if pending[attribute] == nil then
				applyPlayerValue(attribute)
			end
		end
		hydrated = true

		for attribute, value in pairs(pending) do
			send(attribute, value)
		end
		table.clear(pending)
	end

	player:GetAttributeChangedSignal(Attrs.SettingsLoaded):Connect(hydrate)
	hydrate()
end

return SettingsPersistence
