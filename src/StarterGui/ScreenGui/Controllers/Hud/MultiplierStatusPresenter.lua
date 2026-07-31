-- MultiplierStatusPresenter: binds complete multiplier sources to fixed Studio-authored slots.
-- It never creates or clones player-facing UI.
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local CursorTooltip = require(Shared:WaitForChild("CursorTooltip"))
local DevTuning = require(Shared:WaitForChild("DevTuning"):WaitForChild("DevTuning"))
local GooSkinColor = require(Shared:WaitForChild("GooSkinColor"))
local MobileScale = require(Shared:WaitForChild("MobileScale"))
local MultiplierHudConfig = require(Shared:WaitForChild("MultiplierHudConfig"))
local NumberFormat = require(Shared:WaitForChild("NumberFormat"))

local MultiplierStatusPresenter = {}

local function formatCountdown(remaining)
	local seconds = math.max(0, math.ceil(tonumber(remaining) or 0))
	local hours = math.floor(seconds / 3600)
	local minutes = math.floor(seconds % 3600 / 60)
	local remainder = seconds % 60
	if hours > 0 then
		return string.format("%d:%02d:%02d", hours, minutes, remainder)
	end
	return string.format("%d:%02d", minutes, remainder)
end

local function getRemaining(source, now)
	if typeof(source.RemainingInstance) == "Instance" then
		return math.max(0, tonumber(source.RemainingInstance:GetAttribute("RemainingSeconds")) or 0)
	end
	if type(source.RemainingSeconds) == "number" then
		return math.max(0, source.RemainingSeconds)
	end
	if type(source.ExpiresAt) == "number" then
		return math.max(0, source.ExpiresAt - now)
	end
	return nil
end

local function getSlots(container)
	local slots = {}
	for _, child in ipairs(container:GetChildren()) do
		if child:IsA("Frame") and child.Name:match("^" .. MultiplierHudConfig.SlotPrefix .. "%d+$") then
			table.insert(slots, child)
		end
	end
	table.sort(slots, function(left, right)
		return left.LayoutOrder < right.LayoutOrder
	end)
	return slots
end

local function formatAffectedNames(names)
	if type(names) ~= "table" or #names == 0 then
		return "No building types"
	end
	return table.concat(names, ", ")
end

local function formatAffectedCount(source, adjective)
	local count = math.max(0, math.floor(tonumber(source.AffectedCount) or 0))
	local noun = count == 1 and "building" or "buildings"
	return ("%d %s %s"):format(count, adjective, noun)
end

local function pluralizeBuildingName(name, count)
	if count == 1 then
		return name
	end
	if name:match("[^aeiou]y$") then
		return name:sub(1, -2) .. "ies"
	end
	if name:match("[sxz]$") or name:match("ch$") or name:match("sh$") then
		return name .. "es"
	end
	return name .. "s"
end

local function getCompactScope(source)
	if source.Kind == "BuildingUpgrade" then
		return formatAffectedNames(source.AffectedNames)
	end
	if source.Kind == "Floor" then
		return formatAffectedCount(source, "matching")
	end
	if source.Kind == "BoostField" then
		local count = math.max(0, math.floor(tonumber(source.AffectedCount) or 0))
		return ("%d %s"):format(count, count == 1 and "building" or "buildings")
	end
	return source.CompactScope or "Active multiplier"
end

local function formatBonus(multiplier)
	local percent = ((tonumber(multiplier) or 1) - 1) * 100
	local sign = percent >= 0 and "+" or ""
	return sign .. NumberFormat.rate(percent) .. "%"
end

local function getDescription(source)
	if source.Kind == "Floor" and type(source.AffectedNames) == "table" then
		local lines = {}
		for _, name in ipairs(source.AffectedNames) do
			local count = math.max(0, math.floor(tonumber(source.AffectedCounts and source.AffectedCounts[name]) or 0))
			table.insert(
				lines,
				("%d %s: %s"):format(count, pluralizeBuildingName(name, count), formatBonus(source.Multiplier))
			)
		end
		if #lines > 0 then
			return table.concat(lines, "\n")
		end
	end
	return getCompactScope(source) .. ": " .. formatBonus(source.Multiplier)
end

local function applyIcon(slot, source, player)
	local icon = slot:FindFirstChild("Icon")
	if not (icon and icon:IsA("ImageLabel")) then
		return
	end
	local definition = MultiplierHudConfig.Icons[source.IconKey]
	icon.Image = definition and definition.Image or MultiplierHudConfig.PlaceholderIcon
	if source.IconKey == "Goo" then
		icon.ImageColor3 = GooSkinColor.getSelectedBodyColor(player)
	else
		icon.ImageColor3 = definition and definition.Color or Color3.new(1, 1, 1)
	end
	icon.ImageTransparency = 0
