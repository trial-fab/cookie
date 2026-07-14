local screenGui = script:FindFirstAncestorOfClass("ScreenGui")
if not screenGui then
	return
end
local Attrs = require(game:GetService("ReplicatedStorage"):WaitForChild("Shared"):WaitForChild("Attrs"))
local GuiNames = require(game:GetService("ReplicatedStorage"):WaitForChild("Shared"):WaitForChild("GuiNames"))
local PvpConfig = require(game:GetService("ReplicatedStorage"):WaitForChild("Shared"):WaitForChild("PvpConfig"))

if screenGui:GetAttribute(Attrs.UseGeneratedMenu) ~= true then
	return
end

local UiMotion = require(game:GetService("ReplicatedStorage"):WaitForChild("Shared"):WaitForChild("UiMotion"))

-- Recursive search: finds buttons even when pre-baked inside MenuPill.
local function waitForDescendant(name)
	local found = screenGui:FindFirstChild(name, true)
	if found then return found end
	local deadline = tick() + 10
	repeat task.wait(0.05); found = screenGui:FindFirstChild(name, true)
	until found or tick() > deadline
	return found
end

local showStore = waitForDescendant("ShowStore")
local showHelp  = waitForDescendant("ShowHelp")
local shield    = waitForDescendant("ShieldEnabled")

-- Wait for UiStyleController to set UiStyleWired (signals attributes are ready).
local deadline = tick() + 8
while not showStore:GetAttribute(Attrs.UiStyleWired) and tick() < deadline do
	task.wait(0.05)
end

-- Pill geometry constants (must match bake script)
local PILL_H        = 40
local BTN_SIZE      = 36
local BTN_GAP       = 4
local SIDE_PAD      = 4
local N_BTNS        = PvpConfig.IsActive() and 5 or 4  -- shield pill hidden while PVP paused
local PILL_W_CLOSED = PILL_H
local PILL_W_OPEN   = 2 * SIDE_PAD + N_BTNS * BTN_SIZE + (N_BTNS - 1) * BTN_GAP  -- 204

local PILL_BG  = Color3.fromRGB(22, 24, 32)
local TEXT_CLR = Color3.fromRGB(244, 247, 252)

-- Find pre-baked pill or create fresh.
local pill = screenGui:FindFirstChild(GuiNames.MenuPill)
if not pill then
	pill = Instance.new("Frame")
	pill.Name = "MenuPill"
	pill.Parent = screenGui
end

pill.AnchorPoint        = Vector2.new(1, 0)
pill.Position           = UDim2.new(1, -12, 0, 10)
pill.Size               = UDim2.fromOffset(PILL_W_CLOSED, PILL_H)
pill.BackgroundColor3   = PILL_BG
pill.BackgroundTransparency = 0.12
pill.BorderSizePixel    = 0
pill.ClipsDescendants   = true   -- reset from bake (which shows open/unclipped)
pill.ZIndex             = 20

local authoredPillBackgroundTransparency = pill.BackgroundTransparency
local authoredPillZIndex = pill.ZIndex
local function updateCompactModalPresentation()
	local compact = screenGui:GetAttribute(Attrs.CompactModalActive) == true
	pill.Visible = true
	pill.BackgroundTransparency = compact and 1 or authoredPillBackgroundTransparency
	pill.ZIndex = compact and math.max(authoredPillZIndex, 102) or authoredPillZIndex
end
screenGui:GetAttributeChangedSignal(Attrs.CompactModalActive):Connect(updateCompactModalPresentation)
updateCompactModalPresentation()

local pillCorner = pill:FindFirstChild("ModernCorner") or Instance.new("UICorner")
pillCorner.Name          = "ModernCorner"
pillCorner.CornerRadius  = UDim.new(0, PILL_H / 2)
pillCorner.Parent        = pill

local pillLayout = pill:FindFirstChildOfClass("UIListLayout") or Instance.new("UIListLayout")
pillLayout.FillDirection        = Enum.FillDirection.Horizontal
pillLayout.HorizontalAlignment  = Enum.HorizontalAlignment.Right
pillLayout.VerticalAlignment    = Enum.VerticalAlignment.Center
pillLayout.SortOrder            = Enum.SortOrder.LayoutOrder
pillLayout.Padding              = UDim.new(0, BTN_GAP)
pillLayout.Parent               = pill

local pillPad = pill:FindFirstChildOfClass("UIPadding") or Instance.new("UIPadding")
pillPad.PaddingLeft  = UDim.new(0, SIDE_PAD)
pillPad.PaddingRight = UDim.new(0, SIDE_PAD)
pillPad.Parent       = pill

