local screenGui = script:FindFirstAncestorOfClass("ScreenGui")
if not screenGui then
	warn("UiStyleController must be inside a ScreenGui")
	return
end
local shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local Attrs = require(shared:WaitForChild("Attrs"))
local GuiNames = require(shared:WaitForChild("GuiNames"))
local IconButton = require(shared:WaitForChild("IconButton"))
local StoreShell = require(shared:WaitForChild("StoreShell"))

local PANEL_COLOR = Color3.fromRGB(16, 18, 26)
local PANEL_ALT_COLOR = Color3.fromRGB(28, 32, 42)
local PANEL_SOFT_COLOR = Color3.fromRGB(36, 42, 54)
local TEXT_COLOR = Color3.fromRGB(244, 247, 252)
local MUTED_TEXT_COLOR = Color3.fromRGB(170, 178, 192)
local ACCENT_COLOR = Color3.fromRGB(0, 170, 255)
local ICON_BG = Color3.fromRGB(30, 32, 40)
local DANGER_COLOR = Color3.fromRGB(185, 54, 55)
local SHIELD_ON_COLOR = Color3.fromRGB(92, 200, 72)
local SHIELD_OFF_COLOR = Color3.fromRGB(118, 126, 142)
local WARNING_COLOR = Color3.fromRGB(236, 190, 96)

-- Studio-authored UI is the source of truth by default. Set RuntimeStyle=true
-- on ScreenGui only if you intentionally want this script to regenerate visual
-- layout/styling at runtime.
local runtimeStyle = screenGui:GetAttribute("RuntimeStyle") == true

local function ensureChild(parent, className, name)
	local child = parent:FindFirstChild(name)
	if child and child.ClassName == className then
		return child
	end

	if child then
		child:Destroy()
	end

	child = Instance.new(className)
	child.Name = name
	child.Parent = parent
	return child
end

local function setFont(textObject, bold)
	if not (textObject:IsA("TextLabel") or textObject:IsA("TextButton") or textObject:IsA("TextBox")) then
		return
	end

	textObject.Font = bold and Enum.Font.GothamBold or Enum.Font.Gotham
	textObject.TextColor3 = TEXT_COLOR
	textObject.TextStrokeTransparency = 1
	textObject.LineHeight = 1.08
end

local function styleSurface(guiObject, radius, color, transparency)
	guiObject.BackgroundColor3 = color
	guiObject.BackgroundTransparency = transparency
	guiObject.BorderSizePixel = 0

	local corner = ensureChild(guiObject, "UICorner", "ModernCorner")
	corner.CornerRadius = UDim.new(0, radius)

	local stroke = ensureChild(guiObject, "UIStroke", "ModernStroke")
	stroke.Color = Color3.fromRGB(255, 255, 255)
	stroke.Transparency = 0.86
	stroke.Thickness = 1
end

local function styleButton(button, color, radius)
	if not button or not button:IsA("GuiButton") then
		return
	end

	styleSurface(button, radius or 8, color, 0.08)
	button.AutoButtonColor = true
	if button:IsA("TextButton") then
		button.TextTransparency = 0
		button.TextSize = 15
		button.TextWrapped = false
		setFont(button, true)
	end
end

local function updateIconButton(button)
	if not button or not button:IsA("GuiButton") then
		return
	end

	local baseColor = button:GetAttribute("BaseColor") or ICON_BG
	local active = button:GetAttribute(Attrs.Active) == true
	local shieldState = button:GetAttribute("ShieldState")
	local backgroundColor = baseColor

	if shieldState ~= nil then
		backgroundColor = shieldState == true and SHIELD_ON_COLOR or SHIELD_OFF_COLOR
	elseif active then
		backgroundColor = ACCENT_COLOR
	end

	button.BackgroundColor3 = backgroundColor
	if button:IsA("TextButton") and not button:GetAttribute(Attrs.IconOnly) then
		button.TextColor3 = TEXT_COLOR
	end
end

