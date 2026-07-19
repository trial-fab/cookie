-- BuildViewController: shared orchestrator for the free-fly "Build View" placement
-- camera. This script owns enter/exit, framing, terrain bounds, and store/build coupling;
-- BuildViewDesktopCamera and BuildViewMobileCamera independently own device input and
-- motion. Two sibling UI ctx modules own the rest:
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
local FloorConfig = require(shared:WaitForChild("FloorConfig"))
local FloorGeometry = require(shared:WaitForChild("FloorGeometry"))
local Attrs = require(shared:WaitForChild("Attrs"))
local GuiNames = require(shared:WaitForChild("GuiNames"))
local StoreShell = require(shared:WaitForChild("StoreShell"))
local BuildModeButtonAnimator = require(script.Parent:WaitForChild("BuildModeButtonAnimator"))
local BuildModeTopbarPosition = require(script.Parent:WaitForChild("BuildModeTopbarPosition"))
local BuildViewDesktopCamera = require(script.Parent:WaitForChild("BuildViewDesktopCamera"))
local BuildViewMobileCamera = require(script.Parent:WaitForChild("BuildViewMobileCamera"))

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
	if
		(object:IsA("TextLabel") or object:IsA("TextButton") or object:IsA("TextBox"))
		and object.Text ~= ""
		and object.TextTransparency < 1
	then
		return true
	end
	if
		(object:IsA("ImageLabel") or object:IsA("ImageButton"))
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

-- Shared lifecycle state. Device-specific input/motion lives in one selected driver.
local cameraPos = Vector3.zero
local yaw = 0
local viewPitch = math.rad(BuildViewCamera.PITCH_DEGREES)
local frameConnection = nil
local cameraReady = false
local lastBuildViewPose = nil
local cameraDriver = nil

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

-- Unlocked build surfaces (Ground + authored unlocked floors) that define the fly
-- bounds. The PART list is cached because resolving it walks the sheet tree; it is
-- invalidated on floor unlock/relock (UnlockedFloorCount covers purchases AND stat
-- resets, which collapse the bounds back to the single plot) and whenever a cached part
-- leaves the Workspace (sheet rebuild). Geometry is re-read from the live parts every
-- frame so the bounds track a floor mid-reveal.
local flySurfaceParts = nil
-- Include-list RaycastParams for the terrain probe below; rebuilt with the surface cache.
local terrainProbeParams = nil

local function refreshFlySurfaces()
	flySurfaceParts = nil
	terrainProbeParams = nil
end

local function getFlySurfaces(base)
	if flySurfaceParts then
		for _, part in ipairs(flySurfaceParts) do
			if not part:IsDescendantOf(Workspace) then
				refreshFlySurfaces()
				break
			end
		end
	end
	if not flySurfaceParts then
		local unlockedCount = math.clamp(
			math.floor(tonumber(player:GetAttribute(Attrs.UnlockedFloorCount)) or 0),
			0,
			FloorConfig.UnlockableFloorCount
		)
		local parts = {}
		for _, surface in ipairs(FloorGeometry.GetUnlockedSurfaces(getPlayerSheet(), unlockedCount)) do
			if surface.boundsPart then
				table.insert(parts, surface.boundsPart)
			end
		end
		flySurfaceParts = parts
	end
	local surfaces = {}
	for _, part in ipairs(flySurfaceParts) do
		table.insert(surfaces, { cframe = part.CFrame, size = part.Size })
	end
	if #surfaces == 0 then
		-- No resolvable sheet surfaces (e.g. mid-join): fall back to the caller's Base so
		-- the camera always has at least the one-plot bounds.
		table.insert(surfaces, { cframe = base.CFrame, size = base.Size })
	end
	return surfaces
end

player:GetAttributeChangedSignal(Attrs.UnlockedFloorCount):Connect(refreshFlySurfaces)

