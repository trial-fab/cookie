-- BuildViewController: orchestrator for the free-fly "Build View" placement
-- camera. This script owns the camera/input lifecycle (enter/exit, the per-frame fly
-- loop, and all keyboard/mouse/touch input) plus the AutoBuildMode store<->build coupling
-- and the in-band TopBar BuildModeButton. Two sibling ctx modules own the rest:
--   * BuildTitleReveal.lua      — the BuildModeActive-driven "Build" title reveal/hide.
--   * BuildSuggestionNudge.lua  — the first-placement BuildViewSuggestion nudge.
-- Both are constructed below with a shared ctx (StoreController-style). The store band's
-- open/close cookie toggle + its launch animation live in StoreToggleController (the band is
-- decoupled from build mode now). Authoring contract (see memory/WORKFLOW.md: UI authored in
-- Studio): nothing here builds frames/buttons — it only BINDS to instances authored in Studio
-- and degrades gracefully when they're absent.
--
-- Placement itself is untouched: StoreController raycasts through
-- Workspace.CurrentCamera, so swapping in the scriptable free-fly camera makes the
-- existing GridPlacement preview/rotation/validity/placement work as-is. While Build
-- View is active the default character controls are disabled (PC + mobile) so WASD /
-- single-finger drag pan the camera instead of moving the avatar.

local screenGui = script:FindFirstAncestorOfClass("ScreenGui")
if not screenGui then
	return
end

-- Single-instance guard (StarterGui scripts can re-run on respawn).
if screenGui:GetAttribute("BuildViewControllerRunning") then
	return
end
screenGui:SetAttribute("BuildViewControllerRunning", true)

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local TweenService = game:GetService("TweenService")
local Workspace = game:GetService("Workspace")

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")

local shared = ReplicatedStorage:WaitForChild("Shared")
local BuildViewCamera = require(shared:WaitForChild("BuildViewCamera"))
local Attrs = require(shared:WaitForChild("Attrs"))
local GuiNames = require(shared:WaitForChild("GuiNames"))
local StoreShell = require(shared:WaitForChild("StoreShell"))
local BuildModeButtonAnimator = require(script.Parent:WaitForChild("BuildModeButtonAnimator"))
local BuildModeTopbarPosition = require(script.Parent:WaitForChild("BuildModeTopbarPosition"))

-- Default character controls (keyboard movement + mobile thumbstick) are suspended
-- while Build View is active so movement input drives the camera, not the avatar. We
-- lazily resolve the PlayerModule controls object and degrade gracefully if it isn't
-- available (e.g. custom character scripts) — Build View still works, the avatar just
-- isn't pinned.
local cachedControls = nil
local function getControls()
	if cachedControls then
		return cachedControls
	end
	local ok, controls = pcall(function()
		local playerScripts = player:WaitForChild("PlayerScripts", 5)
		local playerModule = playerScripts and require(playerScripts:WaitForChild("PlayerModule", 5))
		return playerModule and playerModule:GetControls() or nil
	end)
	if ok then
		cachedControls = controls
	end
	return cachedControls
end

local function setCharacterControlsEnabled(enabled)
	local controls = getControls()
	if not controls then
		return
	end
	pcall(function()
		if enabled then
			controls:Enable()
		else
			controls:Disable()
		end
	end)
end

-- Mobile = touch without a mouse. Touch laptops keep MouseEnabled, so they take the
-- PC path (explicit toggle only, never nagged).
local function isMobileDevice()
	return UserInputService.TouchEnabled and not UserInputService.MouseEnabled
end

-- ---------------------------------------------------------------------------------
-- UI bindings (all optional)
-- ---------------------------------------------------------------------------------
local store = StoreShell.getActive(screenGui)

local function isGuiObjectActuallyVisible(object)
	if not object or not object:IsA("GuiObject") or not object.Visible then
		return false
	end
	local ancestor = object.Parent
	while ancestor and ancestor ~= screenGui do
		if ancestor:IsA("GuiObject") and not ancestor.Visible then
			return false
		end
		ancestor = ancestor.Parent
	end
	return ancestor == screenGui
end

local function guiObjectHasVisibleSurface(object)
	if not isGuiObjectActuallyVisible(object) then
		return false
	end
	if object:IsA("GuiButton") or object:IsA("ScrollingFrame") or object:IsA("TextBox") then
		return true
	end
	if object.BackgroundTransparency < 1 then
		return true
	end
	if (object:IsA("TextLabel") or object:IsA("TextButton") or object:IsA("TextBox"))
		and object.Text ~= ""
		and object.TextTransparency < 1
	then
		return true
	end
	if (object:IsA("ImageLabel") or object:IsA("ImageButton"))
		and object.Image ~= ""
		and object.ImageTransparency < 1
	then
		return true
	end
	return false
end

local function pointInGuiObject(x, y, object)
	if not object or not object:IsA("GuiObject") or not isGuiObjectActuallyVisible(object) then
		return false
	end
	local pos = object.AbsolutePosition
	local size = object.AbsoluteSize
	return x >= pos.X and x <= pos.X + size.X and y >= pos.Y and y <= pos.Y + size.Y
end

-- Whole-footprint input blockers, resolved live so visibility/animation is respected. The
-- store band is the main one: it sits at the bottom, doesn't span the full screen, and is
-- partly transparent, so pixel-accurate hit-testing alone lets a swipe slide through its
-- gaps or off its edge and leak into a camera pan. Blocking its entire rect (only while it's
-- actually open) closes that gap; add other transparent panels here the same way.
local function isPointInBlockingPanel(x, y)
	if store and screenGui:GetAttribute(Attrs.StoreOpen) == true and pointInGuiObject(x, y, store) then
		return true
	end
	return false
end

local function isCameraInputPositionBlocked(position)
	if not position then
		return false
	end
	local x = position.X
	local y = position.Y
	if isPointInBlockingPanel(x, y) then
		return true
	end
	for _, object in ipairs(playerGui:GetGuiObjectsAtPosition(x, y)) do
		if object:IsDescendantOf(screenGui) and guiObjectHasVisibleSurface(object) then
			return true
		end
	end
	return false
end

-- ---------------------------------------------------------------------------------
-- State
-- ---------------------------------------------------------------------------------
local buildViewActive = false
-- Module handles (assigned after enter/exit/toggle are defined, below).
local buildNudge

-- Free-fly camera state. The camera is a free world POSITION with a fixed orientation
-- (BuildViewCamera supplies the look direction); we integrate a velocity each frame for
-- momentum glide. cameraReady gates the per-frame loop until the enter tween lands.
local cameraPos = Vector3.zero
local velocity = Vector3.zero
local frameConnection = nil
local cameraReady = false
local lastBuildViewPose = nil

