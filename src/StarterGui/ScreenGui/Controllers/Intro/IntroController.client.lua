-- IntroController: the first-time-player "cookie meteor" intro.
--
-- Plays ONCE while the server-projected story step is Meteor. Everything here is CLIENT-LOCAL
-- to the newcomer — the crater clone is parented under Workspace on this client only, so other
-- players never see it.
--
-- Flow:
--   1. TITLE SCREEN — the HUD is hidden; a flaming, trailing meteor orbits the whole map (a
--      circle around the baseplate + islands) while a tracking camera follows it. Play marks
--      the intro seen up front; Skip restores gameplay immediately.
--   2. PLAY — the screen fades to black, then reveals the drop camera as the meteor breaks
--      orbit and arcs down.
--   3. Impact fires a particle explosion; the mirrored bottom half (cookiemeteorbottom) is
--      removed; the top settles into the crater.
--   4. The player clicks the rubble a few times; EACH click chips rubble AND tweens the meteor
--      one step closer to the real Cookie's size/rotation/position.
--   5. On the last click the meteor has fully become the Cookie; we reveal the real Cookie and
--      swap. The active Chapter 1 path reports RubbleCleared; optional non-story playback can
--      use the guarded MarkIntroSeen fallback instead.
--
-- VFX are authored on the ReplicatedStorage template (MeteorTrail/MeteorFire/MeteorSmoke, the
-- ExplosionBurst/ExplosionSmoke ParticleEmitters, and the Impact Sound). This controller only
-- toggles/emits them and no-ops gracefully when any are absent.
--
-- A Settings "Replay Intro" action and a Studio dev button can replay the client-local intro
-- without rejoining, wiping the datastore, or changing IntroSeen.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")
local Lighting = game:GetService("Lighting")
local Debris = game:GetService("Debris")

local player = Players.LocalPlayer
local mainGui = script:FindFirstAncestorOfClass("ScreenGui")

local shared = ReplicatedStorage:WaitForChild("Shared")
local Net = require(shared:WaitForChild("Net"))
local Attrs = require(shared:WaitForChild("Attrs"))
local AudioSettings = require(shared:WaitForChild("AudioSettings"))
local StoryConfig = require(shared:WaitForChild("StoryConfig"))
local UiMotion = require(shared:WaitForChild("UiMotion"))

----------------------------------------------------------------------
-- Tunables
----------------------------------------------------------------------

local ORBIT_ALTITUDE = 80        -- studs the meteor orbits above Earth's surface
local ORBIT_TILT = math.rad(12)  -- slight inclination so the orbit isn't a fixed vertical loop
local ORBIT_SPEED = 0.35         -- radians/sec orbital angular speed
local TITLE_SPIN_SPEED = 0.6     -- radians/sec meteor tumble
local SPIN_AXIS = Vector3.new(0.3, 1, 0.15).Unit
local PLAY_BLACKOUT_FADE_TIME = 1
local PLAY_REVEAL_FADE_TIME = 1
local EARTH_HIGHLIGHT_OUTLINE_TRANSPARENCY = 0.5
local FOLLOW_DIST = 160          -- camera follow distance to the side of the meteor
local FOLLOW_UP = 15             -- camera follow height above the meteor
local DESCENT_TIME = 4.0         -- seconds for the cinematic sky drop onto the plot
local DROP_LEAD_ANGLE = math.rad(22) -- title-orbit alignment point near the player's plot
local ATMOSPHERE_ENTRY_LEAD_ANGLE = math.rad(24)
local ATMOSPHERE_ENTRY_EXTRA_HEIGHT = 120
local INTRO_EARTH_REFERENCE_RADIUS = 700 -- original 800x800x800 Earth used to tune the descent
local ATMOSPHERE_CONTROL_HEIGHT = 90
local ATMOSPHERE_CAMERA_BACK = 235
local ATMOSPHERE_CAMERA_SIDE = 80
local ATMOSPHERE_CAMERA_UP = 95
local EARTH_PHASE_FADE_START = 0.56
local EARTH_PHASE_FADE_END = 0.72
local PLAYER_DROP_CAMERA_CUT = 0.56
local DROP_CONTROL_SIDE = -360
local IMPACT_HEIGHT = 210       -- final control point height for a steep slam
local PLAYER_DROP_CAMERA_BACK = 20
local PLAYER_DROP_CAMERA_SIDE = 0
local PLAYER_DROP_CAMERA_UP = 0
local MOMENTUM_START = 0.1       -- descent timing: slow atmosphere entry, then accelerate hard
local LETTERBOX_BAR_HEIGHT = 0.16
local LETTERBOX_TWEEN_TIME = 0.4
local RETURN_CAM_TIME = 2      -- cinematic camera ease back to regular player view
local TITLE_REVEAL_TIME = 1
local TITLE_HOLD_TIME = 1
local CLICKS_TO_CLEAR = 5        -- rubble clicks (= morph steps) before the swap to the real Cookie
local MORPH_STEP_TIME = 0.3      -- per-click tween toward the Cookie
local SHAKE_TIME = 0.45
local SHAKE_MAGNITUDE = 3.2
local INTRO_DECISION_TIMEOUT = 20
local INTRO_SHEET_SPAWN_TIMEOUT = 30
local INTRO_CLOCKTIME = 0        -- midnight: dark + space-like during the orbit
local GAMEPLAY_CLOCKTIME = 14    -- tweened to as the meteor drops, so it lands in daylight
local INTRO_REPLAY_EVENT_NAME = "ReplayIntroRequested"

-- The authored CFrame of CookieSheet.Center that the crater template was built on top of.
-- Each live plot is a clone of that sheet rotated around the ring, so mapping authored->live
-- through this constant drops the whole crater unit dead-centre on the player's own Center,
-- correctly rotated. (Center: position 269,2,0; Rotation 0,90,0.)
local AUTHORED_CENTER_CF = CFrame.new(269, 2, 0) * CFrame.Angles(0, math.rad(90), 0)

----------------------------------------------------------------------
-- Pure helpers
----------------------------------------------------------------------

