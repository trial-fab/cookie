-- GoldenCookieToastController — surfaces golden-cookie earns as a brief "+N GC" toast.
--
-- The server (GoldenCookieService.AddGoldenCookies) fires GoldenCookieEarned on every earn
-- — click drops, map spawns, daily claims, spin refunds — but nothing consumed it, so earns
-- only showed up silently when the GC pill/profile next read the attribute. This listens to
-- that event and pops a small toast.
--
-- Logic only: the toast UI is authored in Studio (StarterGui.ScreenGui.GoldenCookieToast
-- with a Visible=false child "Template" holding a "Label" TextLabel, optional "Icon"). Each
-- earn clones the template, animates it upward while fading, then destroys it. Rapid earns get
-- a small horizontal jitter so they don't perfectly overlap (same idea as the in-world
-- CookieIncrease billboards).

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UiMotion = require(game:GetService("ReplicatedStorage"):WaitForChild("Shared"):WaitForChild("UiMotion"))

local shared = ReplicatedStorage:WaitForChild("Shared")
local NumberFormat = require(shared:WaitForChild("NumberFormat"))
local Net = require(shared:WaitForChild("Net"))

local screenGui = script:FindFirstAncestorOfClass("ScreenGui")
if not screenGui then
	warn("GoldenCookieToastController must be inside a ScreenGui")
	return
end
if screenGui:GetAttribute("GoldenCookieToastControllerRunning") then
	return
end
screenGui:SetAttribute("GoldenCookieToastControllerRunning", true)

local container = screenGui:WaitForChild("GoldenCookieToast", 10)
if not container then
	warn("GoldenCookieToastController disabled: ScreenGui.GoldenCookieToast was not found")
	return
end

local template = container:FindFirstChild("Template")
if not (template and template:IsA("GuiObject")) then
	warn("GoldenCookieToastController disabled: GoldenCookieToast is missing a Template GuiObject")
	return
end
template.Visible = false

local RISE_TIME = 1.4
local LIFETIME = 1.5
local RISE = UDim2.fromScale(0, -0.06)
local tweenInfo = TweenInfo.new(RISE_TIME, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)

-- Fade out every text/image descendant (and the toast's own background, if any).
local function fade(toast)
	local function fadeOne(obj)
		if obj:IsA("TextLabel") or obj:IsA("TextButton") then
			UiMotion.create(obj, tweenInfo, { TextTransparency = 1, TextStrokeTransparency = 1 }):Play()
		elseif obj:IsA("ImageLabel") or obj:IsA("ImageButton") then
			UiMotion.create(obj, tweenInfo, { ImageTransparency = 1 }):Play()
		end
		if obj:IsA("GuiObject") and obj.BackgroundTransparency < 1 then
			UiMotion.create(obj, tweenInfo, { BackgroundTransparency = 1 }):Play()
		end
	end
	fadeOne(toast)
	for _, d in ipairs(toast:GetDescendants()) do
		fadeOne(d)
	end
end

local function show(amount)
	amount = math.floor(tonumber(amount) or 0)
	if amount <= 0 then
		return
	end

	local toast = template:Clone()
	toast.Name = "Toast"

	local label = toast:FindFirstChild("Label", true)
	if label and label:IsA("TextLabel") then
		label.Text = "+" .. NumberFormat.abbreviate(amount) .. " GC"
	end

	-- small horizontal jitter so concurrent earns don't sit exactly on top of each other
	toast.Position = template.Position + UDim2.fromScale(math.random(-4, 4) / 100, 0)
	toast.Visible = true
	toast.Parent = container

	UiMotion.create(toast, tweenInfo, { Position = toast.Position + RISE }):Play()
	fade(toast)

	task.delay(LIFETIME, function()
		if toast and toast.Parent then
			toast:Destroy()
		end
	end)
end

Net.on(Net.Names.GoldenCookieEarned, function(amount)
	show(amount)
end)