end

function MultiplierStatusPresenter.new(screenGui, player)
	local root = screenGui:FindFirstChild(MultiplierHudConfig.RootName)
	if not (root and root:IsA("GuiObject")) then
		warn("Multiplier status HUD disabled: Studio-authored root was not found")
		return nil
	end
	local slotsContainer = root:FindFirstChild(MultiplierHudConfig.SlotsName)
	if not (slotsContainer and slotsContainer:IsA("GuiObject")) then
		warn("Multiplier status HUD disabled: SourceSlots was not found")
		return nil
	end

	local slots = getSlots(slotsContainer)
	local responsiveScale = root:FindFirstChild("ResponsiveScale")
	local layout = slotsContainer:FindFirstChild("Layout")
	local tooltip = CursorTooltip.get(screenGui)
	local assigned = {}
	local slotBySourceId = {}
	local registrations = {}
	local states = {}
	local tuningHandles = {}
	local viewportHandle
	local suppressed = false
	local destroyed = false
	local overflowWarned = false

	local function updateRootVisibility()
		root.Visible = not suppressed and next(assigned) ~= nil
	end

	local function getState(slot)
		local state = states[slot]
		if not state then
			state = {
				generation = 0,
				scale = slot:FindFirstChild("UIScale"),
				pulseScale = slot:FindFirstChild("Icon") and slot.Icon:FindFirstChild("PulseScale"),
			}
			states[slot] = state
		end
		return state
	end

	local function cancelTween(tween)
		if tween then
			tween:Cancel()
		end
	end

	local function cancelFadeTweens(state)
		for _, tween in ipairs(state.fadeTweens or {}) do
			tween:Cancel()
		end
		state.fadeTweens = nil
	end

	local function setTransparency(slot, transparency)
		local icon = slot:FindFirstChild("Icon")
		if icon and icon:IsA("ImageLabel") then
			icon.ImageTransparency = transparency
		end
		local timer = slot:FindFirstChild("Timer")
		if timer and timer:IsA("TextLabel") then
			timer.TextTransparency = transparency
		end
	end

	local function stopPulse(slot)
		local state = getState(slot)
		cancelTween(state.pulseTween)
		state.pulseTween = nil
		if state.pulseScale then
			state.pulseScale.Scale = 1
		end
	end

	local function startPulse(slot)
		local state = getState(slot)
		if state.pulseTween or state.removing or not state.pulseScale then
			return
		end
		state.pulseScale.Scale = 1
		state.pulseTween = TweenService:Create(
			state.pulseScale,
			TweenInfo.new(
				DevTuning.get("MultiplierHud.WarningPulseSeconds"),
				Enum.EasingStyle.Sine,
				Enum.EasingDirection.InOut,
				-1,
				true
			),
			{ Scale = DevTuning.get("MultiplierHud.WarningPulseScale") }
		)
		state.pulseTween:Play()
	end

	local function activate(slot)
		local state = getState(slot)
		state.generation += 1
		local generation = state.generation
		state.removing = false
		cancelTween(state.motionTween)
		state.motionTween = nil
		cancelFadeTweens(state)
		stopPulse(slot)
		setTransparency(slot, 0)
		slot.Visible = true
		if not state.scale then
			return
		end
		state.scale.Scale = DevTuning.get("MultiplierHud.ActivationStartScale")
		local pop = TweenService:Create(
			state.scale,
			TweenInfo.new(
				DevTuning.get("MultiplierHud.ActivationPopSeconds"),
				Enum.EasingStyle.Back,
				Enum.EasingDirection.Out
			),
			{ Scale = DevTuning.get("MultiplierHud.ActivationPopScale") }
		)
		state.motionTween = pop
		pop.Completed:Once(function(playbackState)
			if destroyed or state.generation ~= generation or playbackState ~= Enum.PlaybackState.Completed then
				return
			end
			local settle = TweenService:Create(
				state.scale,
				TweenInfo.new(
					DevTuning.get("MultiplierHud.ActivationSettleSeconds"),
					Enum.EasingStyle.Quad,
					Enum.EasingDirection.Out
				),
				{ Scale = 1 }
			)
			state.motionTween = settle
			settle.Completed:Once(function()
				if destroyed or state.generation ~= generation then
					return
				end
				state.motionTween = nil
				if state.warning then
					startPulse(slot)
				end
			end)
			settle:Play()
		end)
		pop:Play()
	end

	local function remove(slot)
		local source = assigned[slot]
		if not source then
			return
		end
		local removedId = source.Id
		local state = getState(slot)
		state.generation += 1
		local generation = state.generation
		state.removing = true
		state.warning = false
		cancelTween(state.motionTween)
		state.motionTween = nil
		cancelFadeTweens(state)
		stopPulse(slot)
		local registration = registrations[slot]
		if registration then
			registration:clear()
		end
		slotBySourceId[removedId] = nil
		if not state.scale then
			assigned[slot] = nil
			slot.Visible = false
			updateRootVisibility()
			return
		end
		local shrink = TweenService:Create(
			state.scale,
			TweenInfo.new(DevTuning.get("MultiplierHud.RemovalSeconds"), Enum.EasingStyle.Quad, Enum.EasingDirection.In),
			{ Scale = DevTuning.get("MultiplierHud.RemovalScale") }
		)
		local icon = slot:FindFirstChild("Icon")
		local timer = slot:FindFirstChild("Timer")
		local fadeTargets = {}
		if icon and icon:IsA("ImageLabel") then
			table.insert(
				fadeTargets,
				TweenService:Create(
					icon,
					TweenInfo.new(DevTuning.get("MultiplierHud.RemovalSeconds")),
					{ ImageTransparency = 1 }
				)
			)
		end
		if timer and timer:IsA("TextLabel") then
			table.insert(
				fadeTargets,
				TweenService:Create(
					timer,
					TweenInfo.new(DevTuning.get("MultiplierHud.RemovalSeconds")),
					{ TextTransparency = 1 }
				)
			)
		end
		state.motionTween = shrink
		state.fadeTweens = fadeTargets
		for _, tween in ipairs(fadeTargets) do
			tween:Play()
		end
		shrink.Completed:Once(function()
			if destroyed or state.generation ~= generation then
				return
			end
			state.motionTween = nil
			state.fadeTweens = nil
			state.removing = false
			if assigned[slot] and assigned[slot].Id == removedId then
				assigned[slot] = nil
				slot:SetAttribute("SourceId", "")
				slot.Visible = false
			end
			state.scale.Scale = 1
			setTransparency(slot, 0)
			updateRootVisibility()
		end)
		shrink:Play()
	end

	root.Visible = false
	for _, slot in ipairs(slots) do
		slot.Visible = false
		local hitbox = slot:FindFirstChild("Hitbox")
		if hitbox and hitbox:IsA("GuiButton") then
			registrations[slot] = tooltip:registerGui(hitbox, {
				trigger = tooltip.Trigger.HoverAndClick,
				getContent = function()
					local source = assigned[slot]
					if not source or getState(slot).removing then
						return nil
					end
					return {
						mode = "Hint",
						title = tostring(source.DisplayName),
						description = getDescription(source),
					}
				end,
			})
		end
	end

	local function applyLayout()
		if destroyed then
			return
		end
		local compact = MobileScale.shouldUseMobile(root)
		local gap = DevTuning.get("MultiplierHud.SlotGap")
		if layout and layout:IsA("UIListLayout") then
			layout.Padding = UDim.new(0, gap)
		end
		local firstSlot = slots[1]
		local slotWidth = firstSlot and firstSlot.Size.X.Offset or 32
		slotsContainer.AutomaticSize = Enum.AutomaticSize.Y
		slotsContainer.Size = UDim2.fromOffset(
			slotWidth * MultiplierHudConfig.SlotsPerRow + gap * (MultiplierHudConfig.SlotsPerRow - 1),
			0
		)
		if responsiveScale and responsiveScale:IsA("UIScale") then
			responsiveScale.Scale = compact and DevTuning.get("MultiplierHud.CompactScale")
				or DevTuning.get("MultiplierHud.DesktopScale")
		end

		local viewport = MobileScale.getViewportSize(root)
		local safeTopLeft, safeBottomRight = MobileScale.getCoreSafeOffsets(root)
		local bottomOffset = compact and DevTuning.get("MultiplierHud.BottomOffset")
			or MultiplierHudConfig.DesktopXpBarBottomOffset
		root.AnchorPoint = Vector2.new(0, 1)
		root.Position = UDim2.fromOffset(
			math.round(safeTopLeft.X + DevTuning.get("MultiplierHud.LeftOffset")),
			math.round(viewport.Y - safeBottomRight.Y - bottomOffset)
		)
	end

	for _, key in ipairs({
		"LeftOffset",
		"BottomOffset",
		"SlotGap",
		"DesktopScale",
		"CompactScale",
	}) do
		table.insert(tuningHandles, DevTuning.observe("MultiplierHud." .. key, applyLayout))
	end
	viewportHandle = MobileScale.onViewportChanged(applyLayout)

	local presenter = {}

	function presenter:setSuppressed(value)
		suppressed = value == true
		updateRootVisibility()
	end

	function presenter:applySources(sources)
		if destroyed then
			return
		end
		if #sources > #slots and not overflowWarned then
			overflowWarned = true
			warn(("Multiplier status HUD has %d authored slots for %d active sources"):format(#slots, #sources))
		end

		local wanted = {}
		local visibleCount = math.min(#sources, #slots)
		local overflowCount = math.max(0, visibleCount - MultiplierHudConfig.SlotsPerRow)
		for index, source in ipairs(sources) do
			if index <= #slots then
				wanted[source.Id] = true
			end
		end
		for slot, source in pairs(assigned) do
			if not wanted[source.Id] and not getState(slot).removing then
				remove(slot)
			end
		end

		for index, source in ipairs(sources) do
			if index > #slots then
				break
			end
			local slot = slotBySourceId[source.Id]
			local isNew = slot == nil
			if not slot then
				for _, candidate in ipairs(slots) do
					if assigned[candidate] == nil then
						slot = candidate
						break
					end
				end
			end
			if not slot then
				for _, candidate in ipairs(slots) do
					if getState(candidate).removing then
						slot = candidate
						break
					end
				end
			end
			if not slot then
				break
			end

			local state = getState(slot)
			if state.removing then
				state.generation += 1
				state.removing = false
				cancelTween(state.motionTween)
				state.motionTween = nil
				stopPulse(slot)
			end
			local previous = assigned[slot]
			if previous and previous.Id ~= source.Id then
				slotBySourceId[previous.Id] = nil
				isNew = true
			end
			assigned[slot] = source
			slotBySourceId[source.Id] = slot
			slot.LayoutOrder = overflowCount > 0
					and (index <= MultiplierHudConfig.SlotsPerRow and overflowCount + index or index - MultiplierHudConfig.SlotsPerRow)
				or index
			slot:SetAttribute("SourceId", source.Id)
			applyIcon(slot, source, player)
			setTransparency(slot, 0)
			slot.Visible = true
			if isNew then
				activate(slot)
			end
		end

		-- Reapply the configured spacing whenever visibility changes cause the list to wrap or unwrap.
		applyLayout()
		updateRootVisibility()
		presenter:refreshCountdowns()
	end

	function presenter:refreshCountdowns()
		if destroyed then
			return
		end
		local now = Workspace:GetServerTimeNow()
		local warningThreshold = DevTuning.get("MultiplierHud.WarningThresholdSeconds")
		local normalColor = DevTuning.get("MultiplierHud.NormalTextColor")
		local warningColor = DevTuning.get("MultiplierHud.WarningTextColor")
		for slot, source in pairs(assigned) do
			local state = getState(slot)
			if not state.removing then
				local timer = slot:FindFirstChild("Timer")
				local remaining = getRemaining(source, now)
				local warning = remaining ~= nil and remaining <= warningThreshold
				state.warning = warning
				if timer and timer:IsA("TextLabel") then
					if remaining ~= nil then
						timer.Text = formatCountdown(remaining)
						timer.TextSize = DevTuning.get("MultiplierHud.CountdownTextSize")
						timer.TextColor3 = warning and warningColor or normalColor
					else
						timer.Text = MultiplierHudConfig.InfinityText
						timer.TextSize = DevTuning.get("MultiplierHud.InfinityTextSize")
						timer.TextColor3 = normalColor
					end
				end
				if warning then
					startPulse(slot)
				else
					stopPulse(slot)
				end
				local registration = registrations[slot]
				if registration then
					registration:refresh()
				end
			end
		end
	end

	function presenter:destroy()
		if destroyed then
			return
		end
		destroyed = true
		for _, registration in pairs(registrations) do
			registration:disconnect()
		end
		for _, state in pairs(states) do
			cancelTween(state.motionTween)
			cancelTween(state.pulseTween)
			cancelFadeTweens(state)
		end
		for _, handle in ipairs(tuningHandles) do
			handle:Disconnect()
		end
		if viewportHandle then
			viewportHandle:destroy()
		end
		table.clear(assigned)
		table.clear(slotBySourceId)
		root.Visible = false
	end

	applyLayout()
	return presenter
end

return MultiplierStatusPresenter
