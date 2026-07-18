-- StoreMultiPlaceIconAnim — the Multi-Place row's duplicating-block icon.
-- The row's icon layer slots hold three block images authored as the EXPANDED
-- composition (wired in UpgradeConfig): IconDetail1 is the middle block,
-- IconFill and IconOutline are the top and bottom copies. On: all three sit at
-- their authored (0,0) spots, reading as a duplicated stack. Off: the copies
-- slide inward (top down, bottom up) so their drawn blocks coincide with and
-- hide behind the middle block, reading as a single block. Offsets were
-- live-tuned against the authored art and baked in 2026-07-16.
-- StoreUpgradeIconProgression repaints images but never touches layer
-- Position, so the poses survive row refreshes.
--
-- Extracted per the Store convention: the orchestrator calls this through
-- ctx.multiPlaceIconAnim.* — it does NOT re-alias as top-level locals.
--
-- ctx deps: none (the row is passed per call).

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local UiMotion = require(Shared:WaitForChild("UiMotion"))

local StoreMultiPlaceIconAnim = {}

local LAYER_TOP = "IconFill"
local LAYER_BOTTOM = "IconOutline"
local LAYER_MIDDLE = "IconDetail1"

-- Baked Off-pose offsets, normalized from the 80px Upgrades-row icon so the
-- smaller toolbar copy performs the same proportional movement.
local AUTHORED_ICON_SIZE = 80
local TOP_OFFSET_SCALE = 17 / AUTHORED_ICON_SIZE
local BOTTOM_OFFSET_SCALE = 16 / AUTHORED_ICON_SIZE
local TWEEN_SECONDS = 0.25

local function findLayers(row)
	local icon = row and row:FindFirstChild("Icon", true)
	if not (icon and icon:IsA("ImageLabel")) then
		return nil
	end

	local top = icon:FindFirstChild(LAYER_TOP)
	local bottom = icon:FindFirstChild(LAYER_BOTTOM)
	local middle = icon:FindFirstChild(LAYER_MIDDLE)
	if not (top and bottom and middle) then
		return nil
	end

	return { top = top, bottom = bottom, middle = middle }
end

function StoreMultiPlaceIconAnim.new(_ctx)
	local lastRow = nil
	local currentActive = nil
	local activeTweens = {}

	local function cancelTweens()
		for _, tween in ipairs(activeTweens) do
			tween:Cancel()
		end
		table.clear(activeTweens)
	end

	-- The top copy renders below the middle block while stacked, but lies on top of
	-- it in the expanded pose. Both flips happen as their tween starts: the images
	-- aren't exact replicas, so a swap at rest (e.g. at the collapse end) reads as
	-- a visible art flash, while motion masks it.
	local function setTopAboveMiddle(layers, above)
		local base = layers.top:GetAttribute("BaseZIndex")
		if base == nil then
			base = layers.top.ZIndex
			layers.top:SetAttribute("BaseZIndex", base)
		end
		layers.top.ZIndex = above and (layers.middle.ZIndex + 1) or base
	end

	local function applyPose(row, active, animate)
		local layers = findLayers(row)
		if not layers then
			return
		end

		cancelTweens()
		-- The images are authored as the expanded composition: On is all three at
		-- their authored (0,0) spots. Off slides the top copy down and the bottom
		-- copy up so their drawn blocks coincide with (and hide behind) the middle.
		local goals = {
			[layers.top] = UDim2.new(0, 0, active and 0 or TOP_OFFSET_SCALE, 0),
			[layers.bottom] = UDim2.new(0, 0, active and 0 or -BOTTOM_OFFSET_SCALE, 0),
			[layers.middle] = UDim2.fromOffset(0, 0),
		}

		setTopAboveMiddle(layers, active)
		if not animate or TWEEN_SECONDS <= 0 then
			for layer, position in pairs(goals) do
				layer.Position = position
			end
			return
		end

		local info = TweenInfo.new(TWEEN_SECONDS, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
		for layer, position in pairs(goals) do
			local tween = UiMotion.create(layer, info, { Position = position })
			table.insert(activeTweens, tween)
			tween:Play()
		end
	end

	-- Called from the orchestrator's updateRow for the Multi-Place row. updateRow
	-- reruns for unrelated reasons (affordability, formula sources), so only a real
	-- state change animates; a rebuilt row instance snaps to the current pose.
	local function updateRow(row, active)
		if not row then
			return
		end

		active = active == true
		local firstAttach = lastRow ~= row
		if not firstAttach and currentActive == active then
			return
		end

		local animate = not firstAttach and currentActive ~= active
		lastRow = row
		currentActive = active
		applyPose(row, active, animate)
	end

	return {
		updateRow = updateRow,
	}
end

return StoreMultiPlaceIconAnim
