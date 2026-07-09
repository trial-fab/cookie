local Players = game:GetService("Players")
local ServerScriptService = game:GetService("ServerScriptService")
local Workspace = game:GetService("Workspace")

local SheetService = {}
local PlayerDataService = require(ServerScriptService.Services.PlayerDataService)
local Attrs = require(game:GetService("ReplicatedStorage"):WaitForChild("Shared"):WaitForChild("Attrs"))

--[[
	Radial wedge layout (cap PLOT_CAP plots).

	Plots are evenly spaced around a shared circle centered on Workspace.Baseplate.
	Slot i sits at angle theta = (i-1) * 2*pi/PLOT_CAP (slot 1 -> +X). Each plot's INNER
	edge (the hub-facing side) is pinned at radius R_INNER from the center; the plot
	extends OUTWARD along its local +Z. Plots grow outward via Base Expansion
	(UpgradeService), so the inner edge / spawn / cookie stay put near the hub while
	build space expands toward the rim and beyond.

	Slots are assigned, not players: a slot persists as an "open plot" when its owner
	leaves and is reused by the next joiner (lowest free slot first). Only TRAILING
	(highest-index) empty plots are trimmed, so occupied plots never move.

	Workspace.Baseplate is the disc whose .Position is the circle center; the code only
	reads it (it never resizes the baseplate). All tunables below are in studs.
]]

local CONFIG = {
	PLOT_CAP = 10,   -- plots evenly spaced around the circle (10 -> 36 deg apart)
	R_INNER = 250,   -- inner (hub-facing) edge distance from center; plots grow outward from here
	                 -- (~22.5-stud gap between adjacent plots at the inner edge; the zero-gap
	                 --  minimum for 10 plots @ 132 wide is ~214. Pair with baseplate radius >= ~310.)
}

local DEBUG = false
local function dprint(...)
	if DEBUG then
		print("[SheetService]", ...)
	end
end

local cookieSheetsFolder
local sheetTemplate
local sheetBaseY              -- authored Y of a sheet's Base (keeps sheets at their designed height)
local sheetBaseSize          -- authored Base size (local X = width, Z = depth) for reset on reuse
local sheetEdgeSize          -- authored Edge size for reset on reuse
local baseOrigin             -- Vector3: circle center; X/Z used, Y comes from sheetBaseY for plots

-- tiles[i] = sheet Model for slot (i-1). Always contiguous 1..#tiles (we only trim the tail).
local tiles = {}
local assignedSheetsByPlayer = {}
local teleportDebounce = {}
local debugStack = {}         -- test-harness faux-owned plots (LIFO); see SheetService.Debug*

----------------------------------------------------------------------
-- Slot math (1-based slot index -> world CFrame for the Base center)
----------------------------------------------------------------------

-- Unit direction for a slot's angle (slot 1 -> +X), evenly spaced around the circle.
local function slotDirection(slot)
	local theta = (slot - 1) * (2 * math.pi / CONFIG.PLOT_CAP)
	return Vector3.new(math.cos(theta), 0, math.sin(theta))
end

-- Target CFrame for a sheet's Base center: inner edge pinned at R_INNER, local +Z pointing
-- radially outward (+Y up), for a plot of the given depth (Base local-Z size).
local function plotBaseCFrame(slot, depth)
	local dir = slotDirection(slot)
	local centerRadius = CONFIG.R_INNER + depth / 2
	local pos = Vector3.new(
		baseOrigin.X + dir.X * centerRadius,
		sheetBaseY,
		baseOrigin.Z + dir.Z * centerRadius
	)
	-- lookAt's front (-Z) faces (pos - dir), so local +Z = dir (outward).
	return CFrame.lookAt(pos, pos - dir, Vector3.yAxis)
end

----------------------------------------------------------------------
-- Sheet helpers
----------------------------------------------------------------------

local function getSheetOwnerValue(sheet)
	return sheet:FindFirstChild("SheetOwner")
end

local function getSheetCenter(sheet)
	local base = sheet:FindFirstChild("Base")
	if base and base:IsA("BasePart") then
		return base
	end
	return nil
end

local function isOwned(sheet)
	local ownerValue = getSheetOwnerValue(sheet)
	return ownerValue ~= nil and ownerValue.Value ~= nil
end

local function setAvailable(sheet, available)
	-- Source of truth for "open plot" visuals; author the vacant look in Studio off this attribute.
	sheet:SetAttribute("Available", available)
end

local function moveSheetCenterTo(sheet, targetCenterCFrame)
	local center = getSheetCenter(sheet)
	if not center then
		return false
	end
	local offset = targetCenterCFrame * center.CFrame:Inverse()
	sheet:PivotTo(offset * sheet:GetPivot())
	return true
end

