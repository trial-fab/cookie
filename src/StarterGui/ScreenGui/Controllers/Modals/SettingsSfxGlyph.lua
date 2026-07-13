local ContentProvider = game:GetService("ContentProvider")

local SettingsSfxGlyph = {}

local FRAME_DURATION = 0.08
local SPEAKER_OFF = "rbxassetid://70713683594675"
local SPEAKER_ONE = "rbxassetid://76968638009907"
local SPEAKER_FULL = "rbxassetid://95322317886639"
local IMAGES = {
	SPEAKER_OFF,
	SPEAKER_ONE,
	SPEAKER_FULL,
}

function SettingsSfxGlyph.new(body)
	local row = body:FindFirstChild("Sfx", true)
	local glyph = row and row:FindFirstChild("Glyph", true)
	if not (glyph and (glyph:IsA("ImageLabel") or glyph:IsA("ImageButton"))) then
		return {
			setEnabled = function() end,
		}
	end

	task.spawn(function()
		pcall(function()
			ContentProvider:PreloadAsync(IMAGES)
		end)
	end)

	local token = 0
	glyph.Image = SPEAKER_OFF

	local function setEnabled(enabled, animate)
		enabled = enabled == true
		token += 1
		local currentToken = token
		local restingImage = enabled and SPEAKER_FULL or SPEAKER_OFF
		if not animate then
			glyph.Image = restingImage
			return
		end

		local sequence = enabled and { SPEAKER_ONE, SPEAKER_FULL } or { SPEAKER_FULL, SPEAKER_ONE, SPEAKER_OFF }
		task.spawn(function()
			for index, image in ipairs(sequence) do
				if token ~= currentToken or not glyph.Parent then
					return
				end
				glyph.Image = image
				if index < #sequence then
					task.wait(FRAME_DURATION)
				end
			end
		end)
	end

	return {
		setEnabled = setEnabled,
	}
end

return SettingsSfxGlyph
