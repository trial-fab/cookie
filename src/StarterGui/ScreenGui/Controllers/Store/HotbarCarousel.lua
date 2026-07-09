-- HotbarCarousel: the custom item hotbar / carousel (Phase 1 toolbar). It only BINDS to the
-- Studio-authored Hotbar scaffold (ScreenGui.Hotbar with round SlotLeft/SlotCenter/SlotRight
-- frames, each a disc with an `icon` + `hitbox`) and never builds instances. SlotCenter is the
-- mixer (item #1, the gifted mixer that opens the store); the flanks are placeholders until more
-- items exist. Constructed by StoreToggleController as a ctx module sharing setStoreOpen.
--
-- State machine (see docs/ReleaseRoadMap.md "Custom toolbar / hotbar carousel"):
--   * Toolbar visible, store closed: tapping a non-centred slot spins it to centre (it becomes
--     active). Tapping/selecting the mixer (or B) opens the store, but only AFTER any spin settles.
--   * Open MORPH: the SlotCenter disc shrinks into the cookie's footprint (still opaque, so the
--     coloured disc reads as the cookie background), THEN -- as the StoreBottomOff cookie launches
--     up in its place -- the disc fades out. The placeholders hide. So the disc "becomes" the cookie.
--   * Close: placeholders return; the centre slot stays empty (disc invisible) while the cookie
--     descends into it; on landing the disc reappears at the cookie footprint and GROWS back to its
--     full authored size about its centre (the cookie reconstitutes into the disc).
--
-- StoreBottomOff is the flight actor only (its cookie art is invisible at idle -- see
-- StoreToggleAnimator). The mixer TAP is owned by SlotCenter.hitbox, which renders above the
-- launcher (Hotbar ZIndex > StoreBottomOff), so we can sequence the shrink before the launch.
--
-- ctx: { screenGui, store, setStoreOpen }.
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local StarterGui = game:GetService("StarterGui")
local UserInputService = game:GetService("UserInputService")

local shared = ReplicatedStorage:WaitForChild("Shared")
local Attrs = require(shared:WaitForChild("Attrs"))
local GuiNames = require(shared:WaitForChild("GuiNames"))
local MobileScale = require(shared:WaitForChild("MobileScale"))

local HotbarCarousel = {}

