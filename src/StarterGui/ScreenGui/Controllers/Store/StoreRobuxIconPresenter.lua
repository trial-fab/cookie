-- StoreRobuxIconPresenter: binds baked Robux card art and gradients to Studio-authored layers.
-- ProductIcon is the foreground image. The VIP card additionally expects a sibling ImageLabel
-- named VipAvatar, cloned from ProfileModal's Avatar as a persistent Studio exemplar.

local Players = game:GetService("Players")
local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")

local Config = require(Shared:WaitForChild("StoreRobuxIconConfig"))
local UiGradientAnimator = require(Shared:WaitForChild("UiGradientAnimator"))

local StoreRobuxIconPresenter = {}

local CENTER = UDim2.fromScale(0.5, 0.5)
local CENTER_ANCHOR = Vector2.new(0.5, 0.5)

local function makeVipNameSequence(topLeft, bottomRight)
	return ColorSequence.new({
		ColorSequenceKeypoint.new(0, topLeft),
		ColorSequenceKeypoint.new(1 / 6, bottomRight),
		ColorSequenceKeypoint.new(2 / 6, topLeft),
		ColorSequenceKeypoint.new(3 / 6, bottomRight),
		ColorSequenceKeypoint.new(4 / 6, topLeft),
		ColorSequenceKeypoint.new(5 / 6, bottomRight),
		ColorSequenceKeypoint.new(1, topLeft),
	})
end

local function findImage(row, name)
	local image = row:FindFirstChild(name, true)
	if image and (image:IsA("ImageLabel") or image:IsA("ImageButton")) then
		return image
	end
	return nil
end

local function findGradient(row, name)
	local gradient = row:FindFirstChild(name, true)
	if gradient and gradient:IsA("UIGradient") then
		return gradient
	end
	return nil
end

function StoreRobuxIconPresenter.new()
	local M = {}
	local boundRows = {}
	local gradientAnimations = {}
	local active = false
	local warnedMissingVipAvatar = false

	local function updateGradientAnimation(gradient, enabled, mode, duration, options)
		gradient.Enabled = enabled
		local handle = gradientAnimations[gradient]
		if not enabled and not handle then
			return
		end

		if not handle then
			local animatorOptions = {}
			for key, value in pairs(options or {}) do
				animatorOptions[key] = value
			end
			animatorOptions.mode = mode
			animatorOptions.duration = duration
			handle = UiGradientAnimator.new(gradient, animatorOptions)
			gradientAnimations[gradient] = handle
		end
		handle.setDuration(duration)
		handle.setActive(enabled)
	end

	local function stopGradientAnimation(gradient)
		local handle = gradientAnimations[gradient]
		if handle then
			handle.setActive(false)
		end
		gradient.Enabled = false
	end

	local function setCenteredSize(image, width, height)
		image.AnchorPoint = CENTER_ANCHOR
		image.Position = CENTER
		image.Size = UDim2.fromOffset(width, height)
	end

	local function apply(row, itemId)
		if not (row and row.Parent) then
			boundRows[row] = nil
			return
		end

		local productIcon = findImage(row, "ProductIcon") or findImage(row, "Icon")
		if not productIcon then
			return
		end

		local sunburst = findImage(row, Config.SunburstName)
		if sunburst then
			sunburst.Image = Config.SunburstImage
			sunburst.Visible = Config.SunburstImage ~= ""
			setCenteredSize(sunburst, Config.SunburstWidth, Config.SunburstHeight)

			local sunburstGradient = findGradient(sunburst, Config.SunburstGradientName)
			if sunburstGradient then
				if itemId == Config.StarterPackItemId then
					updateGradientAnimation(
						sunburstGradient,
						active,
						UiGradientAnimator.Mode.Rotate,
						Config.StarterPackSunburstRainbowSeconds
					)
				elseif itemId == Config.VipItemId then
					stopGradientAnimation(sunburstGradient)
					sunburstGradient.Color = ColorSequence.new({
						ColorSequenceKeypoint.new(0, Config.VipGradientTopLeft),
						ColorSequenceKeypoint.new(1, Config.VipGradientBottomRight),
					})
					sunburstGradient.Rotation = Config.VipSunburstGradientRotation
					sunburstGradient.Offset = Vector2.zero
					sunburstGradient.Enabled = active
				else
					stopGradientAnimation(sunburstGradient)
				end
			end
		end

		local nameGradient = findGradient(row, Config.ProductNameGradientName)
		if nameGradient then
			local animateName = itemId == Config.StarterPackItemId
			if itemId == Config.VipItemId then
				nameGradient.Color = makeVipNameSequence(Config.VipGradientTopLeft, Config.VipGradientBottomRight)
				animateName = Config.VipNameGradientEnabled
			end

			if animateName then
				updateGradientAnimation(
					nameGradient,
					active,
					UiGradientAnimator.Mode.Horizontal,
					Config.ProductNameGradientSeconds,
					{
						startOffset = Vector2.new(-Config.ProductNameGradientTravel, 0),
						endOffset = Vector2.new(Config.ProductNameGradientTravel, 0),
					}
				)
			else
				stopGradientAnimation(nameGradient)
			end
		end

		local vipAvatar = findImage(row, Config.VipAvatarName)
		if vipAvatar then
			vipAvatar.Visible = false
		end

		if itemId == Config.StarterPackItemId then
			productIcon.Image = Config.StarterPackImage
			productIcon.Visible = true
			setCenteredSize(productIcon, Config.StarterPackWidth, Config.StarterPackHeight)
		elseif itemId == Config.VipItemId then
			productIcon.Image = Config.VipOutlineImage
			productIcon.Visible = true
			setCenteredSize(productIcon, Config.VipOutlineWidth, Config.VipOutlineHeight)

			if vipAvatar then
				vipAvatar.Image = ("rbxthumb://type=AvatarHeadShot&id=%d&w=150&h=150"):format(
					Players.LocalPlayer.UserId
				)
				vipAvatar.Visible = true
				setCenteredSize(vipAvatar, Config.VipAvatarWidth, Config.VipAvatarHeight)
			elseif not warnedMissingVipAvatar then
				warn(
					("Robux VIP card is missing Studio-authored %s ImageLabel; the outline will render without the player headshot."):format(
						Config.VipAvatarName
					)
				)
				warnedMissingVipAvatar = true
			end
		end
	end

	local function refreshAll()
		for row, itemId in pairs(boundRows) do
			apply(row, itemId)
		end
	end

	function M.bind(row, item)
		local itemId = item and item.Id
		boundRows[row] = itemId
		apply(row, itemId)
	end

	function M.setActive(value)
		active = value == true
		refreshAll()
	end

	return M
end

return StoreRobuxIconPresenter
