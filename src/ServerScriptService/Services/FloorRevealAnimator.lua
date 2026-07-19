-- FloorRevealAnimator: server-authoritative visual state for authored upper floors and
-- their matching crater gates. Saved ownership remains in FloorService; this module only
-- snapshots authored poses, snaps join/reset state, and runs reversible world tweens.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Attrs = require(Shared:WaitForChild("Attrs"))
local DevTuning = require(Shared:WaitForChild("DevTuning"):WaitForChild("DevTuning"))
local FloorConfig = require(Shared:WaitForChild("FloorConfig"))
local FloorGeometry = require(Shared:WaitForChild("FloorGeometry"))

local FloorRevealAnimator = {}

local CRATER_MODEL_NAME = "CraterTerraces"
local SLOT_NAME_FORMAT = "Slot%02d"
local TUNING_PREFIX = "VerticalFloors."

local sheetRecords = setmetatable({}, { __mode = "k" })
-- Crater gates are static for the server lifetime, so retain strong authored-geometry
-- snapshots. Weak Instance keys can be collected even while the engine still owns the
-- instance; a later stat reset would then recapture the 0.05-stud revealed size as locked.
local lockedGateCFrames = {}
local lockedGateSizes = {}
local initialized = false

local function tuning(key)
	return DevTuning.get(TUNING_PREFIX .. key)
end

local function getCrater()
	local crater = Workspace:FindFirstChild(CRATER_MODEL_NAME)
	return crater and crater:IsA("Model") and crater or nil
end

local function getSlot(sheet)
	local crater = getCrater()
	local slotIndex = sheet and sheet:GetAttribute(Attrs.PlotSlotIndex)
	if not crater or type(slotIndex) ~= "number" then
		return nil
	end
	local slot = crater:FindFirstChild(SLOT_NAME_FORMAT:format(slotIndex))
	return slot and slot:IsA("Model") and slot or nil
end

local function getGates(sheet, floorId)
	local slot = getSlot(sheet)
	local gateModel = slot and slot:FindFirstChild("LockedGates")
	if not gateModel then
		return {}
	end
	local gates = {}
	for _, sideName in ipairs({ "Left", "Right" }) do
		local gate = gateModel:FindFirstChild(floorId .. "Gate" .. sideName)
		if gate and gate:IsA("BasePart") then
			table.insert(gates, gate)
		end
	end
	return gates
end

local function getLockedGateCFrame(gate)
	local cached = lockedGateCFrames[gate]
	if cached then
		return cached
	end
	local locked = gate:GetAttribute("LockedCFrame")
	local cframe = typeof(locked) == "CFrame" and locked or gate.CFrame
	lockedGateCFrames[gate] = cframe
	return cframe
end

local function getLockedGateSize(gate)
	local cached = lockedGateSizes[gate]
	if cached then
		return cached
	end
	local authored = gate:GetAttribute("LockedSize")
	local size = typeof(authored) == "Vector3" and authored or gate.Size
	if typeof(authored) ~= "Vector3" then
		-- Recovery for a hot-reloaded or legacy session already left retracted. The Studio-
		-- authored RevealWorldOffset is one full gate-width along the opening axis (67 studs
		-- for the current crater), so it reconstructs the missing locked dimension without
		-- guessing from the 0.05-stud sliver.
		local offset = gate:GetAttribute("RevealWorldOffset")
		if typeof(offset) == "Vector3" and offset.Magnitude > 1e-6 then
			local lockedCFrame = getLockedGateCFrame(gate)
			local direction = offset.Unit
			local xScore = math.abs(lockedCFrame.RightVector:Dot(direction))
			local yScore = math.abs(lockedCFrame.UpVector:Dot(direction))
			local zScore = math.abs(lockedCFrame.LookVector:Dot(direction))
			if xScore >= yScore and xScore >= zScore then
				size = Vector3.new(math.max(size.X, offset.Magnitude), size.Y, size.Z)
			elseif yScore >= zScore then
				size = Vector3.new(size.X, math.max(size.Y, offset.Magnitude), size.Z)
			else
				size = Vector3.new(size.X, size.Y, math.max(size.Z, offset.Magnitude))
			end
		end
	end
	lockedGateSizes[gate] = size
	return size
end