-- Sustained inputs. heldKeys latches WASD/arrows/QE; heightHoldDir is the on-screen
-- up/down button state (+1 rise, -1 descend). One-finger touch pans by grabbing a world
-- point (touchPanGrabPoint) and moving cameraPos directly each event; a flick-release hands
-- a decaying throw to touchThrowVelocity, while a stopped-then-released drag parks instantly.
local heldKeys = {}
local heightHoldDir = 0
local touchPanActive = false
-- Grab-the-world pan: the world point pinned under the finger while a one-finger drag is
-- active (nil otherwise). Each move shifts the camera so this point stays under the finger --
-- the touch twin of the PC middle-mouse pan. Releasing mid-motion hands a throw to
-- touchThrowVelocity (decaying glide); releasing while still parks with no drift.
local touchPanGrabPoint = nil
local touchThrowVelocity = Vector3.zero
-- Velocity-tracker buffer for the drag-and-release fling: recent finger screen-position samples
-- { t, x, y }, trimmed to TOUCH_VELOCITY_WINDOW. Fed from the TouchPan INPUT events (which fire
-- on the touch digitizer -- reliably and often, independent of render frame rate), plus the
-- release position on lift, so it never depends on the per-frame loop (which can be starved on
-- low-end devices). On release the throw is the displacement across the window: a moving finger
-- yields a real velocity (fling); a finger held still produces no fresh samples, so the window
-- empties to the rest spot and it parks.
local touchPanSamples = {}
local touchesStartedOnUi = {}
-- Physical finger bookkeeping. activeTouchCount tracks fingers currently down;
-- multiTouchLatched goes true the moment a second finger lands and stays true until ALL
-- fingers lift, so the finger left behind when you release one of a pinch/twist is never
-- misread as the start of a single-finger pan.
local activeTouchCount = 0
local multiTouchLatched = false
local wheelDollyVelocity = Vector3.zero
local placementDragInput = nil
local placementDragPosition = nil
local middleMouseDragging = false
local middleMouseGrabPoint = nil

-- Saved camera state so exiting restores exactly what the player had.
local savedCameraType = nil
local savedCameraCFrame = nil
local savedCameraFieldOfView = nil
local savedCameraSubject = nil
-- True once savedCamera* holds a genuine (non-Scriptable) default-camera snapshot. We
-- only ever capture from the real follow camera, never from a half-finished transition.
local savedCameraValid = false
-- The in-flight enter/exit camera tween, and a token that supersedes stale transitions.
-- Together these make rapid toggle spam safe: a new transition cancels the old tween and
-- invalidates its Completed handler, so a half-done pose can never be saved or restored.
local activeCameraTween = nil
local transitionToken = 0

local function cancelActiveCameraTween()
	if activeCameraTween then
		activeCameraTween:Cancel()
		activeCameraTween = nil
	end
end

local ENTER_TWEEN = TweenInfo.new(0.45, Enum.EasingStyle.Quint, Enum.EasingDirection.Out)
local EXIT_TWEEN = TweenInfo.new(0.35, Enum.EasingStyle.Quint, Enum.EasingDirection.Out)

local function getPlayerSheet()
	local cookieSheets = Workspace:FindFirstChild("CookieSheets")
	if not cookieSheets then
		return nil
	end
	for _, sheet in ipairs(cookieSheets:GetChildren()) do
		local owner = sheet:FindFirstChild("SheetOwner")
		if owner and owner.Value == player then
			return sheet
		end
	end
	return nil
end

local function getBasePart()
	local sheet = getPlayerSheet()
	local base = sheet and sheet:FindFirstChild("Base")
	if base and base:IsA("BasePart") then
		return base
	end
	return nil
end

-- Movement tuning (studs, seconds). Horizontal speed scales with height so flying feels
-- consistent whether you're zoomed onto one cell or surveying the whole plot.
local KEY_MOVE_SPEED = 60
local VERT_SPEED = 48
local WHEEL_DOLLY_STEP = 26
local WHEEL_ZOOM_TAU = 0.22
local EDGE_PAN_ZONE_PX = 72
local EDGE_PAN_SPEED = 72
local ACCEL_TAU = 0.10 -- responsiveness while a key/button is held
local DECEL_TAU = 0.32 -- glide-out after release (momentum)
local BOUNDS_TAU = 0.18 -- ease-back toward the loose plot bounds
local PINCH_SENSITIVITY = 0.6
local TOUCH_THROW_TAU = 0.22 -- glide-out after a drag-and-release flick (touch momentum)
-- Phone-style fling, à la Android's VelocityTracker: the throw velocity is measured from the
-- finger's own screen-position samples over only the last TOUCH_VELOCITY_WINDOW seconds before
-- release (mobile scrollers use ~100ms). If the finger was still during that window there's no
-- displacement, so velocity is ~0 and the camera parks; if it was moving, it flings, with
-- momentum scaled to that recent speed. (We measure positions ourselves because Roblox's own
-- TouchPan velocity is unreliably scaled.)
local TOUCH_VELOCITY_WINDOW = 0.15
-- Minimum release speed (px/s) to fling at all -- below it the pan parks. Real swipes measure in
-- the hundreds-to-thousands of px/s, so this comfortably passes even a small quick flick while
-- rejecting the slow drift of a finger lifting off.
local MIN_FLING_PX_PER_SEC = 0

-- View rotation (right-drag on PC, two-finger twist on touch). yaw spins around the plot;
-- viewPitch tilts the angle, clamped to the camera's pitch range.
local MIN_PITCH = math.rad(BuildViewCamera.MIN_PITCH_DEGREES)
local MAX_PITCH = math.rad(BuildViewCamera.MAX_PITCH_DEGREES)
local YAW_DRAG_SENSITIVITY = 0.005 -- radians per pixel of horizontal right-drag
local PITCH_DRAG_SENSITIVITY = 0.004 -- radians per pixel of vertical right-drag
local yaw = 0
local viewPitch = math.rad(BuildViewCamera.PITCH_DEGREES)

-- Right-mouse drag rotates the view. The cursor is locked in place during right-drag so
-- rotation can keep moving. Middle-mouse pan keeps the cursor free so it can grab the
-- world point under it, like Studio's viewport pan.
local rightDragging = false
local function updateMouseBehavior()
	UserInputService.MouseBehavior = rightDragging and Enum.MouseBehavior.LockCurrentPosition
		or Enum.MouseBehavior.Default
end

local function setRightDragging(active)
	if active == rightDragging then
		return
	end
	rightDragging = active
	updateMouseBehavior()
end

local function setMiddleMouseDragging(active)
	if active == middleMouseDragging then
		return
	end
	middleMouseDragging = active
	if not active then
		middleMouseGrabPoint = nil
	end
	updateMouseBehavior()
end

