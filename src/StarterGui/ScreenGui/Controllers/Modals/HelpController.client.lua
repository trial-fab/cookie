local screenGui = script:FindFirstAncestorOfClass("ScreenGui")

local GuiService = game:GetService("GuiService")
local UserInputService = game:GetService("UserInputService")
local ModalOutsideClose = require(script.Parent:WaitForChild("ModalOutsideClose"))
local ModalCoordinator = require(script.Parent:WaitForChild("ModalCoordinator"))
local ModalPageTransition = require(script.Parent:WaitForChild("ModalPageTransition"))
local ModalResponsiveLayout = require(script.Parent:WaitForChild("ModalResponsiveLayout"))
local shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local GuiNames = require(shared:WaitForChild("GuiNames"))
local IconButton = require(shared:WaitForChild("IconButton"))
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
local previousSelection = nil
local gamepadFocusOwned = false
local setHelpVisible

-- The modal's single UIScale is reserved for responsive layout, never open/close motion.
local function getResponsiveScale()
	local s = helpGui:FindFirstChild("AnimScale")
	if not s or not s:IsA("UIScale") then
		s = helpGui:FindFirstChildOfClass("UIScale")
		if not s then
			s = Instance.new("UIScale")
			s.Name = "AnimScale"
			s.Scale = 1
			s.Parent = helpGui
		end
	end
	return s
end
local responsiveLayout = ModalResponsiveLayout.bind({
	modal = helpGui,
	close = function()
		if setHelpVisible then
			setHelpVisible(false)
		end
	end,
})
local function restScale()
	return responsiveLayout.restScale()
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

-- Single-open coordination: only one main modal is open at a time.
local helpSlot = ModalCoordinator.register("Help", function()
	if helpVisible then
		setHelpVisible(false)
	end
end)

function setHelpVisible(value)
	local previousOwner = ModalCoordinator.current()
	local deferCompactClose = not value and responsiveLayout.isCompact() and previousOwner == "Help"
	helpVisible = value

	if value then
		helpSlot.open()
	elseif not deferCompactClose then
		helpSlot.close()
	end

	if activeTween then
		activeTween:Cancel()
		activeTween = nil
	end

	helpIcon.set(value, value and "CLOSE" or "HELP")

	local scale = getResponsiveScale()
	local rest = restScale()
	local restPosition = helpGui.Position
	scale.Scale = rest

	if value then
		showCurrentPage()
		helpGui.Visible = true
		if UserInputService.PreferredInput == Enum.PreferredInput.Gamepad then
			previousSelection = GuiService.SelectedObject
			gamepadFocusOwned = true
			task.defer(function()
				if helpVisible then
					GuiService.SelectedObject = pageForwardButton
				end
			end)
		end
		if responsiveLayout.isCompact() then
			activeTween = ModalPageTransition.openCompact(screenGui, helpGui, previousOwner, "Help")
		else
			local switched
			activeTween, switched = ModalPageTransition.open(screenGui, helpGui, previousOwner, "Help", restPosition)
			if not switched then
				activeTween = ModalPageTransition.openSession(scale, rest)
			end
		end
	else
		if gamepadFocusOwned then
			gamepadFocusOwned = false
			local restore = previousSelection
			previousSelection = nil
			if not (restore and restore.Parent and restore:IsA("GuiObject") and restore.Selectable) then
				restore = showHelpButton
			end
			task.defer(function()
				if restore and restore.Parent and restore:IsA("GuiObject") and restore.Selectable then
					GuiService.SelectedObject = restore
				end
			end)
		end
		local function finishClose()
			if not helpVisible then
				helpGui.Visible = false
			end
		end
		if responsiveLayout.isCompact() then
			if deferCompactClose then
				activeTween = ModalPageTransition.closeCompactAfterMenu(screenGui, function()
					helpSlot.close()
				end, finishClose)
			else
				activeTween = ModalPageTransition.closeCompact(
					screenGui,
					helpGui,
					"Help",
					ModalCoordinator.current(),
					finishClose
				)
			end
		else
			local switched
			activeTween, switched = ModalPageTransition.close(
				screenGui,
				helpGui,
				"Help",
				ModalCoordinator.current(),
				restPosition,
				finishClose
			)
			if not switched then
				activeTween = ModalPageTransition.closeSession(scale, rest, finishClose)
			end
		end
	end
end

responsiveLayout.bindViewport(getResponsiveScale, function()
	return activeTween
end)

rebuildPages()
showCurrentPage()
-- Initial state: hidden immediately
helpGui.Visible = false
helpIcon.set(false, "HELP")

if showHelpButton then
	showHelpButton.Activated:Connect(function()
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

pageForwardButton.Activated:Connect(function()
	currentPage += 1
	showCurrentPage()
end)

pageBackButton.Activated:Connect(function()
	currentPage -= 1
	showCurrentPage()
end)

UserInputService.InputBegan:Connect(function(input)
	if not helpVisible then
		return
	end

	local key = input.KeyCode
	if key == Enum.KeyCode.ButtonB or key == Enum.KeyCode.Escape then
		setHelpVisible(false)
	elseif key == Enum.KeyCode.Right or key == Enum.KeyCode.DPadRight or key == Enum.KeyCode.ButtonR1 then
		currentPage += 1
		showCurrentPage()
	elseif key == Enum.KeyCode.Left or key == Enum.KeyCode.DPadLeft or key == Enum.KeyCode.ButtonL1 then
		currentPage -= 1
		showCurrentPage()
	end
end)
