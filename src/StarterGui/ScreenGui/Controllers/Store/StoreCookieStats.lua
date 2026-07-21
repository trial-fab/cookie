-- StoreCookieStats: the cookieStats reveal on each store card. The stats panel fades in
-- (opacity tween, no CanvasGroup) while you hover an unlocked row, and stays shown while the
-- row is locked via right-click / touch long-press. Hovering, locking, or actively dragging
-- the preview slides previewFrame right (centered -> shifted) so the revealed stats and the
-- preview card read as one centered pair; releasing a drag restores the hover/lock state. The
-- same previewFrame catch also drives drag-to-spin, so this module shares StorePreview's
-- previewInteraction object (ctx.preview)
-- for the drag state machine and registers the global touch handlers that route to it.
-- Exposes setup(row, upgradeId, activateRow) (called from createRow) and updateHover()
-- (called from the RenderStepped tick).
local UiMotion = require(game:GetService("ReplicatedStorage"):WaitForChild("Shared"):WaitForChild("UiMotion"))
local UserInputService = game:GetService("UserInputService")
local GuiService = game:GetService("GuiService")
local HapticService = game:GetService("HapticService")

local STATS_FADE_TWEEN_INFO = TweenInfo.new(0.15, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local PREVIEW_SLIDE_TWEEN_INFO = TweenInfo.new(0.18, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
-- previewFrame slides between two states so the card alone (stats hidden) or the stats+card
-- pair (stats revealed) always reads as balanced in the slot:
--   • revealed → the Studio-authored position, pinned to the right edge (AnchorPoint.X = 1,
--                Position.X = {1, 0}) so the card hugs the right of the template.
--   • hidden   → re-centered (AnchorPoint.X = 0.5, Position.X = {0.5, 0}).
-- Both keep the authored Y anchor/position, and the targets are captured per row from the
-- cloned template (not hard-coded), so re-authoring the card in Studio just works.
local STATS_LOCK_HOLD_SECONDS = 0.5
local STATS_LOCK_HAPTIC_SECONDS = 0.08

local StoreCookieStats = {}

function StoreCookieStats.new(ctx)
	local previewInteraction = ctx.preview
	local screenGui = ctx.screenGui

	local statsSlideControllers = {}
	local lockedStatsByUpgradeId = {}
	-- Global "lock all" state, driven by the buildings-tab eye toggle (StatsEyeController).
	-- When true every row shows its stats regardless of hover / per-row lock.
	local lockAllActive = false

	local function findDescendantIgnoreCase(parent, descendantName)
		local targetName = string.lower(descendantName)
		for _, descendant in ipairs(parent:GetDescendants()) do
			if string.lower(descendant.Name) == targetName then
				return descendant
			end
		end

		return nil
	end

	local function pulseTouchHaptic()
		local supported = false
		pcall(function()
			supported = HapticService:IsMotorSupported(Enum.UserInputType.Touch, Enum.VibrationMotor.Small)
		end)

		if not supported then
			return
		end

		pcall(function()
			HapticService:SetMotor(Enum.UserInputType.Touch, Enum.VibrationMotor.Small, 1)
		end)
		task.delay(STATS_LOCK_HAPTIC_SECONDS, function()
			pcall(function()
				HapticService:SetMotor(Enum.UserInputType.Touch, Enum.VibrationMotor.Small, 0)
			end)
		end)
	end

	local function setupCookieStatsSlide(row, upgradeId, activateRow)
		if not row:IsA("GuiObject") then
			return
		end

		local cookieStats = findDescendantIgnoreCase(row, "cookieStats")
		if not cookieStats or not cookieStats:IsA("GuiObject") then
			return
		end

		local previewFrame = findDescendantIgnoreCase(row, "previewFrame")
		if previewFrame and not previewFrame:IsA("GuiObject") then
			previewFrame = nil
		end
		local hoverExclusions = {}
		for _, name in ipairs({ "info", "InfoHitbox", "Description" }) do
			local object = findDescendantIgnoreCase(row, name)
			if object and object:IsA("GuiObject") then
				table.insert(hoverExclusions, object)
			end
		end

		-- Capture the authored (revealed) position/anchor before applyState first moves it, and
		-- derive the centered (hidden) counterpart. Anchor and position scale interpolate
		-- together, so the card's left edge travels linearly between centered and right-hugged.
		local previewShiftedPosition, previewShiftedAnchor
		local previewCenteredPosition, previewCenteredAnchor
		if previewFrame then
			previewShiftedPosition = previewFrame.Position
			previewShiftedAnchor = previewFrame.AnchorPoint
			previewCenteredPosition = UDim2.new(0.5, 0, previewShiftedPosition.Y.Scale, previewShiftedPosition.Y.Offset)
			previewCenteredAnchor = Vector2.new(0.5, previewShiftedAnchor.Y)
		end

		-- The stats panel no longer slides; it fades. The panel itself is transparent, so the
		-- visible content lives in its deep sub-frames / icons / labels. Capture every
		-- descendant transparency that should animate, with its authored base value (mirrors
		-- the NEAR_MISS accent capture in StoreController).
		local fadeEntries = {}
		local function captureFade(object)
			if object:IsA("GuiObject") and object.BackgroundTransparency < 1 then
				table.insert(
					fadeEntries,
					{ object = object, prop = "BackgroundTransparency", base = object.BackgroundTransparency }
				)
			end
			if object:IsA("TextLabel") or object:IsA("TextButton") then
				if object.TextTransparency < 1 then
					table.insert(
						fadeEntries,
						{ object = object, prop = "TextTransparency", base = object.TextTransparency }
					)
				end
				if object.TextStrokeTransparency < 1 then
					table.insert(
						fadeEntries,
						{ object = object, prop = "TextStrokeTransparency", base = object.TextStrokeTransparency }
					)
				end
			elseif object:IsA("ImageLabel") or object:IsA("ImageButton") then
				if object.ImageTransparency < 1 then
					table.insert(
						fadeEntries,
						{ object = object, prop = "ImageTransparency", base = object.ImageTransparency }
					)
				end
			elseif object:IsA("UIStroke") then
				if object.Transparency < 1 then
					table.insert(fadeEntries, { object = object, prop = "Transparency", base = object.Transparency })
				end
			end
		end

		captureFade(cookieStats)
		for _, descendant in ipairs(cookieStats:GetDescendants()) do
			captureFade(descendant)
		end

		local fadeToken = 0
		local function setStatsOpacity(show, animate)
			animate = animate == true
			fadeToken += 1
			local token = fadeToken

			if show then
				cookieStats.Visible = true
			end

			for _, entry in ipairs(fadeEntries) do
				if entry.object.Parent then
					local target = show and entry.base or 1
					if animate then
						UiMotion.create(entry.object, STATS_FADE_TWEEN_INFO, { [entry.prop] = target }):Play()
					else
						entry.object[entry.prop] = target
					end
				end
			end

			-- Once fully hidden, drop the panel out of render/input so the transparent overlay
			-- never sits over the centered preview card.
			if not show then
				if animate then
					task.delay(STATS_FADE_TWEEN_INFO.Time, function()
						if token == fadeToken then
							cookieStats.Visible = false
						end
					end)
				else
					cookieStats.Visible = false
				end
			end
		end

		local activePreviewTween = nil
		local function setPreviewShifted(shifted, animate)
			if not previewFrame then
				return
			end

			if activePreviewTween then
				activePreviewTween:Cancel()
				activePreviewTween = nil
			end

			local targetPosition = shifted and previewShiftedPosition or previewCenteredPosition
			local targetAnchor = shifted and previewShiftedAnchor or previewCenteredAnchor
			if animate then
				activePreviewTween = UiMotion.create(previewFrame, PREVIEW_SLIDE_TWEEN_INFO, {
					Position = targetPosition,
					AnchorPoint = targetAnchor,
				})
				activePreviewTween:Play()
			else
				previewFrame.AnchorPoint = targetAnchor
				previewFrame.Position = targetPosition
			end
		end

		local isHovering = false
		local suppressHoverUntilLeave = false
		local isPreviewSpinHeld = false

		local function isLocked()
			return lockedStatsByUpgradeId[upgradeId] == true
		end

		local function statsAreHidden()
			local config = ctx.UpgradeConfig[upgradeId]
			return config ~= nil and ctx.isBuildingLocked(upgradeId, config)
		end
		local wereStatsHidden = statsAreHidden()

		-- Active preview spinning temporarily pins the hover state. This keeps the stats and
		-- shifted preview stable when the pointer leaves the row during a drag; release returns
		-- immediately to the normal hover/lock state.
		local function statsShouldShow()
			if statsAreHidden() then
				return false
			end

			return lockAllActive
				or isLocked()
				or isPreviewSpinHeld
				or (UserInputService.MouseEnabled and isHovering and not suppressHoverUntilLeave)
		end

		local function applyState(animate)
			local shouldShow = statsShouldShow()
			setStatsOpacity(shouldShow, animate)
			setPreviewShifted(shouldShow, animate)
		end

		local function toggleStatsLock()
			if statsAreHidden() then
				lockedStatsByUpgradeId[upgradeId] = nil
				applyState(true)
				return
			end

			local nextLocked = not isLocked()
			lockedStatsByUpgradeId[upgradeId] = nextLocked or nil
			suppressHoverUntilLeave = not nextLocked and isHovering
			applyState(true)
		end

		applyState(false)

		if previewFrame then
			local lockCatch = Instance.new("TextButton")
			lockCatch.Name = "StatsLockCatch"
			lockCatch.BackgroundTransparency = 1
			lockCatch.BorderSizePixel = 0
			lockCatch.Text = ""
			lockCatch.AutoButtonColor = false
			lockCatch.Size = UDim2.fromScale(1, 1)
			lockCatch.Position = UDim2.fromScale(0, 0)
			lockCatch.ZIndex = 100
			lockCatch.Parent = previewFrame

			local activeTouchInput = nil
			local touchHoldToken = 0
			local touchHoldCompleted = false
			local dragInput = nil
			local dragStartPosition = nil
			local lastDragPosition = nil
			local isDraggingPreview = false
			local suppressNextActivation = false

			local function getInputPosition(input)
				return Vector2.new(input.Position.X, input.Position.Y)
			end

			local function cancelTouchHold()
				touchHoldToken += 1
				activeTouchInput = nil
				touchHoldCompleted = false
			end

			local function beginPreviewDrag(input)
				if previewInteraction.activeDragOwner and previewInteraction.activeDragOwner ~= lockCatch then
					return false
				end

				previewInteraction.activeDragOwner = lockCatch
				dragInput = input
				dragStartPosition = getInputPosition(input)
				lastDragPosition = dragStartPosition
				isDraggingPreview = false
				return true
			end

			local function updatePreviewDrag(input)
				if
					previewInteraction.activeDragOwner ~= lockCatch
					or not dragInput
					or not dragStartPosition
					or not lastDragPosition
				then
					return
				end

				local isMatchingTouch = dragInput.UserInputType == Enum.UserInputType.Touch
					and input.UserInputType == Enum.UserInputType.Touch
				local isMatchingMouse = dragInput.UserInputType == Enum.UserInputType.MouseButton1
					and input.UserInputType == Enum.UserInputType.MouseMovement
				if not isMatchingTouch and not isMatchingMouse then
					return
				end

				local position = getInputPosition(input)
				local totalDelta = position - dragStartPosition
				if not isDraggingPreview then
					if totalDelta.Magnitude < previewInteraction.dragThresholdPx then
						return
					end

					if not previewInteraction.getSpinner(row) then
						return
					end

					isDraggingPreview = true
					isPreviewSpinHeld = true
					suppressNextActivation = true
					cancelTouchHold()
					applyState(true)
				end

				local delta = position - lastDragPosition
				lastDragPosition = position
				previewInteraction.rotate(row, delta.X)
			end

			local function endPreviewDrag(input)
				if previewInteraction.activeDragOwner ~= lockCatch or not dragInput then
					return false
				end

				local isMatchingTouch = dragInput.UserInputType == Enum.UserInputType.Touch
					and input.UserInputType == Enum.UserInputType.Touch
				local isMatchingMouse = dragInput.UserInputType == Enum.UserInputType.MouseButton1
					and input.UserInputType == Enum.UserInputType.MouseButton1
				if not isMatchingTouch and not isMatchingMouse then
					return false
				end

				local didDrag = isDraggingPreview
				previewInteraction.setDragging(previewInteraction.getSpinner(row), false)
				dragInput = nil
				dragStartPosition = nil
				lastDragPosition = nil
				isDraggingPreview = false
				isPreviewSpinHeld = false
				previewInteraction.activeDragOwner = nil
				applyState(true)
				return didDrag
			end

			lockCatch.InputBegan:Connect(function(input)
				if input.UserInputType == Enum.UserInputType.MouseButton1 then
					beginPreviewDrag(input)
				end
			end)

			local function beginTouchPreviewDrag(input)
				if previewInteraction.activeDragOwner or dragInput then
					return
				end

				if not beginPreviewDrag(input) then
					return
				end

				activeTouchInput = input
				touchHoldCompleted = false
				touchHoldToken += 1
				local token = touchHoldToken

				task.delay(STATS_LOCK_HOLD_SECONDS, function()
					if token ~= touchHoldToken or activeTouchInput ~= input or isDraggingPreview then
						return
					end

					touchHoldCompleted = true
					toggleStatsLock()
					pulseTouchHaptic()
				end)
			end

			local function finishPreviewDrag(input, activateTouchTap)
				local didDrag = endPreviewDrag(input)
				if didDrag then
					cancelTouchHold()
					task.delay(0.25, function()
						suppressNextActivation = false
					end)
					return
				end

				if not activateTouchTap then
					return
				end

				if input.UserInputType ~= Enum.UserInputType.Touch or activeTouchInput ~= input then
					return
				end

				local completed = touchHoldCompleted
				cancelTouchHold()
				if not completed and activateRow then
					activateRow()
				end
			end

			lockCatch.InputEnded:Connect(function(input)
				if input.UserInputType == Enum.UserInputType.MouseButton1 then
					finishPreviewDrag(input, false)
				end
			end)

			local dragChangedConnection = UserInputService.InputChanged:Connect(updatePreviewDrag)
			local dragEndedConnection = UserInputService.InputEnded:Connect(function(input)
				if previewInteraction.activeDragOwner == lockCatch then
					finishPreviewDrag(input, false)
				end
			end)
			local touchController = {
				LockCatch = lockCatch,
				Begin = beginTouchPreviewDrag,
				Update = updatePreviewDrag,
				Finish = finishPreviewDrag,
			}
			table.insert(previewInteraction.touchControllers, touchController)

			row.Destroying:Connect(function()
				if dragChangedConnection then
					dragChangedConnection:Disconnect()
					dragChangedConnection = nil
				end
				if dragEndedConnection then
					dragEndedConnection:Disconnect()
					dragEndedConnection = nil
				end
				for index = #previewInteraction.touchControllers, 1, -1 do
					if previewInteraction.touchControllers[index] == touchController then
						table.remove(previewInteraction.touchControllers, index)
						break
					end
				end
			end)

			lockCatch.Activated:Connect(function(inputObject)
				if suppressNextActivation then
					suppressNextActivation = false
					return
				end

				local inputType = inputObject and inputObject.UserInputType
				if inputType ~= Enum.UserInputType.Touch and activateRow then
					activateRow()
				end
			end)

			lockCatch.MouseButton2Click:Connect(function()
				toggleStatsLock()
			end)
		end

		table.insert(statsSlideControllers, {
			Row = row,
			HoverExclusions = hoverExclusions,
			SetHovered = function(hovered)
				local areStatsHidden = statsAreHidden()
				if hovered and not isHovering and areStatsHidden and ctx.startLockedBuildingNameReveal then
					ctx.startLockedBuildingNameReveal(upgradeId, row)
				end
				if hovered == isHovering and areStatsHidden == wereStatsHidden then
					return
				end

				isHovering = hovered
				wereStatsHidden = areStatsHidden
				if not hovered then
					suppressHoverUntilLeave = false
				end
				applyState(true)
			end,
			Collapse = function()
				isHovering = false
				suppressHoverUntilLeave = false
				wereStatsHidden = statsAreHidden()
				-- Force the default look regardless of lock (used when a row is recycled/hidden).
				setStatsOpacity(false, false)
				setPreviewShifted(false, false)
			end,
			-- Re-evaluate show/hide from current state (used when lock-all toggles).
			Refresh = function()
				applyState(true)
			end,
		})
	end

	local function isGuiObjectVisibleInHierarchy(guiObject)
		local current = guiObject
		while current and current ~= screenGui do
			if current:IsA("GuiObject") and not current.Visible then
				return false
			end

			current = current.Parent
		end

		return true
	end

	local function isPointInsideGuiObject(point, guiObject)
		if not guiObject.Parent or not isGuiObjectVisibleInHierarchy(guiObject) then
			return false
		end

		local position = guiObject.AbsolutePosition
		local size = guiObject.AbsoluteSize
		return point.X >= position.X
			and point.X <= position.X + size.X
			and point.Y >= position.Y
			and point.Y <= position.Y + size.Y
	end

	UserInputService.TouchStarted:Connect(function(input)
		if previewInteraction.activeTouchController then
			return
		end

		local point = Vector2.new(input.Position.X, input.Position.Y)
		for index = #previewInteraction.touchControllers, 1, -1 do
			local controller = previewInteraction.touchControllers[index]
			if controller.LockCatch and isPointInsideGuiObject(point, controller.LockCatch) then
				previewInteraction.activeTouchController = controller
				controller.Begin(input)
				if previewInteraction.activeDragOwner ~= controller.LockCatch then
					previewInteraction.activeTouchController = nil
				end
				return
			end
		end
	end)

	UserInputService.TouchMoved:Connect(function(input)
		local controller = previewInteraction.activeTouchController
		if controller then
			controller.Update(input)
		end
	end)

	UserInputService.TouchEnded:Connect(function(input)
		local controller = previewInteraction.activeTouchController
		if controller then
			controller.Finish(input, true)
			previewInteraction.activeTouchController = nil
		end
	end)

	local function updateStatsSlideHover()
		if not UserInputService.MouseEnabled then
			for _, controller in ipairs(statsSlideControllers) do
				controller.SetHovered(false)
			end
			return
		end

		-- MouseLocation is in full-screen coordinates while GuiObject.AbsolutePosition is in
		-- ScreenGui coordinates. The inset must be removed even when IgnoreGuiInset is true;
		-- otherwise a row reads as hovered while the pointer is visibly above its preview.
		local pointerPosition = UserInputService:GetMouseLocation() - GuiService:GetGuiInset()
		for _, controller in ipairs(statsSlideControllers) do
			local excluded = false
			for _, object in ipairs(controller.HoverExclusions) do
				if isPointInsideGuiObject(pointerPosition, object) then
					excluded = true
					break
				end
			end
			controller.SetHovered(not excluded and isPointInsideGuiObject(pointerPosition, controller.Row))
		end
	end

	-- Turn the global lock-all on/off and re-apply every registered row's state. New rows
	-- created while active pick it up automatically via statsShouldShow() on their initial
	-- applyState, so only the already-mounted controllers need a nudge here.
	local function setLockAll(active)
		active = active and true or false
		if lockAllActive == active then
			return
		end

		lockAllActive = active
		for _, controller in ipairs(statsSlideControllers) do
			controller.Refresh()
		end
	end

	local function isLockAll()
		return lockAllActive
	end

	return {
		setup = setupCookieStatsSlide,
		updateHover = updateStatsSlideHover,
		setLockAll = setLockAll,
		isLockAll = isLockAll,
	}
end

return StoreCookieStats
