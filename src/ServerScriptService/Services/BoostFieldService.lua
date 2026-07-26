-- BoostFieldService: authoritative drop of a purchased charge as a timed field on a plot.
--
-- A field boosts the buildings of the plot it lands on, whoever dropped it — dropping on someone
-- else's plot is the intended social gift (docs/boost-shop-design.md §12.3). The client sends only
-- an item id and a world position; the server resolves which plot and floor that point belongs to
-- from live geometry, so a forged position can only ever miss.
--
-- Time is measured in **remaining seconds that tick down while the plot owner is present**, not a
-- wall clock (§12.6). A field is therefore "5 minutes of play time": production only runs while
-- the owner is in the server, so a wall-clock timer burning during their absence would pay them
-- nothing and just feel like theft.
--
-- Persisting a field across a rejoin, and the production grouping that actually applies the
-- boost, are the next build. Today the field exists, is owned, is validated, expires correctly,
-- and consumes exactly one charge.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Attrs = require(ReplicatedStorage.Shared.Attrs)
local BoostShopConfig = require(ReplicatedStorage.Shared.BoostShopConfig)
local FloorConfig = require(ReplicatedStorage.Shared.FloorConfig)
local FloorGeometry = require(ReplicatedStorage.Shared.FloorGeometry)
local Net = require(ReplicatedStorage.Shared.Net)
local BoostAnalyticsService = require(script.Parent.BoostAnalyticsService)
local BoostFieldEffects = require(ReplicatedStorage.Shared.BoostFieldEffects)
local BoostShopService = require(script.Parent.BoostShopService)
local PlayerDataService = require(script.Parent.PlayerDataService)
local SheetService = require(script.Parent.SheetService)

local BoostFieldService = {}

local TICK_SECONDS = 1
-- A field parked for longer than this is dropped rather than resurrected: coming back after a
-- month to a boost you no longer remember buying is confusing, not generous.
local FREEZE_CAP_SECONDS = 7 * 24 * 60 * 60

-- field model -> { itemId, ownerUserId, remaining }
local activeFields = {}
local timerRunning = false

-- Anything that changes a plot's fields notifies here, so a listener can react at the moment of the
-- change instead of at the next production tick. ProductionService registers its CpS refresh.
local fieldsChangedListeners = {}

function BoostFieldService.OnFieldsChanged(callback)
	table.insert(fieldsChangedListeners, callback)
end

local function notifyFieldsChanged(owner)
	for _, callback in ipairs(fieldsChangedListeners) do
		-- Spawned so a listener that errors or yields cannot break the drop it is reacting to.
		task.spawn(callback, owner)
	end
end

local function getTemplate()
	local template = ReplicatedStorage:FindFirstChild(BoostShopConfig.GhostTemplateName)
	if not template then
		warn(
			("BoostFieldService: no `%s` template in ReplicatedStorage — fields cannot be dropped."):format(
				BoostShopConfig.GhostTemplateName
			)
		)
	end
	return template
end

-- Which plot/floor a world point sits on, or nil when it is not over any player's buildable
-- surface. Authoritative: derived from live sheet geometry, never from client input.
--
-- FloorGeometry.FindSurfaceAtPoint picks the CLOSEST surface rather than the first that matches,
-- so a terraced stack binds the field to the floor it was actually dropped on instead of whichever
-- floor the definition list happened to name first.
local function resolveTarget(position)
	for _, owner in ipairs(Players:GetPlayers()) do
		local sheet = SheetService.GetPlayerSheet(owner)
		if sheet then
			local surfaces = FloorGeometry.GetUnlockedSurfaces(sheet, owner:GetAttribute(Attrs.UnlockedFloorCount))
			local surface = FloorGeometry.FindSurfaceAtPoint(surfaces, position, BoostShopConfig.SurfaceToleranceY)
			if surface then
				return owner, sheet, surface
			end
		end
	end
	return nil
end

local function fieldName(itemId)
	return BoostShopConfig.FieldNamePrefix .. itemId
end

