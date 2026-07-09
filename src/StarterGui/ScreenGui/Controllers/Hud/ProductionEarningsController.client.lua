local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local shared = ReplicatedStorage:WaitForChild("Shared")
local NumberFormat = require(shared:WaitForChild("NumberFormat"))
local Net = require(shared:WaitForChild("Net"))

local TWEEN_INFO = TweenInfo.new(2, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)

local function getBuildingRootPart(building)
	if typeof(building) ~= "Instance" or not building:IsA("Model") then
		return nil
	end

	local main = building:FindFirstChild("Main", true)
	if main and main:IsA("BasePart") then
		return main
	end

	return building:FindFirstChildWhichIsA("BasePart", true)
end

local function renderEarnings(building, amount)
	if type(amount) ~= "number" or amount == 0 then
		return
	end

	local part = getBuildingRootPart(building)
	if not part then
		return
	end

	local billboard = Instance.new("BillboardGui")
	billboard.Name = "CookieEarnings"
	billboard.AlwaysOnTop = true
	billboard.Size = UDim2.new(5, 0, 5, 0)
	billboard.StudsOffset = Vector3.new(math.random(-2, 2), 4, math.random(-2, 2))
	billboard.Adornee = part
	billboard.Parent = part

	local label = Instance.new("TextLabel")
	label.BackgroundTransparency = 1
	label.Size = UDim2.fromScale(1, 1)
	label.Font = Enum.Font.ArialBold
	label.TextSize = 18
	label.TextScaled = false
	label.TextStrokeTransparency = 1
	label.TextColor3 = Color3.fromRGB(35, 170, 70)
	label.Text = (amount > 0 and "+" or "") .. NumberFormat.abbreviate(amount)
	label.Parent = billboard

	local tween = TweenService:Create(billboard, TWEEN_INFO, {
		StudsOffset = billboard.StudsOffset + Vector3.new(0, 2.4, 0),
	})
	local labelTween = TweenService:Create(label, TWEEN_INFO, {
		TextTransparency = 1,
	})

	tween:Play()
	labelTween:Play()
	tween.Completed:Connect(function()
		billboard:Destroy()
	end)
end

Net.on(Net.Names.ProductionEarnings, function(payload)
	if type(payload) ~= "table" then
		return
	end

	for _, entry in ipairs(payload) do
		if type(entry) == "table" then
			renderEarnings(entry.Building, entry.Amount)
		end
	end
end)