local function getGateRevealPose(gate)
	local lockedCFrame = getLockedGateCFrame(gate)
	local lockedSize = getLockedGateSize(gate)
	local authoredOffset = gate:GetAttribute("RevealWorldOffset")
	local requestedDirection = typeof(authoredOffset) == "Vector3"
			and authoredOffset.Magnitude > 1e-6
			and authoredOffset.Unit
		or nil
	local axes = {
		{ key = "X", vector = lockedCFrame.RightVector, length = lockedSize.X },
		{ key = "Y", vector = lockedCFrame.UpVector, length = lockedSize.Y },
		{ key = "Z", vector = lockedCFrame.LookVector, length = lockedSize.Z },
	}
	local selected = axes[1]
	if requestedDirection then
		for _, candidate in ipairs(axes) do
			if
				math.abs(candidate.vector:Dot(requestedDirection)) > math.abs(selected.vector:Dot(requestedDirection))
			then
				selected = candidate
			end
		end
	end
	local direction = selected.vector
	if requestedDirection then
		direction *= direction:Dot(requestedDirection) >= 0 and 1 or -1
	elseif string.find(gate.Name, "Left", 1, true) then
		direction *= -1
	end
	local thickness = math.min(selected.length, math.max(0.05, tuning("GateOpenThickness")))
	local revealedSize = lockedSize
	if selected.key == "X" then
		revealedSize = Vector3.new(thickness, lockedSize.Y, lockedSize.Z)
	elseif selected.key == "Y" then
		revealedSize = Vector3.new(lockedSize.X, thickness, lockedSize.Z)
	else
		revealedSize = Vector3.new(lockedSize.X, lockedSize.Y, thickness)
	end
	-- Shift by half the removed length so the outer edge stays fixed and the inner edge
	-- retracts outward. Every intermediate tween shape remains inside the locked footprint.
	local revealedCFrame = lockedCFrame + direction * ((selected.length - thickness) / 2)
	return revealedCFrame, revealedSize
end

local function snapGate(gate, revealed)
	local targetCFrame, targetSize
	if revealed then
		targetCFrame, targetSize = getGateRevealPose(gate)
	else
		targetCFrame, targetSize = getLockedGateCFrame(gate), getLockedGateSize(gate)
	end
	gate.CFrame = targetCFrame
	gate.Size = targetSize
	gate.Transparency = revealed and 1 or 0
	gate.CanCollide = not revealed
	gate.CanQuery = not revealed
	gate.CanTouch = false
	gate.CastShadow = not revealed
end

local function normalizeCraterGates()
	local crater = getCrater()
	if not crater then
		warn("FloorRevealAnimator: Workspace.CraterTerraces is missing; floor animation will run without gates.")
		return
	end
	for _, descendant in ipairs(crater:GetDescendants()) do
		if descendant:IsA("BasePart") and descendant:GetAttribute("CraterRole") == "RevealGate" then
			snapGate(descendant, false)
		end
	end
end

local function partSortKey(state)
	local position = state.finalCFrame.Position
	return string.format("%012.4f/%012.4f/%012.4f/%s", position.Y, position.X, position.Z, state.part.Name)
end

local function captureFloor(sheet, definition)
	local model = FloorGeometry.GetFloorModel(sheet, definition.Id)
	if not model then
		return nil
	end

	local parts = {}
	for _, descendant in ipairs(model:GetDescendants()) do
		if descendant:IsA("BasePart") then
			table.insert(parts, {
				part = descendant,
				finalCFrame = descendant.CFrame,
				transparency = descendant.Transparency,
				canCollide = descendant.CanCollide,
				canQuery = descendant.CanQuery,
				canTouch = descendant.CanTouch,
				castShadow = descendant.CastShadow,
			})
		end
	end
	table.sort(parts, function(left, right)
		return partSortKey(left) < partSortKey(right)
	end)

	return {
		model = model,
		floorId = definition.Id,
		parts = parts,
		token = 0,
		tweens = {},
		visualState = "authored",
	}
end