local function getPlayerCookieSheet()
	local cookieSheets = Workspace:FindFirstChild("CookieSheets")
	if not cookieSheets then
		return nil
	end
	for _, sheet in ipairs(cookieSheets:GetChildren()) do
		local sheetOwner = sheet:FindFirstChild("SheetOwner")
		if sheetOwner and sheetOwner.Value == player then
			return sheet
		end
	end
	return nil
end

local function waitForSheet()
	local deadline = os.clock() + 30
	local sheet = getPlayerCookieSheet()
	while not sheet and os.clock() < deadline do
		task.wait(0.2)
		sheet = getPlayerCookieSheet()
	end
	return sheet
end

local function waitForCharacterAtSheet(character, sheet)
	local humanoidRootPart = character:WaitForChild("HumanoidRootPart", 10)
	local spawnPoint = sheet and sheet:FindFirstChild("SpawnPoint")
	if not humanoidRootPart or not spawnPoint or not spawnPoint:IsA("BasePart") then
		return humanoidRootPart
	end

	-- Sheet assignment happens before the server finishes restoring the run and teleports the
	-- character. A genuine first join can therefore see the plot while the avatar and default
	-- camera are still at the map origin. Do not capture that transient pose for the intro return.
	local deadline = os.clock() + INTRO_SHEET_SPAWN_TIMEOUT
	local allowedHorizontalDistance = math.max(spawnPoint.Size.X, spawnPoint.Size.Z) / 2 + 24
	while player.Character == character and humanoidRootPart.Parent and os.clock() < deadline do
		local offset = humanoidRootPart.Position - spawnPoint.Position
		if Vector2.new(offset.X, offset.Z).Magnitude <= allowedHorizontalDistance then
			-- Give Roblox's default camera two render turns to follow the server teleport before the
			-- cinematic snapshots it.
			RunService.RenderStepped:Wait()
			RunService.RenderStepped:Wait()
			return humanoidRootPart
		end
		RunService.Heartbeat:Wait()
	end

	return nil
end

local function gameplayCameraSnapshot(character, humanoidRootPart, camera)
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	local subject = camera.CameraSubject
	if not subject or not subject:IsDescendantOf(character) then
		subject = humanoid
	end

	local cameraCFrame = camera.CFrame
	local distanceFromCharacter = (cameraCFrame.Position - humanoidRootPart.Position).Magnitude
	if distanceFromCharacter < 1 or distanceFromCharacter > 200 then
		-- The default camera has not caught the plot teleport yet. Use a conventional safe
		-- third-person return pose; CameraType.Custom takes over from here on the next render.
		local focus = humanoidRootPart.Position + Vector3.new(0, 2.5, 0)
		local position = focus - humanoidRootPart.CFrame.LookVector * 14 + Vector3.new(0, 6, 0)
		cameraCFrame = CFrame.lookAt(position, focus)
	end

	return cameraCFrame, subject
end

local function collectRubble(model)
	local parts = {}
	for _, descendant in ipairs(model:GetDescendants()) do
		if descendant:IsA("BasePart") and descendant.Name == "crater" then
			table.insert(parts, descendant)
		end
	end
	return parts
end

local function setPartsHidden(parts, hidden)
	for _, part in ipairs(parts) do
		part.Transparency = hidden and 1 or (part:GetAttribute("IntroBaseTransparency") or 0)
		part.CanCollide = not hidden
		part.CanQuery = not hidden
	end
end

-- Toggle every built-in effect of a class (Trail / Fire / Smoke) under `root`.
local function setEffectEnabled(root, className, enabled)
	for _, descendant in ipairs(root:GetDescendants()) do
		if descendant:IsA(className) then
			descendant.Enabled = enabled
		end
	end
end

local function clearMotionEffects(root)
	for _, descendant in ipairs(root:GetDescendants()) do
		if descendant:IsA("Trail") or descendant:IsA("ParticleEmitter") then
			pcall(function()
				descendant:Clear()
			end)
		end
	end
end

-- One-shot burst from a named ParticleEmitter (the custom explosion).
local function emitBurst(root, name, count)
	for _, descendant in ipairs(root:GetDescendants()) do
		if descendant:IsA("ParticleEmitter") and descendant.Name == name then
			descendant:Emit(count)
		end
	end
end

local function playSound(root, name)
	local sound = root:FindFirstChild(name, true)
	if sound and sound:IsA("Sound") then
		AudioSettings.playSfx(sound)
	end
end

local function addImpactEmitter(attachment, name, props, count)
	local emitter = Instance.new("ParticleEmitter")
	emitter.Name = name
	emitter.Enabled = false
	emitter.Rate = 0
	for key, value in pairs(props) do
		emitter[key] = value
	end
	emitter.Parent = attachment
	emitter:Emit(count)
	return emitter
end

local function emitCustomImpactExplosion(position)
	local part = Instance.new("Part")
	part.Name = "IntroCustomImpactExplosion"
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.Transparency = 1
	part.Size = Vector3.one
	part.CFrame = CFrame.new(position)
	part.Parent = Workspace

	local attachment = Instance.new("Attachment")
	attachment.Parent = part

	addImpactEmitter(attachment, "ImpactFlash", {
		Texture = "rbxasset://textures/particles/sparkles_main.dds",
		Color = ColorSequence.new(Color3.fromRGB(255, 244, 206), Color3.fromRGB(255, 118, 41)),
		LightEmission = 1,
		LightInfluence = 0,
		Lifetime = NumberRange.new(0.12, 0.2),
		Speed = NumberRange.new(45, 80),
		SpreadAngle = Vector2.new(180, 180),
		Size = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 6),
			NumberSequenceKeypoint.new(1, 0),
		}),
		Transparency = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 0),
			NumberSequenceKeypoint.new(1, 1),
		}),
	}, 55)

	addImpactEmitter(attachment, "ImpactDust", {
		Texture = "rbxasset://textures/particles/smoke_main.dds",
		Color = ColorSequence.new(Color3.fromRGB(122, 96, 76), Color3.fromRGB(55, 47, 42)),
		LightEmission = 0.05,
		Lifetime = NumberRange.new(0.8, 1.35),
		Speed = NumberRange.new(22, 48),
		SpreadAngle = Vector2.new(180, 35),
		Acceleration = Vector3.new(0, 26, 0),
		Drag = 7,
		Size = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 5),
			NumberSequenceKeypoint.new(0.45, 12),
			NumberSequenceKeypoint.new(1, 18),
		}),
		Transparency = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 0.18),
			NumberSequenceKeypoint.new(0.65, 0.48),
			NumberSequenceKeypoint.new(1, 1),
		}),
	}, 95)

	addImpactEmitter(attachment, "ImpactSparks", {
		Texture = "rbxasset://textures/particles/sparkles_main.dds",
		Color = ColorSequence.new(Color3.fromRGB(255, 221, 112), Color3.fromRGB(255, 84, 30)),
		LightEmission = 0.8,
		LightInfluence = 0,
		Lifetime = NumberRange.new(0.35, 0.75),
		Speed = NumberRange.new(65, 115),
		SpreadAngle = Vector2.new(180, 70),
		Acceleration = Vector3.new(0, -90, 0),
		Drag = 3,
		Size = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 0.9),
			NumberSequenceKeypoint.new(1, 0),
		}),
		Transparency = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 0),
			NumberSequenceKeypoint.new(1, 1),
		}),
	}, 70)

	Debris:AddItem(part, 3)
