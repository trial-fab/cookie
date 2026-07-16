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

function SettingsPersistence.new(screenGui, deviceType)
	local player = Players.LocalPlayer
	local applyingServerState = false
	local hydrated = false
	local pending = {}
	local resetPending = false

	local function applyPlayerValue(attribute)
		local storageAttribute = SettingsConfig.GetStorageAttribute(attribute, deviceType)
		local value = storageAttribute and player:GetAttribute(storageAttribute)
		if type(value) ~= "boolean" or screenGui:GetAttribute(attribute) == value then
			return
		end

		applyingServerState = true
		screenGui:SetAttribute(attribute, value)
		applyingServerState = false
	end

	local function send(attribute, value)
		Net.fireServer(Net.Names.UpdateSetting, attribute, value, deviceType)
	end

	local function sendReset()
		-- Reset travels over the same ordered event as updates. The second argument carries the
		-- current device type because there is no boolean setting value for this action.
		Net.fireServer(Net.Names.UpdateSetting, SettingsConfig.ResetAllCommand, deviceType)
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

		local storageAttribute = SettingsConfig.GetStorageAttribute(attribute, deviceType)
		if storageAttribute then
			player:GetAttributeChangedSignal(storageAttribute):Connect(function()
				if hydrated and pending[attribute] == nil then
					applyPlayerValue(attribute)
				end
			end)
		end
	end

	local function hydrate()
		if hydrated or player:GetAttribute(Attrs.SettingsLoaded) ~= true then
			return
		end

		if not resetPending then
			for _, attribute in ipairs(SettingsConfig.Attributes) do
				if pending[attribute] == nil then
					applyPlayerValue(attribute)
				end
			end
		end
		hydrated = true

		if resetPending then
			sendReset()
			resetPending = false
		end
		for attribute, value in pairs(pending) do
			send(attribute, value)
		end
		table.clear(pending)
	end

	player:GetAttributeChangedSignal(Attrs.SettingsLoaded):Connect(hydrate)
	hydrate()

	local api = {}

	function api.resetToDefaults(getDefault)
		if type(getDefault) ~= "function" then
			return
		end

		applyingServerState = true
		for _, attribute in ipairs(SettingsConfig.Attributes) do
			screenGui:SetAttribute(attribute, getDefault(attribute))
		end
		applyingServerState = false
		table.clear(pending)

		if hydrated then
			sendReset()
		else
			resetPending = true
		end
	end

	return api
end

return SettingsPersistence