-- ── Freeze / resume (§12.6) ─────────────────────────────────────────────────────
--
-- A field is stored in the PLOT OWNER's profile, never the dropper's: it is the owner's buildings
-- it boosts, and writing it anywhere else would mean touching another player's save. Position is
-- kept relative to the floor's placement origin exactly as a building placement is, because a
-- world position is meaningless next session -- plots are reassigned and re-placed around the ring.
--
-- The remaining time is mirrored on every timer tick rather than captured on leave. That makes the
-- freeze free (the profile is saved on its own schedule and on leave), and it means a server crash
-- loses at most a second instead of the whole field -- the exact "dropped a 40-gem charge and
-- immediately crashed" complaint this design set out to kill.

local function getStoredFields(player)
	local data = PlayerDataService.Get(player)
	local persistent = type(data) == "table" and data.Persistent
	if type(persistent) ~= "table" then
		return nil
	end
	if type(persistent.BoostFields) ~= "table" then
		persistent.BoostFields = {}
	end
	return persistent.BoostFields
end

local function storedFieldKey(itemId, floorId)
	return ("%s::%s"):format(itemId, FloorConfig.NormalizeId(floorId))
end

-- Canonicalize the save map on read. Older saves keyed a field by item id alone because the
-- original rule allowed only one per plot; their entry already carries FloorId, so migration is
-- lossless. Keeping the map flat also makes each field independently replaceable on timer ticks.
local function normalizeStoredFields(stored)
	local normalized = {}
	for key, entry in pairs(stored) do
		if type(entry) == "table" then
			local itemId = entry.ItemId
			if not BoostShopConfig.Items[itemId] and BoostShopConfig.Items[key] then
				itemId = key
			end
			if BoostShopConfig.Items[itemId] then
				local floorId = FloorConfig.NormalizeId(entry.FloorId)
				entry.ItemId = itemId
				entry.FloorId = floorId
				normalized[storedFieldKey(itemId, floorId)] = entry
			end
		end
	end
	table.clear(stored)
	for key, entry in pairs(normalized) do
		stored[key] = entry
	end
	return stored
end

local function writeStoredField(owner, itemId, floorId, entry)
	local stored = getStoredFields(owner)
	if not stored then
		return false
	end
	normalizeStoredFields(stored)[storedFieldKey(itemId, floorId)] = entry
	return true
end

local function clearStoredField(owner, itemId, floorId)
	local stored = getStoredFields(owner)
	if stored then
		normalizeStoredFields(stored)[storedFieldKey(itemId, floorId)] = nil
	end
end

-- One field per type per floor. Identical names can coexist under a sheet, so FloorId is the
-- discriminator instead of FindFirstChild's arbitrary first match.
local function findField(sheet, itemId, floorId)
	local targetName = fieldName(itemId)
	local targetFloorId = FloorConfig.NormalizeId(floorId)
	for _, child in ipairs(sheet:GetChildren()) do
		if child.Name == targetName and FloorConfig.NormalizeId(child:GetAttribute(Attrs.FloorId)) == targetFloorId then
			return child
		end
	end
	return nil
end

