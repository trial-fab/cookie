-- Shared presentation owner for the four main menu modals. Studio owns the modal hierarchy and
-- the optional direct-child `MobileClose` button; this module only switches runtime geometry,
-- safe-area placement, and visibility between authored desktop and compact-phone modes.
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local MobileScale = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("MobileScale"))

local ModalResponsiveLayout = {}

local CLOSE_NAME = "MobileClose"
local COMPACT_Z_INDEX = 100

local function captureRootAppearance(modal)
	local corner = modal:FindFirstChildWhichIsA("UICorner")
	local stroke = modal:FindFirstChildWhichIsA("UIStroke")
	return {
		active = modal.Active,
		backgroundTransparency = modal.BackgroundTransparency,
		zIndex = modal.ZIndex,
		corner = corner,
		cornerRadius = corner and corner.CornerRadius or nil,
		stroke = stroke,
		strokeEnabled = stroke and stroke.Enabled or nil,
	}
end

local function captureClose(closeButton)
	if not closeButton then
		return nil
	end
	return {
		anchorPoint = closeButton.AnchorPoint,
		position = closeButton.Position,
		size = closeButton.Size,
		visible = closeButton.Visible,
		zIndex = closeButton.ZIndex,
	}
end

local function captureCompactContent(modal, closeButton)
	local content = {}
	local header = modal:FindFirstChild("Header")
	local headerBottomScale = nil
	local headerBottomOffset = nil
	if header and header:IsA("GuiObject") then
		local headerTopScale = header.Position.Y.Scale - header.AnchorPoint.Y * header.Size.Y.Scale
		local headerTopOffset = header.Position.Y.Offset - header.AnchorPoint.Y * header.Size.Y.Offset
		headerBottomScale = headerTopScale + header.Size.Y.Scale
		headerBottomOffset = headerTopOffset + header.Size.Y.Offset
	end

	for _, child in ipairs(modal:GetChildren()) do
		if child:IsA("GuiObject") and child ~= closeButton then
			local minimumTopShift = 0
			if child ~= header and headerBottomScale ~= nil then
				local childTopScale = child.Position.Y.Scale - child.AnchorPoint.Y * child.Size.Y.Scale
				local childTopOffset = child.Position.Y.Offset - child.AnchorPoint.Y * child.Size.Y.Offset
				if math.abs(childTopScale - headerBottomScale) < 0.0001 then
					minimumTopShift = math.max(0, headerBottomOffset - childTopOffset)
				end
			end
			table.insert(content, {
				gui = child,
				anchorPoint = child.AnchorPoint,
				position = child.Position,
				size = child.Size,
				minimumTopShift = minimumTopShift,
			})
		end
	end
	return content
end

local function applyCompactContent(content, topInset, compact)
	for _, entry in ipairs(content) do
		local gui = entry.gui
		if gui.Parent then
			gui.Position = entry.position
			gui.Size = entry.size

			if compact then
				local compactTopShift = topInset + entry.minimumTopShift
				if entry.size.Y.Scale > 0 then
					-- Move the top edge below CoreUI while keeping the authored bottom edge fixed.
					-- This works for both top-anchored scrolling regions and Profile's centered,
					-- full-height content frame.
					gui.Position = UDim2.new(
						entry.position.X.Scale,
						entry.position.X.Offset,
						entry.position.Y.Scale,
						entry.position.Y.Offset + compactTopShift * (1 - entry.anchorPoint.Y)
					)
					gui.Size = UDim2.new(
						entry.size.X.Scale,
						entry.size.X.Offset,
						entry.size.Y.Scale,
						entry.size.Y.Offset - compactTopShift
					)
				elseif entry.position.Y.Scale == 0 and entry.anchorPoint.Y == 0 then
					-- Fixed-height top chrome (Header, Wheel TabBar, etc.) moves below CoreUI
					-- without changing its authored height.
					gui.Position = UDim2.new(
						entry.position.X.Scale,
						entry.position.X.Offset,
						entry.position.Y.Scale,
						entry.position.Y.Offset + compactTopShift
					)
				end
			end
		end
	end
end

local function captureHeaderAccent(modal)
	local header = modal:FindFirstChild("Header")
	local accent = header and header:FindFirstChild("HeaderAccent")
	if not (accent and accent:IsA("GuiObject")) then
		return nil
	end
	local corner = accent:FindFirstChildWhichIsA("UICorner")
	return {
		accent = accent,
		position = accent.Position,
		size = accent.Size,
		corner = corner,
		cornerRadius = corner and corner.CornerRadius or nil,
		bottomLeftRadius = corner and corner.BottomLeftRadius or nil,
		bottomRightRadius = corner and corner.BottomRightRadius or nil,
		topLeftRadius = corner and corner.TopLeftRadius or nil,
		topRightRadius = corner and corner.TopRightRadius or nil,
	}
end