-- Apply pill-button styling + hover circle to a button.
local function stylePillBtn(btn)
	btn.Size                = UDim2.fromOffset(BTN_SIZE, BTN_SIZE)
	btn.BackgroundColor3    = Color3.fromRGB(255, 255, 255)
	btn.BackgroundTransparency = 1
	btn.AutoButtonColor     = false
	btn.BorderSizePixel     = 0
	btn.TextColor3          = TEXT_CLR
	btn.TextSize            = 18
	btn.Font                = Enum.Font.GothamBold
	btn.ZIndex              = pill.ZIndex + 1

	local corner = btn:FindFirstChildOfClass("UICorner")
	if not corner then
		corner = Instance.new("UICorner")
		corner.Parent = btn
	end
	corner.CornerRadius = UDim.new(0, BTN_SIZE / 2)

	local stroke = btn:FindFirstChild("ModernStroke")
	if stroke then stroke:Destroy() end
end

-- Find or create toggle button (LayoutOrder=1 = rightmost).
local toggleBtn = pill:FindFirstChild("ToggleButton")
if not toggleBtn then
	toggleBtn = Instance.new("TextButton")
	toggleBtn.Name = "ToggleButton"
	toggleBtn.Parent = pill
end
toggleBtn.Text        = ""
toggleBtn.LayoutOrder = 5   -- rightmost: always visible when pill is closed
toggleBtn.ZIndex      = pill.ZIndex + 2
stylePillBtn(toggleBtn)

-- Ensure hamburger bars frame exists.
local bars = toggleBtn:FindFirstChild("HamburgerIcon")
if not bars then
	bars = Instance.new("Frame")
	bars.Name                 = "HamburgerIcon"
	bars.BackgroundTransparency = 1
	bars.AnchorPoint          = Vector2.new(0.5, 0.5)
	bars.Position             = UDim2.fromScale(0.5, 0.5)
	bars.Size                 = UDim2.fromOffset(16, 12)
	bars.ZIndex               = toggleBtn.ZIndex + 1
	bars.Parent               = toggleBtn
	for i = 1, 3 do
		local bar = Instance.new("Frame")
		bar.Name              = "Bar" .. i
		bar.Size              = UDim2.new(1, 0, 0, 2)
		bar.Position          = UDim2.fromOffset(0, (i - 1) * 5)
		bar.BackgroundColor3  = TEXT_CLR
		bar.BorderSizePixel   = 0
		bar.ZIndex            = bars.ZIndex + 1
		local c = Instance.new("UICorner")
		c.CornerRadius = UDim.new(0, 1)
		c.Parent = bar
		bar.Parent = bars
	end
end
bars.Visible = true  -- start closed (hamburger visible)

-- Move button into pill and apply styling only when not already there.
local function ensureInPill(btn, order)
	btn.LayoutOrder   = order
	btn.AnchorPoint   = Vector2.new(0, 0)
	if btn.Parent ~= pill then
		btn.Parent = pill
	end
	stylePillBtn(btn)
end

-- Layout order (left=1 to right=5 with HorizontalAlignment=Right):
--   Profile(1) · Store(2) · Help(3) · Shield(4) · Toggle(5)
-- Toggle is LayoutOrder=5 so it stays at the far right when the pill is closed.
if PvpConfig.IsActive() then
	ensureInPill(shield, 4)
elseif shield then
	shield.Visible = false
end

showHelp.Text = "?"
ensureInPill(showHelp, 3)

-- Keep GridIcon for ShowStore; resize if it was baked at a larger size.
local gridIcon = showStore:FindFirstChild("GridIcon")
if gridIcon then
	gridIcon.Size    = UDim2.fromOffset(16, 16)
	showStore.Text   = ""
else
	showStore.Text = "▦"
end
ensureInPill(showStore, 2)

-- Find or create profile button (LayoutOrder=1 = leftmost, revealed last).
local profileBtn = pill:FindFirstChild(GuiNames.ProfileButton)
if not profileBtn then
	profileBtn = Instance.new("TextButton")
	profileBtn.Name = "ProfileButton"
	profileBtn.Parent = pill
end
profileBtn.Text        = "◎"
profileBtn.LayoutOrder = 1
profileBtn.ZIndex      = pill.ZIndex + 1
stylePillBtn(profileBtn)

-- Menu animation state.
local menuOpen   = false
local activeTween = nil
local openInfo   = TweenInfo.new(0.22, Enum.EasingStyle.Quart, Enum.EasingDirection.Out)
local closeInfo  = TweenInfo.new(0.18, Enum.EasingStyle.Quart, Enum.EasingDirection.In)

local function setMenuOpen(open)
	menuOpen = open
	bars.Visible   = not open
	toggleBtn.Text = open and "×" or ""

	if activeTween then activeTween:Cancel() end
	local targetW = open and PILL_W_OPEN or PILL_W_CLOSED
	activeTween = UiMotion.create(pill, open and openInfo or closeInfo, {
		Size = UDim2.fromOffset(targetW, PILL_H),
	})
	activeTween:Play()
end

toggleBtn.MouseButton1Click:Connect(function()
	setMenuOpen(not menuOpen)
end)
