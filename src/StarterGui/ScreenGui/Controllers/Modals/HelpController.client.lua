local screenGui = script:FindFirstAncestorOfClass("ScreenGui")

local TweenService = game:GetService("TweenService")
local ModalOutsideClose = require(script.Parent:WaitForChild("ModalOutsideClose"))
local ModalCoordinator = require(script.Parent:WaitForChild("ModalCoordinator"))
local shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local GuiNames = require(shared:WaitForChild("GuiNames"))
local IconButton = require(shared:WaitForChild("IconButton"))
local MobileScale = require(shared:WaitForChild("MobileScale"))
local scaleInfo = TweenInfo.new(0.18, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)

local helpGui = screenGui:WaitForChild(GuiNames.Help)
local menuPill = screenGui:FindFirstChild(GuiNames.MenuPill, true)

-- Recursive search so buttons are found whether they are direct children or inside MenuPill.
local function waitForDescendant(name)
	local found = screenGui:FindFirstChild(name, true)
	if found then return found end
	local deadline = tick() + 10
	repeat task.wait(0.05); found = screenGui:FindFirstChild(name, true)
	until found or tick() > deadline
	return found
end

local function findMenuControl(...)
	local names = { ... }
	for _, name in ipairs(names) do
		if menuPill then
			-- Recursive: the authored pill nests its button as MenuPill.MenuItemsClip.Help,
			-- so a shallow lookup misses it and the screenGui fallback below would wrongly
			-- match the ScreenGui.Help *modal* frame instead of the pill's help button.
			local child = menuPill:FindFirstChild(name, true)
			if child then
				return child
			end
		end
	end

	for _, name in ipairs(names) do
		local found = screenGui:FindFirstChild(name, true)
		if found then
			return found
		end
	end

	return nil
end

local resolvedHelpButton, showHelpContainer = IconButton.resolveButton(findMenuControl(GuiNames.ShowHelp, GuiNames.Help) or waitForDescendant(GuiNames.ShowHelp))
local helpIcon = IconButton.new(showHelpContainer, resolvedHelpButton, { imageAttrPrefix = "Help" })
local showHelpButton = helpIcon.button

local pagesContainer = helpGui:WaitForChild("Pages")
local pageNumberLabel = helpGui:WaitForChild("PageNumber")
local pageBackButton = helpGui:WaitForChild("PageBack")
local pageForwardButton = helpGui:WaitForChild("PageForwards")

local pages = {}
local pageCount = 0
local currentPage = 1
local helpVisible = false
local activeTween = nil

-- UIScale used for BOTH the pop-in/pop-out animation and the shared responsive scale
-- (Roblox honours only one UIScale per object).
local function getAnimScale()
	local s = helpGui:FindFirstChild("AnimScale")
	if not s or not s:IsA("UIScale") then
		s = Instance.new("UIScale")
		s.Name = "AnimScale"
		s.Scale = 1
		s.Parent = helpGui
	end
	return s
end
-- Resting scale: the shared continuous responsive factor (1 at 1080p, smaller on phones).
-- The open/close pop is expressed RELATIVE to this so the two compose on the single UIScale.
-- Captured once before the first resolveModal call (which rewrites helpGui.Size on mobile).
local designSize = Vector2.new(helpGui.Size.X.Offset, helpGui.Size.Y.Offset)
local function restScale()
	return MobileScale.resolveModal(helpGui, designSize)
end

local function rebuildPages()
	pages = {}
	pageCount = 0

	for _, page in ipairs(pagesContainer:GetChildren()) do
		local pageIndex = tonumber(page.Name)
		if pageIndex then
			pages[pageIndex] = page
			pageCount += 1
		end
	end
end

local function clampPage()
	if pageCount <= 0 then
		currentPage = 1
		return
	end

	if currentPage < 1 then
		currentPage = pageCount
	elseif currentPage > pageCount then
		currentPage = 1
	end
end

local function showCurrentPage()
	clampPage()

	for index, page in pairs(pages) do
		page.Visible = index == currentPage
	end

	pageNumberLabel.Text = tostring(currentPage) .. " / " .. tostring(pageCount)
end

-- Single-open coordination: only one of Help/Settings/Profile open at a time.
local setHelpVisible
local helpSlot = ModalCoordinator.register("Help", function()
	if helpVisible then
		setHelpVisible(false)
	end
end)

function setHelpVisible(value)
	helpVisible = value

	if value then
		helpSlot.open()
	else
		helpSlot.close()
	end

	if activeTween then
		activeTween:Cancel()
		activeTween = nil
	end

	helpIcon.set(value, value and "CLOSE" or "HELP")

	local scale = getAnimScale()

	if value then
		showCurrentPage()
		local rest = restScale()
		scale.Scale = rest * 0.92
		helpGui.Visible = true
		activeTween = TweenService:Create(scale, scaleInfo, { Scale = rest })
		activeTween:Play()
	else
		activeTween = TweenService:Create(scale, scaleInfo, { Scale = restScale() * 0.92 })
		activeTween.Completed:Once(function()
			helpGui.Visible = false
			scale.Scale = restScale()
		end)
		activeTween:Play()
	end
end

-- Keep the resting scale right across viewport/orientation changes. Skip while a pop tween
-- is mid-flight (it lands on restScale() itself) so we don't snap over the animation.
MobileScale.onViewportChanged(function()
	local rest = restScale() -- also re-lays out size + position for the current viewport
	-- Skip only while a pop is actually animating; a finished tween lingers non-nil and must not
	-- block live re-scaling when the window is resized.
	if activeTween and activeTween.PlaybackState == Enum.PlaybackState.Playing then return end
	getAnimScale().Scale = rest
end)

rebuildPages()
showCurrentPage()
-- Initial state: hidden immediately
helpGui.Visible = false
helpIcon.set(false, "HELP")

if showHelpButton then
	showHelpButton.MouseButton1Click:Connect(function()
		setHelpVisible(not helpVisible)
	end)
else
	warn("HelpController could not find ShowHelp button")
end

ModalOutsideClose.bind({
	modal = helpGui,
	isOpen = function()
		return helpVisible
	end,
	close = function()
		setHelpVisible(false)
	end,
	getIgnoreRoots = function()
		return { showHelpButton, showHelpContainer }
	end,
})

pageForwardButton.MouseButton1Click:Connect(function()
	currentPage += 1
	showCurrentPage()
end)

pageBackButton.MouseButton1Click:Connect(function()
	currentPage -= 1
	showCurrentPage()
end)