local function prepareIconButton(button, icon, _baseColor)
	if not button or not button:IsA("GuiButton") then
		return
	end

	-- When already inside MenuPill, only wire attributes; pill controller owns visual styling.
	if button.Parent and button.Parent.Name == "MenuPill" then
		button:SetAttribute(Attrs.IconOnly, true)
		if not button:GetAttribute(Attrs.UiStyleWired) then
			button:SetAttribute(Attrs.UiStyleWired, true)
			button:GetAttributeChangedSignal(Attrs.Active):Connect(function()
				updateIconButton(button)
			end)
			button:GetAttributeChangedSignal("ShieldState"):Connect(function()
				updateIconButton(button)
			end)
		end
		return
	end

	button:SetAttribute(Attrs.IconOnly, true)
	button:SetAttribute("BaseColor", _baseColor or ICON_BG)
	button.AnchorPoint = Vector2.new(1, 0)
	button.Size = UDim2.fromOffset(44, 44)
	if button:IsA("TextButton") then
		button.Text = icon
		button.TextSize = 22
		button.TextWrapped = false
		button.TextScaled = false
	end
	button.ZIndex = 20
	styleButton(button, _baseColor or ICON_BG, 20)
	updateIconButton(button)

	local gridIcon = button:FindFirstChild("GridIcon")
	if icon == "grid" then
		if button:IsA("TextButton") then
			button.Text = ""
		end
		if not gridIcon then
			gridIcon = Instance.new("Frame")
			gridIcon.Name = "GridIcon"
			gridIcon.Parent = button
		end
		gridIcon.BackgroundTransparency = 1
		gridIcon.AnchorPoint = Vector2.new(0.5, 0.5)
		gridIcon.Position = UDim2.fromScale(0.5, 0.5)
		gridIcon.Size = UDim2.fromOffset(18, 18)
		gridIcon.ZIndex = button.ZIndex + 1
		for index = 1, 4 do
			local square = gridIcon:FindFirstChild("Square" .. index)
			if not square then
				square = Instance.new("Frame")
				square.Name = "Square" .. index
				square.Parent = gridIcon
			end
			square.Size = UDim2.fromOffset(7, 7)
			square.Position = UDim2.fromOffset(((index - 1) % 2) * 11, math.floor((index - 1) / 2) * 11)
			square.BackgroundColor3 = TEXT_COLOR
			square.BorderSizePixel = 0
			square.ZIndex = gridIcon.ZIndex + 1
			local corner = ensureChild(square, "UICorner", "Corner")
			corner.CornerRadius = UDim.new(0, 2)
		end
	elseif gridIcon then
		gridIcon:Destroy()
	end

	if not button:GetAttribute(Attrs.UiStyleWired) then
		button:SetAttribute(Attrs.UiStyleWired, true)
		button:GetAttributeChangedSignal(Attrs.Active):Connect(function()
			updateIconButton(button)
		end)
		button:GetAttributeChangedSignal("ShieldState"):Connect(function()
			updateIconButton(button)
		end)
	end
end

local function ensureTab(store, tabBar, name, text)
	local button = tabBar:FindFirstChild(name)
	if not button then
		button = Instance.new("TextButton")
		button.Name = name
		button.Parent = tabBar
	end

	button.Size = UDim2.new(1 / 3, -4, 1, 0)
	button.Text = text
	button.TextSize = 13
	button.TextWrapped = false
	button.TextScaled = false
	button.ZIndex = store.ZIndex + 2
	styleButton(button, PANEL_SOFT_COLOR, 8)

	-- Cyan bottom line for active tab
	local activeLine = ensureChild(button, "Frame", "ActiveLine")
	activeLine.Size = UDim2.new(1, 0, 0, 3)
	activeLine.Position = UDim2.new(0, 0, 1, -3)
	activeLine.BackgroundColor3 = ACCENT_COLOR
	activeLine.BorderSizePixel = 0
	activeLine.Visible = false
	activeLine.ZIndex = button.ZIndex + 2

	-- task.defer avoids race with StoreController's BackgroundTransparency assignment
	if not button:GetAttribute("TabStyleWired") then
		button:SetAttribute("TabStyleWired", true)
		button:GetAttributeChangedSignal(Attrs.Active):Connect(function()
			task.defer(function()
				if not button or not button.Parent then
					return
				end
				local isActive = button:GetAttribute(Attrs.Active) == true
				local line = button:FindFirstChild("ActiveLine")
				if line then
					line.Visible = isActive
				end
				button.BackgroundColor3 = isActive and PANEL_COLOR or PANEL_SOFT_COLOR
				button.BackgroundTransparency = isActive and 0.04 or 0.6
				button.TextTransparency = isActive and 0 or 0.25
			end)
		end)
	end

	return button
end

