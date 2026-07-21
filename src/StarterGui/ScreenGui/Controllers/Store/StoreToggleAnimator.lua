-- StoreToggleAnimator: owns the StoreBottom open/close cookie toggle's visual feedback — the
-- cookie/hands launcher, the active-state split-cookie artwork, and the open/close fly
-- animation. It only BINDS to UI authored in Studio (StoreBottom.TopBar.StoreBottomOff/On,
-- with a legacy buildModeToggleOff/On fallback) and never builds instances. Split out of the
-- old BuildToggleAnimator when the store band was decoupled from build mode (the cookie now
-- drives the STORE, not build mode).
--
-- Reactive contract: the animation is driven entirely by the ScreenGui StoreOpen attribute
-- (StoreToggleController owns it). When StoreOpen flips true the cookie launches up and blooms
-- into the active toggle; when it flips false the cookie descends back to the launcher. Because
-- both the button click and the B keybind flip the same attribute, every entry path animates
-- identically — there is no keyboard "teleport" special-case (that bug lived in the old
-- scheduleActiveToggleLanding/launchInFlight path, now deleted).
--
-- ctx: { screenGui, store, setStoreOpen }. setStoreOpen(open) is called from the button input
-- (the controller flips the attribute, the watcher below plays the animation).
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TextService = game:GetService("TextService")
local UserInputService = game:GetService("UserInputService")

local shared = ReplicatedStorage:WaitForChild("Shared")
local Attrs = require(shared:WaitForChild("Attrs"))
local GuiNames = require(shared:WaitForChild("GuiNames"))
local UiMotion = require(shared:WaitForChild("UiMotion"))

local StoreToggleAnimator = {}