local KEY_FORWARD = { [Enum.KeyCode.W] = true, [Enum.KeyCode.Up] = true }
local KEY_BACK = { [Enum.KeyCode.S] = true, [Enum.KeyCode.Down] = true }
local KEY_RIGHT = { [Enum.KeyCode.D] = true, [Enum.KeyCode.Right] = true }
local KEY_LEFT = { [Enum.KeyCode.A] = true, [Enum.KeyCode.Left] = true }

local function isMoveKey(key)
	return KEY_FORWARD[key] or KEY_BACK[key] or KEY_RIGHT[key] or KEY_LEFT[key]
		or key == Enum.KeyCode.Q or key == Enum.KeyCode.E
		or key == Enum.KeyCode.Space
		or key == Enum.KeyCode.LeftShift or key == Enum.KeyCode.RightShift
end

-- Movement speed multiplier from current height above the plot, so the same key throws
-- you proportionally further when zoomed out. Clamped so it never crawls or teleports.
local function speedFactor(base)
	return math.clamp((cameraPos.Y - base.CFrame.Position.Y) / 60, 0.65, 8)
end

local function isPlacementActive()
	return screenGui:GetAttribute(Attrs.PlacementActive) == true
end

-- Desired world velocity (studs/s) from the currently held keys and on-screen up/down
-- buttons, in the plot's flattened forward/right basis plus a vertical component.
local function computeMoveTarget(base)
	local forward, right = BuildViewCamera.movementBasis(base.CFrame, yaw)
	local dir = Vector3.zero
	for key in pairs(heldKeys) do
		if KEY_FORWARD[key] then
			dir += forward
		elseif KEY_BACK[key] then
			dir -= forward
		elseif KEY_RIGHT[key] then
			dir += right
		elseif KEY_LEFT[key] then
			dir -= right
		end
	end
	local vert = heightHoldDir
	if heldKeys[Enum.KeyCode.E] or heldKeys[Enum.KeyCode.Space] then
		vert += 1
	end
	if heldKeys[Enum.KeyCode.Q] or heldKeys[Enum.KeyCode.LeftShift] or heldKeys[Enum.KeyCode.RightShift] then
		vert -= 1
	end
	vert = math.clamp(vert, -1, 1)
	local factor = speedFactor(base)
	local horiz = (dir.Magnitude > 1e-3) and (dir.Unit * KEY_MOVE_SPEED * factor) or Vector3.zero
	return horiz + Vector3.new(0, vert * VERT_SPEED * factor, 0)
end

local function computePlacementEdgePanTarget(base)
	if not placementDragPosition or not isPlacementActive() then
		return Vector3.zero
	end
	local cam = Workspace.CurrentCamera
	if not cam then
		return Vector3.zero
	end
	local viewport = cam.ViewportSize
	if viewport.X <= 0 or viewport.Y <= 0 then
		return Vector3.zero
	end

	local zone = math.min(EDGE_PAN_ZONE_PX, viewport.X * 0.2, viewport.Y * 0.2)
	local x = placementDragPosition.X
	local y = placementDragPosition.Y
	local xDir = 0
	local yDir = 0

	if x < zone then
		xDir = -(1 - x / zone)
	elseif x > viewport.X - zone then
		xDir = (x - (viewport.X - zone)) / zone
	end
	if y < zone then
		yDir = 1 - y / zone
	elseif y > viewport.Y - zone then
		yDir = -((y - (viewport.Y - zone)) / zone)
	end

	xDir = math.clamp(xDir, -1, 1)
	yDir = math.clamp(yDir, -1, 1)
	if xDir == 0 and yDir == 0 then
		return Vector3.zero
	end

	local forward, right = BuildViewCamera.movementBasis(base.CFrame, yaw)
	local dir = right * xDir + forward * yDir
	if dir.Magnitude < 1e-3 then
		return Vector3.zero
	end
	return dir.Unit * EDGE_PAN_SPEED * speedFactor(base)
end

-- Record a finger screen position into the velocity-tracker buffer, dropping samples older than
-- the velocity window (but never below two, so a fling stays measurable at low frame rates).
local function pushTouchPanSample(x, y)
	local now = os.clock()
	table.insert(touchPanSamples, { t = now, x = x, y = y })
	while #touchPanSamples > 2 and (now - touchPanSamples[1].t) > TOUCH_VELOCITY_WINDOW do
		table.remove(touchPanSamples, 1)
	end
end

-- Per-frame fly loop: integrate velocity (momentum), ease toward the loose plot bounds,
-- and convert the free position into the fixed-angle camera CFrame.
local function stepCamera(dt)
	if not buildViewActive or not cameraReady then
		return
	end
	local base = getBasePart()
	local cam = Workspace.CurrentCamera
	if not base or not cam then
		return
	end
	if touchPanActive or middleMouseDragging then
		-- Grab-style panning (touch grab / middle-mouse) moves cameraPos directly in the
		-- input handler with no momentum, so hold velocity at zero here.
		velocity = Vector3.zero
	else
		local target = computeMoveTarget(base) + computePlacementEdgePanTarget(base)
		local tau = (target.Magnitude > 1e-3) and ACCEL_TAU or DECEL_TAU
		velocity = velocity:Lerp(target, 1 - math.exp(-dt / tau))
	end
	cameraPos += velocity * dt
	if wheelDollyVelocity.Magnitude > 0.01 then
		cameraPos += wheelDollyVelocity * dt
		wheelDollyVelocity *= math.exp(-dt / WHEEL_ZOOM_TAU)
	else
		wheelDollyVelocity = Vector3.zero
	end
	-- Touch drag-and-release momentum: glide the post-release throw and decay it. A live grab
	-- (touchPanActive) drives cameraPos directly, so the throw is held at zero until release.
	if touchPanActive or touchThrowVelocity.Magnitude <= 0.01 then
		touchThrowVelocity = Vector3.zero
	else
		cameraPos += touchThrowVelocity * dt
		touchThrowVelocity *= math.exp(-dt / TOUCH_THROW_TAU)
	end
	local bounded = BuildViewCamera.softBounds(cameraPos, base.CFrame, base.Size, isMobileDevice(), yaw, viewPitch)
	cameraPos = cameraPos:Lerp(bounded, 1 - math.exp(-dt / BOUNDS_TAU))
	cam.CFrame = BuildViewCamera.toCFrame(cameraPos, base.CFrame, yaw, viewPitch)
end

