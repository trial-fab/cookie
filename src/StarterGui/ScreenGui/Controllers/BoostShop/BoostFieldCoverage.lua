-- BoostFieldCoverage: what the ghost is actually about to buy.
--
-- A radius disc tells the player how BIG the field is. It does not tell them the thing they are
-- deciding — how many of their buildings fall inside it (§12.1). This outlines those buildings and
-- counts them live as the ghost moves.
--
-- The membership test is deliberately the SAME one the server pays out on
-- (BoostFieldService.GetBuildingEffects + ProductionService's grouping): the plot owner's building
-- models, on the field's floor, within the radius measured horizontally. If this drifted from that,
-- the ghost would promise a number the field then failed to deliver.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local shared = ReplicatedStorage:WaitForChild("Shared")
local Attrs = require(shared:WaitForChild("Attrs"))
local BoostShopConfig = require(shared:WaitForChild("BoostShopConfig"))
local FloorConfig = require(shared:WaitForChild("FloorConfig"))
local UpgradeConfig = require(shared:WaitForChild("UpgradeConfig"))

local BoostFieldCoverage = {}

local function sheetOwner(sheet)
	local value = sheet and sheet:FindFirstChild("SheetOwner")
	return value and value:IsA("ObjectValue") and value.Value or nil
end

local function buildingOwner(model)
	local value = model:FindFirstChild("Owner")
	return value and value:IsA("ObjectValue") and value.Value or nil
end

-- options: { screenGui }
function BoostFieldCoverage.new(options)
	local screenGui = options.screenGui

	local label = screenGui:FindFirstChild(BoostShopConfig.CoverageLabelName, true)
	if label and not label:IsA("TextLabel") then
		label = nil
	end
	if not label then
		warn(
			("BoostFieldCoverage: no `%s` TextLabel under the ScreenGui — the covered count is hidden."):format(
				BoostShopConfig.CoverageLabelName
			)
		)
	end

	-- Highlights are pooled and re-adorned rather than created per move: creating instances every
	-- frame while the ghost follows the cursor would be the expensive part, whereas re-pointing an
	-- existing one is cheap.
	--
	-- They live in a FOLDER, and this is load-bearing: a Highlight with no Adornee falls back to
	-- adorning its PARENT, and `Workspace` is itself a Model — so an idle pooled Highlight parented
	-- straight to Workspace lights up the entire map. A Folder is neither a Model nor a BasePart,
	-- so a nil Adornee has nothing to fall back to.
	local pool = {}
	local covered = {}

	local container = Instance.new("Folder")
	container.Name = "BoostCoverageHighlights"
	container.Parent = Workspace

	local function acquire(index)
		local highlight = pool[index]
		if not highlight then
			highlight = Instance.new("Highlight")
			highlight.Name = "BoostCoverageHighlight"
			highlight.FillTransparency = 0.75
			highlight.OutlineTransparency = 0
			highlight.DepthMode = Enum.HighlightDepthMode.Occluded
			highlight.Enabled = false
			highlight.Parent = container
			pool[index] = highlight
		end
		return highlight
	end

	-- Belt and braces alongside the folder: an unused Highlight is switched off outright, so it can
	-- neither adorn anything by accident nor cost anything to render.
	local function release(highlight)
		highlight.Enabled = false
		highlight.Adornee = nil
	end

	local function setLabel(text)
		if label then
			label.Text = text or label.Text
			label.Visible = text ~= nil
		end
	end

	local function clear()
		table.clear(covered)
		for _, highlight in ipairs(pool) do
			release(highlight)
		end
		setLabel(nil)
	end

	-- Recomputes coverage for a ghost sitting at `position` on `surface`. `color` tints the outlines
	-- to the item, so the covered set reads as belonging to the disc that selected it.
	local function update(surface, position, radius, color)
		table.clear(covered)

		local sheet = surface and surface.sheet
		local owner = sheetOwner(sheet)
		if not owner then
			clear()
			return 0
		end

		local radiusSquared = radius * radius
		for _, child in ipairs(sheet:GetChildren()) do
			if child:IsA("Model") and buildingOwner(child) == owner then
				local upgradeId = child:GetAttribute(Attrs.UpgradeId)
				local config = type(upgradeId) == "string" and UpgradeConfig[upgradeId]
				if config and config.TemplateKind == "Building" then
					local floorId = FloorConfig.NormalizeId(child:GetAttribute(Attrs.FloorId))
					if floorId == surface.floorId then
						-- Horizontal distance only: a building's height never lifts it out of the
						-- flat disc it is standing in, which is how the server measures it too.
						local origin = child:GetPivot().Position
						local dx, dz = origin.X - position.X, origin.Z - position.Z
						if dx * dx + dz * dz <= radiusSquared then
							table.insert(covered, child)
						end
					end
				end
			end
		end

		local total = #covered
		local shown = math.min(total, BoostShopConfig.MaxCoverageHighlights)
		for index = 1, shown do
			local highlight = acquire(index)
			highlight.Adornee = covered[index]
			highlight.FillColor = color
			highlight.OutlineColor = color
			highlight.Enabled = true
		end
		-- Everything the pool grew to but this coverage does not need goes fully idle.
		for index = shown + 1, #pool do
			release(pool[index])
		end

		if total == 0 then
			setLabel("No buildings covered")
		elseif total == 1 then
			setLabel("1 building covered")
		else
			setLabel(("%d buildings covered"):format(total))
		end
		return total
	end

	return {
		update = update,
		clear = clear,
		destroy = function()
			clear()
			table.clear(pool)
			container:Destroy()
		end,
	}
end

return BoostFieldCoverage