local function ensureStoreTabs(store)
	local tabBar = store:FindFirstChild("TabBar")
	local created = false
	if not tabBar then
		tabBar = Instance.new("Frame")
		tabBar.Name = "TabBar"
		tabBar.Position = UDim2.fromOffset(14, 58)
		tabBar.Size = UDim2.new(1, -28, 0, 38)
		tabBar.Parent = store
		created = true
	end

	tabBar.BackgroundTransparency = 1
	tabBar.ZIndex = math.max(tabBar.ZIndex, store.ZIndex + 2)

	if created then
		local layout = ensureChild(tabBar, "UIListLayout", "TabLayout")
		layout.FillDirection = Enum.FillDirection.Horizontal
		layout.SortOrder = Enum.SortOrder.LayoutOrder
		layout.Padding = UDim.new(0, 8)
	end

	local legacyGearTab = tabBar:FindFirstChild("GearTab")
	if legacyGearTab and not tabBar:FindFirstChild("RobuxTab") then
		legacyGearTab.Name = "RobuxTab"
	end

	local buildings = ensureTab(store, tabBar, "BuildingsTab", "▦  Buildings")
	local robux = ensureTab(store, tabBar, "RobuxTab", "R$  Robux")
	local upgrades = ensureTab(store, tabBar, "UpgradesTab", "⌁  Upgrades")
	buildings.LayoutOrder = 1
	robux.LayoutOrder = 2
	upgrades.LayoutOrder = 3

	return tabBar
end

local function styleStoreRow(row)
	if not row or not row:IsA("Frame") then
		return
	end

	local catch = row:FindFirstChild("Catch", true)
	if catch and catch:IsA("GuiButton") then
		catch.BackgroundTransparency = 1
		catch.TextTransparency = 1
		catch.BorderSizePixel = 0
		catch.ZIndex = row.ZIndex + 5
	end
end

local function styleStore(store)
	if not store then
		return
	end

	store.ClipsDescendants = true
	store.ZIndex = math.max(store.ZIndex, 8)
	styleSurface(store, 12, PANEL_COLOR, 0.06)

	local title = store:FindFirstChild("Title")
	if title and title:IsA("TextLabel") then
		title.Size = UDim2.new(1, 0, 0, 50)
		title.Position = UDim2.fromOffset(0, 0)
		title.TextSize = 20
		title.TextXAlignment = Enum.TextXAlignment.Center
		title.ZIndex = store.ZIndex + 1
		styleSurface(title, 12, PANEL_ALT_COLOR, 0.1)
		setFont(title, true)
	end

	ensureStoreTabs(store)

	local page = store:FindFirstChild("PageTemplate")
	if page and page:IsA("Frame") then
		page.BackgroundTransparency = 1
		page.ClipsDescendants = true
		page.ZIndex = store.ZIndex + 1
		page.ChildAdded:Connect(function(child)
			task.defer(styleStoreRow, child)
		end)
	end

	local tabBar = store:FindFirstChild("TabBar")
	if tabBar and tabBar:IsA("GuiObject") then
		tabBar.ZIndex = math.max(tabBar.ZIndex, store.ZIndex + 2)
	end

	local buttonBar = store:FindFirstChild("ButtonBar")
	if buttonBar and buttonBar:IsA("GuiObject") then
		buttonBar.ZIndex = math.max(buttonBar.ZIndex, store.ZIndex + 2)
	end

	for _, rowName in ipairs({ "Template", "TemplateUpgrade", "TemplateGearGiver", "TemplateRobuxProduct" }) do
		styleStoreRow(store:FindFirstChild(rowName))
	end

	if page then
		for _, child in ipairs(page:GetChildren()) do
			styleStoreRow(child)
		end
	end

	local back = store:FindFirstChild("PageBack")
	local nextButton = store:FindFirstChild("PageForwards")
	local pageId = store:FindFirstChild("PageId")
	local category = store:FindFirstChild("MoveUpgrade")

	if back and back:IsA("TextButton") then
		back.Size = UDim2.fromOffset(80, 36)
		back.Position = UDim2.new(0, 14, 1, -78)
		back.Text = "Prev"
		back.ZIndex = store.ZIndex + 2
		styleButton(back, PANEL_SOFT_COLOR, 8)
	end

	if nextButton and nextButton:IsA("TextButton") then
		nextButton.Size = UDim2.fromOffset(80, 36)
		nextButton.Position = UDim2.new(1, -94, 1, -78)
		nextButton.Text = "Next"
		nextButton.ZIndex = store.ZIndex + 2
		styleButton(nextButton, PANEL_SOFT_COLOR, 8)
	end

	if pageId and pageId:IsA("TextLabel") then
		pageId.Size = UDim2.new(1, -208, 0, 36)
		pageId.Position = UDim2.new(0, 104, 1, -78)
		pageId.TextSize = 13
		pageId.BackgroundTransparency = 1
		pageId.ZIndex = store.ZIndex + 2
		setFont(pageId, false)
	end

	if category and category:IsA("TextButton") then
		category.Size = UDim2.new(0.5, -22, 0, 38)
		category.Position = UDim2.new(0.5, 8, 1, -40)
		category.Visible = false
		category.ZIndex = store.ZIndex + 2
		styleButton(category, ACCENT_COLOR, 8)
	end
