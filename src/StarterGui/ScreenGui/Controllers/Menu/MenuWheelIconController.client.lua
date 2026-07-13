-- MenuWheelIconController — micro-interaction for the Wheel launcher icon in MenuPill.
--
-- The Wheel icon is two stacked ImageButtons authored in Studio: WheelBase (the ring, on top)
-- and WheelCookie (the cookie, behind). This controller animates WheelCookie:
--   * spins continuously while the icon is hovered, stopping (and easing home) on leave;
--   * does a single 360° on a quick click so a no-hover click still has motion;
--   * turns gold while the Wheel modal is open (golden-cookie theme).
--
-- Ownership split mirrors MenuSettingsIconController/SettingsController: this controller renders
-- the icon from the Wheel container's Active attribute but never writes it — WheelController owns
-- Active (the modal's open state) and binds the open/close click to the same shared Hitbox we
-- create here. We also publish Attrs.Hovering on the Wheel frame so MenuProfileFaceController can
-- react with its soft-right face even though WheelBase sits on top of the hover area.
--
-- The continuous spin is driven by a looping Tween, NOT a per-frame Heartbeat/RenderStepped write:
-- some clients throttle their update loop to ~0 fps when the scene is idle, which freezes manual
-- per-frame Position/Rotation writes; an active Tween keeps the client rendering.
local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local Attrs = require(Shared:WaitForChild("Attrs"))
local GuiNames = require(Shared:WaitForChild("GuiNames"))
local IconButton = require(Shared:WaitForChild("IconButton"))
local UiMotion = require(Shared:WaitForChild("UiMotion"))

local screenGui = script:FindFirstAncestorOfClass("ScreenGui")
if not screenGui then
	return
end
if screenGui:GetAttribute("MenuWheelIconWired") == true then
	return
end

local pill = screenGui:WaitForChild(GuiNames.MenuPill, 10)
if not pill then
	warn("MenuWheelIconController: MenuPill not found")
	return
end

local wheelFrame = pill:FindFirstChild(GuiNames.Wheel, true)
local deadline = os.clock() + 10
while not wheelFrame and os.clock() < deadline do
	task.wait(0.05)
	wheelFrame = pill:FindFirstChild(GuiNames.Wheel, true)
end
if not wheelFrame or not wheelFrame:IsA("GuiObject") then
	warn("MenuWheelIconController: Wheel frame not found")
	return
end

local cookie = wheelFrame:FindFirstChild("WheelCookie")
local base = wheelFrame:FindFirstChild("WheelBase")
if not (cookie and cookie:IsA("ImageButton")) then
	warn("MenuWheelIconController: WheelCookie image button not found")
	return
end

screenGui:SetAttribute("MenuWheelIconWired", true)

local GOLD = Color3.fromRGB(255, 196, 35)
local WHITE = Color3.fromRGB(255, 255, 255)

-- The cookie's own button states must not fight us while we drive Rotation/ImageColor3.
cookie.AutoButtonColor = false
cookie.Rotation = 0
cookie.ImageColor3 = WHITE

-- Shared hitbox over the whole Wheel frame. WheelController.resolveButton looks for a child named
-- "Hitbox" first, so the modal's open/close click binds to this same button automatically.
local hitbox = IconButton.createHitbox(wheelFrame, base or cookie)

local SPIN_PERIOD = 1.1 -- seconds per full revolution while hovering
local spinLoopInfo = TweenInfo.new(SPIN_PERIOD, Enum.EasingStyle.Linear, Enum.EasingDirection.InOut, -1)

-- All motion is CLOCKWISE only: Rotation never decreases. The continuous spin loops 0→360, and the
-- settle always advances *forward* the short way to the next upright (a multiple of 360) before
-- snapping back into [0, 360). Tweening Rotation down to 0 is what read as a counter-clockwise
-- rewind, so we never do that.
local activeTween = nil
local hovering = false
local spinning = false -- the continuous loop is running; guards against restarting it (which would jump Rotation to 0)

local function isActive()
	return wheelFrame:GetAttribute(Attrs.Active) == true
		or (hitbox and hitbox:GetAttribute(Attrs.Active) == true)
end

local function cancelActive()
	if activeTween then activeTween:Cancel(); activeTween = nil end
end

-- Continuous spin: a looping tween from the CURRENT angle to current+360. A repeating tween replays
-- from its start value each cycle, and start+360 ≡ start (mod 360), so the wrap is seamless from any
-- starting angle — which lets us resume mid-return without snapping back to 0 (the old jump). We do
-- NOT reset Rotation to 0 here: if the cursor leaves and comes back while the cookie is still easing
-- home, the spin simply continues forward from wherever it is.
local function startSpin()
	cancelActive()
	if UiMotion.isReduced(cookie) then
		spinning = false
		cookie.Rotation = 0
		return
	end
	spinning = true
	local current = cookie.Rotation
	activeTween = UiMotion.create(cookie, spinLoopInfo, { Rotation = current + 360 })
	activeTween:Play()
end

-- Stop the spin and finish the rotation: keep turning forward only as far as the next upright, then
-- snap to 0. The duration tracks the spin speed (capped) so a near-complete turn coasts to a stop
-- and a barely-started one finishes quickly — it reads as the cookie returning to where it began,
-- never an extra full lap. Used by both MouseLeave and click.
local function settleToUpright()
	cancelActive()
	spinning = false
	local current = cookie.Rotation % 360
	cookie.Rotation = current
	if current == 0 then return end
	local remaining = 360 - current
	local duration = math.clamp(remaining / 360 * SPIN_PERIOD, 0.1, SPIN_PERIOD)
	local info = TweenInfo.new(duration, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
	local t = UiMotion.create(cookie, info, { Rotation = 360 })
	activeTween = t
	t:Play()
	t.Completed:Once(function(state)
		if t ~= activeTween then return end
		activeTween = nil
		if state == Enum.PlaybackState.Completed then cookie.Rotation = 0 end
	end)
end

-- Gold while the modal is open, white otherwise. WheelController owns the Active attribute.
local function updateColor()
	cookie.ImageColor3 = isActive() and GOLD or WHITE
end

-- Spin follows hover ONLY — same whether or not the wheel is selected. On hover it spins; off hover
-- it finishes forward to its starting upright and stops. Being selected (modal open) only changes
-- the colour (gold), never the spin. Opening/closing the modal is handled by WheelController on this
-- same hitbox.
local function refresh()
	if hovering then
		if not spinning then
			startSpin()
		end
	elseif spinning then
		settleToUpright()
	end
end

hitbox.MouseEnter:Connect(function()
	hovering = true
	wheelFrame:SetAttribute(Attrs.Hovering, true)
	refresh()
end)

hitbox.MouseLeave:Connect(function()
	hovering = false
	wheelFrame:SetAttribute(Attrs.Hovering, false)
	refresh()
end)

-- Active drives the colour only.
wheelFrame:GetAttributeChangedSignal(Attrs.Active):Connect(updateColor)
hitbox:GetAttributeChangedSignal(Attrs.Active):Connect(updateColor)
screenGui:GetAttributeChangedSignal(Attrs.ReducedMotionEnabled):Connect(function()
	if screenGui:GetAttribute(Attrs.ReducedMotionEnabled) == true then
		cancelActive()
		spinning = false
		cookie.Rotation = 0
	else
		refresh()
	end
end)

updateColor()