-- Orbit the view by (dYaw, dPitch) radians while keeping the current focus point centered,
-- so rotating spins around what you're looking at instead of swinging it off-screen.
local function applyOrbit(base, dYaw, dPitch)
	if dYaw == 0 and dPitch == 0 then
		return
	end
	local focus = BuildViewCamera.focusPoint(cameraPos, base.CFrame, base.Size, yaw, viewPitch)
	local distance = focus and (cameraPos - focus).Magnitude or 120
	if not focus then
		-- No ground hit (extreme tilt): fall back to orbiting the plot center.
		focus = base.CFrame.Position + Vector3.new(0, base.Size.Y / 2, 0)
	end
	yaw = yaw + dYaw
	viewPitch = math.clamp(viewPitch + dPitch, MIN_PITCH, MAX_PITCH)
	local lookDir = BuildViewCamera.lookDirection(base.CFrame, yaw, viewPitch)
	cameraPos = focus - lookDir * distance
end

-- Optional on-screen height buttons (touch) + their container, authored in Studio. The
-- container is hidden outside build mode; buttons drive heightHoldDir while held.
local buildControls = screenGui:FindFirstChild(GuiNames.BuildControls)
local buildControlsUp = buildControls and buildControls:FindFirstChild("Up")
local buildControlsDown = buildControls and buildControls:FindFirstChild("Down")
local buildControlsRequested = false
if buildControls then
	buildControls.Visible = false
end

local function setBuildControlsVisible(visible)
	buildControlsRequested = visible == true
	if buildControls then
		buildControls.Visible = buildControlsRequested
			and screenGui:GetAttribute(Attrs.CompactModalActive) ~= true
	end
end
screenGui:GetAttributeChangedSignal(Attrs.CompactModalActive):Connect(function()
	setBuildControlsVisible(buildControlsRequested)
end)

local function bindHeightButton(button, dir)
	if not button or not button:IsA("GuiButton") then
		return
	end
	button.MouseButton1Down:Connect(function()
		heightHoldDir = dir
	end)
	local function release()
		if heightHoldDir == dir then
			heightHoldDir = 0
		end
	end
	button.MouseButton1Up:Connect(release)
	button.MouseLeave:Connect(release)
end
bindHeightButton(buildControlsUp, 1)
bindHeightButton(buildControlsDown, -1)


local function enterBuildView()
	if buildViewActive then
		return
	end
	if player:GetAttribute(Attrs.MixerUnlocked) ~= true then
		return
	end
	local base = getBasePart()
	local camera = Workspace.CurrentCamera
	if not base or not camera then
		return
	end
	buildViewActive = true
	transitionToken += 1
	local token = transitionToken
	-- Entering counts as "answered": hide the nudge and suppress it this session.
	buildNudge.onEnterBuildView()
	-- Pin the avatar so movement input drives the camera, not the character.
	table.clear(heldKeys)
	heightHoldDir = 0
	touchPanActive = false
	touchPanGrabPoint = nil
	touchThrowVelocity = Vector3.zero
	table.clear(touchPanSamples)
	activeTouchCount = 0
	multiTouchLatched = false
	velocity = Vector3.zero
	wheelDollyVelocity = Vector3.zero
	setMiddleMouseDragging(false)
	middleMouseGrabPoint = nil
	table.clear(touchesStartedOnUi)
	placementDragInput = nil
	placementDragPosition = nil

	setCharacterControlsEnabled(false)

	cancelActiveCameraTween()
	-- Capture the camera to restore on exit ONLY from a real default camera. If it's
	-- already Scriptable we're re-entering mid-exit (button spam) — keep the snapshot we
	-- took the first time so we still restore to the genuine follow camera, never to a
	-- frozen diagonal mid-transition pose.
	if camera.CameraType ~= Enum.CameraType.Scriptable or not savedCameraValid then
		savedCameraType = camera.CameraType
		savedCameraCFrame = camera.CFrame
		savedCameraFieldOfView = camera.FieldOfView
		savedCameraSubject = camera.CameraSubject
		savedCameraValid = camera.CameraType ~= Enum.CameraType.Scriptable
	end

	if lastBuildViewPose then
		yaw = lastBuildViewPose.yaw or 0
		viewPitch = math.clamp(lastBuildViewPose.pitch or math.rad(BuildViewCamera.PITCH_DEGREES),
			MIN_PITCH, MAX_PITCH)
		cameraPos = BuildViewCamera.softBounds(
			lastBuildViewPose.position,
			base.CFrame,
			base.Size,
			isMobileDevice(),
			yaw,
			viewPitch
		)
	else
		yaw = 0
		viewPitch = math.rad(BuildViewCamera.PITCH_DEGREES)
		cameraPos = BuildViewCamera.framePose(
			base.CFrame,
			base.Size,
			camera.ViewportSize,
			isMobileDevice(),
			nil,
			yaw,
			viewPitch
		)
	end
	cameraReady = false
	camera.CameraType = Enum.CameraType.Scriptable
	camera.FieldOfView = BuildViewCamera.DEFAULT_FOV

	-- Fly in from the avatar view to the framed build pose, then hand off to the
	-- per-frame momentum loop (gated on cameraReady so the intro tween reads cleanly).
	activeCameraTween = TweenService:Create(camera, ENTER_TWEEN, {
		CFrame = BuildViewCamera.toCFrame(cameraPos, base.CFrame, yaw, viewPitch),
	})
	activeCameraTween.Completed:Once(function()
		if token == transitionToken then
			cameraReady = true
		end
	end)
	activeCameraTween:Play()

	if frameConnection then
		frameConnection:Disconnect()
	end
	frameConnection = RunService.RenderStepped:Connect(stepCamera)

	screenGui:SetAttribute(Attrs.BuildModeActive, true)
	-- Only pull the store band up with build mode when the player opted into the coupling
	-- (AutoBuildMode). PC default (toggle off) keeps V as a pure fly camera with no store; mobile
	-- (toggle on) and any opt-in player still get the band while building. (Mixer-unlock gate above
	-- already guards this entry. StoreVisibilityController also gates the band on this, but it keys
	-- off StoreOpen here, so the toggle must be respected at the source too.)
	if screenGui:GetAttribute(Attrs.AutoBuildMode) == true then
		screenGui:SetAttribute(Attrs.StoreOpen, true)
	end
	setBuildControlsVisible(true)
end