-- Expiry. This is the ONLY path that clears the saved copy: a field that merely stops existing
-- because its owner left (SheetService destroys their plot's models on release) must stay frozen
-- in their profile, which is what makes it come back on rejoin.
local function expireField(field, state)
	activeFields[field] = nil
	local owner = Players:GetPlayerByUserId(state.ownerUserId)
	if owner then
		clearStoredField(owner, state.itemId, state.floorId)
	end
	field:Destroy()
	if owner then
		BoostAnalyticsService.RecordExpired(owner, state.itemId, state.duration)
		notifyFieldsChanged(owner)
	end
end

-- Single shared timer for every live field. Remaining time only decrements while the plot owner
-- is in the server, which is what makes a field "play time" rather than wall-clock time.
local function ensureTimer()
	if timerRunning then
		return
	end
	timerRunning = true

	task.spawn(function()
		while true do
			task.wait(TICK_SECONDS)

			local anyLeft = false
			for field, state in pairs(activeFields) do
				if not field.Parent then
					-- Released with the plot on leave: forget the live instance, keep the save.
					activeFields[field] = nil
				else
					anyLeft = true
					local owner = Players:GetPlayerByUserId(state.ownerUserId)
					if owner then
						state.remaining -= TICK_SECONDS
						if state.remaining <= 0 then
							expireField(field, state)
						else
							field:SetAttribute("RemainingSeconds", state.remaining)
							if state.stored then
								-- Same table the profile holds, so the freeze is always current.
								state.stored.Remaining = state.remaining
								state.stored.FrozenAt = os.time()
							end
						end
					end
				end
			end

			if not anyLeft then
				timerRunning = false
				break
			end
		end
	end)
end

-- Leaves the canister's glowing Core standing at the middle of the field. The disc's ping travels
-- outward from that point, and without something sitting there it reads as a ring expanding out of
-- bare ground. Only the Core, not the whole canister: the canister is what the player is HOLDING
-- during placement, and leaving one behind would look like litter rather than a source.
local function attachCore(field, item, restingPosition)
	local previews = ReplicatedStorage:FindFirstChild(BoostShopConfig.PreviewFolderName)
	local canister = previews and previews:FindFirstChild(item.CanisterName)
	local source = canister and canister:FindFirstChild(BoostShopConfig.Pulse.CorePartName)
	if not (source and source:IsA("BasePart")) then
		return
	end

	local core = source:Clone()
	core.Anchored = true
	core.CanCollide = false
	core.CanQuery = false
	core.CanTouch = false
	-- Sat ON the surface rather than sunk into it. Its authored Neon colour is kept: the core IS
	-- the item's identity, which is exactly what makes a dropped field readable at a glance.
	core.CFrame = CFrame.new(restingPosition + Vector3.new(0, core.Size.Y / 2, 0))
	core.Parent = field
end

-- `attribution` is who the field came FROM (equal to the owner for a self-drop), carried separately
-- from `owner` so a restored gift still reads as a gift after the giver has left the server.
local function buildField(template, item, surface, position, owner, attribution, remainingSeconds)
	local field = template:Clone()
	field.Name = fieldName(item.Id)

	-- Scale the authored disc from the radius it was drawn at to this item's radius. The disc is a
	-- Cylinder laid flat (X points up), so Y and Z are the radial axes and X is thickness. The
	-- authored transparency/material are never touched: the user owns the look, code owns
	-- geometry+color.
	local radius = item.Radius
	local referenceRadius = tonumber(template:GetAttribute("ReferenceRadius")) or radius
	local scale = radius / referenceRadius
	for _, part in ipairs(field:GetDescendants()) do
		if part:IsA("BasePart") then
			part.Size = Vector3.new(part.Size.X, part.Size.Y * scale, part.Size.Z * scale)
			part.Color = item.FieldColor
			part.Anchored = true
			part.CanCollide = false
			part.CanQuery = false
			part.CanTouch = false
		elseif part:IsA("Highlight") then
			-- The sonar ring the client animates. Colouring it here keeps the field's identity in
			-- one place: the server owns what the field IS, the client only owns how it moves.
			part.OutlineColor = item.FieldColor
		elseif part:IsA("ParticleEmitter") then
			-- Everything else about the emitter is authored in Studio; only its colour is code's,
			-- because one shared template has to serve an orange field and a cyan one.
			part.Color = ColorSequence.new(item.FieldColor)
		end
	end

	-- Sit the disc on the floor surface, keeping the authored flat orientation. The same
	-- ClampToSurface/lift the placement ghost used, so the field lands exactly under the preview
	-- and a point nudged past the edge by float error resolves inward instead of being refused.
	local pivot = field:GetPivot()
	local restingPosition = FloorGeometry.ClampToSurface(surface, position, BoostShopConfig.FieldSurfaceLift)
	field:PivotTo(CFrame.new(restingPosition) * pivot.Rotation)

	-- After the disc is in place and after the radius scaling above, so the core is positioned in
	-- final world space and never inherits the disc's scale.
	attachCore(field, item, restingPosition)

	-- The sheet's own release path destroys models carrying an `Owner` pointing at the leaving
	-- player, so this is what stops a field from being inherited by the next player assigned to
	-- the plot. It cannot be mistaken for a building: both the production grouping and placement
	-- serialization additionally require an `UpgradeId` attribute, which a field never sets.
	local ownerValue = Instance.new("ObjectValue")
	ownerValue.Name = "Owner"
	ownerValue.Value = owner
	ownerValue.Parent = field

	field:SetAttribute("AgentDraft", nil)
	field:SetAttribute("ItemId", item.Id)
	field:SetAttribute("Radius", radius)
	field:SetAttribute("StrengthPercent", item.StrengthPercent)
	field:SetAttribute(Attrs.FloorId, surface.floorId)
	field:SetAttribute("OwnerUserId", owner.UserId)
	field:SetAttribute("RemainingSeconds", remainingSeconds)
	-- Attribution for the gift label; equal to the owner for a self-drop.
	field:SetAttribute("FromUserId", attribution.userId)
	field:SetAttribute("FromDisplayName", attribution.displayName)

	return field, restingPosition
end

-- Puts a built field under the shared timer and mirrors it into the owner's profile. The stored
-- table is held by reference so each tick's countdown updates the save in place.
local function activateField(field, item, surface, owner, attribution, remainingSeconds, restingPosition)
	local localPosition = surface.originCFrame:PointToObjectSpace(restingPosition)
	local stored = {
		ItemId = item.Id,
		Remaining = remainingSeconds,
		FloorId = surface.floorId,
		X = localPosition.X,
		Y = localPosition.Y,
		Z = localPosition.Z,
		FromUserId = attribution.userId,
		FromDisplayName = attribution.displayName,
		FrozenAt = os.time(),
	}

	activeFields[field] = {
		itemId = item.Id,
		floorId = surface.floorId,
		ownerUserId = owner.UserId,
		remaining = remainingSeconds,
		duration = remainingSeconds,
		stored = writeStoredField(owner, item.Id, surface.floorId, stored) and stored or nil,
	}
	ensureTimer()
end

-- Authoritative drop. Returns success, message.
function BoostFieldService.Drop(player, itemId, position)
	local item = BoostShopConfig.Items[itemId]
	if not item then
		return false, "Unknown boost."
	end
	if typeof(position) ~= "Vector3" then
		return false, "Invalid drop position."
	end

	local template = getTemplate()
	if not template then
		return false, "Boost field asset is missing."
	end

	if BoostShopService.GetCharges(player, itemId) <= 0 then
		return false, ("You don't have a %s to place."):format(item.DisplayName)
	end

	local owner, sheet, surface = resolveTarget(position)
	if not owner then
		return false, "Place the field on an unlocked floor."
	end
	if findField(sheet, itemId, surface.floorId) then
		return false, "This floor already has that field."
	end

	-- Consume last, after every rejection path: a refused drop must never cost a charge. Both the
	-- check above and this consume are yield-free, so two racing drops cannot spend one charge
	-- twice or put two fields of a type on one floor.
	if not BoostShopService.ConsumeCharge(player, itemId) then
		return false, ("You don't have a %s to place."):format(item.DisplayName)
	end

	local attribution = { userId = player.UserId, displayName = player.DisplayName }
	local duration = item.DurationSeconds
	local field, restingPosition = buildField(template, item, surface, position, owner, attribution, duration)
	field.Parent = sheet
	activateField(field, item, surface, owner, attribution, duration, restingPosition)
	-- Coverage is the quality of the drop, and the number the player was actually choosing on. A
	-- drop covering nothing is 40 gems wasted, which is exactly what this should be able to reveal.
	BoostAnalyticsService.RecordDropped(
		player,
		item.Id,
		BoostFieldEffects.CountCovered(sheet, surface.floorId, restingPosition, item.Radius),
		surface.floorId,
		owner ~= player
	)
	-- The owner's production changed the instant this landed; do not make their CpS readout wait
	-- for the next tick to admit it.
	notifyFieldsChanged(owner)

	if owner == player then
		return true, ("%s placed."):format(item.DisplayName)
	end
	return true, ("%s placed on %s's floor."):format(item.DisplayName, owner.DisplayName)
end

-- Live fields on a plot.
function BoostFieldService.GetFields(sheet)
	local fields = {}
	if not sheet then
		return fields
	end
	local prefix = BoostShopConfig.FieldNamePrefix
	for _, child in ipairs(sheet:GetChildren()) do
		if
			child:IsA("Model")
			and child.Name:sub(1, #prefix) == prefix
			and BoostShopConfig.Items[child:GetAttribute("ItemId") or child.Name:sub(#prefix + 1)]
		then
			table.insert(fields, child)
		end
	end
	return fields
end

-- Coverage arithmetic lives in Shared/BoostFieldEffects so the production tick, the building-stats
-- tooltip, and the multiplier HUD cannot disagree about which buildings a field affects.

-- Destroys this player's live fields and forgets the frozen copies. Yield-free so the dev
-- onboarding reset can group it with its other canonical persistent mutations, next to the
-- ClearCharges that returns the same player to a clean pre-purchase state.
function BoostFieldService.ClearFields(player)
	local stored = getStoredFields(player)
	if not stored then
		return false
	end
	table.clear(stored)

	local sheet = SheetService.GetPlayerSheet(player)
	for _, field in ipairs(BoostFieldService.GetFields(sheet)) do
		activeFields[field] = nil
		field:Destroy()
	end
	notifyFieldsChanged(player)
	return true
end

-- Re-places this player's frozen fields and resumes their countdowns.
--
-- MUST run after OfflineEarningsService.OnPlayerSetup. That service pays away-time against a live
-- ProductionService.GetCps snapshot, and a field restored first would be inside that snapshot --
-- paying offline earnings for a boost that was frozen the entire time the player was away.
function BoostFieldService.RestoreFields(player)
	local stored = getStoredFields(player)
	if not stored or next(stored) == nil then
		return 0
	end
	normalizeStoredFields(stored)

	local sheet = SheetService.GetPlayerSheet(player)
	local template = getTemplate()
	if not (sheet and template) then
		return 0
	end

	-- Resolve against UNLOCKED surfaces only: a floor that was locked again by a run reset, or one
	-- whose authored geometry is missing, must not resurrect a field onto a surface the player
	-- cannot see or build on.
	local surfacesByFloorId = {}
	for _, surface in ipairs(FloorGeometry.GetUnlockedSurfaces(sheet, player:GetAttribute(Attrs.UnlockedFloorCount))) do
		surfacesByFloorId[surface.floorId] = surface
	end

	local now = os.time()
	local restored = 0
	for _, floor in ipairs(FloorConfig.GetDefinitions()) do
		for _, itemId in ipairs(BoostShopConfig.Order) do
			local key = storedFieldKey(itemId, floor.Id)
			local entry = stored[key]
			if type(entry) == "table" then
				local item = BoostShopConfig.Items[itemId]
				-- Clamped against the item's own duration so a stale or tampered save can never hand
				-- back more field than the charge was ever worth.
				local remaining = math.min(math.floor(tonumber(entry.Remaining) or 0), item.DurationSeconds)
				local frozenAt = tonumber(entry.FrozenAt) or 0
				local surface = surfacesByFloorId[floor.Id]
				local x, y, z = tonumber(entry.X), tonumber(entry.Y), tonumber(entry.Z)
				local stale = frozenAt > 0 and now - frozenAt > FREEZE_CAP_SECONDS

				if remaining <= 0 or stale or not surface or not (x and y and z) then
					stored[key] = nil
				elseif not findField(sheet, itemId, floor.Id) then
					local attribution = {
						userId = tonumber(entry.FromUserId) or player.UserId,
						displayName = tostring(entry.FromDisplayName or player.DisplayName),
					}
					local position = surface.originCFrame:PointToWorldSpace(Vector3.new(x, y, z))
					local field, restingPosition =
						buildField(template, item, surface, position, player, attribution, remaining)
					field.Parent = sheet
					activateField(field, item, surface, player, attribution, remaining, restingPosition)
					restored += 1
					notifyFieldsChanged(player)
				end
			end
		end
	end

	return restored
end

function BoostFieldService.Init()
	Net.onInvoke(Net.Names.DropBoostField, function(player, itemId, position)
		if type(itemId) ~= "string" then
			return { success = false, message = "Unknown boost." }
		end

		local success, message = BoostFieldService.Drop(player, itemId, position)
		return { success = success, message = message, itemId = itemId }
	end)

	print("BoostFieldService initialized")
end

return BoostFieldService