-- Slow enough to read as a deliberate cycle; the open gate waits exactly this long before firing.
local SPIN_INFO = TweenInfo.new(0.32, Enum.EasingStyle.Quint, Enum.EasingDirection.Out)
-- Open morph: shrink the disc into the cookie footprint, then fade it as the cookie launches.
local SHRINK_INFO = TweenInfo.new(0.14, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local FADE_INFO = TweenInfo.new(0.22, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
-- Close grow: the disc reappears at the footprint and expands back to full about its centre.
local GROW_INFO = TweenInfo.new(0.2, Enum.EasingStyle.Back, Enum.EasingDirection.Out)
-- Disc shrink target as a fraction of the cookie background's on-screen size (a touch smaller, so it
-- tucks inside the cookie before the cookie takes over).
local FOOTPRINT_FACTOR = 0.85
local KEYBIND_BADGE_NAME = "KeybindBadge"
local HOTBAR_MOBILE_SCALE = 0.82 -- match StoreBottom's mobile shrink

function HotbarCarousel.new(ctx)
	local screenGui = ctx.screenGui
	local setStoreOpen = ctx.setStoreOpen

	-- Hide Roblox's default backpack so the custom bar doesn't double up with the real hotbar.
	pcall(function()
		StarterGui:SetCoreGuiEnabled(Enum.CoreGuiType.Backpack, false)
	end)

	local hotbar = screenGui:FindFirstChild(GuiNames.Hotbar)
	local slotCenter = hotbar and hotbar:FindFirstChild("SlotCenter")
	local slotLeft = hotbar and hotbar:FindFirstChild("SlotLeft")
	local slotRight = hotbar and hotbar:FindFirstChild("SlotRight")

	-- No scaffold (or the user renamed it): degrade to a no-op so the store still works standalone.
	if not (hotbar and slotCenter and slotLeft and slotRight) then
		if not hotbar then
			warn("HotbarCarousel: no ScreenGui.Hotbar scaffold found -- carousel disabled (store still works)")
		end
		return {
			requestOpenMixer = function()
				if setStoreOpen then
					setStoreOpen(screenGui:GetAttribute(Attrs.StoreOpen) ~= true)
				end
			end,
			selectItemNumber = function(number)
				if number == 1 and setStoreOpen then
					setStoreOpen(screenGui:GetAttribute(Attrs.StoreOpen) ~= true)
				end
			end,
			setUnlocked = function() end,
		}
	end

	local storeOff = screenGui:FindFirstChild(GuiNames.StoreBottomOff)
	local storeOffHit = storeOff and storeOff:FindFirstChild("hitbox")
	local cookieBg = storeOff and storeOff:FindFirstChild("cookieBackground")
	-- The launcher's resting ZIndex; the animator raises it during a flight and drops it on landing.
	-- That drop (back to rest, store closed) is our cue to grow the disc back in.
	local storeOffBaseZ = storeOff and storeOff.ZIndex

	local hotbarScale = hotbar:FindFirstChildOfClass("UIScale")
	if not hotbarScale then
		hotbarScale = Instance.new("UIScale")
		hotbarScale.Name = "MobileScale"
		hotbarScale.Parent = hotbar
	end
	local baseHotbarScale = math.max(hotbarScale.Scale, 0.01)

	local function getHotbarScale()
		return math.max(hotbarScale.Scale, 0.01)
	end

	local function applyHotbarMobileScale()
		hotbarScale.Scale = baseHotbarScale * (MobileScale.shouldUseMobile(hotbar) and HOTBAR_MOBILE_SCALE or 1)
	end

	-- The centre disc: capture its authored full geometry + resting opacities so the open/close morph
	-- can return to exactly the authored look (the disc BG is intentionally semi-transparent).
	local mixerIcon = slotCenter:FindFirstChild("icon")
	local centerStroke = slotCenter:FindFirstChildWhichIsA("UIStroke")
	local fullSize = slotCenter.Size
	local fullPos = slotCenter.Position
	local restBG = slotCenter.BackgroundTransparency
	local restStroke = centerStroke and centerStroke.Transparency or 0
	local restIcon = mixerIcon and mixerIcon.ImageTransparency or 0

	-- Capture the three authored poses (the scaffold's resting layout) keyed by slot position.
	local function captureCornerRadii(corner)
		if not corner then
			return nil
		end
		local ok, radii = pcall(function()
			return {
				TopLeftRadius = corner.TopLeftRadius,
				TopRightRadius = corner.TopRightRadius,
				BottomLeftRadius = corner.BottomLeftRadius,
				BottomRightRadius = corner.BottomRightRadius,
			}
		end)
		return ok and radii or nil
	end

	local function applyCornerPose(corner, pose, animate)
		if not corner then
			return
		end
		if pose.CornerRadii then
			if animate then
				TweenService:Create(corner, SPIN_INFO, pose.CornerRadii):Play()
			else
				for property, value in pairs(pose.CornerRadii) do
					corner[property] = value
				end
			end
		elseif pose.CornerRadius then
			if animate then
				TweenService:Create(corner, SPIN_INFO, { CornerRadius = pose.CornerRadius }):Play()
			else
				corner.CornerRadius = pose.CornerRadius
			end
		end
	end

	local function capturePose(slot)
		local stroke = slot:FindFirstChildWhichIsA("UIStroke")
		local corner = slot:FindFirstChildWhichIsA("UICorner")
		local badge = slot:FindFirstChild(KEYBIND_BADGE_NAME)
		local badgeCorner = badge and badge:FindFirstChildWhichIsA("UICorner")
		local badgeStroke = badge and badge:FindFirstChildWhichIsA("UIStroke")
		return {
			Position = slot.Position,
			Size = slot.Size,
			ZIndex = slot.ZIndex,
			Stroke = stroke and stroke.Thickness or nil,
			CornerRadius = corner and corner.CornerRadius or nil,
			CornerRadii = captureCornerRadii(corner),
			Badge = badge and {
				AnchorPoint = badge.AnchorPoint,
				Position = badge.Position,
				Size = badge.Size,
				ZIndexOffset = badge.ZIndex - slot.ZIndex,
				CornerRadius = badgeCorner and badgeCorner.CornerRadius or nil,
				Stroke = badgeStroke and badgeStroke.Thickness or nil,
			} or nil,
		}
	end
	local poses = {
		left = capturePose(slotLeft),
		center = capturePose(slotCenter),
		right = capturePose(slotRight),
	}
	-- Which slot currently occupies each pose, and the convenience pointer to the centred one.
	local slotByPose = { left = slotLeft, center = slotCenter, right = slotRight }
	local slotByItemNumber = { [1] = slotCenter, [2] = slotLeft, [3] = slotRight }
	local centerSlot = slotCenter
	slotLeft:SetAttribute("HotbarPose", "left")
	slotLeft:SetAttribute("HotbarItemNumber", 2)
	slotCenter:SetAttribute("HotbarPose", "center")
	slotCenter:SetAttribute("HotbarItemNumber", 1)
	slotRight:SetAttribute("HotbarPose", "right")
	slotRight:SetAttribute("HotbarItemNumber", 3)

	local unlocked = false
	local keybindBadgesSuppressed = false
	local mixerTransition = "idle"
	local pendingSelectAfterClose = nil
	local onMixerRestored = nil

	local function storeOpen()
		return screenGui:GetAttribute(Attrs.StoreOpen) == true
	end

	local function isMobileDevice()
		return UserInputService.TouchEnabled and not UserInputService.MouseEnabled
	end

	local function setBadgeText(badge, text)
		if badge:IsA("TextLabel") or badge:IsA("TextButton") or badge:IsA("TextBox") then
			badge.Text = text
			return
		end
		local label = badge:FindFirstChildWhichIsA("TextLabel", true)
			or badge:FindFirstChildWhichIsA("TextButton", true)
		if label then
			label.Text = text
		end
	end

	local function updateKeybindBadges()
		local visible = unlocked and not storeOpen() and not isMobileDevice() and not keybindBadgesSuppressed
		for itemNumber, slot in pairs(slotByItemNumber) do
			local badge = slot:FindFirstChild(KEYBIND_BADGE_NAME)
			if badge and badge:IsA("GuiObject") then
				badge.Visible = visible
				setBadgeText(badge, tostring(itemNumber))
			end
		end
	end

	local function setKeybindBadgesSuppressed(suppressed)
		keybindBadgesSuppressed = suppressed == true
		updateKeybindBadges()
	end

	-- ── Centre-disc morph ───────────────────────────────────────────────────────────
	-- The cookie background's on-screen size is the disc's shrink/grow footprint. Read live so it
	-- adapts to device scale.
	local function footprintPx()
		if cookieBg and cookieBg.AbsoluteSize.X > 0 then
			return cookieBg.AbsoluteSize.X * FOOTPRINT_FACTOR / getHotbarScale()
		end
		return fullSize.Y.Offset * 0.5
	end

	-- SlotCenter is bottom-anchored (for the carousel row), so to scale it about its CENTRE we shift
	-- Position.Y in lockstep with the height. Returns Size, Position for a square of side h.
	local function centerSquare(h)
		local fy = fullPos.Y.Offset + (h - fullSize.Y.Offset) / 2
		return UDim2.fromOffset(h, h), UDim2.new(fullPos.X.Scale, fullPos.X.Offset, fullPos.Y.Scale, fy)
	end

	local morphToken = 0
	local activeSizeTween = nil
	local function cancelSizeTween()
		if activeSizeTween then
			activeSizeTween:Cancel()
			activeSizeTween = nil
		end
	end
	local function setDiscOpacity(bg, stroke, icon)
		slotCenter.BackgroundTransparency = bg
		if centerStroke then
			centerStroke.Transparency = stroke
		end
		if mixerIcon then
			mixerIcon.ImageTransparency = icon
		end
	end

	-- Instant snaps for fallback / init.
	local function snapRest()
		morphToken += 1
		cancelSizeTween()
		slotCenter.Size = fullSize
		slotCenter.Position = fullPos
		setDiscOpacity(restBG, restStroke, restIcon)
	end
	local function snapOpen()
		morphToken += 1
		cancelSizeTween()
		local s, p = centerSquare(footprintPx())
		slotCenter.Size, slotCenter.Position = s, p
		setDiscOpacity(1, 1, 1)
	end

	MobileScale.onViewportChanged(function()
		local before = getHotbarScale()
		applyHotbarMobileScale()
		if math.abs(getHotbarScale() - before) <= 0.001 then
			return
		end
		-- If the mixer is already hidden in its open footprint, keep that local footprint aligned
		-- with the unscaled launcher cookie after an orientation change.
		local shouldRefreshOpenFootprint = activeSizeTween == nil
			and centerSlot == slotCenter
			and (storeOpen() or mixerTransition == "open")
			and slotCenter.BackgroundTransparency >= 0.99
		if shouldRefreshOpenFootprint then
			snapOpen()
		end
	end)

	-- Open morph: shrink the disc (opaque) into the cookie footprint, then fire onComplete (the real
	-- store-open / cookie launch) and fade the disc out as the cookie shoots up out of it.
	local function morphOpen(onComplete)
		morphToken += 1
		local token = morphToken
		cancelSizeTween()
		setKeybindBadgesSuppressed(true)
		if mixerIcon then
			mixerIcon.ImageTransparency = 1 -- icon out immediately; the bare coloured disc is the morph
		end
		local s, p = centerSquare(footprintPx())
		local shrink = TweenService:Create(slotCenter, SHRINK_INFO, { Size = s, Position = p })
		activeSizeTween = shrink
		shrink.Completed:Once(function(state)
			if state ~= Enum.PlaybackState.Completed or token ~= morphToken then
				return
			end
			-- Start the disc fade BEFORE flipping the store open, and keep it as the active tween so the
			-- StoreOpen reaction (onStoreOpenChanged) doesn't snap the disc transparent and preempt the
			-- fade -- the cookie launches up into the fading disc.
			local fade = TweenService:Create(slotCenter, FADE_INFO, { BackgroundTransparency = 1 })
			activeSizeTween = fade
			fade.Completed:Once(function()
				if activeSizeTween == fade then
					activeSizeTween = nil
				end
			end)
			if centerStroke then
				TweenService:Create(centerStroke, FADE_INFO, { Transparency = 1 }):Play()
			end
			fade:Play()
			if onComplete then
				onComplete()
			end
		end)
		shrink:Play()
	end

	-- Close grow: the descended cookie has landed (and the animator hid it); the disc reappears at the
	-- cookie footprint, opaque, then expands back to its full authored size about its centre.
	local function growToRest()
		morphToken += 1
		local token = morphToken
		cancelSizeTween()
		local s, p = centerSquare(footprintPx())
		slotCenter.Size, slotCenter.Position = s, p
		setDiscOpacity(restBG, restStroke, restIcon)
		local grow = TweenService:Create(slotCenter, GROW_INFO, { Size = fullSize, Position = fullPos })
		activeSizeTween = grow
		grow.Completed:Once(function(state)
			if activeSizeTween == grow then
				activeSizeTween = nil
			end
			if state == Enum.PlaybackState.Completed and token == morphToken and onMixerRestored then
				onMixerRestored()
			end
		end)
		grow:Play()
	end

	local function setPlaceholdersVisible(value)
		slotLeft.Visible = value
		slotRight.Visible = value
		updateKeybindBadges()
	end

	-- Hitbox routing: the mixer tap is SlotCenter.hitbox (above the launcher), enabled whenever the
	-- bar is interactive (store closed) and disabled while open. The launcher's own hitbox is unused.
	local function updateMixerFace()
		local centerHit = slotCenter:FindFirstChild("hitbox")
		local open = storeOpen()
		if centerHit then
			centerHit.Active = not open
			centerHit.Interactable = not open
		end
		if storeOffHit then
			storeOffHit.Interactable = false
		end
	end

	-- Move a slot (and all its descendants' ZIndex) to a pose; tween Position/Size when animating.
	local function applyPose(slot, poseName, animate)
		local pose = poses[poseName]
		slot:SetAttribute("HotbarPose", poseName)
		slot.ZIndex = pose.ZIndex
		for _, d in ipairs(slot:GetDescendants()) do
			if d:IsA("GuiObject") then
				d.ZIndex = pose.ZIndex
			end
		end
		if pose.Stroke then
			local stroke = slot:FindFirstChildWhichIsA("UIStroke")
			if stroke then
				stroke.Thickness = pose.Stroke
			end
		end
		if pose.CornerRadius then
			applyCornerPose(slot:FindFirstChildWhichIsA("UICorner"), pose, animate)
		end
		local badge = slot:FindFirstChild(KEYBIND_BADGE_NAME)
		if badge and badge:IsA("GuiObject") and pose.Badge then
			badge.ZIndex = pose.ZIndex + pose.Badge.ZIndexOffset
			badge.AnchorPoint = pose.Badge.AnchorPoint
			local badgeCorner = badge:FindFirstChildWhichIsA("UICorner")
			if badgeCorner and pose.Badge.CornerRadius then
				badgeCorner.CornerRadius = pose.Badge.CornerRadius
			end
			local badgeStroke = badge:FindFirstChildWhichIsA("UIStroke")
			if badgeStroke and pose.Badge.Stroke then
				badgeStroke.Thickness = pose.Badge.Stroke
			end
			if animate then
				TweenService:Create(badge, SPIN_INFO, {
					Position = pose.Badge.Position,
					Size = pose.Badge.Size,
				}):Play()
			else
				badge.Position = pose.Badge.Position
				badge.Size = pose.Badge.Size
			end
		end
		if animate then
			TweenService:Create(slot, SPIN_INFO, { Position = pose.Position, Size = pose.Size }):Play()
		else
			slot.Position = pose.Position
			slot.Size = pose.Size
		end
	end

	-- Rotate the ring one step so `slot` lands in the centre pose; the centred slot moves out to the
	-- flank `slot` vacated, keeping all three visible (a true 3-slot cycle). No-op if already centred.
	local function rotateToCenter(slot)
		if slot == centerSlot then
			return false
		end
		local p = slot:GetAttribute("HotbarPose")
		local newByPose
		if p == "left" then
			newByPose = { center = slotByPose.left, right = slotByPose.center, left = slotByPose.right }
		else -- "right"
			newByPose = { center = slotByPose.right, left = slotByPose.center, right = slotByPose.left }
		end
		slotByPose = newByPose
		centerSlot = slotByPose.center
		for poseName, s in pairs(slotByPose) do
			applyPose(s, poseName, true)
		end
		return true
	end

	-- The spin->open gate. B / the mixer tap route here. Already open => toggle closed. Otherwise spin
	-- the mixer to centre (if needed), then play the open morph; the cookie launch fires when the
	-- shrink settles (so the disc visibly collapses into the cookie before it shoots up).
	local openToken = 0
	local function requestOpenMixer()
		if not setStoreOpen then
			return
		end
		if mixerTransition == "opening" or mixerTransition == "closing" then
			return
		end
		if storeOpen() then
			pendingSelectAfterClose = nil
			mixerTransition = "closing"
			setKeybindBadgesSuppressed(true)
			setStoreOpen(false)
			return
		end
		pendingSelectAfterClose = nil
		mixerTransition = "opening"
		setKeybindBadgesSuppressed(true)
		openToken += 1
		local token = openToken
		local function launch()
			if token ~= openToken or storeOpen() or mixerTransition ~= "opening" then
				return
			end
			setPlaceholdersVisible(false)
			updateMixerFace() -- disable the tap while opening
			morphOpen(function()
				if token == openToken and not storeOpen() then
					setStoreOpen(true)
				end
			end)
		end
		if centerSlot == slotCenter then
			launch()
		else
			rotateToCenter(slotCenter)
			task.delay(SPIN_INFO.Time, launch)
		end
	end

	-- A slot tap: the mixer routes through the open gate; a placeholder just spins to centre (becomes
	-- active) with no open, since it has no item yet.
	local function selectSlot(slot)
		if not unlocked then
			return
		end
		if slot == slotCenter then
			requestOpenMixer()
		elseif slot ~= centerSlot then
			rotateToCenter(slot)
		end
	end

	onMixerRestored = function()
		mixerTransition = "idle"
		setKeybindBadgesSuppressed(false)
		local pending = pendingSelectAfterClose
		pendingSelectAfterClose = nil
		if pending and unlocked and not storeOpen() then
			selectSlot(pending)
		end
	end

	local function selectItemNumber(number)
		local slot = slotByItemNumber[number]
		if not slot then
			return
		end
		-- If the Mixer is open/closing, selecting another identity should close cleanly,
		-- then spin after the mixer disc has fully grown back into the hotbar.
		if slot ~= slotCenter and (storeOpen() or mixerTransition == "open" or mixerTransition == "closing") then
			pendingSelectAfterClose = slot
			if mixerTransition ~= "closing" then
				mixerTransition = "closing"
				setKeybindBadgesSuppressed(true)
				if setStoreOpen then
					setStoreOpen(false)
				end
			end
			return
		end
		if mixerTransition == "opening" then
			return
		end
		selectSlot(slot)
	end

	for _, slot in ipairs({ slotLeft, slotCenter, slotRight }) do
		local hit = slot:FindFirstChild("hitbox")
		if hit and hit:IsA("GuiButton") then
			hit.Activated:Connect(function()
				selectSlot(slot)
			end)
		end
	end

	-- React to store state. Opening: ensure the hidden open state (fallback for opens NOT routed
	-- through requestOpenMixer, e.g. build-mode coupling -- the routed path already morphed, so skip
	-- the snap then to let the fade finish). Closing: bring placeholders back as the landing-pad
	-- context; the disc stays hidden until the cookie lands and growToRest fires.
	local function onStoreOpenChanged()
		if storeOpen() then
			mixerTransition = "open"
			pendingSelectAfterClose = nil
			setKeybindBadgesSuppressed(true)
			setPlaceholdersVisible(false)
			if activeSizeTween == nil and slotCenter.BackgroundTransparency < 1 then
				snapOpen()
			end
			updateMixerFace()
			updateKeybindBadges()
		else
			if mixerTransition ~= "closing" then
				mixerTransition = "closing"
			end
			setKeybindBadgesSuppressed(true)
			setPlaceholdersVisible(unlocked)
			updateMixerFace()
			updateKeybindBadges()
			-- Safety: if no cookie flight happens (so growToRest never fires), restore the disc.
			if not storeOff then
				snapRest()
				if onMixerRestored then
					onMixerRestored()
				end
			else
				task.delay(0.6, function()
					if storeOpen() then
						return
					end
					if centerSlot == slotCenter and slotCenter.BackgroundTransparency >= 0.99 then
						snapRest()
					elseif centerSlot == slotCenter then
						return
					end
					if onMixerRestored then
						onMixerRestored()
					end
				end)
			end
		end
	end
	screenGui:GetAttributeChangedSignal(Attrs.StoreOpen):Connect(onStoreOpenChanged)

	-- Landing: when the animator drops the launcher ZIndex back to rest (store closed, mixer centred),
	-- the cookie has settled into the slot -- grow the disc back in from its footprint.
	if storeOff then
		storeOff:GetPropertyChangedSignal("ZIndex"):Connect(function()
			local atRest = storeOffBaseZ ~= nil and storeOff.ZIndex == storeOffBaseZ
			if atRest and not storeOpen() and centerSlot == slotCenter then
				growToRest()
			end
		end)
	end

	-- Mixer gate: the controller hides the whole bar until building is unlocked, then restores it.
	local function setUnlocked(value)
		unlocked = value == true
		if not unlocked then
			hotbar.Visible = false
		else
			hotbar.Visible = true
			setPlaceholdersVisible(not storeOpen())
			if storeOpen() then
				snapOpen()
			else
				snapRest()
			end
			updateMixerFace()
		end
		updateKeybindBadges()
	end

	-- Initial pose: disc at full authored rest, bar hidden until unlock/onStoreOpen drives it.
	snapRest()
	updateMixerFace()
	updateKeybindBadges()
	hotbar.Visible = false

	return {
		requestOpenMixer = requestOpenMixer,
		selectItemNumber = selectItemNumber,
		setUnlocked = setUnlocked,
	}
end

return HotbarCarousel
