local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")
local UiMotion = require(game:GetService("ReplicatedStorage"):WaitForChild("Shared"):WaitForChild("UiMotion"))

local Net = require(ReplicatedStorage.Shared.Net)

local RISE_DISTANCE = 10
local TWEEN_INFO = TweenInfo.new(1, Enum.EasingStyle.Linear, Enum.EasingDirection.Out)
-- CookieIncrease is broadcast to every client, and one plot's autoclicker alone fires it twice a
-- second. Each popup costs a BillboardGui clone plus two tweens, so an unculled loop pays that
-- for every plot on the map at once. Plots sit on a ring ~196 studs apart at their centres
-- (SheetService: 10 slots, R_INNER 251), so this keeps your own plot and its two immediate
-- neighbours and discards the rest before any instance is created.
local MAX_RENDER_DISTANCE = 200

local function renderIncrease(payload)
	if type(payload) ~= "table" then
		return
	end

	local cookiePart = payload.CookiePart
	if typeof(cookiePart) ~= "Instance" or not cookiePart:IsA("BasePart") or not cookiePart:IsDescendantOf(workspace) then
		return
	end

	-- Cheapest rejection first: distance before the child lookup, and both before the clone.
	local camera = Workspace.CurrentCamera
	if not camera or (camera.CFrame.Position - cookiePart.Position).Magnitude > MAX_RENDER_DISTANCE then
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