local function applyHeaderAccent(state, compact)
	if not (state and state.accent.Parent) then
		return
	end
	if compact then
		state.accent.Position = UDim2.fromScale(0, 0)
		state.accent.Size = UDim2.new(state.size.X.Scale, state.size.X.Offset, 1, 0)
		if state.corner then
			state.corner.CornerRadius = UDim.new(0, 0)
			state.corner.BottomLeftRadius = UDim.new(1, 0)
			state.corner.BottomRightRadius = UDim.new(0, 0)
			state.corner.TopLeftRadius = UDim.new(0, 0)
			state.corner.TopRightRadius = UDim.new(1, 0)
		end
	else
		state.accent.Position = state.position
		state.accent.Size = state.size
		if state.corner then
			state.corner.CornerRadius = state.cornerRadius
			state.corner.BottomLeftRadius = state.bottomLeftRadius
			state.corner.BottomRightRadius = state.bottomRightRadius
			state.corner.TopLeftRadius = state.topLeftRadius
			state.corner.TopRightRadius = state.topRightRadius
		end
	end
end

function ModalResponsiveLayout.bind(config)
	local modal = assert(config.modal, "ModalResponsiveLayout.bind requires modal")
	local designSize = Vector2.new(modal.Size.X.Offset, modal.Size.Y.Offset)
	local authored = captureRootAppearance(modal)
	local closeButton = modal:FindFirstChild(CLOSE_NAME)
	if closeButton and not closeButton:IsA("GuiButton") then
		warn(("%s.%s must be a GuiButton; compact close disabled"):format(modal.Name, CLOSE_NAME))
		closeButton = nil
	elseif not closeButton then
		warn(
			("%s is missing direct-child GuiButton %s; add it in Studio for compact close"):format(
				modal.Name,
				CLOSE_NAME
			)
		)
	end
	local authoredClose = captureClose(closeButton)
	local compactContent = captureCompactContent(modal, closeButton)
	local headerAccent = captureHeaderAccent(modal)
	local screenGui = modal:FindFirstAncestorOfClass("ScreenGui")

	if closeButton then
		closeButton.Activated:Connect(function()
			if MobileScale.shouldUseMobile(modal) and config.close then
				config.close()
			end
		end)
	end

	local handle = {}

	function handle.isCompact()
		-- Never enter a phone presentation that has no touch-accessible escape route. This lets
		-- code safely sync before the Studio-owned button is authored instead of trapping players.
		return closeButton ~= nil and MobileScale.shouldUseMobile(modal)
	end

	function handle.restScale()
		local compact = handle.isCompact()
		local scale = MobileScale.resolveModal(modal, designSize, {
			mobilePresentation = compact and "fullscreen" or nil,
			mobileScale = 0.82,
			nativeTextDesktop = true,
		})

		modal.Active = compact or authored.active
		modal.BackgroundTransparency = compact and 0 or authored.backgroundTransparency
		modal.ZIndex = compact and math.max(authored.zIndex, COMPACT_Z_INDEX) or authored.zIndex
		if authored.corner then
			authored.corner.CornerRadius = compact and UDim.new(0, 0) or authored.cornerRadius
		end
		if authored.stroke then
			if compact then
				authored.stroke.Enabled = false
			else
				authored.stroke.Enabled = authored.strokeEnabled
			end
		end

		local safeTopLeft = MobileScale.getCoreSafeOffsets(modal)
		applyCompactContent(compactContent, safeTopLeft.Y, compact)
		applyHeaderAccent(headerAccent, compact)

		if closeButton then
			if compact then
				-- Occupy the same live top-right slot as the leaderboard toggle, which the
				-- compact-modal state hides. This keeps the close control level with Roblox's
				-- topbar and immediately to the right of the still-available menu pill.
				local boardToggle = screenGui and screenGui:FindFirstChild("BoardToggle")
				if boardToggle and boardToggle:IsA("GuiObject") then
					closeButton.AnchorPoint = boardToggle.AnchorPoint
					closeButton.Position = boardToggle.Position
					closeButton.Size = boardToggle.Size
				else
					closeButton.AnchorPoint = Vector2.new(0, 0)
					closeButton.Position = UDim2.new(1, -54, 0, 12)
					closeButton.Size = UDim2.fromOffset(44, 44)
				end
				closeButton.Visible = true
				closeButton.ZIndex = math.max(authoredClose.zIndex, COMPACT_Z_INDEX + 1)
			else
				closeButton.AnchorPoint = authoredClose.anchorPoint
				closeButton.Position = authoredClose.position
				closeButton.Size = authoredClose.size
				closeButton.Visible = authoredClose.visible
				closeButton.ZIndex = authoredClose.zIndex
			end
		end

		return scale
	end

	-- Reflow immediately on normal viewport changes. If a page/content tween is in flight, wait
	-- for its authored 0.28 s duration before applying the latest geometry so an orientation flip
	-- cannot leave the modal stuck in its previous presentation mode.
	function handle.bindViewport(getScale, getActiveTween)
		local revision = 0
		return MobileScale.onViewportChanged(function()
			revision += 1
			local requestedRevision = revision
			local tween = getActiveTween()
			local function applyLatest()
				if requestedRevision == revision then
					getScale().Scale = handle.restScale()
				end
			end
			if tween and tween.PlaybackState == Enum.PlaybackState.Playing then
				task.delay(0.32, applyLatest)
			else
				applyLatest()
			end
		end)
	end

	return handle
end

return ModalResponsiveLayout
