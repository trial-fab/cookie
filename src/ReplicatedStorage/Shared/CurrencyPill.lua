-- CurrencyPill: content-sized exact-number binding for Studio-authored currency slots.
-- All measurements are authored/logical pixels. Ancestor UIScale changes therefore affect only
-- rendering, never the width target or an in-flight local Position/Size tween.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TextService = game:GetService("TextService")

local NumberFormat = require(ReplicatedStorage.Shared.NumberFormat)
local UiMotion = require(ReplicatedStorage.Shared.UiMotion)

local CurrencyPill = {}

local WIDTH_TWEEN = TweenInfo.new(0.18, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)

local function findAmount(container)
	local amount = container and container:FindFirstChild("Amount", true)
	return amount and (amount:IsA("TextLabel") or amount:IsA("TextButton")) and amount or nil
end

local function resolveLogicalWidth(object, rootScale)
	if not (object and object:IsA("GuiObject")) then
		return 0
	end
	if object.Size.X.Offset ~= 0 then
		return object.Size.X.Offset
	end
	return object.AbsoluteSize.X / math.max(tonumber(rootScale) or 1, 0.01)
end

local function findIcon(container, amount, preferred)
	if preferred and preferred:IsA("GuiObject") then
		return preferred
	end
	for _, child in ipairs(container:GetChildren()) do
		if child ~= amount and (child:IsA("ImageLabel") or child:IsA("ImageButton")) then
			return child
		end
	end
	return nil
end

local function getChromeWidth(container, amount, icon, rootScale)
	local width = resolveLogicalWidth(icon, rootScale)
	local layout = container:FindFirstChildOfClass("UIListLayout")
	if layout and icon then
		width += layout.Padding.Offset
	end
	local padding = container:FindFirstChildOfClass("UIPadding")
	if padding then
		width += padding.PaddingLeft.Offset + padding.PaddingRight.Offset
	end
	return math.max(0, width)
end

local function measureText(amount, text)
	local params = Instance.new("GetTextBoundsParams")
	params.Text = text
	params.Font = amount.FontFace
	params.Size = amount.TextSize
	params.Width = math.huge
	local ok, bounds = pcall(TextService.GetTextBoundsAsync, TextService, params)
	if ok and typeof(bounds) == "Vector2" then
		return bounds.X
	end
	return amount.TextBounds.X
end

function CurrencyPill.bind(container, options)
	options = type(options) == "table" and options or {}
	if not (container and container:IsA("GuiObject")) then
		return {
			setValue = function() end,
			getTargetWidth = function()
				return 0
			end,
			disconnect = function() end,
		}
	end

	local amount = findAmount(container)
	if not amount then
		return {
			setValue = function() end,
			getTargetWidth = function()
				return container.Size.X.Offset
			end,
			disconnect = function() end,
		}
	end

	local icon = findIcon(container, amount, options.icon)
	local widthTween
	local targetWidth = container.Size.X.Offset
	local generation = 0
	local disconnected = false

	-- Explicit Size owns the animated width. Parent rows may still use AutomaticSize.X around
	-- this pill, but the pill itself must not let AutomaticSize fight its tween.
	container.AutomaticSize = Enum.AutomaticSize.None

	local function currentRootScale()
		return type(options.getRootScale) == "function" and options.getRootScale() or 1
	end

	local function applyWidth(width, immediate)
		width = math.max(1, math.ceil(width))
		if targetWidth == width then
			return
		end
		targetWidth = width
		if widthTween then
			widthTween:Cancel()
			widthTween = nil
		end
		local targetSize = UDim2.new(0, width, container.Size.Y.Scale, container.Size.Y.Offset)
		if immediate == true or options.animateWidth == false then
			container.Size = targetSize
		else
			widthTween = UiMotion.create(container, options.widthTweenInfo or WIDTH_TWEEN, { Size = targetSize })
			widthTween:Play()
		end
		if type(options.onWidthChanged) == "function" then
			options.onWidthChanged(width, immediate == true)
		end
	end

	local function setValue(value, immediate)
		local text = NumberFormat.exact(math.max(0, math.floor(tonumber(value) or 0)))
		amount.Text = text
		generation += 1
		local thisGeneration = generation
		task.spawn(function()
			local textWidth = measureText(amount, text)
			if disconnected or generation ~= thisGeneration or amount.Text ~= text then
				return
			end
			applyWidth(textWidth + getChromeWidth(container, amount, icon, currentRootScale()), immediate)
		end)
	end

	return {
		setValue = setValue,
		getTargetWidth = function()
			return targetWidth
		end,
		getAmount = function()
			return amount
		end,
		getIcon = function()
			return icon
		end,
		disconnect = function()
			disconnected = true
			generation += 1
			if widthTween then
				widthTween:Cancel()
			end
		end,
	}
end

return CurrencyPill