-- Terrain probe for the camera's bottom lock: the topmost MAP surface directly beneath
-- the camera. Only static map geometry counts -- the plot surfaces, the terraces/crater
-- (including locked gates), and the world ground; placed buildings, the Cookie, and
-- props are deliberately excluded so the camera can still glide between them. Probing
-- real geometry makes the camera "collide" with the world: flying into a terrace wall
-- trails it up the wall face onto the new floor level (the bounds spring does the
-- easing) instead of popping at an invisible footprint edge.
local TERRAIN_PROBE_RISE = 600 -- cast origin this far above the plot top (above any terrace)
local TERRAIN_PROBE_DEPTH = 800 -- ray length; reaches well below the plot surface

local function getTerrainProbeParams()
	if terrainProbeParams then
		return terrainProbeParams
	end
	local include = {}
	local sheet = getPlayerSheet()
	if sheet then
		for _, name in ipairs({ "Base", "Edge", "Center", "Floors" }) do
			local instance = sheet:FindFirstChild(name)
			if instance then
				table.insert(include, instance)
			end
		end
	end
	for _, name in ipairs({ "CraterTerraces", "Baseplate" }) do
		local instance = Workspace:FindFirstChild(name)
		if instance then
			table.insert(include, instance)
		end
	end
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Include
	params.FilterDescendantsInstances = include
	terrainProbeParams = params
	return params
end

-- World Y of the map surface under `position`, or nil when nothing is there (softBounds
-- then falls back to the Ground top).
local function getSupportTopY(position, base)
	local baseTopY = base.Position.Y + base.Size.Y / 2
	local origin = Vector3.new(position.X, baseTopY + TERRAIN_PROBE_RISE, position.Z)
	local result = Workspace:Raycast(origin, Vector3.new(0, -TERRAIN_PROBE_DEPTH, 0), getTerrainProbeParams())
	return result and result.Position.Y or nil
end

local function isPlacementActive()
	return screenGui:GetAttribute(Attrs.PlacementActive) == true
end

local function softBoundsOptions(position, base)
	local options = cameraDriver:getBoundsOptions()
	options.supportTopY = getSupportTopY(position, base)
	return options
end

local function renderCamera(base)
	local camera = Workspace.CurrentCamera
	if camera and base then
		camera.CFrame = BuildViewCamera.toCFrame(cameraPos, base.CFrame, yaw, viewPitch)
	end
end

-- The selected device driver applies input/momentum; this orchestrator retains the
-- shared terrain-aware bounds and final camera render.
local function stepCamera(dt)
	if not buildViewActive or not cameraReady then
		return
	end
	local base = getBasePart()
	local cam = Workspace.CurrentCamera
	if not base or not cam then
		return
	end
	cameraDriver:step(dt, base)
	local bounded = BuildViewCamera.softBounds(cameraPos, getFlySurfaces(base), softBoundsOptions(cameraPos, base))
	cameraPos = cameraPos:Lerp(bounded, 1 - math.exp(-dt / cameraDriver:getValue("BoundsResponseSeconds")))
	cam.CFrame = BuildViewCamera.toCFrame(cameraPos, base.CFrame, yaw, viewPitch)
end

