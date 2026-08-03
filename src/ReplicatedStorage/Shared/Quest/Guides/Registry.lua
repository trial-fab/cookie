-- Declarative guide-kind validation. Runtime target lookup remains client-owned.

local Registry = {}

local KINDS = {
	Cookie = true,
	Dialogue = true,
	StoreOpenPath = true,
	StoreRow = true,
	UiControl = true,
	PlacedBuilding = true,
	WorldPosition = true,
	WorldObject = true,
	OffscreenWorldTarget = true,
}

local FRAMES = {
	Pointer = true,
	CookieHighlight = true,
	CatchPulse = true,
	WorldPointer = true,
	-- Ground-following arrow trail from the player to a world target. Only meaningful on the
	-- world guide kinds; other kinds fall back to the flat pointer.
	WorldTrail = true,
}

local STYLES = {
	Pointer = true,
	HighlightPointer = true,
	CatchPulse = true,
	StaticHighlight = true,
}

local function short(value)
	return type(value) == "string" and #value > 0 and #value <= 96
end

function Registry.Validate(value)
	if type(value) ~= "table" then
		return false, "guide must be a table"
	end
	local allowed = {
		Kind = true,
		TargetId = true,
		Style = true,
		Frame = true,
		Surface = true,
		Category = true,
		PlacementControlId = true,
		SavingTargetId = true,
		ModeControlId = true,
		UpgradeId = true,
	}
	for key in pairs(value) do
		if type(key) ~= "string" or not allowed[key] then
			return false, "guide has unknown field " .. tostring(key)
		end
	end
	if not KINDS[value.Kind] then
		return false, "unknown guide kind"
	end
	if not FRAMES[value.Frame] then
		return false, "unknown GuideFrame"
	end
	if not STYLES[value.Style] then
		return false, "unknown guide style"
	end
	for _, field in ipairs({
		"TargetId",
		"Surface",
		"Category",
		"PlacementControlId",
		"SavingTargetId",
		"ModeControlId",
		"UpgradeId",
	}) do
		if value[field] ~= nil and not short(value[field]) then
			return false, "invalid guide " .. field
		end
	end
	if value.Repeat ~= nil and type(value.Repeat) ~= "boolean" then
		return false, "invalid guide repeat flag"
	end
	if value.Kind == "StoreRow" and not short(value.TargetId) then
		return false, "StoreRow guide needs TargetId"
	elseif value.Kind == "UiControl" and not short(value.TargetId) then
		return false, "UiControl guide needs TargetId"
	elseif value.Kind == "PlacedBuilding" and not short(value.UpgradeId) then
		return false, "PlacedBuilding guide needs UpgradeId"
	elseif (value.Kind == "WorldPosition" or value.Kind == "WorldObject" or value.Kind == "OffscreenWorldTarget")
		and not short(value.TargetId)
	then
		return false, value.Kind .. " guide needs TargetId"
	end
	return true
end

function Registry.IsKind(value)
	return KINDS[value] == true
end

return table.freeze(Registry)
