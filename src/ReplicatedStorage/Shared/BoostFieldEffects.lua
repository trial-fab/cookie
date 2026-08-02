-- BoostFieldEffects: the single rule for which boost fields affect which building.
--
-- Shared because three callers need the same answer and must never disagree about it: the server's
-- production tick (which pays the cookies), the building-stats tooltip (which tells the player what
-- their multiplier is), and the multiplier HUD (which explains where it came from). A second copy
-- of this arithmetic anywhere is a bug waiting to happen — the player would be shown one number and
-- paid another.
--
-- Fields are ordinary replicated instances carrying their own shape, so the client can answer this
-- as authoritatively as the server: radius and strength are read from the FIELD, not from config,
-- because a field keeps the shape it was dropped with even if the config is retuned mid-session.

local BoostShopConfig = require(script.Parent:WaitForChild("BoostShopConfig"))
local FloorConfig = require(script.Parent:WaitForChild("FloorConfig"))
local UpgradeConfig = require(script.Parent:WaitForChild("UpgradeConfig"))
local Attrs = require(script.Parent:WaitForChild("Attrs"))

local BoostFieldEffects = {}

-- Flattens a plot's fields into what a coverage test needs. Returns nil (not an empty table) when
-- the plot has no fields, so the overwhelmingly common case costs one comparison in the caller's
-- hot loop.
function BoostFieldEffects.GetCoverage(sheet)
	if not sheet then
		return nil
	end

	local coverage = nil
	local prefix = BoostShopConfig.FieldNamePrefix
	for _, field in ipairs(sheet:GetChildren()) do
		if
			field:IsA("Model")
			and field.Name:sub(1, #prefix) == prefix
			and field:GetAttribute(BoostShopConfig.Expiry.StartedAtAttribute) == nil
		then
			local id = field:GetAttribute("ItemId") or field.Name:sub(#prefix + 1)
			local item = BoostShopConfig.Items[id]
			if item then
				local radius = tonumber(field:GetAttribute("Radius")) or item.Radius
				local strengthPercent = tonumber(field:GetAttribute("StrengthPercent")) or item.StrengthPercent
				coverage = coverage or {}
				table.insert(coverage, {
					floorId = FloorConfig.NormalizeId(field:GetAttribute(Attrs.FloorId)),
					center = field:GetPivot().Position,
					radiusSquared = radius * radius,
					strength = 1 + strengthPercent / 100,
					effect = item.Effect,
				})
			end
		end
	end
	return coverage
end

-- The multipliers a building standing at `position` on `floorId` receives: one for output (Power),
-- one for payout frequency (Speed). A field is a flat disc bound to its floor, so the test is
-- horizontal — a building's own height never lifts it out of the field it is standing in.
--
-- Config decides which field feeds which factor, so a third field type later needs no change here.
function BoostFieldEffects.Apply(coverage, floorId, position)
	local outputMultiplier, frequencyMultiplier = 1, 1
	if not coverage then
		return outputMultiplier, frequencyMultiplier
	end

	for _, entry in pairs(coverage) do
		if entry.floorId == floorId then
			local dx = position.X - entry.center.X
			local dz = position.Z - entry.center.Z
			if dx * dx + dz * dz <= entry.radiusSquared then
				if entry.effect == BoostShopConfig.Effect.Frequency then
					frequencyMultiplier *= entry.strength
				else
					outputMultiplier *= entry.strength
				end
			end
		end
	end
	return outputMultiplier, frequencyMultiplier
end

-- How many of the plot's buildings a disc at `position` on `floorId` covers. Same membership rule
-- as `Apply`, asked the other way round: about one field rather than one building. Analytics uses
-- it to record the quality of a drop, since a field covering nothing is 40 gems wasted.
function BoostFieldEffects.CountCovered(sheet, floorId, position, radius)
	if not sheet then
		return 0
	end

	local radiusSquared = radius * radius
	local count = 0
	for _, child in ipairs(sheet:GetChildren()) do
		if child:IsA("Model") then
			local upgradeId = child:GetAttribute(Attrs.UpgradeId)
			local config = type(upgradeId) == "string" and UpgradeConfig[upgradeId]
			if config and config.TemplateKind == "Building" then
				if FloorConfig.NormalizeId(child:GetAttribute(Attrs.FloorId)) == floorId then
					local origin = child:GetPivot().Position
					local dx, dz = origin.X - position.X, origin.Z - position.Z
					if dx * dx + dz * dz <= radiusSquared then
						count += 1
					end
				end
			end
		end
	end
	return count
end

-- One building, resolved from the instance itself. For a caller looking at a single building rather
-- than sweeping a whole plot; placed buildings are direct children of their sheet.
function BoostFieldEffects.ForBuilding(building)
	if not (building and building.Parent) then
		return 1, 1
	end
	local coverage = BoostFieldEffects.GetCoverage(building.Parent)
	if not coverage then
		return 1, 1
	end
	return BoostFieldEffects.Apply(
		coverage,
		FloorConfig.NormalizeId(building:GetAttribute(Attrs.FloorId)),
		building:GetPivot().Position
	)
end

return BoostFieldEffects