local function registerSheet(sheet)
	if not sheet or not sheet:IsA("Model") then
		return nil, false
	end
	local existing = sheetRecords[sheet]
	if existing then
		return existing, false
	end

	local record = {
		floors = {},
		connections = {},
	}
	sheetRecords[sheet] = record
	for _, definition in ipairs(FloorConfig.GetDefinitions()) do
		if definition.Order > 0 then
			record.floors[definition.Id] = captureFloor(sheet, definition)
		end
	end

	table.insert(
		record.connections,
		sheet:GetAttributeChangedSignal("Available"):Connect(function()
			if sheet:GetAttribute("Available") == true then
				FloorRevealAnimator.SnapSheet(sheet, 0)
			end
		end)
	)
	table.insert(
		record.connections,
		sheet.Destroying:Connect(function()
			for _, floorRecord in pairs(record.floors) do
				if floorRecord then
					floorRecord.token += 1
					for _, tween in ipairs(floorRecord.tweens) do
						tween:Cancel()
					end
				end
			end
			for _, connection in ipairs(record.connections) do
				connection:Disconnect()
			end
			sheetRecords[sheet] = nil
		end)
	)
	return record, true
end

local function cancelFloorAnimation(record)
	record.token += 1
	for _, tween in ipairs(record.tweens) do
		tween:Cancel()
	end
	table.clear(record.tweens)
	return record.token
end

local function outwardDirection(sheet)
	local base = sheet:FindFirstChild("Base")
	if not (base and base:IsA("BasePart")) then
		return Vector3.xAxis
	end
	local direction = base.CFrame:VectorToWorldSpace(Vector3.zAxis)
	direction = Vector3.new(direction.X, 0, direction.Z)
	return direction.Magnitude > 1e-6 and direction.Unit or Vector3.xAxis
end

local function startOffset(sheet)
	return Vector3.yAxis * tuning("FloorStartHeight") - outwardDirection(sheet) * tuning("FloorStartRadialOffset")
end

local function hideFloorAtStart(sheet, record)
	local offset = startOffset(sheet)
	for _, state in ipairs(record.parts) do
		local part = state.part
		if part.Parent then
			part.CFrame = state.finalCFrame + offset
			part.Transparency = 1
			part.CanCollide = false
			part.CanQuery = false
			part.CanTouch = false
			part.CastShadow = false
		end
	end
end

local function restorePart(state)
	local part = state.part
	if part.Parent then
		part.CFrame = state.finalCFrame
		part.Transparency = state.transparency
		part.CanCollide = state.canCollide
		part.CanQuery = state.canQuery
		part.CanTouch = state.canTouch
		part.CastShadow = state.castShadow
	end
end

local function restoreFloor(record)
	for _, state in ipairs(record.parts) do
		restorePart(state)
	end
end

local function snapFloor(sheet, record, revealed)
	cancelFloorAnimation(record)
	if revealed then
		restoreFloor(record)
	else
		hideFloorAtStart(sheet, record)
	end
	for _, gate in ipairs(getGates(sheet, record.floorId)) do
		snapGate(gate, revealed)
	end
	record.visualState = revealed and "revealed" or "locked"
end

local function playTween(record, token, part, tweenInfo, goals, delaySeconds, beforeTween, afterTween)
	task.delay(delaySeconds, function()
		if record.token ~= token or not part.Parent then
			return
		end
		if beforeTween then
			beforeTween()
		end
		local tween = TweenService:Create(part, tweenInfo, goals)
		table.insert(record.tweens, tween)
		local completedConnection
		completedConnection = tween.Completed:Connect(function(playbackState)
			completedConnection:Disconnect()
			if
				playbackState == Enum.PlaybackState.Completed
				and record.token == token
				and part.Parent
				and afterTween
			then
				afterTween()
			end
		end)
		tween:Play()
	end)
end