-- Optional Studio-authored height buttons delegate to whichever camera driver is active.
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
		buildControls.Visible = buildControlsRequested and screenGui:GetAttribute(Attrs.CompactModalActive) ~= true
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
		cameraDriver:setHeightDirection(dir)
	end)
	local function release()
		cameraDriver:setHeightDirection(0)
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
	-- The sheet may have been reassigned/rebuilt while out of Build View; re-resolve the
	-- fly surfaces so the bounds never pull toward another player's plot.
	refreshFlySurfaces()
	-- Entering counts as "answered": hide the nudge and suppress it this session.
	buildNudge.onEnterBuildView()
	-- Pin the avatar so movement input drives the camera, not the character.
	cameraDriver:reset()

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

	local minPitch, maxPitch = cameraDriver:getPitchLimits()
	if lastBuildViewPose then
		yaw = lastBuildViewPose.yaw or 0
		viewPitch = math.clamp(
			lastBuildViewPose.pitch or math.rad(cameraDriver:getValue("DefaultPitchDegrees")),
			minPitch,
			maxPitch
		)
		cameraPos = BuildViewCamera.softBounds(
			lastBuildViewPose.position,
			getFlySurfaces(base),
			softBoundsOptions(lastBuildViewPose.position, base)
		)
	else
		yaw = 0
		viewPitch = math.clamp(math.rad(cameraDriver:getValue("DefaultPitchDegrees")), minPitch, maxPitch)
		cameraPos = BuildViewCamera.framePose(
			base.CFrame,
			base.Size,
			camera.ViewportSize,
			false,
			cameraDriver:getValue("FieldOfView"),
			yaw,
			viewPitch,
			cameraDriver:getFramingOptions()
		)
		-- The framing pose must land inside the fly bounds: with a low tuned ceiling the
		-- unclamped pose would sit above it and visibly sink right after the fly-in tween.
		cameraPos = BuildViewCamera.softBounds(cameraPos, getFlySurfaces(base), softBoundsOptions(cameraPos, base))
	end
	cameraReady = false
	camera.CameraType = Enum.CameraType.Scriptable
	camera.FieldOfView = cameraDriver:getValue("FieldOfView")

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
	cameraDriver:reset()
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
		local restoreType = (savedCameraType and savedCameraType ~= Enum.CameraType.Scriptable) and savedCameraType
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

-- Enabling Auto Build while Settings owns the background must not open the Store underneath
-- the modal. Once the modal restores its saved surfaces, reopen on the next task so that restore
-- completes first regardless of signal connection order.
local autoBuildStoreRequestToken = 0
local function requestAutoBuildStoreWhenAvailable()
	autoBuildStoreRequestToken += 1
	local token = autoBuildStoreRequestToken
	if
		not buildViewActive
		or screenGui:GetAttribute(Attrs.AutoBuildMode) ~= true
		or screenGui:GetAttribute(Attrs.BackgroundSurfacesSuspended) == true
	then
		return
	end
	task.defer(function()
		if
			token == autoBuildStoreRequestToken
			and buildViewActive
			and screenGui:GetAttribute(Attrs.AutoBuildMode) == true
			and screenGui:GetAttribute(Attrs.BackgroundSurfacesSuspended) ~= true
		then
			screenGui:SetAttribute(Attrs.StoreOpen, true)
		end
	end)
end
screenGui:GetAttributeChangedSignal(Attrs.AutoBuildMode):Connect(requestAutoBuildStoreWhenAvailable)
screenGui:GetAttributeChangedSignal(Attrs.BackgroundSurfacesSuspended):Connect(requestAutoBuildStoreWhenAvailable)

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
	end
	cameraDriver:onPlacementActiveChanged(active)
end)

-- Select exactly one input/motion driver for this client. Both share only the plot
-- framing/bounds helpers above and the lifecycle state exposed through this context.
local desktopCamera
local mobileCamera

local function makeCameraContext(isSelected)
	return {
		getPosition = function()
			return cameraPos
		end,
		setPosition = function(position)
			cameraPos = position
		end,
		getYaw = function()
			return yaw
		end,
		setYaw = function(value)
			yaw = value
		end,
		getPitch = function()
			return viewPitch
		end,
		setPitch = function(value)
			viewPitch = value
		end,
		getBasePart = getBasePart,
		isPlacementActive = isPlacementActive,
		isActive = function()
			return buildViewActive
		end,
		isSelected = isSelected,
		isInputBlocked = isCameraInputPositionBlocked,
		renderNow = renderCamera,
		toggleBuildView = toggleBuildView,
		exitBuildView = exitBuildView,
	}
end

desktopCamera = BuildViewDesktopCamera.new(makeCameraContext(function()
	return desktopCamera ~= nil and cameraDriver == desktopCamera
end))
mobileCamera = BuildViewMobileCamera.new(makeCameraContext(function()
	return mobileCamera ~= nil and cameraDriver == mobileCamera
end))
cameraDriver = isMobileDevice() and mobileCamera or desktopCamera
