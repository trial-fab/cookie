local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UiMotion = require(game:GetService("ReplicatedStorage"):WaitForChild("Shared"):WaitForChild("UiMotion"))

local Net = require(ReplicatedStorage.Shared.Net)

local RISE_DISTANCE = 10
local TWEEN_INFO = TweenInfo.new(1, Enum.EasingStyle.Linear, Enum.EasingDirection.Out)

local function renderIncrease(payload)
	if type(payload) ~= "table" then
		return
	end

	local cookiePart = payload.CookiePart
	if typeof(cookiePart) ~= "Instance" or not cookiePart:IsA("BasePart") or not cookiePart:IsDescendantOf(workspace) then
		return
	end

	local template = cookiePart:FindFirstChild("BillboardGui")
	if not template or not template:IsA("BillboardGui") then
		return
	end

	local startOffset = typeof(payload.StartOffset) == "Vector3" and payload.StartOffset or Vector3.zero
	local clone = template:Clone()
	clone.Name = "CookieIncrease"
	clone.Adornee = cookiePart
	clone.StudsOffset = startOffset
	clone.Enabled = true

	local countLabel = clone:FindFirstChild("Count", true)
	if countLabel and countLabel:IsA("TextLabel") then
		countLabel.Text = tostring(payload.Text or "")
		countLabel.TextTransparency = 0
		if typeof(payload.TextColor) == "Color3" then
			countLabel.TextColor3 = payload.TextColor
		end
	end

	clone.Parent = cookiePart

	local movementTween = UiMotion.create(clone, TWEEN_INFO, {
		StudsOffset = startOffset + Vector3.new(0, RISE_DISTANCE, 0),
	})
	local fadeTween
	if countLabel and countLabel:IsA("TextLabel") then
		fadeTween = UiMotion.create(countLabel, TWEEN_INFO, {
			TextTransparency = 1,
		})
	end

	movementTween:Play()
	if fadeTween then
		fadeTween:Play()
	end

	movementTween.Completed:Once(function()
		clone:Destroy()
	end)
end

Net.on(Net.Names.CookieIncrease, renderIncrease)