local function animateFloor(sheet, record, revealed)
	local token = cancelFloorAnimation(record)
	local floorDuration = revealed and tuning("FloorRevealDuration") or tuning("FloorRelockDuration")
	local gateDuration = revealed and tuning("GateRevealDuration") or tuning("GateRelockDuration")
	local stagger = tuning("PartStagger")
	local easingDirection = revealed and Enum.EasingDirection.Out or Enum.EasingDirection.In
	local floorTweenInfo = TweenInfo.new(floorDuration, tuning("FloorEasingStyle"), easingDirection)
	local gateTweenInfo = TweenInfo.new(gateDuration, tuning("GateEasingStyle"), easingDirection)
	local sequenceGap = tuning("SequenceGap")
	local floorTrackDelay = 0
	local gateTrackDelay = 0
	if sequenceGap > 0 then
		if revealed then
			floorTrackDelay = sequenceGap
		else
			gateTrackDelay = sequenceGap
		end
	elseif sequenceGap < 0 then
		if revealed then
			gateTrackDelay = -sequenceGap
		else
			floorTrackDelay = -sequenceGap
		end
	end
	local offset = startOffset(sheet)

	if revealed and record.visualState == "locked" then
		hideFloorAtStart(sheet, record)
	end

	for index, state in ipairs(record.parts) do
		local part = state.part
		if part.Parent then
			local goals
			if revealed then
				goals = {
					CFrame = state.finalCFrame,
					Transparency = state.transparency,
				}
			else
				goals = {
					CFrame = state.finalCFrame + offset,
					Transparency = 1,
				}
			end
			playTween(record, token, part, floorTweenInfo, goals, floorTrackDelay + (index - 1) * stagger, function()
				part.CanCollide = false
				part.CanQuery = false
				part.CanTouch = false
				part.CastShadow = false
			end, revealed and function()
				restorePart(state)
			end or nil)
		end
	end

	for _, gate in ipairs(getGates(sheet, record.floorId)) do
		local gateCFrame, gateSize
		if revealed then
			gateCFrame, gateSize = getGateRevealPose(gate)
		else
			gateCFrame, gateSize = getLockedGateCFrame(gate), getLockedGateSize(gate)
		end
		playTween(
			record,
			token,
			gate,
			gateTweenInfo,
			{
				CFrame = gateCFrame,
				Size = gateSize,
			},
			gateTrackDelay,
			function()
				-- Make the retracting half visible for both opening and closing. The
				-- completion callback hides only the fully opened sliver.
				gate.Transparency = 0
				gate.CanCollide = false
				gate.CanQuery = false
				gate.CanTouch = false
				gate.CastShadow = true
			end,
			revealed
					and function()
						-- Hide at this gate's own completion, independent of the longer staggered
						-- floor track, so no residual sliver lingers after it is fully open.
						gate.Transparency = 1
						gate.CastShadow = false
					end
				or nil
		)
	end

	record.visualState = revealed and "revealing" or "relocking"
	local floorCompletion = floorTrackDelay + floorDuration + math.max(#record.parts - 1, 0) * stagger
	local gateCompletion = gateTrackDelay + gateDuration
	local completionDelay = math.max(floorCompletion, gateCompletion) + 0.05
	task.delay(completionDelay, function()
		if record.token ~= token then
			return
		end
		if revealed then
			restoreFloor(record)
		else
			hideFloorAtStart(sheet, record)
		end
		for _, gate in ipairs(getGates(sheet, record.floorId)) do
			snapGate(gate, revealed)
		end
		table.clear(record.tweens)
		record.visualState = revealed and "revealed" or "locked"
	end)
end

function FloorRevealAnimator.SetFloorState(sheet, floorId, revealed, animate)
	local sheetRecord = registerSheet(sheet)
	local floorRecord = sheetRecord and sheetRecord.floors[floorId]
	if not floorRecord then
		return false
	end
	if animate then
		animateFloor(sheet, floorRecord, revealed)
	else
		snapFloor(sheet, floorRecord, revealed)
	end
	return true
end

function FloorRevealAnimator.SnapSheet(sheet, unlockedCount)
	local sheetRecord = registerSheet(sheet)
	if not sheetRecord then
		return false
	end
	for _, definition in ipairs(FloorConfig.GetDefinitions()) do
		if definition.Order > 0 then
			local floorRecord = sheetRecord.floors[definition.Id]
			if floorRecord then
				snapFloor(sheet, floorRecord, definition.Order <= unlockedCount)
			end
		end
	end
	return true
end

function FloorRevealAnimator.GetVisualState(sheet, floorId)
	local sheetRecord = sheetRecords[sheet]
	local floorRecord = sheetRecord and sheetRecord.floors[floorId]
	return floorRecord and floorRecord.visualState or nil
end

function FloorRevealAnimator.Init()
	if initialized then
		return
	end
	initialized = true
	normalizeCraterGates()

	local cookieSheets = Workspace:WaitForChild("CookieSheets")
	for _, child in ipairs(cookieSheets:GetChildren()) do
		task.defer(function()
			local _, created = registerSheet(child)
			if created then
				FloorRevealAnimator.SnapSheet(child, 0)
			end
		end)
	end
	cookieSheets.ChildAdded:Connect(function(child)
		task.defer(function()
			local _, created = registerSheet(child)
			if created then
				FloorRevealAnimator.SnapSheet(child, 0)
			end
		end)
	end)
end

return FloorRevealAnimator
