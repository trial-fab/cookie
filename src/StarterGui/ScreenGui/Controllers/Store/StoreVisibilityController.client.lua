local screenGui = script:FindFirstAncestorOfClass("ScreenGui")
if not screenGui then
	warn("StoreVisibilityController must be inside a ScreenGui")
	return
end

local TweenService = game:GetService("TweenService")
local shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local Attrs = require(shared:WaitForChild("Attrs"))
local GuiNames = require(shared:WaitForChild("GuiNames"))
local IconButton = require(shared:WaitForChild("IconButton"))
local StoreShell = require(shared:WaitForChild("StoreShell"))

local store = StoreShell.getActive(screenGui)
if not store then
	warn("StoreVisibilityController disabled: no store shell (StoreBottom/StoreSide) was found")
	return
end

-- The Help *modal* is authored as a direct child of the ScreenGui (HelpController resolves it
-- the same way via WaitForChild). Keep this lookup non-recursive on purpose: a recursive
-- search for GuiNames.Help could match the help *button* inside MenuPill instead -- the exact
-- wrong-instance ambiguity that broke the help modal once already.
local help = screenGui:FindFirstChild(GuiNames.Help)
local menuPill = screenGui:FindFirstChild(GuiNames.MenuPill, true)
local resolveButton = IconButton.resolveButton

local function findMenuControl(...)
	local names = { ... }
	-- Recursive within MenuPill so the control is found wherever it sits in the pill subtree,
	-- and -- crucially -- before the screenGui-wide fallback below, which for "Help" could
	-- otherwise match the Help modal instead of the help button (the original help-modal bug).
	for _, name in ipairs(names) do
		if menuPill then
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

local setButtonActive = IconButton.setActive

-- Only the Help button is still resolved here (opening the store closes the Help modal).
-- The old ShowStore/Close toggle buttons are gone: the store is driven entirely by build
-- mode now. BuildViewController owns the store's Close button (it leaves build mode).
local showHelpButton, showHelpContainer = resolveButton(findMenuControl(GuiNames.ShowHelp, GuiNames.Help))

-- The store band is shown whenever the player has it open OR is in build mode *with the store
-- coupled in* (AutoBuildMode on), and hidden the moment a building is being placed so the player
-- sees the plot clearly while aiming. Build mode only pulls the band up when AutoBuildMode is on:
-- that's the device-aware coupling (opt-out on touch, opt-in on PC) -- so PC's default (toggle
-- off) V is a pure fly camera with no band, while the band still shows on B or on mobile build.
-- This controller is purely reactive: it watches the relevant ScreenGui attributes and tweens the
-- band to match. (Owners: StoreToggleController writes StoreOpen + seeds AutoBuildMode;
-- BuildViewController writes BuildModeActive; StorePlacement writes PlacementActive.)
--   visible  <=>  (StoreOpen or (BuildModeActive and AutoBuildMode)) and not PlacementActive
local storeVisible = false
local activeTween = nil
local tweenInfo = TweenInfo.new(0.22, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
-- The authored resting position is the open pose. It is captured LAZILY on the first open
-- rather than at load: the layout (margins/MobileScale) settles the band a frame or two
-- after this script runs, so a load-time snapshot would be a few px off. The band is only
-- ever hidden via Visible=false until the first open, so its position is still the settled
-- authored pose at that moment. `openPosition` seeds with the load-time value as a fallback.
local openPosition = store.Position
local openCaptured = false

local function getOpenPos()
	return openPosition
end

-- StoreBottom is anchored to the bottom edge (AnchorPoint Y = 1, Position.Y = {1, -margin}),
-- so "closed" slides the whole band straight down until it clears the screen bottom.
local function getClosedPos()
	local height = store.AbsoluteSize.Y
	if height <= 0 then
		height = store.Size.Y.Offset
	end

	local open = getOpenPos()
	return UDim2.new(open.X.Scale, open.X.Offset, open.Y.Scale, open.Y.Offset + height + 48)
end

local function setStoreVisible(value)
	if value == storeVisible then
		return
	end
	storeVisible = value

	if activeTween then
		activeTween:Cancel()
		activeTween = nil
	end

	-- Opening the store closes the Help modal so they never overlap.
	if help and value then
		help.Visible = false
		if showHelpButton then
			setButtonActive(showHelpButton, showHelpContainer, false, "HELP")
		end
	end

	if value then
		-- Capture the settled authored open pose the first time we open (see note above).
		if not openCaptured then
			openPosition = store.Position
			openCaptured = true
		end
		store.Visible = true
		store.Position = getClosedPos()
		activeTween = TweenService:Create(store, tweenInfo, { Position = getOpenPos() })
		activeTween:Play()
	else
		local tween = TweenService:Create(store, tweenInfo, { Position = getClosedPos() })
		activeTween = tween
		-- Hide once off-screen so the parked band can't intercept input.
		tween.Completed:Connect(function(state)
			if activeTween == tween and state == Enum.PlaybackState.Completed then
				store.Visible = false
			end
		end)
		tween:Play()
	end
end

-- Reactive driver: recompute desired visibility from the attributes.
local function refreshFromAttributes()
	local storeOpen = screenGui:GetAttribute(Attrs.StoreOpen) == true
	local buildMode = screenGui:GetAttribute(Attrs.BuildModeActive) == true
	local autoBuild = screenGui:GetAttribute(Attrs.AutoBuildMode) == true
	local placing = screenGui:GetAttribute(Attrs.PlacementActive) == true
	setStoreVisible((storeOpen or (buildMode and autoBuild)) and not placing)
end

screenGui:GetAttributeChangedSignal(Attrs.StoreOpen):Connect(refreshFromAttributes)
screenGui:GetAttributeChangedSignal(Attrs.BuildModeActive):Connect(refreshFromAttributes)
screenGui:GetAttributeChangedSignal(Attrs.AutoBuildMode):Connect(refreshFromAttributes)
screenGui:GetAttributeChangedSignal(Attrs.PlacementActive):Connect(refreshFromAttributes)

-- Initial state: hidden until build mode is entered. We only hide (Visible = false) and
-- leave the authored open position in place — the closed slide-out pose is computed lazily
-- on the first real open, by which point the band has rendered and has a valid AbsoluteSize.
store.Visible = false
refreshFromAttributes()
