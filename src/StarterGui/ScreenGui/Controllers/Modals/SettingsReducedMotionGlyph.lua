local ContentProvider = game:GetService("ContentProvider")
local UiMotion = require(game:GetService("ReplicatedStorage"):WaitForChild("Shared"):WaitForChild("UiMotion"))

local SettingsReducedMotionGlyph = {}

local PLAY_ROTATABLE = "rbxassetid://124626664950201"
local PLAY_UP = "rbxassetid://86482760047995"
local PLAY_DOWN = "rbxassetid://112691372867898"
local OFF_ROTATION = -90
local ON_ROTATION = 90
local WINDUP_ANGLE = 10
local OVERSHOOT_ANGLE = 10
local WINDUP_INFO = TweenInfo.new(0.12, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut)
local FLIP_INFO = TweenInfo.new(0.3, Enum.EasingStyle.Quart, Enum.EasingDirection.In)
local SETTLE_INFO = TweenInfo.new(0.14, Enum.EasingStyle.Quart, Enum.EasingDirection.Out)

function SettingsReducedMotionGlyph.new(body)
	local row = body:FindFirstChild("ReducedMotion", true) or body:FindFirstChild("Animations", true)
	local glyph = row and row:FindFirstChild("Glyph", true)
	if not (glyph and (glyph:IsA("ImageLabel") or glyph:IsA("ImageButton"))) then
		return {
			setEnabled = function() end,
		}
	end

	local activeTween
	local sequenceToken = 0
	local settledEnabled = false
	local assetsReady = false
	local pendingRest

	local function cancelTween()
		sequenceToken += 1
		if activeTween then
			activeTween:Cancel()
			activeTween = nil
		end
	end

	local function tweenTo(rotation, tweenInfo, token, onComplete)
		activeTween = UiMotion.create(glyph, tweenInfo, { Rotation = rotation })
		activeTween.Completed:Once(function(state)
			if token == sequenceToken and state == Enum.PlaybackState.Completed and glyph.Parent then
				onComplete()
			end
		end)
		activeTween:Play()
	end

	local function applyRestingImage(enabled, token)
		if token ~= sequenceToken or not glyph.Parent then
			return
		end
		activeTween = nil
		settledEnabled = enabled
		if not assetsReady then
			pendingRest = { enabled = enabled, token = token }
			return
		end

		pendingRest = nil
		glyph.Image = enabled and PLAY_DOWN or PLAY_UP
		glyph.Rotation = 0
	end

	task.spawn(function()
		pcall(function()
			ContentProvider:PreloadAsync({ PLAY_ROTATABLE, PLAY_UP, PLAY_DOWN })
		end)
		assetsReady = true
		if pendingRest then
			applyRestingImage(pendingRest.enabled, pendingRest.token)
		end
	end)

	local function setEnabled(enabled, animate)
		enabled = enabled == true
		local target = enabled and ON_ROTATION or OFF_ROTATION
		cancelTween()
		if not animate then
			applyRestingImage(enabled, sequenceToken)
			return
		end

		local token = sequenceToken
		pendingRest = nil
		if glyph.Image ~= PLAY_ROTATABLE then
			glyph.Image = PLAY_ROTATABLE
			glyph.Rotation = settledEnabled and ON_ROTATION or OFF_ROTATION
		end
		local direction = enabled and 1 or -1
		local windup = glyph.Rotation - direction * WINDUP_ANGLE
		local overshoot = target + direction * OVERSHOOT_ANGLE
		tweenTo(windup, WINDUP_INFO, token, function()
			tweenTo(overshoot, FLIP_INFO, token, function()
				tweenTo(target, SETTLE_INFO, token, function()
					applyRestingImage(enabled, token)
				end)
			end)
		end)
	end

	return {
		setEnabled = setEnabled,
	}
end

return SettingsReducedMotionGlyph