end

-- Cubic Bezier point — the break-orbit descent. A tangent-aligned P1 lets the drop leave along
-- the orbit's direction of travel, so the meteor keeps its momentum instead of stopping dead.
local function cubicBezier(p0, p1, p2, p3, t)
	local u = 1 - t
	return (u * u * u) * p0 + (3 * u * u * t) * p1 + (3 * u * t * t) * p2 + (t * t * t) * p3
end

local function smoothstep(alpha)
	alpha = math.clamp(alpha, 0, 1)
	return alpha * alpha * (3 - 2 * alpha)
end

----------------------------------------------------------------------
-- Title-screen Play button (built in code; it's the only active UI during the intro)
----------------------------------------------------------------------

local function buildTitleGui(allowSkip)
	local gui = Instance.new("ScreenGui")
	gui.Name = "IntroTitleGui"
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = true
	gui.DisplayOrder = 2000

	-- A round play-icon button (the only UI on the title screen).
	local button = Instance.new("TextButton")
	button.Name = "PlayButton"
	button.AnchorPoint = Vector2.new(0.5, 1)
	button.Position = UDim2.fromScale(0.5, 0.88)
	button.Size = UDim2.fromOffset(96, 96)
	button.BackgroundColor3 = Color3.fromRGB(60, 130, 246)
	button.Text = ""
	button.AutoButtonColor = true
	button.Parent = gui
	local glyph = Instance.new("ImageLabel")
	glyph.Name = "Glyph"
	glyph.AnchorPoint = Vector2.new(0.5, 0.5)
	glyph.Position = UDim2.new(0.5, 4, 0.5, 0)
	glyph.Size = UDim2.fromOffset(48, 48)
	glyph.BackgroundTransparency = 1
	glyph.Image = "rbxassetid://124626664950201"
	glyph.ImageColor3 = Color3.fromRGB(255, 255, 255)
	glyph.Parent = button
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(1, 0) -- full circle
	corner.Parent = button
	local stroke = Instance.new("UIStroke")
	stroke.Thickness = 3
	stroke.Color = Color3.fromRGB(255, 255, 255)
	stroke.Transparency = 0.3
	stroke.Parent = button

	local skipButton
	if allowSkip then
		skipButton = Instance.new("TextButton")
		skipButton.Name = "SkipButton"
		skipButton.AnchorPoint = Vector2.new(1, 1)
		skipButton.Position = UDim2.new(1, -24, 1, -24)
		skipButton.Size = UDim2.fromOffset(92, 36)
		skipButton.BackgroundColor3 = Color3.fromRGB(18, 22, 32)
		skipButton.BackgroundTransparency = 0.2
		skipButton.TextColor3 = Color3.fromRGB(235, 240, 250)
		skipButton.Font = Enum.Font.GothamBold
		skipButton.TextSize = 15
		skipButton.Text = "Skip"
		skipButton.AutoButtonColor = true
		skipButton.Parent = gui
		local skipCorner = Instance.new("UICorner")
		skipCorner.CornerRadius = UDim.new(0, 8)
		skipCorner.Parent = skipButton
		local skipStroke = Instance.new("UIStroke")
		skipStroke.Thickness = 1
		skipStroke.Color = Color3.fromRGB(255, 255, 255)
		skipStroke.Transparency = 0.75
		skipStroke.Parent = skipButton
	end

	return gui, button, skipButton
end

local function buildBlackoutGui()
	local gui = Instance.new("ScreenGui")
	gui.Name = "IntroBlackoutGui"
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = true
	gui.DisplayOrder = 2001

	local frame = Instance.new("Frame")
	frame.Name = "Blackout"
	frame.Size = UDim2.fromScale(1, 1)
	frame.BackgroundColor3 = Color3.fromRGB(0, 0, 0)
	frame.BackgroundTransparency = 1
	frame.BorderSizePixel = 0
	frame.Parent = gui

	return gui, frame
end

local function buildLetterboxGui()
	local gui = Instance.new("ScreenGui")
	gui.Name = "IntroLetterboxGui"
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = true
	gui.ScreenInsets = Enum.ScreenInsets.None
	gui.ClipToDeviceSafeArea = false
	gui.SafeAreaCompatibility = Enum.SafeAreaCompatibility.None
	gui.DisplayOrder = 2002

	local topBar = Instance.new("Frame")
	topBar.Name = "TopBar"
	topBar.Size = UDim2.new(1, 0, LETTERBOX_BAR_HEIGHT, 0)
	topBar.Position = UDim2.fromScale(0, 0)
	topBar.BackgroundColor3 = Color3.fromRGB(0, 0, 0)
	topBar.BorderSizePixel = 0
	topBar.Parent = gui

	local bottomBar = Instance.new("Frame")
	bottomBar.Name = "BottomBar"
	bottomBar.AnchorPoint = Vector2.new(0, 1)
	bottomBar.Size = UDim2.new(1, 0, LETTERBOX_BAR_HEIGHT, 0)
	bottomBar.Position = UDim2.fromScale(0, 1)
	bottomBar.BackgroundColor3 = Color3.fromRGB(0, 0, 0)
	bottomBar.BorderSizePixel = 0
	bottomBar.Parent = gui

	return gui, topBar, bottomBar
end

local function tweenLetterboxOut(topBar, bottomBar)
	local info = TweenInfo.new(LETTERBOX_TWEEN_TIME, Enum.EasingStyle.Quad, Enum.EasingDirection.InOut)
	local topTween = UiMotion.create(topBar, info, {
		Position = UDim2.fromScale(0, -LETTERBOX_BAR_HEIGHT),
	})
	local bottomTween = UiMotion.create(bottomBar, info, {
		Position = UDim2.fromScale(0, 1 + LETTERBOX_BAR_HEIGHT),
	})
	topTween:Play()
	bottomTween:Play()
	topTween.Completed:Wait()
end

local function playTitleReveal(playerGui)
	local gui = Instance.new("ScreenGui")
	gui.Name = "IntroTitleRevealGui"
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = true
	gui.DisplayOrder = 2003
	gui.Parent = playerGui

	local title = Instance.new("TextLabel")
	title.Name = "Title"
	title.AnchorPoint = Vector2.new(0.5, 0.5)
	title.Position = UDim2.fromScale(0.5, -0.14)
	title.Size = UDim2.fromScale(0.78, 0.12)
	title.BackgroundTransparency = 1
	title.Font = Enum.Font.GothamBlack
	title.Text = "Cookie Clicker"
	title.TextColor3 = Color3.fromRGB(255, 245, 218)
	title.TextScaled = true
	title.TextTransparency = 1
	title.TextStrokeColor3 = Color3.fromRGB(78, 39, 12)
	title.TextStrokeTransparency = 1
	title.Parent = gui

	local sizeLimit = Instance.new("UITextSizeConstraint")
	sizeLimit.MinTextSize = 24
	sizeLimit.MaxTextSize = 78
	sizeLimit.Parent = title

	local scale = Instance.new("UIScale")
	scale.Scale = 0.78
	scale.Parent = title

	local inInfo = TweenInfo.new(TITLE_REVEAL_TIME, Enum.EasingStyle.Back, Enum.EasingDirection.Out)
	local titleTween = UiMotion.create(title, inInfo, {
		Position = UDim2.fromScale(0.5, 0.44),
		TextTransparency = 0,
		TextStrokeTransparency = 0.28,
	})
	local scaleTween = UiMotion.create(scale, inInfo, {
		Scale = 1,
	})
	titleTween:Play()
	scaleTween:Play()
	titleTween.Completed:Wait()

	task.wait(TITLE_HOLD_TIME)

	local outInfo = TweenInfo.new(0.35, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
	local fadeTween = UiMotion.create(title, outInfo, {
		TextTransparency = 1,
		TextStrokeTransparency = 1,
		Position = UDim2.fromScale(0.5, 0.4),
	})
	fadeTween:Play()
	fadeTween.Completed:Wait()
	gui:Destroy()
end

----------------------------------------------------------------------
-- Earth backdrop (client-local, intro-only): cloned, orbited, then faded + removed
----------------------------------------------------------------------

-- Clone the user-authored Earth mesh from the intro assets and centre it on the world origin.
-- Client-local, so only the newcomer sees it; removed on landing so a sheet that grows past
-- Earth never shows the planet mesh in normal play.
local function cloneEarth()
	local source = ReplicatedStorage:WaitForChild("IntroAssets", 10)
	source = source and source:FindFirstChild("earth")
	if not source then
		warn("IntroController: ReplicatedStorage.IntroAssets.earth missing; orbiting without a planet")
		return nil
	end
	local earth = source:Clone()
	earth.Name = "IntroEarth"
	earth.Anchored = true
	earth.CanCollide = false
	earth.CanQuery = false
	earth.CastShadow = false

	local highlight = Instance.new("Highlight")
	highlight.Name = "IntroEarthAmbientFill"
	highlight.Adornee = earth
	highlight.FillTransparency = 1
	highlight.OutlineColor = Color3.fromRGB(255, 255, 255)
	highlight.OutlineTransparency = EARTH_HIGHLIGHT_OUTLINE_TRANSPARENCY
	highlight.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
	highlight.Parent = earth

	earth:PivotTo(CFrame.new(0, 0, 0)) -- its authored centre is the world origin
	earth.Parent = Workspace
	return earth
end

----------------------------------------------------------------------
-- The intro (re-runnable so the dev button can replay it)
----------------------------------------------------------------------

local running = false

local function getReplayEvent()
	local existing = mainGui and mainGui:FindFirstChild(INTRO_REPLAY_EVENT_NAME)
	if existing and existing:IsA("BindableEvent") then
		return existing
	end
	if not mainGui then
		return nil
	end
	local event = Instance.new("BindableEvent")
	event.Name = INTRO_REPLAY_EVENT_NAME
	event.Parent = mainGui
	return event
end

local function playIntro(options)
	if running then
		return
	end
	options = options or {}
	local shouldMarkSeen = options.markSeen ~= false
	local completeStory = options.completeStory == true
	local allowSkip = options.allowSkip ~= false
	local markSeenSent = false

	local function markIntroSeen()
		if shouldMarkSeen and not markSeenSent then
			markSeenSent = true
			Net.fireServer(Net.Names.MarkIntroSeen)
		end
	end

	local function markRubbleCleared()
		if completeStory then
			Net.fireServer(Net.Names.StoryAction, "RubbleCleared")
		else
			markIntroSeen()
		end
	end

	local sheet = waitForSheet()
	if not sheet then
		return
	end
	local centerPart = sheet:WaitForChild("Center", 10)
	local cookie = sheet:WaitForChild("Cookie", 10)
	if not centerPart or not cookie then
		return
	end

	local template = ReplicatedStorage:WaitForChild("IntroAssets", 10)
	template = template and template:FindFirstChild("crater")
	if not template then
		warn("IntroController: ReplicatedStorage.IntroAssets.crater missing; skipping intro")
		return
	end

	local character = player.Character or player.CharacterAdded:Wait()
	local humanoidRootPart = waitForCharacterAtSheet(character, sheet)
	local camera = Workspace.CurrentCamera
	if not humanoidRootPart or not camera then
		warn("IntroController: character did not reach its CookieSheet before the intro timeout")
		return
	end

	running = true

	-- Build the crater on the player's Center.
	local craterClone = template:Clone()
	local meteor = craterClone:FindFirstChild("cookiemeteor", true)
	if not meteor then
		craterClone:Destroy()
		running = false
		warn("IntroController: template has no cookiemeteor; skipping intro")
		return
	end

	-- Map the authored layout onto this plot's live (rotated) Center.
	local toLive = centerPart.CFrame * AUTHORED_CENTER_CF:Inverse()
	craterClone:PivotTo(toLive * craterClone:GetPivot())
	craterClone.Parent = Workspace

	local rubble = collectRubble(craterClone)
	for _, part in ipairs(rubble) do
		part:SetAttribute("IntroBaseTransparency", part.Transparency)
		part.Anchored = true
	end
	meteor.Anchored = true

	-- Hide the real Cookie locally (server ClickDetector untouched; others unaffected).
	cookie.LocalTransparencyModifier = 1
	-- Rubble stays hidden until impact.
	setPartsHidden(rubble, true)

	-- The crater rest pose for the meteor (where it settles + the morph start reference).
	local restingCF = meteor:GetPivot()
	local restingPos = restingCF.Position
	local restRotation = restingCF - restingPos -- rotation-only

	-- cookiemeteorbottom is the mirrored half that makes the falling cookie read as a 3D meteor.
	-- It's an anchored child, so it won't follow PivotTo on its own -- we drive it each frame, then
	-- hide it on impact so only the top half settles into the crater.
	local meteorBottom = meteor:FindFirstChild("cookiemeteorbottom")
	local bottomOffset = meteorBottom and meteor.CFrame:ToObjectSpace(meteorBottom.CFrame)

	local function placeMeteor(cf)
		meteor:PivotTo(cf)
		if meteorBottom then
			meteorBottom.CFrame = cf * bottomOffset
		end
	end

	-- Save the live camera so we can restore the genuine follow camera afterward.
	local savedCameraType = camera.CameraType
	local savedCameraCFrame, savedCameraSubject = gameplayCameraSnapshot(character, humanoidRootPart, camera)
	local savedCameraFieldOfView = camera.FieldOfView
	local wasRootAnchored = humanoidRootPart.Anchored

	local craterDestroyed = false
	local earth
	local titleGui
	local blackoutGui
	local letterboxGui
	local letterboxTop
	local letterboxBottom
	local playConn
	local skipConn
	local skipRequested = false

	local function cleanupIntro()
		if playConn then
			playConn:Disconnect()
			playConn = nil
		end
		if skipConn then
			skipConn:Disconnect()
			skipConn = nil
		end
		if titleGui then
			titleGui:Destroy()
			titleGui = nil
		end
		if blackoutGui then
			blackoutGui:Destroy()
			blackoutGui = nil
		end
		if letterboxGui then
			letterboxGui:Destroy()
			letterboxGui = nil
			letterboxTop = nil
			letterboxBottom = nil
		end
		cookie.LocalTransparencyModifier = 0
		if not craterDestroyed then
			craterDestroyed = true
			craterClone:Destroy()
		end
		camera.CameraType = (savedCameraType ~= Enum.CameraType.Scriptable) and savedCameraType
			or Enum.CameraType.Custom
		camera.CameraSubject = savedCameraSubject
		camera.FieldOfView = savedCameraFieldOfView
		camera.CFrame = savedCameraCFrame
		if mainGui then
			mainGui.Enabled = true
		end
		humanoidRootPart.Anchored = wasRootAnchored
		Lighting.ClockTime = GAMEPLAY_CLOCKTIME
		if earth then
			earth:Destroy()
			earth = nil
		end
		running = false
	end

	-- Freeze the avatar and hide the HUD for the whole intro.
	humanoidRootPart.Anchored = true
	if mainGui then
		mainGui.Enabled = false
	end
	camera.CameraType = Enum.CameraType.Scriptable
	setEffectEnabled(meteor, "Smoke", false)
	-- Flaming, trailing meteor for the whole orbit + descent.
	setEffectEnabled(meteor, "Trail", true)
	setEffectEnabled(meteor, "Fire", true)

	----------------------------------------------------------------
	-- Orbit geometry: a slightly-tilted great circle around Earth (centred on the world origin).
	----------------------------------------------------------------
	-- Earth backdrop + evening light (client-local; both reverted on landing).
	Lighting.ClockTime = INTRO_CLOCKTIME
	earth = cloneEarth()

	local orbitCenter = Vector3.zero -- world origin = Earth's centre
	local plotFlat = Vector3.new(restingPos.X, 0, restingPos.Z)
	local outwardDir = plotFlat - orbitCenter
	outwardDir = outwardDir.Magnitude > 0 and outwardDir.Unit or Vector3.xAxis

	-- Radius is derived from Earth so the meteor orbits just above its surface.
	local earthRadius = earth and earth.Size.X / 2 or INTRO_EARTH_REFERENCE_RADIUS
	local orbitRadius = earthRadius + ORBIT_ALTITUDE

	-- Orbit plane: spanned by `outwardDir` (toward the plot) and an up-axis tilted by ORBIT_TILT,
	-- so the loop is an inclined orbit rather than a fixed vertical one.
	local uAxis = outwardDir
	local vAxis = CFrame.fromAxisAngle(outwardDir, ORBIT_TILT) * Vector3.yAxis
	local sideDir = uAxis:Cross(vAxis) -- plane normal -> the side the camera follows from
	sideDir = sideDir.Magnitude > 0 and sideDir.Unit or Vector3.zAxis

	local function orbitPos(theta)
		return orbitCenter + (math.cos(theta) * uAxis + math.sin(theta) * vAxis) * orbitRadius
	end

	-- Title-orbit alignment point near the player's plot. The actual drop uses a separate
	-- cinematic sky path after Play, but this keeps the idle orbit composed around the sheet.
	local sheetHorizDist = (plotFlat - orbitCenter).Magnitude
	local aboveSheetAngle = math.acos(math.clamp(sheetHorizDist / orbitRadius, -1, 1))
	local dropAngle = aboveSheetAngle + DROP_LEAD_ANGLE

	-- Camera follows the meteor side-on; `dist` lets the drop start slightly closer.
	local function trackCamera(meteorPos, dist)
		dist = dist or FOLLOW_DIST
		camera.CFrame = CFrame.lookAt(meteorPos + sideDir * dist + Vector3.new(0, FOLLOW_UP, 0), meteorPos)
	end

	----------------------------------------------------------------
	-- Phase 1: title screen — orbit the map, wait for Play.
	----------------------------------------------------------------
	local theta0 = dropAngle + math.pi -- start across the orbit from the drop point

	local playButton, skipButton
	titleGui, playButton, skipButton = buildTitleGui(allowSkip)
	titleGui.Parent = player:WaitForChild("PlayerGui")
	local playPressed = false
	playConn = playButton.Activated:Connect(function()
		playPressed = true
		markIntroSeen()
	end)
	if skipButton then
		skipConn = skipButton.Activated:Connect(function()
			skipRequested = true
			markIntroSeen()
		end)
	end

	local titleStart = os.clock()
	while not playPressed and not skipRequested do
		local now = os.clock() - titleStart
		-- DECREASING theta: the meteor sweeps over the top and down toward the sheet side, so its
		-- momentum already heads into the dive when it reaches the break point.
		local theta = theta0 - now * ORBIT_SPEED
		local pos = orbitPos(theta)
		placeMeteor(CFrame.fromAxisAngle(SPIN_AXIS, now * TITLE_SPIN_SPEED) + pos)
		trackCamera(pos)
		RunService.RenderStepped:Wait()
	end
	if skipRequested then
		cleanupIntro()
		return
	end

	local blackoutFrame
	blackoutGui, blackoutFrame = buildBlackoutGui()
	blackoutGui.Parent = player:WaitForChild("PlayerGui")

	local blackoutElapsed = 0
	local blackoutStartTitleTime = os.clock() - titleStart
	while blackoutElapsed < PLAY_BLACKOUT_FADE_TIME do
		local dt = RunService.RenderStepped:Wait()
		blackoutElapsed = math.min(blackoutElapsed + dt, PLAY_BLACKOUT_FADE_TIME)
		local alpha = blackoutElapsed / PLAY_BLACKOUT_FADE_TIME
		local titleTime = blackoutStartTitleTime + blackoutElapsed
		local theta = theta0 - titleTime * ORBIT_SPEED
		local pos = orbitPos(theta)
		placeMeteor(CFrame.fromAxisAngle(SPIN_AXIS, titleTime * TITLE_SPIN_SPEED) + pos)
		trackCamera(pos)
		blackoutFrame.BackgroundTransparency = 1 - alpha
	end

	if playConn then
		playConn:Disconnect()
		playConn = nil
	end
	if skipConn then
		skipConn:Disconnect()
		skipConn = nil
	end
	if titleGui then
		titleGui:Destroy()
		titleGui = nil
	end
	letterboxGui, letterboxTop, letterboxBottom = buildLetterboxGui()
	letterboxGui.Parent = player:WaitForChild("PlayerGui")

	local nowAtPlay = os.clock() - titleStart
	local spinBase = nowAtPlay * TITLE_SPIN_SPEED
	local entryAngle = dropAngle + ATMOSPHERE_ENTRY_LEAD_ANGLE
	local entryHeightOffset = ATMOSPHERE_ENTRY_EXTRA_HEIGHT - (earthRadius - INTRO_EARTH_REFERENCE_RADIUS)
	local dropStartPos = orbitPos(entryAngle) + Vector3.new(0, entryHeightOffset, 0)
	local entryDir = dropStartPos - orbitCenter
	entryDir = entryDir.Magnitude > 0 and entryDir.Unit or outwardDir
	local atmospherePiercePos = orbitCenter + entryDir * (earthRadius * 0.72)
	local spinAtDrop = spinBase

	----------------------------------------------------------------
	-- Phase 2: atmosphere entry, then player-grounded impact shot.
	----------------------------------------------------------------
	-- Trails remember their previous endpoints, so clear them under black before moving the
	-- meteor from title orbit into the atmosphere-entry shot.
	setEffectEnabled(meteor, "Trail", false)
	setEffectEnabled(meteor, "Fire", false)
	clearMotionEffects(meteor)

	placeMeteor(CFrame.fromAxisAngle(SPIN_AXIS, spinAtDrop) + dropStartPos)

	local b1 = atmospherePiercePos
		+ sideDir * DROP_CONTROL_SIDE
		+ Vector3.new(0, ATMOSPHERE_CONTROL_HEIGHT + entryHeightOffset * 0.35, 0)
	local b2 = restingPos + Vector3.new(0, IMPACT_HEIGHT, 0) -- steep, near-vertical final approach
	local atmosphereCamPos = orbitCenter
		+ entryDir * (earthRadius + ATMOSPHERE_CAMERA_BACK)
		+ sideDir * ATMOSPHERE_CAMERA_SIDE
		+ Vector3.new(0, ATMOSPHERE_CAMERA_UP, 0)
	local playerToImpact = Vector3.new(
		restingPos.X - humanoidRootPart.Position.X,
		0,
		restingPos.Z - humanoidRootPart.Position.Z
	)
	if playerToImpact.Magnitude < 0.001 then
		playerToImpact = outwardDir
	else
		playerToImpact = playerToImpact.Unit
	end
	local playerCamPos = humanoidRootPart.Position
		- playerToImpact * PLAYER_DROP_CAMERA_BACK
		+ sideDir * PLAYER_DROP_CAMERA_SIDE
		+ Vector3.new(0, PLAYER_DROP_CAMERA_UP, 0)

	camera.CFrame = CFrame.lookAt(atmosphereCamPos, dropStartPos)
	RunService.RenderStepped:Wait()
	clearMotionEffects(meteor)
	setEffectEnabled(meteor, "Trail", true)
	setEffectEnabled(meteor, "Fire", true)

	local descentElapsed = 0
	local playerViewStarted = false
	while descentElapsed < DESCENT_TIME do
		local dt = RunService.RenderStepped:Wait()
		descentElapsed = math.min(descentElapsed + dt, DESCENT_TIME)
		local t = descentElapsed / DESCENT_TIME
		-- Carry momentum at the start (nonzero initial speed) then ACCELERATE into the impact.
		local eased = MOMENTUM_START * t + (1 - MOMENTUM_START) * t * t
		local pos = cubicBezier(dropStartPos, b1, b2, restingPos, eased)

		-- Keep tumbling, settling to the crater rest rotation over the last 20% (no landing snap).
		local spinRot = CFrame.fromAxisAngle(SPIN_AXIS, spinAtDrop + descentElapsed * TITLE_SPIN_SPEED)
		local settle = math.clamp((t - 0.8) / 0.2, 0, 1)
		placeMeteor(spinRot:Lerp(restRotation, settle) + pos)

		local playerLookTarget = pos:Lerp(restingPos + Vector3.new(0, 10, 0), math.clamp((t - 0.86) / 0.14, 0, 1))
		local atmosphereLookTarget = pos:Lerp(orbitCenter, math.clamp(1 - (t / PLAYER_DROP_CAMERA_CUT), 0, 1) * 0.18)
		local atmosphereShot = CFrame.lookAt(atmosphereCamPos, atmosphereLookTarget)
		local playerShot = CFrame.lookAt(playerCamPos, playerLookTarget)
		if t < PLAYER_DROP_CAMERA_CUT then
			camera.CFrame = atmosphereShot
		else
			if not playerViewStarted then
				playerViewStarted = true
				Lighting.ClockTime = GAMEPLAY_CLOCKTIME
			end
			camera.CFrame = playerShot
		end

		if earth and playerViewStarted then
			local earthFadeAlpha = smoothstep((t - EARTH_PHASE_FADE_START) / (EARTH_PHASE_FADE_END - EARTH_PHASE_FADE_START))
			earth.Transparency = earthFadeAlpha
			local highlight = earth:FindFirstChild("IntroEarthAmbientFill")
			if highlight and highlight:IsA("Highlight") then
				highlight.OutlineTransparency = EARTH_HIGHLIGHT_OUTLINE_TRANSPARENCY
					+ ((1 - EARTH_HIGHLIGHT_OUTLINE_TRANSPARENCY) * earthFadeAlpha)
			end
			if earthFadeAlpha >= 1 then
				earth:Destroy()
				earth = nil
			end
		end

		if blackoutGui then
			blackoutFrame.BackgroundTransparency = math.clamp(descentElapsed / PLAY_REVEAL_FADE_TIME, 0, 1)
			if blackoutFrame.BackgroundTransparency >= 1 then
				blackoutGui:Destroy()
				blackoutGui = nil
			end
		end
	end
	if blackoutGui then
		blackoutGui:Destroy()
		blackoutGui = nil
	end
	if earth then
		earth:Destroy()
		earth = nil
	end
	local impactCameraCFrame = camera.CFrame
	placeMeteor(restingCF)

	----------------------------------------------------------------
	-- Phase 3: impact — drop the bottom half, particle explosion, reveal rubble, smoulder.
	----------------------------------------------------------------
	setEffectEnabled(meteor, "Trail", false)
	setEffectEnabled(meteor, "Fire", false)
	if meteorBottom then
		meteorBottom.Transparency = 1
		meteorBottom.CanCollide = false
		meteorBottom.CanQuery = false
	end
	setPartsHidden(rubble, false)
	emitBurst(meteor, "ExplosionBurst", 90)
	emitBurst(meteor, "ExplosionSmoke", 30)
	emitCustomImpactExplosion(restingPos)
	setEffectEnabled(meteor, "Smoke", true)
	playSound(craterClone, "Impact")

	-- Camera shake from the final cinematic angle.
	local shakeStart = os.clock()
	while os.clock() - shakeStart < SHAKE_TIME do
		local decay = 1 - (os.clock() - shakeStart) / SHAKE_TIME
		local jitter = Vector3.new(
			(math.random() - 0.5) * 2,
			(math.random() - 0.5) * 2,
			(math.random() - 0.5) * 2
		) * SHAKE_MAGNITUDE * decay
		camera.CFrame = CFrame.lookAt(impactCameraCFrame.Position + jitter, restingPos)
		RunService.RenderStepped:Wait()
	end

	local returnTween = TweenService:Create(
		camera,
		TweenInfo.new(RETURN_CAM_TIME, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut),
		{
			CFrame = savedCameraCFrame,
			FieldOfView = savedCameraFieldOfView,
		}
	)
	returnTween:Play()
	if letterboxGui and letterboxTop and letterboxBottom then
		task.spawn(function()
			tweenLetterboxOut(letterboxTop, letterboxBottom)
		end)
	end
	task.spawn(function()
		playTitleReveal(player:WaitForChild("PlayerGui"))
	end)
	returnTween.Completed:Wait()
	if letterboxGui then
		letterboxGui:Destroy()
		letterboxGui = nil
		letterboxTop = nil
		letterboxBottom = nil
	end

	-- Hand the camera, HUD and avatar back so the player walks up to the wreckage.
	camera.CameraType = (savedCameraType ~= Enum.CameraType.Scriptable) and savedCameraType
		or Enum.CameraType.Custom
	camera.CameraSubject = savedCameraSubject
	camera.FieldOfView = savedCameraFieldOfView
	camera.CFrame = savedCameraCFrame
	if mainGui then
		mainGui.Enabled = true
	end
	humanoidRootPart.Anchored = wasRootAnchored

	-- Back to day; remove Earth.
	Lighting.ClockTime = GAMEPLAY_CLOCKTIME
	if earth then
		earth:Destroy()
		earth = nil
	end

	----------------------------------------------------------------
	-- Phase 4 + 5: each click chips rubble AND morphs the meteor a step toward the real Cookie.
	----------------------------------------------------------------
	local clickDetector = Instance.new("ClickDetector")
	clickDetector.MaxActivationDistance = 32
	clickDetector.CursorIcon = ""
	clickDetector.Parent = meteor

	local prompt = Instance.new("BillboardGui")
	prompt.Name = "IntroClearPrompt"
	prompt.Size = UDim2.fromOffset(220, 50)
	prompt.StudsOffset = Vector3.new(0, 6, 0)
	prompt.AlwaysOnTop = true
	prompt.Adornee = meteor
	prompt.Parent = meteor
	local promptLabel = Instance.new("TextLabel")
	promptLabel.Size = UDim2.fromScale(1, 1)
	promptLabel.BackgroundTransparency = 1
	promptLabel.Font = Enum.Font.ArialBold
	promptLabel.TextScaled = true
	promptLabel.TextColor3 = Color3.fromRGB(255, 255, 255)
	promptLabel.TextStrokeTransparency = 0
	promptLabel.Text = UserInputService.TouchEnabled and "Tap to clear the rubble!" or "Click to clear the rubble!"
	promptLabel.Parent = prompt

	local SINK_INFO = TweenInfo.new(0.35, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
	local MORPH_INFO = TweenInfo.new(MORPH_STEP_TIME, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)

	local function chipAway(parts)
		for _, part in ipairs(parts) do
			local target = part:GetPivot() - Vector3.new(0, 6, 0)
			local tween = TweenService:Create(part, SINK_INFO, { CFrame = target, Transparency = 1 })
			tween:Play()
			tween.Completed:Connect(function()
				part:Destroy()
			end)
		end
	end

	-- Morph references: meteor starts at its crater rest pose/size, target is the real Cookie.
	local meteorStartSize = meteor.Size
	local meteorStartCF = meteor:GetPivot()

	local clicksLeft = CLICKS_TO_CLEAR
	local clearing = false
	clickDetector.MouseClick:Connect(function(clicker)
		if clearing or clicker ~= player then
			return
		end
		clicksLeft -= 1
		local progress = (CLICKS_TO_CLEAR - clicksLeft) / CLICKS_TO_CLEAR -- 1/N .. N/N

		-- Chip a slice of the remaining rubble (all of it on the final click).
		local remainingRubble = {}
		for _, part in ipairs(rubble) do
			if part.Parent then
				table.insert(remainingRubble, part)
			end
		end
		local sliceCount = math.ceil(#remainingRubble / (clicksLeft + 1))
		local slice = {}
		for i = 1, math.min(sliceCount, #remainingRubble) do
			table.insert(slice, remainingRubble[i])
		end
		chipAway(slice)

		-- Step the meteor toward the Cookie's exact size / rotation / position.
		local stepTween = TweenService:Create(meteor, MORPH_INFO, {
			Size = meteorStartSize:Lerp(cookie.Size, progress),
			CFrame = meteorStartCF:Lerp(cookie.CFrame, progress),
		})
		stepTween:Play()

		if clicksLeft <= 0 then
			clearing = true
			setEffectEnabled(meteor, "Smoke", false)
			stepTween.Completed:Wait()
			-- Meteor now coincides with the Cookie: reveal the real Cookie and remove the clone.
			cookie.LocalTransparencyModifier = 0
			craterDestroyed = true
			craterClone:Destroy()
			markRubbleCleared()
			running = false
		else
			promptLabel.Text = "Keep clicking! (" .. clicksLeft .. ")"
		end
	end)
end

----------------------------------------------------------------------
-- Auto-play gate: brand-new accounts only
----------------------------------------------------------------------

-- Wait for the server to seed the decision attribute, then play only for a genuine first-timer.
-- A timeout falls back to "skip" so a missing attribute never plays the cutscene.
local function shouldPlay()
	local deadline = os.clock() + INTRO_DECISION_TIMEOUT
	while player:GetAttribute(Attrs.StoryStep) == nil and os.clock() < deadline do
		task.wait(0.1)
	end
	return player:GetAttribute(Attrs.StoryStep) == StoryConfig.STEPS.Meteor
end

task.spawn(function()
	if shouldPlay() then
		playIntro({ markSeen = false, allowSkip = false, completeStory = true })
	end
end)

local function replayFullChapter()
	if running then
		return
	end

	Net.fireServer(Net.Names.StoryAction, "ResetChapter")

	local deadline = os.clock() + 5
	while os.clock() < deadline do
		local resetComplete = player:GetAttribute(Attrs.StoryStep) == StoryConfig.STEPS.Meteor
			and player:GetAttribute(Attrs.StoryHealingClicks) == 0
			and player:GetAttribute(Attrs.MixerUnlocked) == false
		if resetComplete then
			playIntro({ markSeen = false, allowSkip = false, completeStory = true })
			return
		end
		task.wait(0.05)
	end

	warn("IntroController: timed out waiting for the Chapter 1 replay reset.")
end

local replayEvent = getReplayEvent()
if replayEvent then
	replayEvent.Event:Connect(function()
		task.spawn(replayFullChapter)
	end)
end

-- Studio dev controls: test the goo joy animation or replay Chapter 1 on demand.
----------------------------------------------------------------------

if RunService:IsStudio() then
	local playerGui = player:WaitForChild("PlayerGui")

	local gui = Instance.new("ScreenGui")
	gui.Name = "StoryDevPanel"
	gui.ResetOnSpawn = false
	gui.DisplayOrder = 1000
	gui.Parent = playerGui

	local function makeDevButton(text, y, color, onActivated)
		local button = Instance.new("TextButton")
		button.Size = UDim2.fromOffset(150, 32)
		button.Position = UDim2.fromOffset(12, y)
		button.BackgroundColor3 = color
		button.TextColor3 = Color3.fromRGB(235, 235, 245)
		button.Font = Enum.Font.GothamBold
		button.TextSize = 14
		button.Text = text
		button.AutoButtonColor = true
		button.Parent = gui
		local uiCorner = Instance.new("UICorner")
		uiCorner.CornerRadius = UDim.new(0, 6)
		uiCorner.Parent = button

		button.Activated:Connect(onActivated)
		return button
	end

	makeDevButton("Goo Joy Test", 280, Color3.fromRGB(42, 112, 104), function()
		Net.fireServer(Net.Names.StoryAction, "DebugPlayJoy")
	end)

	makeDevButton("\u{21BB} Replay Chapter 1", 318, Color3.fromRGB(60, 46, 120), function()
		task.spawn(replayFullChapter)
	end)
end
