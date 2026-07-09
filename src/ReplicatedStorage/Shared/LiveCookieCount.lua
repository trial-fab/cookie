-- LiveCookieCount: reusable binding for the exact running cookie total pill.
--
-- The visual tree is Studio-authored. This module only updates the Amount label,
-- auto-fits the container width, and exposes the same shortage flash behavior used
-- by the store cost gate and the always-on bottom-right HUD.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TextService = game:GetService("TextService")
local TweenService = game:GetService("TweenService")

local NumberFormat = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("NumberFormat"))

local LiveCookieCount = {}

local WIDTH_TWEEN = TweenInfo.new(0.18, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local FLASH_TWEEN = TweenInfo.new(0.12, Enum.EasingStyle.Quad, Enum.EasingDirection.Out, 1, true)
local DEFAULT_TEXT_COLOR = Color3.fromRGB(255, 255, 255)
local SHORTAGE_TEXT_COLOR = Color3.fromRGB(255, 72, 72)

local function findAmountLabel(container)
	if not container then
		return nil
	end

	local amount = container:FindFirstChild("Amount", true)
	if amount and (amount:IsA("TextLabel") or amount:IsA("TextButton")) then
		return amount
	end

	return nil
end

function LiveCookieCount.bind(container, cookiesValue, options)
	options = type(options) == "table" and options or {}

	if not (container and container:IsA("GuiObject")) then
		return { flashShortage = function() end, refresh = function() end }
	end
	if not (cookiesValue and cookiesValue:IsA("ValueBase")) then
		return { flashShortage = function() end, refresh = function() end }
	end

	local amount = findAmountLabel(container)
	if not amount then
		return { flashShortage = function() end, refresh = function() end }
	end

	local font = options.font or Enum.Font.ArialBold
	local chromeWidth = tonumber(options.chromeWidth) or 44
	local baseColor = options.baseColor or amount.TextColor3 or DEFAULT_TEXT_COLOR
	local shortageColor = options.shortageColor or SHORTAGE_TEXT_COLOR
	local lastWidth

	local function refresh()
		amount.Text = NumberFormat.exact(cookiesValue.Value)

		local textWidth = TextService:GetTextSize(
			amount.Text,
			amount.TextSize,
			font,
			Vector2.new(math.huge, amount.TextSize)
		).X
		local targetWidth = math.ceil(textWidth) + chromeWidth
		if targetWidth ~= lastWidth then
			lastWidth = targetWidth
			TweenService:Create(container, WIDTH_TWEEN, {
				Size = UDim2.new(0, targetWidth, container.Size.Y.Scale, container.Size.Y.Offset),
			}):Play()
		end
	end

	-- Flash the number red, then settle back to baseColor. Spam taps must not stack: each
	-- flash cancels the in-flight tween and re-anchors the colour to baseColor first. Otherwise
	-- FLASH_TWEEN (reverses = true) "returns" to whatever half-red colour it was interrupted at,
	-- and repeated taps ratchet the number permanently red — the reported lock.
	local activeFlashTween = nil
	local function flashShortage()
		if activeFlashTween then
			activeFlashTween:Cancel()
			activeFlashTween = nil
		end

		amount.TextColor3 = baseColor
		local tween = TweenService:Create(amount, FLASH_TWEEN, { TextColor3 = shortageColor })
		activeFlashTween = tween
		tween:Play()
		tween.Completed:Connect(function()
			if activeFlashTween ~= tween then
				return
			end

			activeFlashTween = nil
			if amount and amount.Parent then
				amount.TextColor3 = baseColor
			end
		end)
	end

	amount.TextColor3 = baseColor
	refresh()
	local connection = cookiesValue:GetPropertyChangedSignal("Value"):Connect(refresh)

	return {
		refresh = refresh,
		flashShortage = flashShortage,
		disconnect = function()
			connection:Disconnect()
		end,
	}
end

return LiveCookieCount