-- Keep the Edge rim hugging the Base: 1 stud larger on each horizontal side, same transform.
local function syncEdge(sheet)
	local base = getSheetCenter(sheet)
	local edge = sheet:FindFirstChild("Edge")
	if not (base and edge and edge:IsA("BasePart")) then
		return
	end
	edge.Size = Vector3.new(base.Size.X + 2, edge.Size.Y, base.Size.Z + 2)
	edge.CFrame = base.CFrame
end
SheetService.SyncEdge = syncEdge

-- Reset a sheet's Base/Edge to authored (starting) size, then re-place it at its slot so the
-- inner edge sits back at R_INNER. Used for fresh tiles and when reusing an open plot that a
-- previous owner may have expanded.
local function placeSheet(sheet, slot)
	local base = getSheetCenter(sheet)
	if base and sheetBaseSize then
		base.Size = sheetBaseSize
	end
	if base then
		moveSheetCenterTo(sheet, plotBaseCFrame(slot, base.Size.Z))
	end
	local edge = sheet:FindFirstChild("Edge")
	if edge and edge:IsA("BasePart") and sheetEdgeSize then
		edge.Size = sheetEdgeSize
	end
	syncEdge(sheet)
end

local function resetGeneratedSheet(sheet)
	local ownerValue = getSheetOwnerValue(sheet)
	if ownerValue then
		ownerValue.Value = nil
	end

	local shieldEnabled = sheet:FindFirstChild("ShieldEnabled")
	if shieldEnabled and shieldEnabled:IsA("BoolValue") then
		shieldEnabled.Value = true
	end

	for _, child in ipairs(sheet:GetChildren()) do
		if child:IsA("Model") and child:GetAttribute(Attrs.UpgradeId) then
			child:Destroy()
		end
	end

	setAvailable(sheet, true)
end

local function captureSheetTemplate()
	local template = cookieSheetsFolder:FindFirstChild("CookieSheet")
	if not template or not template:IsA("Model") then
		warn("CookieSheets.CookieSheet template is missing; player sheet cloning disabled.")
		return false
	end

	local baseCenter = getSheetCenter(template)
	if not baseCenter then
		warn("CookieSheets.CookieSheet missing Base; player sheet cloning disabled.")
		return false
	end

	sheetTemplate = template:Clone()
	sheetBaseY = baseCenter.Position.Y
	sheetBaseSize = baseCenter.Size
	local edge = template:FindFirstChild("Edge")
	if edge and edge:IsA("BasePart") then
		sheetEdgeSize = edge.Size
	end
	resetGeneratedSheet(sheetTemplate)

	-- Park the authored template off-map so it is not a stray plot; the in-memory clone is the source.
	template.Parent = nil
	return true
end

----------------------------------------------------------------------
-- Occupancy guard (axis-aligned box test against player root parts)
----------------------------------------------------------------------

local function anyPlayerInArea(centerPos, sizeX, sizeZ)
	local hx = sizeX / 2 + 8
	local hz = sizeZ / 2 + 8
	for _, pl in ipairs(Players:GetPlayers()) do
		local char = pl.Character
		local hrp = char and char:FindFirstChild("HumanoidRootPart")
		if hrp then
			local d = hrp.Position - centerPos
			if math.abs(d.X) <= hx and math.abs(d.Z) <= hz then
				return true
			end
		end
	end
	return false
end

local function playerOnSheet(sheet)
	local base = getSheetCenter(sheet)
	if not base then
		return false
	end
	-- Conservative AABB proximity check (rotation-agnostic) used only to defer trimming.
	local span = math.max(base.Size.X, base.Size.Z)
	return anyPlayerInArea(base.Position, span, span)
end

----------------------------------------------------------------------
-- Tile create / trim
----------------------------------------------------------------------

local function createTileAtTail()
	local slot = #tiles + 1 -- next 1-based slot index
	if slot > CONFIG.PLOT_CAP then
		return nil -- server full (cap reached)
	end

	local sheet = sheetTemplate:Clone()
	sheet.Name = ("CookieSheet_%d"):format(slot)
	resetGeneratedSheet(sheet)
	sheet.Parent = cookieSheetsFolder
	placeSheet(sheet, slot)

	tiles[slot] = sheet
	return sheet
end

