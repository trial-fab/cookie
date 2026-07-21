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
local DevTuning = require(shared:WaitForChild("DevTuning"):WaitForChild("DevTuning"))
local NumberFormat = require(shared:WaitForChild("NumberFormat"))
local Net = require(shared:WaitForChild("Net"))

local TUNING_PREFIX = "GoldenCookieToast."

local function getTuning(key)
	return DevTuning.get(TUNING_PREFIX .. key)
end

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
-- The persistent root is a layout container, not the hidden exemplar. Older Studio state left
-- both hidden, which made every correctly-visible clone disappear through its ancestor.
container.Visible = true

-- Fade out every text/image descendant (and the toast's own background, if any).
local function fade(toast, fadeTweenInfo)
	local function fadeOne(obj)
		if obj:IsA("TextLabel") or obj:IsA("TextButton") then
			UiMotion.create(obj, fadeTweenInfo, { TextTransparency = 1, TextStrokeTransparency = 1 }):Play()
		elseif obj:IsA("ImageLabel") or obj:IsA("ImageButton") then
			UiMotion.create(obj, fadeTweenInfo, { ImageTransparency = 1 }):Play()
		elseif obj:IsA("UIStroke") then
			UiMotion.create(obj, fadeTweenInfo, { Transparency = 1 }):Play()
		end
		if obj:IsA("GuiObject") and obj.BackgroundTransparency < 1 then
			UiMotion.create(obj, fadeTweenInfo, { BackgroundTransparency = 1 }):Play()
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
	local holdSeconds = getTuning("HoldSeconds")
	local riseSeconds = getTuning("RiseSeconds")
	local fadeSeconds = getTuning("FadeSeconds")
	local rise = UDim2.fromScale(0, getTuning("RiseDistanceScale"))
	local jitterScale = getTuning("HorizontalJitterScale")
	local riseTweenInfo = TweenInfo.new(riseSeconds, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
	local fadeTweenInfo = TweenInfo.new(fadeSeconds, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)

	local label = toast:FindFirstChild("Label", true)
	if label and label:IsA("TextLabel") then
		local formattedAmount = NumberFormat.abbreviate(amount)
		label.Text = string.gsub(getTuning("TextFormat"), "{amount}", function()
			return formattedAmount
		end)
		label.TextSize = getTuning("TextSize")
		label.TextColor3 = getTuning("TextColor")

		local stroke = label:FindFirstChildWhichIsA("UIStroke")
		if stroke then
			stroke.Thickness = getTuning("TextStrokeThickness")
			stroke.Color = getTuning("TextStrokeColor")
		end
	end

	local icon = toast:FindFirstChild("Icon", true)
	if icon and (icon:IsA("ImageLabel") or icon:IsA("ImageButton")) then
		local iconSize = getTuning("IconSize")
		icon.Visible = getTuning("ShowIcon")
		icon.Size = UDim2.fromOffset(iconSize, iconSize)
		icon.ImageColor3 = getTuning("IconColor")
	end

	-- small horizontal jitter so concurrent earns don't sit exactly on top of each other
	toast.Position = template.Position + UDim2.fromScale((math.random() * 2 - 1) * jitterScale, 0)
	toast.Visible = true
	toast.Parent = container

	UiMotion.create(toast, riseTweenInfo, { Position = toast.Position + rise }):Play()
	task.delay(holdSeconds, function()
		if toast and toast.Parent then
			fade(toast, fadeTweenInfo)
		end
	end)

	task.delay(math.max(riseSeconds, holdSeconds + fadeSeconds), function()
		if toast and toast.Parent then
			toast:Destroy()
		end
	end)
end

-- Previewing is entirely client-side: it neither grants GC nor fires the earn remote. The
-- observers also make every edit produce a fresh example while PreviewEnabled remains on.
local previewObservations = {}
local previewReady = false
local function showPreviewIfEnabled()
	if previewReady and getTuning("PreviewEnabled") then
		show(getTuning("PreviewAmount"))
	end
end

for _, feature in ipairs(DevTuning.getCatalog().features) do
	if feature.name == "GoldenCookieToast" then
		for _, definition in ipairs(feature.tunables) do
			table.insert(previewObservations, DevTuning.observe(definition.fullId, showPreviewIfEnabled))
		end
		break
	end
end
previewReady = true
showPreviewIfEnabled()

Net.on(Net.Names.GoldenCookieEarned, function(amount)
	show(amount)
end)
