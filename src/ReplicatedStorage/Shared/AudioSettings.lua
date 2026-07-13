-- AudioSettings -- the only runtime entry point for settings-controlled audio.
--
-- Future code-owned audio should call playMusic/playSfx instead of Sound:Play().
-- Studio-authored or self-playing Sounds can instead be tagged ClickGameMusic /
-- ClickGameSoundEffect, or given AudioCategory = "Music" / "SoundEffect". The
-- AudioSettingsController assigns those Sounds to the same two SoundGroups.

local SoundService = game:GetService("SoundService")

local AudioSettings = {}

AudioSettings.Category = {
	Music = "Music",
	SoundEffect = "SoundEffect",
}

AudioSettings.Tag = {
	Music = "ClickGameMusic",
	SoundEffect = "ClickGameSoundEffect",
}

local GROUP_NAMES = {
	[AudioSettings.Category.Music] = "ClickGameMusic",
	[AudioSettings.Category.SoundEffect] = "ClickGameSoundEffects",
}

local function getGroup(category)
	local name = GROUP_NAMES[category]
	if not name then
		return nil
	end

	local existing = SoundService:FindFirstChild(name)
	if existing and existing:IsA("SoundGroup") then
		return existing
	end

	local group = Instance.new("SoundGroup")
	group.Name = name
	group.Volume = 1
	group.Parent = SoundService
	return group
end

function AudioSettings.getGroup(category)
	return getGroup(category)
end

function AudioSettings.register(sound, category)
	if not (sound and sound:IsA("Sound")) then
		return sound
	end

	local group = getGroup(category)
	if group then
		sound.SoundGroup = group
	end
	return sound
end

function AudioSettings.play(sound, category)
	AudioSettings.register(sound, category)
	if sound and sound:IsA("Sound") then
		sound:Play()
	end
	return sound
end

function AudioSettings.playMusic(sound)
	return AudioSettings.play(sound, AudioSettings.Category.Music)
end

function AudioSettings.playSfx(sound)
	return AudioSettings.play(sound, AudioSettings.Category.SoundEffect)
end

function AudioSettings.setCategoryEnabled(category, enabled)
	local group = getGroup(category)
	if group then
		group.Volume = enabled == false and 0 or 1
	end
end

return AudioSettings