local function trimTrailingEmptyTiles()
	local trimmed = false
	while #tiles > 0 do
		local sheet = tiles[#tiles]
		if isOwned(sheet) then
			break
		end
		if playerOnSheet(sheet) then
			break -- defer: someone is standing on this open plot
		end
		tiles[#tiles] = nil
		sheet:Destroy()
		trimmed = true
	end
	return trimmed
end

----------------------------------------------------------------------
-- Assignment
----------------------------------------------------------------------

local function assignSheetToPlayer(sheet, player)
	local ownerValue = getSheetOwnerValue(sheet)
	if not ownerValue then
		return nil
	end
	ownerValue.Value = player
	setAvailable(sheet, false)
	assignedSheetsByPlayer[player] = sheet
	return sheet
end

function SheetService.GetPlayerSheet(player)
	return assignedSheetsByPlayer[player]
end

function SheetService.AssignSheet(player)
	if assignedSheetsByPlayer[player] then
		return assignedSheetsByPlayer[player]
	end

	-- Reuse the lowest free open plot (reset any prior expansion, re-place at its slot).
	for slot, sheet in ipairs(tiles) do
		if not isOwned(sheet) then
			placeSheet(sheet, slot)
			dprint("Reused open plot", sheet.Name, "for", player.Name)
			return assignSheetToPlayer(sheet, player)
		end
	end

	-- None free: grow the ring by one plot.
	local sheet = createTileAtTail()
	if sheet then
		dprint("Grew ring:", sheet.Name, "for", player.Name)
		return assignSheetToPlayer(sheet, player)
	end

	warn("No available cookie sheet for " .. player.Name .. " (server full)")
	return nil
end

function SheetService.ReleaseSheet(player)
	local sheet = assignedSheetsByPlayer[player]
	if sheet then
		PlayerDataService.UpdateFromPlayerValues(player)
	end

	assignedSheetsByPlayer[player] = nil
	teleportDebounce[player] = nil

	if not sheet then
		return
	end

	local ownerValue = getSheetOwnerValue(sheet)
	if ownerValue and ownerValue.Value == player then
		ownerValue.Value = nil
	end

	local shieldEnabled = sheet:FindFirstChild("ShieldEnabled")
	if shieldEnabled and shieldEnabled:IsA("BoolValue") then
		shieldEnabled.Value = true
	end

	for _, child in ipairs(sheet:GetChildren()) do
		if child:IsA("Model") then
			local owner = child:FindFirstChild("Owner")
			if owner and owner:IsA("ObjectValue") and owner.Value == player then
				child:SetAttribute(Attrs.CountAdjusted, true)
				child:Destroy()
			end
		end
	end

	-- Plot becomes an open plot, reset to starting size, then trim any trailing empties.
	setAvailable(sheet, true)
	local slot = table.find(tiles, sheet)
	if slot then
		placeSheet(sheet, slot)
	end
	trimTrailingEmptyTiles()
end

function SheetService.TeleportToSheet(player, character)
	local sheet = SheetService.GetPlayerSheet(player) or SheetService.AssignSheet(player)
	if not sheet then
		return
	end

	local spawnPoint = sheet:FindFirstChild("SpawnPoint")
	if not spawnPoint or not spawnPoint:IsA("BasePart") then
		warn("Cookie sheet missing SpawnPoint: " .. sheet:GetFullName())
		return
	end

	character:PivotTo(spawnPoint.CFrame + Vector3.new(0, 5, 0))
end

----------------------------------------------------------------------
-- Debug harness: simulate join/leave from a test UI (Studio only).
----------------------------------------------------------------------

function SheetService.DebugAddPlot()
	local sheet
	local slot
	for i, s in ipairs(tiles) do
		if not isOwned(s) then
			sheet, slot = s, i
			break
		end
	end
	if not sheet then
		sheet = createTileAtTail()
		slot = #tiles
	end
	if not sheet then
		return nil -- server full
	end

	placeSheet(sheet, slot)
	local ownerValue = getSheetOwnerValue(sheet)
	if ownerValue then
		ownerValue.Value = sheet -- non-nil sentinel => "owned" (never matches a real player)
	end
	setAvailable(sheet, false)
	table.insert(debugStack, sheet)
	return sheet
end

function SheetService.DebugRemovePlot()
	local sheet = table.remove(debugStack)
	if not sheet then
		return false
	end

	local ownerValue = getSheetOwnerValue(sheet)
	if ownerValue then
		ownerValue.Value = nil
	end
	setAvailable(sheet, true)
	trimTrailingEmptyTiles()
	return true
end

----------------------------------------------------------------------
-- Init
----------------------------------------------------------------------

function SheetService.Init()
	cookieSheetsFolder = Workspace:WaitForChild("CookieSheets")

	local plate = Workspace:FindFirstChild("Baseplate") or Workspace:FindFirstChild("BasePlate")
	if plate then
		baseOrigin = plate.Position
	else
		warn("Workspace.Baseplate not found; using origin as circle center.")
		baseOrigin = Vector3.new(0, 0, 0)
	end

	if not captureSheetTemplate() then
		return
	end

	Players.PlayerRemoving:Connect(function(player)
		SheetService.ReleaseSheet(player)
	end)

	print("SheetService initialized (radial layout)")
end

return SheetService
