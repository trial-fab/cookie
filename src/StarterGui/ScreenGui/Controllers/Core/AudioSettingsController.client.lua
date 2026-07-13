-- Binds the Settings audio preferences to two independent SoundGroups.
-- Tagged/attributed Sounds are routed automatically, including tagged clones.

local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Attrs = require(Shared:WaitForChild("Attrs"))
local AudioSettings = require(Shared:WaitForChild("AudioSettings"))

local screenGui = script:FindFirstAncestorOfClass("ScreenGui")
if not screenGui then
	return
end
if screenGui:GetAttribute("AudioSettingsControllerRunning") then
	return
end
screenGui:SetAttribute("AudioSettingsControllerRunning", true)

local function ensurePreference(attribute)
	if screenGui:GetAttribute(attribute) == nil then
		screenGui:SetAttribute(attribute, true)
	end
end

ensurePreference(Attrs.MusicEnabled)
ensurePreference(Attrs.SfxEnabled)

local function refreshVolumes()
	AudioSettings.setCategoryEnabled(
		AudioSettings.Category.Music,
		screenGui:GetAttribute(Attrs.MusicEnabled) ~= false
	)
	AudioSettings.setCategoryEnabled(
		AudioSettings.Category.SoundEffect,
		screenGui:GetAttribute(Attrs.SfxEnabled) ~= false
	)
end

local function registerTagged(tag, category)
	local function register(instance)
		AudioSettings.register(instance, category)
	end
	for _, instance in ipairs(CollectionService:GetTagged(tag)) do
		register(instance)
	end
	CollectionService:GetInstanceAddedSignal(tag):Connect(register)
end

registerTagged(AudioSettings.Tag.Music, AudioSettings.Category.Music)
registerTagged(AudioSettings.Tag.SoundEffect, AudioSettings.Category.SoundEffect)

local watchedSounds = setmetatable({}, { __mode = "k" })
local function registerAttributed(instance)
	if not instance:IsA("Sound") then
		return
	end
	local function refreshCategory()
		local category = instance:GetAttribute(Attrs.AudioCategory)
		if category == AudioSettings.Category.Music or category == AudioSettings.Category.SoundEffect then
			AudioSettings.register(instance, category)
		end
	end
	if not watchedSounds[instance] then
		watchedSounds[instance] = true
		instance:GetAttributeChangedSignal(Attrs.AudioCategory):Connect(refreshCategory)
	end
	refreshCategory()
end

-- Attribute routing is primarily a convenience for Sounds authored under SoundService.
-- Tags are preferred for Sounds inside templates elsewhere in the DataModel.
for _, instance in ipairs(game:GetDescendants()) do
	registerAttributed(instance)
end
game.DescendantAdded:Connect(registerAttributed)

screenGui:GetAttributeChangedSignal(Attrs.MusicEnabled):Connect(refreshVolumes)
screenGui:GetAttributeChangedSignal(Attrs.SfxEnabled):Connect(refreshVolumes)
refreshVolumes()
