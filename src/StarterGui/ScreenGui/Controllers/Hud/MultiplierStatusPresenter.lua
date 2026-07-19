-- MultiplierStatusPresenter: binds the fixed Studio-authored multiplier source slots.
-- It never creates or clones player-facing UI.
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local CursorTooltip = require(Shared:WaitForChild("CursorTooltip"))
local DevTuning = require(Shared:WaitForChild("DevTuning"):WaitForChild("DevTuning"))
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

function MultiplierStatusPresenter.new(screenGui)
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
	local scale = root:FindFirstChild("ResponsiveScale")
	local layout = slotsContainer:FindFirstChild("Layout")
	local tooltip = CursorTooltip.get(screenGui)
	local assigned = {}
	local registrations = {}
	local tuningHandles = {}
	local viewportHandle
	local suppressed = false
	local destroyed = false
	local overflowWarned = false

	root.Visible = false
	for _, slot in ipairs(slots) do
		slot.Visible = false
		local hitbox = slot:FindFirstChild("Hitbox")
		if hitbox and hitbox:IsA("GuiButton") then
			registrations[slot] = tooltip:registerGui(hitbox, {
				trigger = tooltip.Trigger.HoverAndClick,
				getContent = function()
					local source = assigned[slot]
					if not source then
						return nil
					end
					local description = source.Scope or "Active multiplier source."
					if type(source.ExpiresAt) == "number" then
						description ..= " Remaining " .. formatCountdown(
							source.ExpiresAt - Workspace:GetServerTimeNow()
						) .. "."
					end
					return {
						mode = "Hint",
						title = tostring(source.DisplayName) .. " " .. NumberFormat.multiplier(source.Multiplier),
						description = description,
					}
				end,
			})
		end
	end

	local function applyLayout()
		if destroyed then
			return
		end
		if layout and layout:IsA("UIListLayout") then
			layout.Padding = UDim.new(0, DevTuning.get("MultiplierHud.SlotGap"))
		end
		if scale and scale:IsA("UIScale") then
			scale.Scale = MobileScale.shouldUseMobile(root) and DevTuning.get("MultiplierHud.CompactScale")
				or DevTuning.get("MultiplierHud.DesktopScale")
		end

		local viewport = MobileScale.getViewportSize(root)
		local safeTopLeft, safeBottomRight = MobileScale.getCoreSafeOffsets(root)
		root.AnchorPoint = Vector2.new(0, 1)
		root.Position = UDim2.fromOffset(
			math.round(safeTopLeft.X + DevTuning.get("MultiplierHud.LeftOffset")),
			math.round(viewport.Y - safeBottomRight.Y - DevTuning.get("MultiplierHud.BottomOffset"))
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
		root.Visible = not suppressed and next(assigned) ~= nil
	end

	function presenter:applySources(sources)
		if destroyed then
			return
		end
		if #sources > #slots and not overflowWarned then
			overflowWarned = true
			warn(("Multiplier status HUD has %d authored slots for %d active sources"):format(#slots, #sources))
		end
		for index, slot in ipairs(slots) do
			local registration = registrations[slot]
			if registration then
				registration:clear()
			end
			local source = sources[index]
			assigned[slot] = source
			slot:SetAttribute("SourceId", source and source.Id or "")
			slot.Visible = source ~= nil
		end
		root.Visible = not suppressed and #sources > 0
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
			local timer = slot:FindFirstChild("Timer")
			if timer and timer:IsA("TextLabel") then
				if type(source.ExpiresAt) == "number" then
					local remaining = math.max(0, source.ExpiresAt - now)
					timer.Text = formatCountdown(remaining)
					timer.TextSize = DevTuning.get("MultiplierHud.CountdownTextSize")
					timer.TextColor3 = remaining <= warningThreshold and warningColor or normalColor
				else
					timer.Text = MultiplierHudConfig.InfinityText
					timer.TextSize = DevTuning.get("MultiplierHud.InfinityTextSize")
					timer.TextColor3 = normalColor
				end
			end
			local registration = registrations[slot]
			if registration and type(source.ExpiresAt) == "number" then
				registration:refresh()
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
		for _, handle in ipairs(tuningHandles) do
			handle:Disconnect()
		end
		if viewportHandle then
			viewportHandle:destroy()
		end
		table.clear(assigned)
		root.Visible = false
	end

	applyLayout()
	return presenter
end

return MultiplierStatusPresenter