end

local function styleHelp(help)
	if not help then
		return
	end

	help.AnchorPoint = Vector2.new(0.5, 0.5)
	help.Position = UDim2.fromScale(0.5, 0.5)
	help.Size = UDim2.new(0.72, 0, 0.72, 0)
	help.ClipsDescendants = true
	help.ZIndex = 8
	styleSurface(help, 12, PANEL_COLOR, 0.08)

	local sizeConstraint = ensureChild(help, "UISizeConstraint", "ResponsiveSize")
	sizeConstraint.MinSize = Vector2.new(320, 340)
	sizeConstraint.MaxSize = Vector2.new(720, 520)

	local title = help:FindFirstChild("Title")
	if title and title:IsA("TextLabel") then
		title.Size = UDim2.new(1, -124, 0, 54)
		title.Position = UDim2.fromOffset(0, 0)
		title.TextSize = 20
		title.ZIndex = help.ZIndex + 1
		styleSurface(title, 12, PANEL_ALT_COLOR, 0.1)
		setFont(title, true)
	end

	local close = help:FindFirstChild(GuiNames.Close)
	if close and close:IsA("TextButton") then
		close.Size = UDim2.fromOffset(112, 54)
		close.Position = UDim2.new(1, -112, 0, 0)
		close.ZIndex = help.ZIndex + 2
		styleButton(close, DANGER_COLOR, 10)
	end

	local pages = help:FindFirstChild("Pages")
	if pages and pages:IsA("Frame") then
		pages.Position = UDim2.fromOffset(28, 72)
		pages.Size = UDim2.new(1, -56, 1, -148)
		pages.BackgroundTransparency = 1
		pages.ZIndex = help.ZIndex + 1
	end

	for _, descendant in ipairs(help:GetDescendants()) do
		if descendant:IsA("TextLabel") then
			local lowerName = descendant.Name:lower()
			local bold = lowerName:find("title") ~= nil
			setFont(descendant, bold)
			descendant.TextWrapped = true
			descendant.ZIndex = math.max(descendant.ZIndex, help.ZIndex + 2)
			if descendant.Parent and descendant.Parent.Parent == pages then
				descendant.TextSize = bold and 18 or 13
				descendant.TextYAlignment = Enum.TextYAlignment.Top
				if bold then
					descendant.TextXAlignment = Enum.TextXAlignment.Left
				end
			end
		elseif descendant:IsA("TextButton") and descendant.Name ~= "Close" then
			descendant.ZIndex = math.max(descendant.ZIndex, help.ZIndex + 2)
			styleButton(descendant, descendant.Name:find("Reset") and DANGER_COLOR or ACCENT_COLOR, 8)
		end
	end

	local back = help:FindFirstChild("PageBack")
	local nextButton = help:FindFirstChild("PageForwards")
	local pageNumber = help:FindFirstChild("PageNumber")

	if back and back:IsA("TextButton") then
		back.Size = UDim2.fromOffset(150, 44)
		back.Position = UDim2.new(0, 24, 1, -58)
		back.Text = "Previous"
	end

	if nextButton and nextButton:IsA("TextButton") then
		nextButton.Size = UDim2.fromOffset(150, 44)
		nextButton.Position = UDim2.new(1, -174, 1, -58)
		nextButton.Text = "Next"
	end

	if pageNumber and pageNumber:IsA("TextLabel") then
		pageNumber.Size = UDim2.new(1, -380, 0, 44)
		pageNumber.Position = UDim2.new(0, 190, 1, -58)
		pageNumber.BackgroundTransparency = 1
		pageNumber.TextSize = 14
		setFont(pageNumber, false)
	end
end

