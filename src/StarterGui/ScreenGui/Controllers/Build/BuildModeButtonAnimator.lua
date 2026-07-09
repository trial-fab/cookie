-- BuildModeButtonAnimator: visual feedback for StoreBottom.TopBar.BuildModeButton.
--
-- The authored UI is a BuildModeFrame containing an outer BuildModeCamera ImageButton (the
-- always-on camera body) with a nested camImage ImageLabel that carries the resizable camera art,
-- plus a BuildModeButton shutter ImageButton layered on top. The camera's appearance is authored
-- in Studio and left untouched here. This module overlays a RecordDot layer inside camImage (so it
-- tracks the camera art's size/position) that pulses while build mode is ON (like a record light).
--
-- The shutter is a single image (`visual`) whose frame is HARD-SWAPPED between open/medium/closed.
--
-- Idle (build mode OFF), the shutter rests OPEN. HOVERING spins it a subtle quarter turn while
-- stepping the frames open -> medium -> closed; leaving REVERSES that exact motion -- it un-spins and
-- steps back to OPEN from wherever it currently is, so spamming hover/unhover roughly holds it in
-- place. Clicking turns build mode ON and plays a "zoom into the shutter": the closed shutter grows to
-- the active scale while spinning one turn and stepping closed -> medium -> open, then HOLDS open; the
-- camera enlarges behind it at the same pace. Turning OFF reverses that (open -> medium -> closed) and,
-- if not hovering, spins back to the idle OPEN. The record dot is PAUSED this iteration (it never
-- shows). The invisible hitbox on the outer frame owns clicks/hover. BuildViewController owns
-- BuildModeActive.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ContentProvider = game:GetService("ContentProvider")
local TweenService = game:GetService("TweenService")

local shared = ReplicatedStorage:WaitForChild("Shared")
local Attrs = require(shared:WaitForChild("Attrs"))
local IconButton = require(shared:WaitForChild("IconButton"))

local BuildModeButtonAnimator = {}

-- Centered 512x512 shutter set. These frames drive both the hover/rest frame step and the click
-- scale/spin animation.
local SHUTTER_OPEN = "rbxassetid://128749973486699"
local SHUTTER_MEDIUM = "rbxassetid://128002908781600"
local SHUTTER_CLOSED = "rbxassetid://81727677661365"

-- Shutter "zoom-in" timing:
--   ACTIVATE   - the CLOSED rest face gives way to the click-tween shutter, which grows from the
--                authored size to the active scale while spinning one full turn and stepping closed -> medium
--                -> open, then HOLDS open. BuildModeCamera enlarges (CAMERA_ZOOM) at the same pace, so
--                it reads as zooming into the opening lens.
--   DEACTIVATE - the shutter spins one full turn shut (open -> medium -> closed) while it shrinks from
--                the active scale back to the authored rest size. The camera zooms back out.
-- The enclosing BuildModeFrame CanvasGroup masks everything (oversized/rotating) to the button circle.
local ACTIVATE_TIME = 0.45
local DEACTIVATE_TIME = 0.45
-- One full turn as the shutter opens (ACTIVATE) or closes (DEACTIVATE); lands back at 0deg.
local SHUTTER_SPIN = 360
-- The open/active shutter scales from its Studio-authored size and HOLDS here while build mode is ON.
local SHUTTER_ACTIVE_SCALE = 4.4
-- How much BuildModeCamera enlarges during the zoom, relative to its authored size.
local CAMERA_ZOOM = 6

-- ACTIVATE eases out (decelerates into the held-closed state); DEACTIVATE eases in-out back home.
local ACTIVATE_INFO = TweenInfo.new(ACTIVATE_TIME, Enum.EasingStyle.Quart, Enum.EasingDirection.Out)
local DEACTIVATE_INFO = TweenInfo.new(DEACTIVATE_TIME, Enum.EasingStyle.Quart, Enum.EasingDirection.InOut)

-- Frame swaps must land at points along the *visual* (eased) progress, not raw wall-clock time.
-- Quart/Out front-loads the motion: it's already ~82% spun by the 35% time mark and ~99% by 70%,
-- so a linear task.delay at those fractions crams the closed->medium->open steps into the final
-- sliver of the spin -- the iris pops open right at the end. Inverting the ease maps "step at 35%/70%
-- of the visible motion" back to the correct real-time delay, spreading the opening across the spin.
local function easeOutQuartInverse(p)
	return 1 - (1 - p) ^ 0.25
end

-- Same idea for DEACTIVATE, which eases Quart/InOut (slow -> fast -> slow). Its progress is
-- 8*t^4 on the first half and 1 - (2*(1-t))^4 / 2 on the second, so the inverse is two branches
-- that meet at the midpoint. Because the middle of the motion is the fast part, equal *visual*
-- steps cluster close together in real time -- which is exactly what keeps the close smooth.
local function easeInOutQuartInverse(p)
	if p < 0.5 then
		return (p / 8) ^ 0.25
	end
	return 1 - (2 * (1 - p)) ^ 0.25 / 2
end

-- Hover affordance (build mode OFF only), in place -- no scale change:
-- Hovering spins the centered shutter a SUBTLE turn (HOVER_TURN_DEGREES) while stepping the frames
-- open -> medium -> closed; leaving reverses the exact same motion back to open. The position is read
-- live off the rotation each time, so an interrupted hover/unhover reverses smoothly from where it is
-- -- spamming just oscillates it near the middle. HOVER_TURN_TIME is a full open<->closed pass; a
-- partial (interrupted) pass scales its duration down so the spin rate is constant every time.
-- Rotation maps linearly to the position t in [0,2]: rotation = (t/2)*DEGREES, so t=0 is OPEN
-- (rotation 0), t=1 MEDIUM, t=2 CLOSED (rotation DEGREES). Frames hard-swap at the thirds of the turn.
-- Held frames sit at fractional-turn angles, so this assumes the art reads the same at those angles;
-- if a held frame looks tilted, raise DEGREES to 360.
local HOVER_TURN_DEGREES = 30
local HOVER_TURN_TIME = 0.1

local CONTAINER_ZINDEX = 13

-- Center art IDs are owned here in logic (not read off the instance), so the button keeps
-- working regardless of how the Studio instance is set up. CAMERA is a fallback for the camera
-- art (the real art is authored on the nested camImage ImageLabel); DOT is the red record light
-- overlaid inside camImage and pulsed only while build mode is ON.
local CAMERA_IMAGE = "rbxassetid://122466560711017"
local CAM_IMAGE_NAME = "camImage"
local DOT_IMAGE = "rbxassetid://112329186310439"
local DOT_LAYER_NAME = "RecordDot"

-- Record-light pulsing is PAUSED this iteration (build mode never shows the dot), so no looping
-- flash tween is defined; the dot layer is still created but held hidden. See applyFlashState.

task.spawn(function()
	pcall(function()
		ContentProvider:PreloadAsync({
			SHUTTER_OPEN, SHUTTER_MEDIUM, SHUTTER_CLOSED,
		})
	end)
end)

local function resolveVisual(container)
	if not container then
		return nil
	end
	if container:IsA("ImageButton") or container:IsA("ImageLabel") then
		return container
	end
	-- Recursive: the shutter may be nested inside a ShutterClip CanvasGroup (used to mask it to the
	-- button's circle) rather than sitting as a direct child of the frame.
	local directButton = container:FindFirstChild("BuildModeButton", true)
	if directButton and (directButton:IsA("ImageButton") or directButton:IsA("ImageLabel")) then
		return directButton
	end
	for _, descendant in ipairs(container:GetDescendants()) do
		if descendant:IsA("ImageButton") or descendant:IsA("ImageLabel") then
			local name = string.lower(descendant.Name)
			if name ~= "hitbox" then
				return descendant
			end
		end
	end
	return nil
end

local function resolveIconLayer(container)
	if not container then
		return nil
	end
	-- New camera design: the always-on body is BuildModeCamera. Fall back to the older
	-- BuildModeCenter name so an un-migrated place still resolves.
	local icon = container:FindFirstChild("BuildModeCamera") or container:FindFirstChild("BuildModeCenter")
	if icon and (icon:IsA("ImageButton") or icon:IsA("ImageLabel")) then
		return icon
	end
	return nil
end

-- The camera art now lives on a nested, separately-resizable camImage ImageLabel so it can be sized
-- independently of the BuildModeCamera hitbox. Resolve that layer (falling back to the icon layer
-- itself for un-migrated places) so both the fallback art and the record dot align to the art.
local function resolveCameraImage(iconLayer)
	if not iconLayer then
		return nil
	end
	local cam = iconLayer:FindFirstChild(CAM_IMAGE_NAME)
	if cam and (cam:IsA("ImageLabel") or cam:IsA("ImageButton")) then
		return cam
	end
	return iconLayer
end

local function configureHitbox(hitbox)
	if not hitbox or not hitbox:IsA("GuiButton") then
		return
	end
	hitbox.BackgroundTransparency = 1
	hitbox.BorderSizePixel = 0
	hitbox.AutoButtonColor = false
	hitbox.Selectable = false
	hitbox:SetAttribute(Attrs.IconOnly, true)
	if hitbox:IsA("TextButton") then
		hitbox.Text = ""
		hitbox.TextTransparency = 1
	end
end

local function configureImageButton(image)
	if image and image:IsA("ImageButton") then
		image.AutoButtonColor = false
		image.Selectable = false
		image.HoverImage = ""
		image.PressedImage = ""
	end
end

local function configureVisibility(container, visual, iconLayer, hitbox)
	container.Visible = true
	container.ZIndex = math.max(container.ZIndex, CONTAINER_ZINDEX)
	if iconLayer then
		iconLayer.Visible = true
		iconLayer.ZIndex = math.max(iconLayer.ZIndex, container.ZIndex + 1)
	end
	if visual then
		visual.Visible = true
		visual.ZIndex = math.max(visual.ZIndex, (iconLayer and iconLayer.ZIndex or container.ZIndex) + 1)
	end
	if hitbox then
		hitbox.ZIndex = math.max(hitbox.ZIndex, container.ZIndex + 10)
	end
end

local function sizeHitboxToContainer(hitbox, container)
	if not hitbox or not container or hitbox == container then
		return
	end

	local padding = container:FindFirstChildWhichIsA("UIPadding")
	if padding then
		hitbox.Position = UDim2.new(
			-padding.PaddingLeft.Scale,
			-padding.PaddingLeft.Offset,
			-padding.PaddingTop.Scale,
			-padding.PaddingTop.Offset
		)
		hitbox.Size = UDim2.new(
			1 + padding.PaddingLeft.Scale + padding.PaddingRight.Scale,
			padding.PaddingLeft.Offset + padding.PaddingRight.Offset,
			1 + padding.PaddingTop.Scale + padding.PaddingBottom.Scale,
			padding.PaddingTop.Offset + padding.PaddingBottom.Offset
		)
	else
		hitbox.Position = UDim2.fromScale(0, 0)
		hitbox.Size = UDim2.fromScale(1, 1)
	end
	hitbox.ZIndex = math.max(hitbox.ZIndex, container.ZIndex + 10)
end

local function followLiveCookieCount(container)
	local parent = container.Parent
	if not parent then
		return
	end

	local liveCount = parent:FindFirstChild("LiveCookieCount")
	if not liveCount or not liveCount:IsA("GuiObject") then
		return
	end

	local function getLiveCountWidth()
		if liveCount.Size.X.Scale == 0 then
			return liveCount.Size.X.Offset
		end
		return liveCount.AbsoluteSize.X
	end

	local basePosition = container.Position
	local baseLiveWidth = getLiveCountWidth()
	local gap = -basePosition.X.Offset - baseLiveWidth
	local function refresh()
		local width = getLiveCountWidth()
		container.Position = UDim2.new(
			basePosition.X.Scale,
			-(math.ceil(width) + gap),
			basePosition.Y.Scale,
			basePosition.Y.Offset
		)
	end

	refresh()
	liveCount:GetPropertyChangedSignal("AbsoluteSize"):Connect(refresh)
	liveCount:GetPropertyChangedSignal("Size"):Connect(refresh)
end

-- The flashing dot is its own layer nested inside camImage, so it inherits the camera art's size
-- and position however the user resizes camImage. Prefer a Studio-authored child named RecordDot if
-- the user added one; otherwise create a full-rect overlay filling camImage (the dot art is sized to
-- align with the camera's hole at full size). Idempotent. `dotArt` is the logic-owned record-light
-- image. The overlay keeps its own ImageColor3 (default white) so the red dot shows in true colour
-- even when the camera body underneath is tinted dark.
local function ensureDotLayer(cameraLayer, dotArt)
	if not cameraLayer then
		return nil
	end

	local dot = cameraLayer:FindFirstChild(DOT_LAYER_NAME)
	if not dot or not (dot:IsA("ImageLabel") or dot:IsA("ImageButton")) then
		dot = Instance.new("ImageLabel")
		dot.Name = DOT_LAYER_NAME
		dot.BackgroundTransparency = 1
		dot.BorderSizePixel = 0
		dot.AnchorPoint = Vector2.new(0, 0)
		dot.Position = UDim2.fromScale(0, 0)
		dot.Size = UDim2.fromScale(1, 1)
		dot.ScaleType = cameraLayer.ScaleType
		dot.Active = false
		dot.Parent = cameraLayer
	end

	dot.Image = dotArt
	dot.ImageTransparency = 1
	dot.Visible = true
	-- Sit just above the camera but below the shutter (shutter ZIndex is higher).
	dot.ZIndex = cameraLayer.ZIndex
	return dot
end

-- Scale every component of a UDim2 (both Scale and Offset) by a factor.
local function scaleUDim2(size, factor)
	return UDim2.new(
		size.X.Scale * factor,
		size.X.Offset * factor,
		size.Y.Scale * factor,
		size.Y.Offset * factor
	)
end

-- The UDim2 position a layer would need, if re-anchored to (0.5, 0.5), to occupy the exact same
-- rect it currently does. Lets us centre-anchor the camera (so it scales about its middle) without
-- visually moving it, whatever anchor/position it was authored with.
local function centerPosition(pos, size, anchor)
	return UDim2.new(
		pos.X.Scale + (0.5 - anchor.X) * size.X.Scale,
		pos.X.Offset + (0.5 - anchor.X) * size.X.Offset,
		pos.Y.Scale + (0.5 - anchor.Y) * size.Y.Scale,
		pos.Y.Offset + (0.5 - anchor.Y) * size.Y.Offset
	)
end

function BuildModeButtonAnimator.new(container)
	if not container or not container:IsA("GuiObject") then
		return nil
	end

	local visual = resolveVisual(container)
	local iconLayer = resolveIconLayer(container)
	local hitbox = nil
	if container:IsA("GuiButton") then
		hitbox = container
	else
		hitbox = container:FindFirstChild("Hitbox") or container:FindFirstChild("hitbox")
		if not hitbox and visual and visual:IsA("ImageButton") then
			hitbox = IconButton.createHitbox(container, visual)
		end
	end

	if hitbox and hitbox:IsA("GuiButton") then
		configureHitbox(hitbox)
		sizeHitboxToContainer(hitbox, container)
	else
		hitbox = nil
	end
	configureVisibility(container, visual, iconLayer, hitbox)
	followLiveCookieCount(container)

	-- The camera body is authored in Studio (Image + colour + 0.15 transparency); leave its look
	-- alone. We keep it non-interactive on hover/press so the outer hitbox owns clicks and the
	-- camera simply stays put on hover. The art itself now lives on the nested camImage layer.
	local cameraImage = resolveCameraImage(iconLayer)
	if cameraImage then
		if cameraImage.Image == nil or cameraImage.Image == "" then
			cameraImage.Image = CAMERA_IMAGE
		end
	end
	if iconLayer and iconLayer:IsA("ImageButton") then
		iconLayer.AutoButtonColor = false
		iconLayer.Selectable = false
		iconLayer.HoverImage = ""
		iconLayer.PressedImage = ""
	end

	task.spawn(function()
		pcall(function()
			ContentProvider:PreloadAsync({ CAMERA_IMAGE, DOT_IMAGE })
		end)
	end)

	local dotLayer = ensureDotLayer(cameraImage, DOT_IMAGE)

	-- Shutter rest size is the Studio-authored size; ACTIVATE grows it to activeSize (held while
	-- ON) and DEACTIVATE shrinks it directly back to restSize. Captured before we touch anything.
	local restSize = visual and visual.Size or UDim2.fromScale(1, 1)
	local activeSize = scaleUDim2(restSize, SHUTTER_ACTIVE_SCALE)

	-- Camera zoom geometry. We centre-anchor BuildModeCamera (without moving it) so its Size tween
	-- scales about its own middle, then remember the authored size and the enlarged size. The camera
	-- is hidden behind the opaque closed shutter while ON, so the re-anchor is imperceptible.
	local camRestSize, camBigSize = nil, nil
	if iconLayer then
		camRestSize = iconLayer.Size
		iconLayer.Position = centerPosition(iconLayer.Position, camRestSize, iconLayer.AnchorPoint)
		iconLayer.AnchorPoint = Vector2.new(0.5, 0.5)
		camBigSize = scaleUDim2(camRestSize, CAMERA_ZOOM)
	end

	if visual then
		-- Centre-anchor the shutter so the hover spin and the click animation scale/rotate about the
		-- lens centre; the enclosing BuildModeFrame CanvasGroup masks the oversized (and rotating)
		-- shutter to the button's circle. ImageColor3 stays as authored in Studio.
		visual.AnchorPoint = Vector2.new(0.5, 0.5)
		visual.Position = UDim2.fromScale(0.5, 0.5)
		visual.Size = restSize
		visual.Image = SHUTTER_OPEN
		visual.ImageTransparency = 0
		-- The hitbox (higher ZIndex) owns clicks; keep the shutter itself non-interactive so its
		-- oversized rect never steals input from neighbouring topbar buttons while hidden.
		visual.Active = false
		visual.Interactable = false
		configureImageButton(visual)

		-- Belt-and-suspenders: ensure the shutter's parent clips (the CanvasGroup already composites to
		-- a bounded, rounded buffer, but this is harmless and keeps a non-CanvasGroup parent working).
		local clipHost = visual.Parent
		if clipHost and clipHost:IsA("GuiObject") then
			clipHost.ClipsDescendants = true
		end
	end

	local obj = {
		container = container,
		hitbox = hitbox,
		visual = visual,
		iconLayer = iconLayer,
		dotLayer = dotLayer,
	}

	-- A blink runs a rotation tween and a size tween on the shutter at once (different properties,
	-- so they coexist). Track them together so a re-toggle can cancel the whole set.
	local activeTweens = {}
	local flashTween = nil
	local sequenceToken = 0
	local lastActive = nil
	-- `inTransition` is true while a build ON/OFF animation is running, so a hover step can't fire and
	-- cancel it mid-way (which would strand the camera zoom). `hovering` tracks the pointer so the close
	-- can settle on the hover-appropriate face (holds closed if still hovering, else spins back open).
	-- Hover functions are forward-declared so playDeactivate can hand back to them.
	local inTransition = false
	local hovering = false
	local playHoverClose, playHoverOpen

	local function trackTween(tween)
		table.insert(activeTweens, tween)
		return tween
	end

	local function cancelActiveTween()
		for _, tween in ipairs(activeTweens) do
			tween:Cancel()
		end
		table.clear(activeTweens)
	end

	local function stopFlash()
		if flashTween then
			flashTween:Cancel()
			flashTween = nil
		end
	end

	local function setImage(assetId)
		if visual and visual.Parent then
			visual.Image = assetId
		end
	end

	-- Record-light pulsing is PAUSED this iteration: the dot never shows regardless of build state,
	-- so we just keep the layer present and hidden. Restore the looping flash tween here to bring the
	-- record light back.
	local function applyFlashState(_active)
		if not dotLayer or not dotLayer.Parent then
			return
		end
		stopFlash()
		dotLayer.Image = DOT_IMAGE
		dotLayer.ImageTransparency = 1
	end

	-- ACTIVATE: "zoom into the shutter". The closed shutter grows from its authored size to activeSize
	-- while spinning one full turn and stepping closed -> medium -> open, then HOLDS open. The camera
	-- enlarges behind it at the same pace so the opening lens reads as zooming in.
	local function playActivate()
		if not visual then
			return
		end

		sequenceToken += 1
		local token = sequenceToken
		cancelActiveTween()
		inTransition = true

		local function alive()
			return token == sequenceToken and visual.Parent ~= nil
		end

		-- Start: closed shutter, authored size, un-rotated.
		setImage(SHUTTER_CLOSED)
		visual.Rotation = 0
		visual.Size = restSize
		visual.ImageTransparency = 0

		-- Grow the shutter to the active size while spinning one full turn open.
		local grow = trackTween(TweenService:Create(visual, ACTIVATE_INFO, {
			Size = activeSize,
			Rotation = SHUTTER_SPIN,
		}))

		-- Zoom the camera up at the same pace.
		if iconLayer and camBigSize then
			trackTween(TweenService:Create(iconLayer, ACTIVATE_INFO, { Size = camBigSize })):Play()
		end

		-- Step the iris closed -> medium -> open as it grows, then hold open. Timed against the eased
		-- visual progress (see easeOutQuartInverse) so the frames land at ~35%/70% of the *visible* spin.
		task.delay(ACTIVATE_TIME * easeOutQuartInverse(0.35), function()
			if alive() then setImage(SHUTTER_MEDIUM) end
		end)
		task.delay(ACTIVATE_TIME * easeOutQuartInverse(0.7), function()
			if alive() then setImage(SHUTTER_OPEN) end
		end)

		grow.Completed:Once(function(state)
			if not alive() or state ~= Enum.PlaybackState.Completed then
				return
			end
			-- Held ON state: open shutter scaled up, camera enlarged behind it.
			visual.Rotation = SHUTTER_SPIN
			setImage(SHUTTER_OPEN)
			visual.Size = activeSize
			visual.ImageTransparency = 0
			inTransition = false
		end)
		grow:Play()
	end

	-- DEACTIVATE: reverse of ACTIVATE. The shutter and camera scale back to their authored sizes at
	-- the same pace while the shutter spins one full turn and closes (open -> medium -> closed). It
	-- lands CLOSED in the canonical hover-closed pose (rest size, rotation = HOVER_TURN_DEGREES) so a
	-- following hover-open can reverse cleanly; if not hovering, it spins back to OPEN.
	local function playDeactivate()
		if not visual then
			return
		end

		sequenceToken += 1
		local token = sequenceToken
		cancelActiveTween()
		inTransition = true

		local function alive()
			return token == sequenceToken and visual.Parent ~= nil
		end

		-- Start: open shutter (wherever the current scale is), un-rotated.
		setImage(SHUTTER_OPEN)
		visual.Rotation = 0
		visual.ImageTransparency = 0

		-- Shrink the shutter from the active size back to the authored size while spinning one full turn.
		local shrink = trackTween(TweenService:Create(visual, DEACTIVATE_INFO, {
			Size = restSize,
			Rotation = SHUTTER_SPIN,
		}))

		-- Shrink the camera back to its authored size at the same pace.
		if iconLayer and camRestSize then
			trackTween(TweenService:Create(iconLayer, DEACTIVATE_INFO, { Size = camRestSize })):Play()
		end

		-- Close the iris open -> medium -> closed as it shrinks. Timed against the eased visual
		-- progress (see easeInOutQuartInverse) so the frames land at ~30%/60% of the *visible* spin.
		task.delay(DEACTIVATE_TIME * easeInOutQuartInverse(0.3), function()
			if alive() then setImage(SHUTTER_MEDIUM) end
		end)
		task.delay(DEACTIVATE_TIME * easeInOutQuartInverse(0.6), function()
			if alive() then setImage(SHUTTER_CLOSED) end
		end)

		shrink.Completed:Once(function(state)
			if not alive() or state ~= Enum.PlaybackState.Completed then
				return
			end
			-- Land CLOSED in the hover-closed pose (rotation == HOVER_TURN_DEGREES) so a following
			-- hover-open reverses by a subtle turn. Invisible vs the 360 spin end under fractional-turn
			-- symmetry.
			visual.Size = restSize
			visual.Rotation = HOVER_TURN_DEGREES
			setImage(SHUTTER_CLOSED)
			visual.ImageTransparency = 0
			inTransition = false
			-- Still hovering: the hover state IS closed-held, nothing to do. Otherwise reverse to the
			-- idle OPEN rest.
			if not hovering then
				playHoverOpen()
			end
		end)
		shrink:Play()
	end

	-- Reversible hover. Drives a single position t in [0,2] (0=open, 1=medium, 2=closed) that maps
	-- linearly to rotation: rotation = (t/2)*HOVER_TURN_DEGREES. Hover targets t=2 (close), leave targets
	-- t=0 (open). It reads the CURRENT t off the live rotation, so an interruption reverses smoothly from
	-- exactly where it is; the duration scales with the distance travelled, so the spin rate is constant
	-- no matter how far it goes (no crawl on spam). The frame hard-swaps open/medium/closed at the thirds.
	-- Frame shown for a position t (open/medium/closed by equal thirds; medium straddles t=1).
	local function frameForT(t)
		if t < 2 / 3 then
			return SHUTTER_OPEN
		elseif t <= 4 / 3 then
			return SHUTTER_MEDIUM
		end
		return SHUTTER_CLOSED
	end

	local function animateHover(targetT)
		if not visual then
			return
		end

		-- Rotation is the source of truth for the current position; capture it BEFORE cancelling (so
		-- Cancel's reset can't move it) and restore it after.
		local rotFrom = visual.Rotation

		sequenceToken += 1
		local token = sequenceToken
		cancelActiveTween()

		local function alive()
			return token == sequenceToken and visual.Parent ~= nil
		end

		visual.Size = restSize
		visual.ImageTransparency = 0
		visual.Rotation = rotFrom

		local currentT = math.clamp(2 * rotFrom / HOVER_TURN_DEGREES, 0, 2)
		local rotTo = (targetT / 2) * HOVER_TURN_DEGREES
		setImage(frameForT(currentT))

		local distance = math.abs(targetT - currentT)
		if distance < 1e-3 then
			-- Already there: settle exactly.
			visual.Rotation = rotTo
			setImage(frameForT(targetT))
			return
		end
		local duration = HOVER_TURN_TIME * distance / 2

		-- Constant-rate spin to the target angle; hang the settle off its Completed.
		local spin = trackTween(TweenService:Create(
			visual,
			TweenInfo.new(duration, Enum.EasingStyle.Linear, Enum.EasingDirection.Out),
			{ Rotation = rotTo }
		))

		-- Hard-swap the frame as t crosses each third (2/3, 4/3) that the path passes through -- works
		-- in either direction, so a reversal re-steps the frames back the way it came.
		for _, thr in ipairs({ 2 / 3, 4 / 3 }) do
			local crossed = (currentT < thr) ~= (targetT < thr)
			if crossed then
				local crossTime = duration * (thr - currentT) / (targetT - currentT)
				local frameAfter = frameForT(targetT < currentT and thr - 1e-3 or thr + 1e-3)
				task.delay(crossTime, function()
					if alive() then setImage(frameAfter) end
				end)
			end
		end

		spin.Completed:Once(function(state)
			if alive() and state == Enum.PlaybackState.Completed then
				visual.Rotation = rotTo
				setImage(frameForT(targetT))
			end
		end)
		spin:Play()
	end

	-- Hover in: spin toward CLOSED. Hover out (and the deactivate return-to-idle): reverse back to OPEN.
	function playHoverClose()
		animateHover(2)
	end
	function playHoverOpen()
		animateHover(0)
	end

	function obj.setActive(active)
		container:SetAttribute(Attrs.Active, active)
		if hitbox and hitbox ~= container then
			hitbox:SetAttribute(Attrs.Active, active)
		end
		if visual and visual ~= container and visual ~= hitbox then
			visual:SetAttribute(Attrs.Active, active)
		end

		if lastActive ~= nil and active ~= lastActive then
			if active then
				playActivate()
			else
				playDeactivate()
			end
		elseif lastActive == nil then
			-- First apply: snap to the resting state for the current build mode with no animation.
			cancelActiveTween()
			if active then
				-- Snap straight to the held ON state: open shutter scaled up, camera zoomed.
				if visual then
					visual.Rotation = 0
					visual.Size = activeSize
					setImage(SHUTTER_OPEN)
					visual.ImageTransparency = 0
				end
				if iconLayer and camBigSize then
					iconLayer.Size = camBigSize
				end
			else
				-- Snap to the idle OPEN rest (rotation 0 == hover position t=0).
				if visual then
					visual.Rotation = 0
					visual.Size = restSize
					setImage(SHUTTER_OPEN)
					visual.ImageTransparency = 0
				end
				if iconLayer and camRestSize then
					iconLayer.Size = camRestSize
				end
			end
			applyFlashState(active)
		end
		lastActive = active
	end

	-- Hover affordance: spin the shutter closed/open only while build mode is OFF and no ON/OFF
	-- animation is mid-flight (so it can't strand the camera zoom). Entering spins it closed; leaving
	-- spins it back open. `hovering` is tracked always so the deactivate close knows whether to hold
	-- closed (still hovering) or spin back to the idle open rest.
	if hitbox then
		hitbox.MouseEnter:Connect(function()
			hovering = true
			if not lastActive and not inTransition then
				playHoverClose()
			end
		end)
		hitbox.MouseLeave:Connect(function()
			hovering = false
			if not lastActive and not inTransition then
				playHoverOpen()
			end
		end)
	end

	return obj
end

return BuildModeButtonAnimator