local function exitBuildView()
	if not buildViewActive then
		return
	end
	local wasCameraReady = cameraReady
	buildViewActive = false
	cameraReady = false
	transitionToken += 1
	local token = transitionToken
	if wasCameraReady then
		lastBuildViewPose = {
			position = cameraPos,
			yaw = yaw,
			pitch = viewPitch,
		}
	end
	-- Hand movement back to the avatar.
	table.clear(heldKeys)
	heightHoldDir = 0
	touchPanActive = false
	touchPanGrabPoint = nil
	touchThrowVelocity = Vector3.zero
	table.clear(touchPanSamples)
	activeTouchCount = 0
	multiTouchLatched = false
	velocity = Vector3.zero
	wheelDollyVelocity = Vector3.zero
	table.clear(touchesStartedOnUi)
	placementDragInput = nil
	placementDragPosition = nil
	setRightDragging(false)
	setMiddleMouseDragging(false)
	middleMouseGrabPoint = nil
	setCharacterControlsEnabled(true)

	if frameConnection then
		frameConnection:Disconnect()
		frameConnection = nil
	end

	local camera = Workspace.CurrentCamera
	cancelActiveCameraTween()
	if camera and savedCameraCFrame then
		-- Tween back to the saved framing, then hand control back to the default
		-- camera so the restore reads smoothly rather than snapping. Never restore into
		-- Scriptable (that would leave the camera frozen), so fall back to Custom.
		local restoreType = (savedCameraType and savedCameraType ~= Enum.CameraType.Scriptable)
			and savedCameraType
			or Enum.CameraType.Custom
		local restoreSubject = savedCameraSubject
		local tween = TweenService:Create(camera, EXIT_TWEEN, {
			CFrame = savedCameraCFrame,
			FieldOfView = savedCameraFieldOfView or 70,
		})
		activeCameraTween = tween
		tween.Completed:Connect(function()
			-- Ignore if a newer transition has superseded this one (e.g. the player
			-- re-entered Build View mid-exit), so a stale handoff can't fire.
			if token ~= transitionToken then
				return
			end
			if activeCameraTween == tween then
				activeCameraTween = nil
			end
			savedCameraValid = false
			camera.CameraType = restoreType
			if restoreSubject then
				camera.CameraSubject = restoreSubject
			end
		end)
		tween:Play()
	end

	screenGui:SetAttribute(Attrs.BuildModeActive, false)
	setBuildControlsVisible(false)
	-- In coupled (AutoBuildMode) mode the store and build move together, so leaving build also
	-- closes the band. Otherwise the band stays open for browsing; the player closes it via B.
	if screenGui:GetAttribute(Attrs.AutoBuildMode) == true then
		screenGui:SetAttribute(Attrs.StoreOpen, false)
	end
end

local function toggleBuildView()
	if screenGui:GetAttribute(Attrs.CompactModalActive) == true then
		return
	end
	if buildViewActive then
		exitBuildView()
	elseif player:GetAttribute(Attrs.MixerUnlocked) == true then
		enterBuildView()
	end
end
screenGui:GetAttributeChangedSignal(Attrs.CompactModalActive):Connect(function()
	if screenGui:GetAttribute(Attrs.CompactModalActive) == true then
		exitBuildView()
	end
end)

-- Compose the build-title reveal and first-placement nudge as ctx modules (StoreController-
-- style). They own their UI bindings + state; this orchestrator keeps the camera/input
-- lifecycle. The store open/close cookie + its animation now live in StoreToggleController.
local ctx = {
	player = player,
	screenGui = screenGui,
	store = store,
	toggleBuildView = toggleBuildView,
	enterBuildView = enterBuildView,
	isBuildViewActive = function()
		return buildViewActive
	end,
}
require(script.Parent.BuildTitleReveal).new(ctx)
buildNudge = require(script.Parent.BuildSuggestionNudge).new(ctx)

-- AutoBuildMode coupling — the single owner of the store<->build link. Both directions are gated
-- on the toggle: when coupled, opening the store enters build and closing it exits build (they move
-- together). When decoupled (AutoBuildMode off, PC default) the store and the fly camera are
-- independent — closing the store via B must NOT kick the player out of build/fly, and opening it
-- must not force build on. (StoreToggleController owns StoreOpen; V owns build directly.)
screenGui:GetAttributeChangedSignal(Attrs.StoreOpen):Connect(function()
	if screenGui:GetAttribute(Attrs.AutoBuildMode) ~= true then
		return
	end
	local open = screenGui:GetAttribute(Attrs.StoreOpen) == true
	if open then
		enterBuildView()
	elseif buildViewActive then
		exitBuildView()
	end
end)

local function refreshMixerLock()
	local unlocked = player:GetAttribute(Attrs.MixerUnlocked) == true
	if not unlocked and buildViewActive then
		exitBuildView()
	end
end
player:GetAttributeChangedSignal(Attrs.MixerUnlocked):Connect(refreshMixerLock)
refreshMixerLock()

-- Topbar build toggle: the button that enters/exits build mode (the mobile equivalent of the
-- V key, and a PC affordance too). It prefers PlayerGui.TopbarHudGui.BuildModeFrame, a separate
-- Studio-authored ScreenGui whose position is driven by GuiService.TopbarInset so Roblox's
-- dynamic top-left controls decide its horizontal start. Fall back to the old ScreenGui/store-
-- nested locations while Studio places catch up. BuildModeButtonAnimator keeps the click target
-- on the outer frame and mirrors BuildModeActive onto its Active attribute so every input path
-- gets the same visual feedback.
local topBar = store and store:FindFirstChild("TopBar")
local topbarHudGui = playerGui:FindFirstChild(GuiNames.TopbarHudGui)
if not topbarHudGui then
	topbarHudGui = playerGui:WaitForChild(GuiNames.TopbarHudGui, 3)
end
local buildModeButton = (topbarHudGui and topbarHudGui:FindFirstChild(GuiNames.BuildModeFrame))
	or (topbarHudGui and topbarHudGui:FindFirstChild(GuiNames.BuildModeButton))
	or screenGui:FindFirstChild(GuiNames.BuildModeFrame)
	or (topBar and topBar:FindFirstChild(GuiNames.BuildModeFrame))
	or (store and store:FindFirstChild(GuiNames.BuildModeFrame, true))
	or screenGui:FindFirstChild(GuiNames.BuildModeButton)
	or (topBar and topBar:FindFirstChild(GuiNames.BuildModeButton))
	or (store and store:FindFirstChild(GuiNames.BuildModeButton, true))
	or screenGui:FindFirstChild(GuiNames.BuildModeFrame, true)
if
	topbarHudGui
	and buildModeButton
	and buildModeButton:IsA("GuiObject")
	and buildModeButton:IsDescendantOf(topbarHudGui)
then
	BuildModeTopbarPosition.bind(buildModeButton)
	local authoredBuildModeButtonVisible = buildModeButton.Visible
	local function updateCompactModalVisibility()
		buildModeButton.Visible = authoredBuildModeButtonVisible
			and screenGui:GetAttribute(Attrs.CompactModalActive) ~= true
	end
	screenGui:GetAttributeChangedSignal(Attrs.CompactModalActive):Connect(updateCompactModalVisibility)
	updateCompactModalVisibility()
end
local buildModeButtonAnimator = BuildModeButtonAnimator.new(buildModeButton)
local buildModeButtonHit = buildModeButtonAnimator and buildModeButtonAnimator.hitbox
if not buildModeButtonHit then
	buildModeButtonHit = buildModeButton and (buildModeButton:FindFirstChild("hitbox") or buildModeButton)