-- Styles icon buttons only; MenuController owns their Position.
local function styleTopControls()
	local showStore = screenGui:FindFirstChild(GuiNames.ShowStore, true)
	local menuPill = screenGui:FindFirstChild(GuiNames.MenuPill, true)
	local showHelp = screenGui:FindFirstChild(GuiNames.ShowHelp, true)
	if not showHelp and menuPill then
		showHelp = menuPill:FindFirstChild(GuiNames.Help)
	end
	local shield = screenGui:FindFirstChild("ShieldEnabled", true)

	prepareIconButton(showStore, "grid", ICON_BG)
	prepareIconButton(showHelp, "?", ICON_BG)
	prepareIconButton(shield, "◇", SHIELD_OFF_COLOR)
end

local function applyResponsiveLayout()
	local camera = workspace.CurrentCamera
	local viewportSize = camera and camera.ViewportSize or Vector2.new(1280, 720)
	local isCompact = viewportSize.X < 760

	screenGui:SetAttribute("IsCompact", isCompact)
	styleTopControls()

	local store = StoreShell.getActive(screenGui)
	if store then
		-- Store geometry (the bottom-bar band, mobile scaling) is owned by StoreLayoutBottom
		-- via StoreController; this controller only styles the rows so it doesn't fight that
		-- layout. (The old sidebar Position/Size block lived here for StoreSide.)
		local page = store:FindFirstChild("PageTemplate")
		if page then
			for _, child in ipairs(page:GetChildren()) do
				if child:IsA("Frame") then
					styleStoreRow(child)
				end
			end
		end
	end

	local help = screenGui:FindFirstChild(GuiNames.Help)
	if help then
		if isCompact then
			help.Size = UDim2.new(1, -20, 1, -92)
			help.Position = UDim2.new(0.5, 0, 0.5, 26)
		else
			help.Size = UDim2.new(0.72, 0, 0.72, 0)
			help.Position = UDim2.fromScale(0.5, 0.5)
		end
	end
end

if runtimeStyle then
	for _, descendant in ipairs(screenGui:GetDescendants()) do
		if descendant:IsA("TextLabel") or descendant:IsA("TextButton") or descendant:IsA("TextBox") then
			setFont(descendant, descendant.Name == "Title" or descendant.Name == "UpgradeName")
		end
	end

	styleStore(StoreShell.getActive(screenGui))
	styleHelp(screenGui:FindFirstChild(GuiNames.Help))
	applyResponsiveLayout()

	if workspace.CurrentCamera then
		workspace.CurrentCamera:GetPropertyChangedSignal("ViewportSize"):Connect(applyResponsiveLayout)
	end
else
	-- ManualStyle mode: skip visual restyling but wire the functional listeners
	-- that controllers depend on (IconOnly, UiStyleWired, shield/active state).
	local function wireIconButton(container)
		local btn, owner = IconButton.resolveButton(container)
		if not btn then return end
		if btn:GetAttribute(Attrs.UiStyleWired) then return end
		btn:SetAttribute(Attrs.IconOnly, true)
		btn:SetAttribute(Attrs.UiStyleWired, true)
		if owner and owner ~= btn then
			owner:SetAttribute(Attrs.IconOnly, true)
			owner:SetAttribute(Attrs.UiStyleWired, true)
		end
		btn:GetAttributeChangedSignal(Attrs.Active):Connect(function()
			updateIconButton(btn)
		end)
		btn:GetAttributeChangedSignal("ShieldState"):Connect(function()
			updateIconButton(btn)
		end)
	end

	for _, name in ipairs({ "ShowStore", "ShowHelp", "ShieldEnabled" }) do
		wireIconButton(screenGui:FindFirstChild(name, true))
	end

	local pill = screenGui:FindFirstChild(GuiNames.MenuPill, true)
	if pill then
		for _, child in ipairs(pill:GetChildren()) do
			wireIconButton(child)
		end
		pill.DescendantAdded:Connect(function(descendant)
			if descendant:IsA("GuiButton") then
				wireIconButton(descendant)
			end
		end)
	end
end

-- RuntimeStyle may restyle generated descendants. In manual mode, leave
-- Studio-authored and cloned-template layout alone.
screenGui.DescendantAdded:Connect(function(descendant)
	if runtimeStyle then
		if descendant:IsA("TextLabel") or descendant:IsA("TextButton") or descendant:IsA("TextBox") then
			setFont(descendant, descendant.Name == "Title" or descendant.Name == "UpgradeName")
		end
		if descendant:IsA("ViewportFrame") and descendant.Name == "Preview" then
			local row = descendant:FindFirstAncestorOfClass("Frame")
			if row then
				task.defer(styleStoreRow, row)
			end
		end
	end
end)
