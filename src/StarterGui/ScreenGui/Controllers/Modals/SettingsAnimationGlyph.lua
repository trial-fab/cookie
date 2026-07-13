local ContentProvider = game:GetService("ContentProvider")

local SettingsAnimationGlyph = {}

local FRAME_DURATION = 0.2
local FULL_FRAME_HOLD = 2
local FRAMES = {
	"rbxassetid://134785365446336", -- Explosion-Start
	"rbxassetid://81655242613823", -- Explosion-Semi1
	"rbxassetid://139200004621471", -- Explosion-Semi2
	"rbxassetid://79561629479748", -- Explosion-Mid
	"rbxassetid://97330933293714", -- Explosion-Full
}
local FULL_FRAME = FRAMES[#FRAMES]

function SettingsAnimationGlyph.new(body)
	local row = body:FindFirstChild("ReducedMotion", true) or body:FindFirstChild("Animations", true)
	local glyph = row and row:FindFirstChild("Glyph", true)
	if not (glyph and (glyph:IsA("ImageLabel") or glyph:IsA("ImageButton"))) then
		return {
			setActive = function() end,
		}
	end

	task.spawn(function()
		pcall(function()
			ContentProvider:PreloadAsync(FRAMES)
		end)
	end)

	local active = false
	local token = 0
	glyph.Image = FULL_FRAME

	local function setActive(nextActive)
		nextActive = nextActive == true
		if active == nextActive then
			if not active then
				glyph.Image = FULL_FRAME
			end
			return
		end

		active = nextActive
		token += 1
		local currentToken = token
		glyph.Image = FULL_FRAME
		if not active then
			return
		end

		task.spawn(function()
			while active and token == currentToken and glyph.Parent do
				for index, image in ipairs(FRAMES) do
					if not active or token ~= currentToken or not glyph.Parent then
						return
					end
					glyph.Image = image
					task.wait(index == #FRAMES and FULL_FRAME_HOLD or FRAME_DURATION)
				end
			end
		end)
	end

	return {
		setActive = setActive,
	}
end

return SettingsAnimationGlyph