end
if buildModeButtonHit and buildModeButtonHit:IsA("GuiButton") then
	buildModeButtonHit.Activated:Connect(toggleBuildView)
end
local function reflectBuildModeButton()
	local active = screenGui:GetAttribute(Attrs.BuildModeActive) == true
	if buildModeButtonAnimator then
		buildModeButtonAnimator.setActive(active)
	else
		if buildModeButton and buildModeButton:IsA("GuiObject") then
			buildModeButton:SetAttribute(Attrs.Active, active)
		end
		if buildModeButtonHit and buildModeButtonHit ~= buildModeButton then
			buildModeButtonHit:SetAttribute(Attrs.Active, active)
		end
	end
end
screenGui:GetAttributeChangedSignal(Attrs.BuildModeActive):Connect(reflectBuildModeButton)
reflectBuildModeButton()


screenGui:GetAttributeChangedSignal(Attrs.PlacementActive):Connect(function()
	local active = screenGui:GetAttribute(Attrs.PlacementActive) == true
	if active then
		buildNudge.maybeShow()
	else
		buildNudge.hide()
		placementDragInput = nil
		placementDragPosition = nil
	end
end)

-- ---------------------------------------------------------------------------------
-- Fly input — only while Build View is active.
--   * One-finger touch drag pans by grabbing the world point under the finger and holding it
--     there, the touch twin of the PC middle-mouse pan. Releasing mid-flick throws the camera
--     with decaying momentum; releasing a stopped drag (or a tap) parks it. While a
--     building IS being placed (StorePlacement's "PlacementActive" attribute) the single
--     finger belongs to placement, so panning needs the camera unoccupied.
--   * Two fingers pinch to zoom (toward the pinch focus) and twist to rotate the view; they
--     never also pan, and the finger left behind when you lift one is ignored until ALL
--     fingers lift, so releasing a pinch/twist can't jolt the camera.
--   * Three-finger vertical drag tilts the camera pitch on mobile.
--   * Mouse wheel dollies along the view direction on PC.
--   * WASD/arrows glide, Q/E fly up/down (default character controls are disabled while
--     active). On-screen Up/Down buttons cover height on touch.
-- ---------------------------------------------------------------------------------
;(function()
local pinchStart = nil
local twistStartYaw = nil
local twistStartRotation = nil
local threeFingerPitchStart = nil
-- Touch-point count the pinch/twist were last anchored against. Roblox reports pinch `scale`
-- and `rotation` cumulatively from the gesture start, so when the finger SET changes mid-gesture
-- (a finger lifts/lands, or the digitizer drops one for a frame) the baseline jumps. Re-anchor
-- whenever the count changes so each stable finger pair starts fresh instead of snapping.
local pinchAnchorCount = nil
local twistAnchorCount = nil

local function clearTouchCameraGesture()
	touchPanActive = false
	touchPanGrabPoint = nil
	touchThrowVelocity = Vector3.zero
	table.clear(touchPanSamples)
	pinchStart = nil
	twistStartYaw = nil
	twistStartRotation = nil
	threeFingerPitchStart = nil
end

local function hasUiStartedTouch()
	return next(touchesStartedOnUi) ~= nil
end

local function screenPositionToBasePlanePoint(base, screenPosition)
	local cam = Workspace.CurrentCamera
	if not cam or not base or not screenPosition then
		return nil
	end
	local ray = cam:ScreenPointToRay(screenPosition.X, screenPosition.Y)
	local planeY = base.CFrame.Position.Y + base.Size.Y / 2
	local direction = ray.Direction
	if math.abs(direction.Y) < 1e-6 then
		return nil
	end
	local t = (planeY - ray.Origin.Y) / direction.Y
	if t <= 0 then
		return nil
	end
	return ray.Origin + direction * t
end

-- Fling velocity (px/s) from the per-frame samples spanning the velocity window at release, or
-- nil if too few samples / no time elapsed. The oldest-to-newest displacement over the window is
-- an average that ignores per-frame jitter; a finger held still produces same-position samples
-- (~0 velocity -> park), and the lift-off twitch is never sampled (it lands between frames).
local function computeTouchFlingVelocity()
	-- Drop samples older than the window relative to NOW, so a pan that ended a moment ago (say,
	-- just before a pinch) leaves nothing fresh and won't fling -- only motion right up to the
	-- release counts.
	local now = os.clock()
	while #touchPanSamples > 0 and (now - touchPanSamples[1].t) > TOUCH_VELOCITY_WINDOW do
		table.remove(touchPanSamples, 1)
	end
	if #touchPanSamples < 2 then
		return nil
	end
	local oldest = touchPanSamples[1]
	local newest = touchPanSamples[#touchPanSamples]
	local dt = newest.t - oldest.t
	if dt <= 1e-4 then
		return nil
	end
	return Vector2.new((newest.x - oldest.x) / dt, (newest.y - oldest.y) / dt)
end

-- Convert a touch-pan pixel velocity (px/s) into a world glide velocity (studs/s) in the plot
-- plane, matching the grab-pan direction. Used only to seed the release "throw"; the live drag
-- itself is grab-driven, not velocity-driven.
local function touchPixelsToWorldVelocity(base, pixels)
	local cam = Workspace.CurrentCamera
	if not cam then
		return Vector3.zero
	end
	local focus = BuildViewCamera.focusPoint(cameraPos, base.CFrame, base.Size, yaw, viewPitch)
	local distance = focus and (cameraPos - focus).Magnitude
		or math.max(1, cameraPos.Y - base.CFrame.Position.Y)
	local viewportY = math.max(1, cam.ViewportSize.Y)
	local studsPerPixel = (2 * distance * math.tan(math.rad(BuildViewCamera.DEFAULT_FOV / 2))) / viewportY
	local forward, right = BuildViewCamera.movementBasis(base.CFrame, yaw)
	return right * (-pixels.X * studsPerPixel) + forward * (pixels.Y * studsPerPixel)
end

UserInputService.TouchPan:Connect(function(touchPositions, totalTranslation, _panVelocity, state, _gameProcessed)
	if not buildViewActive then
		clearTouchCameraGesture()
		return
	end
	-- Ownership is decided once, by where the gesture STARTED. If any active finger began on a
	-- UI element, leave the whole gesture to the GUI. Otherwise it's a camera gesture and we
	-- keep driving it even as the finger travels over UI -- it can't activate that UI, since
	-- the press began off it. (Current finger position / gameProcessed are deliberately ignored
	-- so a pan that drifts onto UI on a small screen is never cancelled.)
	if hasUiStartedTouch() then
		clearTouchCameraGesture()
		return
	end
	-- Handle release FIRST, before any multi-finger guard below. Touch digitizers routinely
	-- report a transient second contact as a finger lifts, which sets multiTouchLatched and would
	-- otherwise route the End through the pinch/placement guard and swallow the fling (a race the
	-- mouse never triggers -- hence "works in Studio, not on phone"). The fling is gated on FRESH
	-- pan samples (computeTouchFlingVelocity trims to the velocity window), so a real pinch/three-
	-- finger end -- which left no recent one-finger samples -- still won't fling.
	if state == Enum.UserInputState.End or state == Enum.UserInputState.Cancel then
		touchPanActive = false
		touchPanGrabPoint = nil
		threeFingerPitchStart = nil
		velocity = Vector3.zero
		if state == Enum.UserInputState.End then
			-- Sample the release position too, so even a flick of just a couple events has the two
			-- samples needed to measure velocity, with the newest sample exactly at release time.
			if touchPositions[1] then
				pushTouchPanSample(touchPositions[1].X, touchPositions[1].Y)
			end
			local fling = computeTouchFlingVelocity()
			if fling and fling.Magnitude > MIN_FLING_PX_PER_SEC then
				local base = getBasePart()
				if base then
					touchThrowVelocity = touchPixelsToWorldVelocity(base, fling)
				end
			end
		end
		table.clear(touchPanSamples)
		return
	end
	if threeFingerPitchStart and (state == Enum.UserInputState.End
		or state == Enum.UserInputState.Cancel
		or #touchPositions < 3)
	then
		threeFingerPitchStart = nil
		touchPanActive = false
		return
	end
	if #touchPositions >= 3 then
		touchPanActive = false
		touchPanGrabPoint = nil
		local base = getBasePart()
		if not base then
			return
		end
		if state == Enum.UserInputState.Begin or not threeFingerPitchStart then
			threeFingerPitchStart = {
				pitch = viewPitch,
				translationY = totalTranslation.Y,
			}
		end
		local targetPitch = math.clamp(
			threeFingerPitchStart.pitch + (totalTranslation.Y - threeFingerPitchStart.translationY) * PITCH_DRAG_SENSITIVITY,
			MIN_PITCH,
			MAX_PITCH
		)
		applyOrbit(base, 0, targetPitch - viewPitch)
		return
	end
	-- Two fingers are pinch (zoom) + twist (rotate), handled in their own signals; TouchPan
	-- does nothing for them so a two-finger drag never also pans. (Release is already handled
	-- above, so only Begin/Change reach here.)
	if #touchPositions ~= 1 then
		touchPanActive = false
		touchPanGrabPoint = nil
		return
	end
	-- The single finger belongs to placement while a building is being placed, and the finger
	-- left behind after a pinch/twist must be ignored until ALL fingers lift.
	if isPlacementActive() or multiTouchLatched then
		touchPanActive = false
		touchPanGrabPoint = nil
		return
	end
	local base = getBasePart()
	if not base then
		return
	end
	-- Grab-the-world pan: pin the world point first touched and shift the camera each move so
	-- it stays under the finger, exactly like the PC middle-mouse pan (the release adds the
	-- throw, handled above). The first
	-- event only captures the grab point; subsequent events do the drag.
	local anchor = touchPositions[1]
	if not touchPanGrabPoint then
		touchPanGrabPoint = screenPositionToBasePlanePoint(base, anchor)
		touchPanActive = touchPanGrabPoint ~= nil
		-- Fresh grab: reset the velocity tracker and seed it with this first finger position.
		table.clear(touchPanSamples)
		pushTouchPanSample(anchor.X, anchor.Y)
		return
	end
	local currentPoint = screenPositionToBasePlanePoint(base, anchor)
	if currentPoint then
		cameraPos += touchPanGrabPoint - currentPoint
		velocity = Vector3.zero
		wheelDollyVelocity = Vector3.zero
		-- Feed the velocity tracker on each move event for the release-fling measurement.
		pushTouchPanSample(anchor.X, anchor.Y)
		local cam = Workspace.CurrentCamera
		if cam then
			cam.CFrame = BuildViewCamera.toCFrame(cameraPos, base.CFrame, yaw, viewPitch)
		end
	end
	touchPanActive = true
end)

-- TouchPinch reports `scale` CUMULATIVELY relative to the gesture's start, so we anchor
-- the dolly distance/focus captured when the pinch began rather than compounding per
-- event. Pinch out (scale > 1) zooms in. PINCH_SENSITIVITY < 1 softens the response.
UserInputService.TouchPinch:Connect(function(touchPositions, scale, _pinchVelocity, state, _gameProcessed)
	if not buildViewActive then
		clearTouchCameraGesture()
		return
	end
	if state == Enum.UserInputState.End or state == Enum.UserInputState.Cancel then
		pinchStart = nil
		return
	end
	if #touchPositions >= 3 then
		pinchStart = nil
		return
	end
	-- Owned by gesture start (see TouchPan): block only if a finger began on UI.
	if hasUiStartedTouch() then
		clearTouchCameraGesture()
		return
	end
	if not scale or scale <= 0 then
		return
	end
	local base = getBasePart()
	if not base then
		return
	end
	local focus = BuildViewCamera.focusPoint(cameraPos, base.CFrame, base.Size, yaw, viewPitch)
	if not focus then
		return
	end
	if state == Enum.UserInputState.Begin or not pinchStart or pinchAnchorCount ~= #touchPositions then
		pinchStart = { scale = scale, distance = (cameraPos - focus).Magnitude, focus = focus }
		pinchAnchorCount = #touchPositions
	end
	local relative = scale / pinchStart.scale
	local effective = relative ^ PINCH_SENSITIVITY
	local newDistance = math.clamp(pinchStart.distance / effective,
		BuildViewCamera.MIN_DISTANCE, BuildViewCamera.MAX_DISTANCE)
	cameraPos = pinchStart.focus - BuildViewCamera.lookDirection(base.CFrame, yaw, viewPitch) * newDistance
end)

-- Two-finger twist (mobile) rotates the view yaw, orbiting the focus. Roblox reports
-- `rotation` cumulatively from the gesture start (like pinch scale), so anchor to the yaw
-- captured when the twist began and drive the delta from there.
UserInputService.TouchRotate:Connect(function(touchPositions, rotation, _rotateVelocity, state, _gameProcessed)
	if not buildViewActive then
		clearTouchCameraGesture()
		return
	end
	-- Owned by gesture start (see TouchPan): block only if a finger began on UI.
	if hasUiStartedTouch() then
		clearTouchCameraGesture()
		return
	end
	if state == Enum.UserInputState.End or state == Enum.UserInputState.Cancel then
		twistStartYaw = nil
		return
	end
	if #touchPositions >= 3 then
		twistStartYaw = nil
		twistStartRotation = nil
		return
	end
	local base = getBasePart()
	if not base then
		return
	end
	if state == Enum.UserInputState.Begin or not twistStartYaw or twistAnchorCount ~= #touchPositions then
		twistStartYaw = yaw
		twistStartRotation = rotation
		twistAnchorCount = #touchPositions
	end
	-- Roblox reports touch rotation in radians; twisting fingers clockwise should swing
	-- the view with them.
	local targetYaw = twistStartYaw + (rotation - twistStartRotation)
	applyOrbit(base, targetYaw - yaw, 0)
end)

UserInputService.InputChanged:Connect(function(input, gameProcessed)
	if not buildViewActive then
		return
	end
	if placementDragInput == input and input.UserInputType == Enum.UserInputType.Touch then
		placementDragPosition = Vector2.new(input.Position.X, input.Position.Y)
	elseif placementDragInput == "mouse" and input.UserInputType == Enum.UserInputType.MouseMovement then
		placementDragPosition = UserInputService:GetMouseLocation()
	end
	if input.UserInputType == Enum.UserInputType.MouseWheel then
		-- Don't steal the wheel from a scrolling UI (shop list, settings modal).
		if gameProcessed or isCameraInputPositionBlocked(UserInputService:GetMouseLocation()) then
			return
		end
		local base = getBasePart()
		if not base then
			return
		end
		-- Studio-style dolly: wheel up moves in the direction the camera faces; wheel
		-- down backs away along the opposite direction. Height remains on Q/E/Shift/Space.
		local lookDir = BuildViewCamera.lookDirection(base.CFrame, yaw, viewPitch)
		wheelDollyVelocity += lookDir * ((input.Position.Z * WHEEL_DOLLY_STEP) / WHEEL_ZOOM_TAU)
	elseif middleMouseDragging and input.UserInputType == Enum.UserInputType.MouseMovement then
		local base = getBasePart()
		local cursorPoint = base and screenPositionToBasePlanePoint(base, UserInputService:GetMouseLocation())
		if cursorPoint and middleMouseGrabPoint then
			cameraPos += middleMouseGrabPoint - cursorPoint
			velocity = Vector3.zero
			wheelDollyVelocity = Vector3.zero
			local cam = Workspace.CurrentCamera
			if cam then
				cam.CFrame = BuildViewCamera.toCFrame(cameraPos, base.CFrame, yaw, viewPitch)
			end
		elseif cursorPoint then
			middleMouseGrabPoint = cursorPoint
		end
	elseif rightDragging and input.UserInputType == Enum.UserInputType.MouseMovement then
		local base = getBasePart()
		if base then
			-- Drag left looks left, drag right looks right; drag up tilts toward top-down.
			applyOrbit(base, -input.Delta.X * YAW_DRAG_SENSITIVITY, input.Delta.Y * PITCH_DRAG_SENSITIVITY)
		end
	end
end)

-- Keyboard: V toggles build mode, Escape exits (only consumes when active so it never steals
-- Escape from menus / placement cancel). B opens/closes the store band (handled in
-- StoreToggleController). WASD/arrows/QE latch while active.
UserInputService.InputBegan:Connect(function(input, gameProcessed)
	local isPointerPress = input.UserInputType == Enum.UserInputType.Touch
		or input.UserInputType == Enum.UserInputType.MouseButton1
		or input.UserInputType == Enum.UserInputType.MouseButton3
	if input.UserInputType == Enum.UserInputType.Touch then
		activeTouchCount += 1
		-- Touching the screen halts any release glide in progress (tap-to-stop, like scrolling).
		touchThrowVelocity = Vector3.zero
		if activeTouchCount >= 2 then
			-- A second finger landed: we're now in a pinch/twist/tilt. Abandon any one-finger
			-- pan and latch until every finger lifts so the leftover finger can't restart one.
			multiTouchLatched = true
			touchPanActive = false
			touchPanGrabPoint = nil
		end
	end
	local startsOnUi = isPointerPress and isCameraInputPositionBlocked(input.Position)
	if input.UserInputType == Enum.UserInputType.Touch and startsOnUi then
		touchesStartedOnUi[input] = true
		clearTouchCameraGesture()
	end
	if gameProcessed then
		return
	end
	if buildViewActive and isPlacementActive() and not startsOnUi then
		if input.UserInputType == Enum.UserInputType.Touch then
			placementDragInput = input
			placementDragPosition = Vector2.new(input.Position.X, input.Position.Y)
		elseif input.UserInputType == Enum.UserInputType.MouseButton1 then
			placementDragInput = "mouse"
			placementDragPosition = UserInputService:GetMouseLocation()
		end
	end
	if input.KeyCode == Enum.KeyCode.V then
		toggleBuildView()
		return
	elseif input.KeyCode == Enum.KeyCode.Escape and buildViewActive then
		exitBuildView()
		return
	end
	if buildViewActive and input.UserInputType == Enum.UserInputType.MouseButton2 then
		setRightDragging(true)
		return
	end
	if buildViewActive and input.UserInputType == Enum.UserInputType.MouseButton3 and not startsOnUi then
		local base = getBasePart()
		local grabPoint = base and screenPositionToBasePlanePoint(base, UserInputService:GetMouseLocation())
		if grabPoint then
			middleMouseGrabPoint = grabPoint
			setMiddleMouseDragging(true)
			velocity = Vector3.zero
			wheelDollyVelocity = Vector3.zero
		end
		return
	end
	if buildViewActive and isMoveKey(input.KeyCode) then
		heldKeys[input.KeyCode] = true
	end
end)

-- Always release on key-up / button-up (no gameProcessed gate) so nothing gets stuck held.
UserInputService.InputEnded:Connect(function(input)
	if input.UserInputType == Enum.UserInputType.Touch then
		activeTouchCount = math.max(0, activeTouchCount - 1)
		if activeTouchCount == 0 then
			-- Every finger is up: drop the multi-touch latch and any leftover pan grab so the
			-- next fresh one-finger touch starts a clean grab-pan.
			multiTouchLatched = false
			touchPanActive = false
			touchPanGrabPoint = nil
		end
		touchesStartedOnUi[input] = nil
		if placementDragInput == input then
			placementDragInput = nil
			placementDragPosition = nil
		end
		if not hasUiStartedTouch() then
			pinchStart = nil
			twistStartYaw = nil
			twistStartRotation = nil
			threeFingerPitchStart = nil
		end
	end
	if input.UserInputType == Enum.UserInputType.MouseButton1 and placementDragInput == "mouse" then
		placementDragInput = nil
		placementDragPosition = nil
	end
	if isMoveKey(input.KeyCode) then
		heldKeys[input.KeyCode] = nil
	end
	if input.UserInputType == Enum.UserInputType.MouseButton2 then
		setRightDragging(false)
	end
	if input.UserInputType == Enum.UserInputType.MouseButton3 then
		setMiddleMouseDragging(false)
	end
end)
end)()