function StoreToggleAnimator.new(ctx)
	local screenGui = ctx.screenGui
	local store = ctx.store
	local setStoreOpen = ctx.setStoreOpen

	local topBar = store and store:FindFirstChild("TopBar")
	-- StoreBottomOff is the closed-state cookie/hands launcher; StoreBottomOn is the open-state
	-- split-cookie artwork. Resolve the current names first, then the legacy buildModeToggle*
	-- names so the controller keeps working before the Studio instance rename.
	local function resolve(currentName, legacyName)
		return (topBar and topBar:FindFirstChild(currentName))
			or (store and store:FindFirstChild(currentName))
			or screenGui:FindFirstChild(currentName)
			or (topBar and topBar:FindFirstChild(legacyName))
			or (store and store:FindFirstChild(legacyName))
			or screenGui:FindFirstChild(legacyName)
	end
	local toggleOff = resolve(GuiNames.StoreBottomOff, "buildModeToggleOff")
	local toggleOn = resolve(GuiNames.StoreBottomOn, "buildModeToggleOn")
	local cookieToggle = toggleOff
	local buildModeCookie = toggleOff and toggleOff:FindFirstChild("cookie")
	local buildModeCookieBackground = toggleOff and toggleOff:FindFirstChild("cookieBackground")
	-- The active toggle's split cookie: two halves (each a background image with a nested cookie)
	-- plus the "Build"/"Sell"/"Store" label inside a clip wrapper that unscrolls as the halves part.
	local cookieBackgroundLeft = toggleOn and toggleOn:FindFirstChild("cookieBackgroundLeft")
	local cookieBackgroundRight = toggleOn and toggleOn:FindFirstChild("cookieBackgroundRight")
	local buildLabelClip = toggleOn and toggleOn:FindFirstChild("buildLabelClip")
	local buildLabel = buildLabelClip and buildLabelClip:FindFirstChild("buildLabel")
	local buildLabelBack = toggleOn and toggleOn:FindFirstChild("buildLabelBack")
	local toggleButton = store and store:FindFirstChild("BuildViewToggle")
	local imageToggleHitbox = toggleOff and toggleOff:FindFirstChild("hitbox")
	local activeToggleHitbox = toggleOn
		and (toggleOn:FindFirstChild("hitbox") or (toggleOn:IsA("GuiButton") and toggleOn or nil))
	if not activeToggleHitbox and toggleOn then
		activeToggleHitbox = toggleOn:FindFirstChildWhichIsA("GuiButton", true)
	end
	if toggleButton and not toggleButton:IsA("GuiButton") then
		toggleButton = nil
	end
	if imageToggleHitbox and not imageToggleHitbox:IsA("GuiButton") then
		imageToggleHitbox = nil
	end
	if activeToggleHitbox and not activeToggleHitbox:IsA("GuiButton") then
		activeToggleHitbox = nil
	end
	if imageToggleHitbox then
		imageToggleHitbox.BackgroundTransparency = 1
		imageToggleHitbox.BorderSizePixel = 0
		imageToggleHitbox.AutoButtonColor = false
		if imageToggleHitbox:IsA("TextButton") then
			imageToggleHitbox.Text = ""
			imageToggleHitbox.TextTransparency = 1
		end
	end
	if activeToggleHitbox then
		activeToggleHitbox.BackgroundTransparency = 1
		activeToggleHitbox.BorderSizePixel = 0
		activeToggleHitbox.AutoButtonColor = false
		if activeToggleHitbox:IsA("TextButton") then
			activeToggleHitbox.Text = ""
			activeToggleHitbox.TextTransparency = 1
		end
	end

	local cookieBasePosition = buildModeCookie and buildModeCookie.Position
	local cookieBaseVisible = buildModeCookie and buildModeCookie.Visible
	local cookieBackgroundBasePosition = buildModeCookieBackground and buildModeCookieBackground.Position
	local cookieBackgroundBaseVisible = buildModeCookieBackground and buildModeCookieBackground.Visible
	local toggleOffBaseVisible = toggleOff and toggleOff.Visible
	local toggleOffBaseZIndex = toggleOff and toggleOff.ZIndex
	-- The active toggle's authored home position (it parks above the viewport during placement).
	local toggleOnHomePosition = toggleOn and toggleOn.Position
	-- Authored positions are the OPEN (split) pose; closed = both halves stacked at centre.
	local splitOpenLeft = cookieBackgroundLeft and cookieBackgroundLeft.Position
	local splitOpenRight = cookieBackgroundRight and cookieBackgroundRight.Position
	local SPLIT_CLOSED_OFFSET = 21 -- Adjust this manually to align the swapped image canvases.
	local splitClosedLeft = UDim2.new(0.5, -SPLIT_CLOSED_OFFSET, 0.5, 0)
	local splitClosedRight = UDim2.new(0.5, SPLIT_CLOSED_OFFSET, 0.5, 0)
	local clipOpenSize = nil
	local clipClosedSize = nil
	-- buildLabelBack (the backing behind the label) tracks the same width span, keeping its own height.
	local backOpenSize = nil
	local backClosedSize = nil
	local toggleOnAuthoredSize = toggleOn and toggleOn.Size
	local authoredLabelTextWidth = buildLabel
		and TextService:GetTextSize(buildLabel.Text, buildLabel.TextSize, buildLabel.Font, Vector2.new(10000, 10000)).X

	-- Preserve the authored Build-label padding, but let every other mode word contribute its
	-- actual rendered-width difference. The label clip is scale-sized to this frame, so resizing
	-- StoreBottomOn also keeps its backing, split-cookie positions, and hitbox in sync.
	local function getToggleOnOpenSize()
		if not (toggleOnAuthoredSize and buildLabel and authoredLabelTextWidth) then
			return toggleOnAuthoredSize
		end
		local textWidth =
			TextService:GetTextSize(buildLabel.Text, buildLabel.TextSize, buildLabel.Font, Vector2.new(10000, 10000)).X
		local widthOffset = math.max(0, toggleOnAuthoredSize.X.Offset + textWidth - authoredLabelTextWidth)
		return UDim2.new(
			toggleOnAuthoredSize.X.Scale,
			widthOffset,
			toggleOnAuthoredSize.Y.Scale,
			toggleOnAuthoredSize.Y.Offset
		)
	end

	-- Tween the clip between its authored open width and an exact zero width. Keeping these fixed
	-- avoids marker rounding drift and translucent seams during rapid hover reversals.
	if buildLabelClip then
		local openW = buildLabelClip.Size.X
		local clipHeight = buildLabelClip.Size.Y
		clipOpenSize = UDim2.new(openW.Scale, openW.Offset, clipHeight.Scale, clipHeight.Offset)
		clipClosedSize = UDim2.new(0, 0, clipHeight.Scale, clipHeight.Offset)
		if buildLabelBack then
			local backHeight = buildLabelBack.Size.Y
			backOpenSize = UDim2.new(openW.Scale, openW.Offset, backHeight.Scale, backHeight.Offset)
			backClosedSize = UDim2.new(0, 0, backHeight.Scale, backHeight.Offset)
		end
	end
	local cookieTweens = {}
	local splitTweens = {}
	local splitToken = 0
	local splitIsOpen = false
	local placementTween = nil
	local launchToken = 0
	local cookieLaunchInProgress = false
	local cookiePressHeld = false
	local mixerGateVisible = false
	-- Full-screen launch (Off -> On) and its mirror descent (On -> Off). Kept a touch slow so the
	-- cookie reads clearly as it crosses the whole screen.
	local COOKIE_LAUNCH_INFO = TweenInfo.new(0.4, Enum.EasingStyle.Quint, Enum.EasingDirection.Out)
	local COOKIE_DESCENT_INFO = TweenInfo.new(0.4, Enum.EasingStyle.Quint, Enum.EasingDirection.Out)
	-- While the cookie is in flight from the bottom launcher up to the active toggle, lift the
	-- whole launcher above the rest of the HUD (store band, menu pill, etc.). The ScreenGui uses
	-- Sibling ZIndexBehavior, so it's the launcher's own ZIndex -- not the cookie's -- that wins.
	local TOGGLE_OFF_FLIGHT_ZINDEX = 250
	-- The split-cookie bloom (open) and the hover/exit close.
	local COOKIE_OPEN_INFO = TweenInfo.new(0.26, Enum.EasingStyle.Quint, Enum.EasingDirection.Out)
	local COOKIE_CLOSE_INFO = TweenInfo.new(0.16, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)

	-- Store is "showing" (active On toggle owns the cookie) iff the StoreOpen attribute is set.
	-- This is the single source of truth the whole animator branches on.
	local function storeShowing()
		return screenGui:GetAttribute(Attrs.StoreOpen) == true
	end

	local function backgroundControlsAvailable()
		return screenGui:GetAttribute(Attrs.BackgroundSurfacesSuspended) ~= true
	end

	local function offsetCookiePosition(yOffset)
		if not cookieBasePosition then
			return UDim2.new()
		end
		return UDim2.new(
			cookieBasePosition.X.Scale,
			cookieBasePosition.X.Offset,
			cookieBasePosition.Y.Scale,
			cookieBasePosition.Y.Offset + yOffset
		)
	end

	local function offsetCookieBackgroundPosition(yOffset)
		if not cookieBackgroundBasePosition then
			return UDim2.new()
		end
		return UDim2.new(
			cookieBackgroundBasePosition.X.Scale,
			cookieBackgroundBasePosition.X.Offset,
			cookieBackgroundBasePosition.Y.Scale,
			cookieBackgroundBasePosition.Y.Offset + yOffset
		)
	end

	-- The Y offset (in the launcher cookie's local space) that lands its centre exactly on the
	-- active toggle's cookie, so the in-flight cookie can hand off seamlessly on arrival. The
	-- toggles carry no UIScale, so 1 offset px == 1 screen px and we can mix offset/absolute.
	local function getLauncherScale()
		if toggleOff and toggleOff.Size.Y.Scale == 0 and toggleOff.Size.Y.Offset > 0 then
			local abs = toggleOff.AbsoluteSize.Y
			if abs > 0 then
				return abs / toggleOff.Size.Y.Offset
			end
		end
		return 1
	end

	local function getLaunchTargetOffset()
		if not toggleOn or not buildModeCookie or not cookieBasePosition then
			return -34
		end
		local scale = getLauncherScale()
		local currentRel = buildModeCookie.Position.Y.Offset - cookieBasePosition.Y.Offset
		-- Cookie centre (absolute) if it were parked at base, then the active toggle's centre.
		local baseCentreY = (buildModeCookie.AbsolutePosition.Y - currentRel * scale) + buildModeCookie.AbsoluteSize.Y / 2
		local onCentreY = toggleOn.AbsolutePosition.Y + toggleOn.AbsoluteSize.Y / 2
		-- Convert the absolute gap back into the launcher's local Position.Y.Offset units.
		return (onCentreY - baseCentreY) / scale
	end

	local function cancelCookieTweens()
		for _, tween in ipairs(cookieTweens) do
			tween:Cancel()
		end
		table.clear(cookieTweens)
	end

	local function cancelSplitTweens()
		for _, tween in ipairs(splitTweens) do
			tween:Cancel()
		end
		table.clear(splitTweens)
	end

	-- Open/close the two cookie halves between the whole-cookie pose (centred) and their authored
	-- split positions, driving buildLabelClip's width in lockstep so the label unscrolls from the
	-- centre exactly as the halves part. animate=false snaps instantly.
	local function setSplitOpen(open, animate)
		animate = animate == true
		splitToken += 1
		splitIsOpen = open
		cancelSplitTweens()

		local info = open and COOKIE_OPEN_INFO or COOKIE_CLOSE_INFO
		local function drive(object, goal)
			if not object or not goal then
				return
			end
			if animate then
				local tween = UiMotion.create(object, info, goal)
				table.insert(splitTweens, tween)
				tween:Play()
			else
				for prop, value in pairs(goal) do
					object[prop] = value
				end
			end
		end

		drive(cookieBackgroundLeft, splitOpenLeft and { Position = open and splitOpenLeft or splitClosedLeft })
		drive(cookieBackgroundRight, splitOpenRight and { Position = open and splitOpenRight or splitClosedRight })
		if open then
			drive(toggleOn, toggleOnAuthoredSize and { Size = getToggleOnOpenSize() })
		end
		drive(buildLabelClip, clipOpenSize and { Size = open and clipOpenSize or clipClosedSize })
		drive(buildLabelBack, backOpenSize and { Size = open and backOpenSize or backClosedSize })
	end

	local function playCookieTween(info, goals)
		if not buildModeCookie then
			return nil
		end
		-- Mirror the cookie's Y movement onto cookieBackground 1:1 so it always rides beneath it
		-- (lower ZIndex) through every hover/press/recoil/launch tween.
		if buildModeCookieBackground and cookieBackgroundBasePosition and cookieBasePosition and goals.Position then
			local yOffset = goals.Position.Y.Offset - cookieBasePosition.Y.Offset
			local bgTween = UiMotion.create(buildModeCookieBackground, info, {
				Position = offsetCookieBackgroundPosition(yOffset),
			})
			table.insert(cookieTweens, bgTween)
			bgTween.Completed:Once(function()
				for index, activeTween in ipairs(cookieTweens) do
					if activeTween == bgTween then
						table.remove(cookieTweens, index)
						break
					end
				end
			end)
			bgTween:Play()
		end
		local tween = UiMotion.create(buildModeCookie, info, goals)
		table.insert(cookieTweens, tween)
		tween.Completed:Once(function()
			for index, activeTween in ipairs(cookieTweens) do
				if activeTween == tween then
					table.remove(cookieTweens, index)
					break
				end
			end
		end)
		tween:Play()
		return tween
	end

	local function setCookieVisible(visible)
		if buildModeCookie and buildModeCookie:IsA("GuiObject") then
			buildModeCookie.Visible = visible and cookieBaseVisible ~= false
		end
		if buildModeCookieBackground and buildModeCookieBackground:IsA("GuiObject") then
			buildModeCookieBackground.Visible = visible and cookieBackgroundBaseVisible ~= false
		end
	end

	local function setToggleOffVisible(visible)
		if toggleOff and toggleOff:IsA("GuiObject") then
			toggleOff.Visible = visible
				and toggleOffBaseVisible ~= false
				and mixerGateVisible
				and backgroundControlsAvailable()
		end
	end

	-- While a building is being placed, slide the active toggle up off the top of the screen (the
	-- mirror of the store sliding down off the bottom) so the plot is unobstructed, then slide it
	-- back on placement end. Driven off the PlacementActive attribute, so it's identical on PC/mobile.
	local PLACEMENT_TWEEN_INFO = TweenInfo.new(0.22, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
	local function cancelPlacementTween()
		if placementTween then
			placementTween:Cancel()
			placementTween = nil
		end
	end

	local function getToggleParkedPosition()
		local height = toggleOn.AbsoluteSize.Y
		if height <= 0 then
			height = toggleOn.Size.Y.Offset
		end
		return UDim2.new(
			toggleOnHomePosition.X.Scale,
			toggleOnHomePosition.X.Offset,
			toggleOnHomePosition.Y.Scale,
			toggleOnHomePosition.Y.Offset - (height + 48)
		)
	end

	local function setTogglePlacementParked(parked, animate)
		if not toggleOn or not toggleOnHomePosition then
			return
		end
		cancelPlacementTween()
		local target = parked and getToggleParkedPosition() or toggleOnHomePosition
		if animate then
			placementTween = UiMotion.create(toggleOn, PLACEMENT_TWEEN_INFO, { Position = target })
			placementTween:Play()
		else
			toggleOn.Position = target
		end
	end

	local function setToggleOnVisible(visible)
		if toggleOn and toggleOn:IsA("GuiObject") then
			toggleOn.Visible = visible and mixerGateVisible and backgroundControlsAvailable()
			if not visible then
				-- Reset to the whole-cookie pose + home position so the next entry starts clean
				-- (and the launch targets the home centre, not a parked-up pose).
				cancelPlacementTween()
				if toggleOnHomePosition then
					toggleOn.Position = toggleOnHomePosition
				end
				setSplitOpen(false, false)
			end
		end
	end

	-- The open store toggle's label follows the active store mode: Build/Sell on the Buildings
	-- tab, Buy on tabs where sell mode does not apply.
	local function getModeLabel()
		local category = store and store:GetAttribute(Attrs.CurrentCategory)
		if category == "Robux" then
			return "Robux"
		end
		if category and category ~= "Building" then
			return "Buy"
		end
		return (screenGui:GetAttribute(Attrs.SellMode) == true) and "Sell" or "Build"
	end

	local function setLabelText()
		if buildLabel then
			buildLabel.Text = getModeLabel()
		end
	end

	-- The active toggle's entrance: show it as a whole cookie (halves stacked at centre, matching
	-- the just-arrived flying cookie), then bloom the halves open and unscroll the label.
	local function showActiveToggleOpen()
		setToggleOffVisible(false)
		setToggleOnVisible(true)
		setLabelText()
		setSplitOpen(false, false)
		setSplitOpen(true, true)
	end

	-- Let the cookie + cookieBackground overflow the launcher so they stay visible the whole way
	-- up the screen during the launch, and pin the background just beneath the cookie.
	if toggleOff then
		toggleOff.ClipsDescendants = false
	end
	if buildModeCookieBackground and buildModeCookie and buildModeCookieBackground.ZIndex >= buildModeCookie.ZIndex then
		buildModeCookieBackground.ZIndex = buildModeCookie.ZIndex - 1
	end

	-- Exit mirror of the launch: drop the cookie (background beneath it) from the active toggle's
	-- cookie height back down to the launcher, kept visible above the HUD the whole way, then land
	-- with the catch recoil.
	local function playStoreClose()
		if not buildModeCookie or not cookieBasePosition then
			-- No cookie art: just swap back to the closed launcher.
			setToggleOnVisible(false)
			setToggleOffVisible(true)
			return
		end
		cookiePressHeld = false
		launchToken += 1
		local token = launchToken
		cancelCookieTweens()

		setToggleOnVisible(false)
		setToggleOffVisible(true)
		if toggleOff then
			toggleOff.ZIndex = TOGGLE_OFF_FLIGHT_ZINDEX
		end

		-- Park the cookie + background up at the active cookie's height, then fall to rest.
		local startOffset = getLaunchTargetOffset()
		buildModeCookie.Position = offsetCookiePosition(startOffset)
		if buildModeCookieBackground and cookieBackgroundBasePosition then
			buildModeCookieBackground.Position = offsetCookieBackgroundPosition(startOffset)
		end
		setCookieVisible(true)

		local function onArrive()
			if token ~= launchToken then
				return
			end
			if toggleOff and toggleOffBaseZIndex then
				toggleOff.ZIndex = toggleOffBaseZIndex
			end
			-- Landed in the slot: hide the cookie so the launcher is invisible at idle (the hotbar's
			-- grown mixer icon is the resting face). No catch recoil. The ZIndex reset above is what
			-- the HotbarCarousel watches to play its grow-in handoff.
			setCookieVisible(false)
		end

		local tween = playCookieTween(COOKIE_DESCENT_INFO, { Position = offsetCookiePosition(0) })
		if tween then
			tween.Completed:Once(function(state)
				if state == Enum.PlaybackState.Completed then
					onArrive()
				end
			end)
		else
			onArrive()
		end
	end

	-- Entry: shoot the cookie (background riding beneath it) all the way up to the active toggle's
	-- cookie, kept visible above the HUD, then swap to the active artwork the instant it arrives so
	-- it reads as one continuous shot from the bottom launcher to the top. Reactive to StoreOpen,
	-- so the click and the B keybind share this exact animation (no teleport).
	local function playStoreOpen()
		if not buildModeCookie or not cookieBasePosition then
			-- No cookie art: just swap to the active toggle.
			showActiveToggleOpen()
			return
		end
		cookiePressHeld = false
		launchToken += 1
		local token = launchToken
		cookieLaunchInProgress = true
		cancelCookieTweens()

		setCookieVisible(true)
		if toggleOff then
			toggleOff.ZIndex = TOGGLE_OFF_FLIGHT_ZINDEX
		end

		local function restoreLauncher()
			if toggleOff and toggleOffBaseZIndex then
				toggleOff.ZIndex = toggleOffBaseZIndex
			end
			buildModeCookie.Position = offsetCookiePosition(0)
			if buildModeCookieBackground and cookieBackgroundBasePosition then
				buildModeCookieBackground.Position = offsetCookieBackgroundPosition(0)
			end
		end

		local launchTween = playCookieTween(COOKIE_LAUNCH_INFO, { Position = offsetCookiePosition(getLaunchTargetOffset()) })
		if launchTween then
			launchTween.Completed:Once(function()
				cookieLaunchInProgress = false
				if token ~= launchToken then
					return
				end
				if storeShowing() then
					-- Reached the active toggle: hide the flying pieces and hand off to the
					-- split-cookie bloom-open.
					setCookieVisible(false)
					showActiveToggleOpen()
				else
					-- Store was closed again mid-flight: hide the cookie (idle is invisible now).
					setCookieVisible(false)
				end
				restoreLauncher()
			end)
		else
			cookieLaunchInProgress = false
			showActiveToggleOpen()
			restoreLauncher()
		end
	end

	local function holdCookiePress()
		if not buildModeCookie or not cookieBasePosition then
			return
		end
		if cookieLaunchInProgress then
			return
		end

		-- The launcher cookie is invisible at idle now (the hotbar icon is the face), so the press has
		-- no squish art -- it just arms the release, which flips StoreOpen and runs the launch.
		cookiePressHeld = true
	end

	-- Release of the launcher press = request the store to open. Flipping StoreOpen drives the
	-- launch animation through the attribute watcher below (same path the B keybind takes).
	local function releaseCookiePress()
		if not cookiePressHeld then
			return
		end
		cookiePressHeld = false
		if setStoreOpen then
			setStoreOpen(true)
		end
	end

	local function connectCookiePressRelease(hitbox)
		hitbox.InputBegan:Connect(function(input)
			if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
				holdCookiePress()
			end
		end)

		hitbox.InputEnded:Connect(function(input)
			if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
				releaseCookiePress()
			end
		end)

		UserInputService.InputEnded:Connect(function(input)
			if input.UserInputType ~= Enum.UserInputType.MouseButton1 and input.UserInputType ~= Enum.UserInputType.Touch then
				return
			end
			releaseCookiePress()
		end)
	end

	-- Reflect the open state on the toggles' Active attribute so any authored hover/active styling
	-- the user wired in Studio still tracks the store band.
	local function reflectActiveAttribute(open)
		if cookieToggle then
			cookieToggle:SetAttribute(Attrs.Active, open)
		end
		if toggleOn then
			toggleOn:SetAttribute(Attrs.Active, open)
		end
		if imageToggleHitbox then
			imageToggleHitbox:SetAttribute(Attrs.Active, open)
		end
		if activeToggleHitbox then
			activeToggleHitbox:SetAttribute(Attrs.Active, open)
		end
		if toggleButton then
			toggleButton:SetAttribute(Attrs.Active, open)
		end
	end

	-- ── Initial closed pose ─────────────────────────────────────────────────────────
	setToggleOnVisible(false)
	setToggleOffVisible(true)
	setCookieVisible(false) -- launcher cookie is invisible at idle; the hotbar icon is the resting face
	reflectActiveAttribute(false)

	-- ── Reactive driver: StoreOpen owns the animation ───────────────────────────────
	local storeOpenState = storeShowing()
	local function onStoreOpenChanged()
		local open = storeShowing()
		if open == storeOpenState then
			return
		end
		storeOpenState = open
		reflectActiveAttribute(open)
		if open then
			playStoreOpen()
		else
			playStoreClose()
		end
	end
	screenGui:GetAttributeChangedSignal(Attrs.StoreOpen):Connect(onStoreOpenChanged)
	if storeOpenState then
		-- Already open at construction (rare): show the active toggle without a fly-in.
		reflectActiveAttribute(true)
		showActiveToggleOpen()
	end

	-- ── Button input ────────────────────────────────────────────────────────────────
	-- Legacy text toggle: flip the store open/closed.
	if toggleButton then
		toggleButton.Activated:Connect(function()
			if setStoreOpen then
				setStoreOpen(not storeShowing())
			end
		end)
	end

	-- Closed launcher (StoreBottomOff): the cookie is invisible at idle, so there's no hover/press
	-- art -- the hitbox just arms press/release to open the store.
	if imageToggleHitbox then
		connectCookiePressRelease(imageToggleHitbox)
	end

	-- Active toggle (StoreBottomOn): hover closes the split; click closes the store.
	if activeToggleHitbox then
		-- Hover-to-close is a mouse-only affordance. On touch there's no hover, and a tap fires
		-- MouseEnter + Activated together -- if MouseEnter pre-closed the split, Activated would
		-- see it "already closed" and drop immediately. Gating on MouseEnabled keeps the split open
		-- on mobile so the tap itself closes-then-drops (below).
		activeToggleHitbox.MouseEnter:Connect(function()
			if UserInputService.MouseEnabled and storeShowing() then
				setSplitOpen(false, true)
			end
		end)
		activeToggleHitbox.MouseLeave:Connect(function()
			if UserInputService.MouseEnabled and storeShowing() then
				setSplitOpen(true, true)
			end
		end)
		-- On mobile there's no hover to pre-close the cookie, so a tap while it's open must tween
		-- it closed first, then drop -- otherwise it drops mid-close and looks off. When already
		-- closed (e.g. PC hover), drop immediately.
		local dropPending = false
		activeToggleHitbox.Activated:Connect(function()
			if dropPending then
				return
			end
			if splitIsOpen then
				dropPending = true
				setSplitOpen(false, true)
				task.delay(COOKIE_CLOSE_INFO.Time, function()
					dropPending = false
					if storeShowing() and setStoreOpen then
						setStoreOpen(false)
					end
				end)
			elseif setStoreOpen then
				setStoreOpen(false)
			end
		end)
	end

	-- The label reads Build/Sell/Buy; keep it correct while the active toggle is showing.
	-- Category or sell-mode changes flip the word with a furl/unfurl if the cookie is open.
	local sellSwapToken = 0
	local function animateLabelSwap()
		if not storeShowing() then
			setLabelText()
			return
		end
		sellSwapToken += 1
		local token = sellSwapToken
		setSplitOpen(false, true)
		-- Hold the furled cookie an extra 0.4s before reopening so the word swap reads slower.
		task.delay(COOKIE_CLOSE_INFO.Time + 0.4, function()
			if token ~= sellSwapToken or not storeShowing() then
				return
			end
			setLabelText()
			setSplitOpen(true, true)
		end)
	end
	if buildLabel then
		screenGui:GetAttributeChangedSignal(Attrs.SellMode):Connect(animateLabelSwap)
		if store then
			store:GetAttributeChangedSignal(Attrs.CurrentCategory):Connect(animateLabelSwap)
		end
	end

	-- Park the active toggle above the viewport while a building is being placed (mirrors the store
	-- sliding off the bottom), and bring it back when placement ends. Only acts while the store owns
	-- the active toggle.
	if toggleOn then
		screenGui:GetAttributeChangedSignal(Attrs.PlacementActive):Connect(function()
			if not storeShowing() then
				return
			end
			setTogglePlacementParked(screenGui:GetAttribute(Attrs.PlacementActive) == true, true)
		end)
	end

	-- Mixer gate: the controller hides both toggles entirely until building is unlocked, then
	-- restores them to the current store state. Keeps the gate decision with the controller while
	-- the instance resolution stays here.
	local function setGatedVisible(visible)
		mixerGateVisible = visible == true
		if not visible then
			setToggleOffVisible(false)
			setToggleOnVisible(false)
			return
		end
		if storeShowing() then
			setToggleOffVisible(false)
			setToggleOnVisible(true)
		else
			setToggleOnVisible(false)
			setToggleOffVisible(true)
		end
	end
	screenGui:GetAttributeChangedSignal(Attrs.BackgroundSurfacesSuspended):Connect(function()
		setGatedVisible(mixerGateVisible)
	end)

	return {
		setGatedVisible = setGatedVisible,
	}
end

return StoreToggleAnimator
