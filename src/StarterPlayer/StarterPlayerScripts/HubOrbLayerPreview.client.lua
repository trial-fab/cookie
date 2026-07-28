-- HubOrbLayerPreview -- reversible, applying-player-only DevConsole editing for the
-- Ancient Core's concentric visual layers. All edits and clones exist only on this client.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local DevTuning = require(Shared:WaitForChild("DevTuning"):WaitForChild("DevTuning"))
local Net = require(Shared:WaitForChild("Net"))

local ACTIVATED_CFRAME_ATTRIBUTE = "HubActivatedCFrame"
local PREVIEW_LAYER_ATTRIBUTE = "DevOrbLayerPreview"
local MAX_LAYER_COUNT = 16

if not DevTuning.Enabled then
	return
end

local hub = Workspace:WaitForChild("HubPlazaDraft", 10)
local leaderboard = hub and hub:WaitForChild("LeaderboardSystem", 10)
local orbItems = leaderboard and leaderboard:WaitForChild("OrbItems", 10)
local core = orbItems and orbItems:FindFirstChild("OrbCore")
if not (orbItems and orbItems:IsA("Model") and core and core:IsA("BasePart")) then
	warn("HubOrbLayerPreview: LeaderboardSystem.OrbItems.OrbCore not found")
	return
end

local previewActive = false
local originals = {}
local previewClones = {}
local nextCloneNumber = 1

local function isPreviewClone(part)
	return part:GetAttribute(PREVIEW_LAYER_ATTRIBUTE) == true
end

local function isEditableLayer(part)
	return part:IsA("BasePart") and part:GetAttribute("OrbLayerEditorIgnore") ~= true
end

local function captureOriginal(part)
	if originals[part] or isPreviewClone(part) then
		return
	end
	originals[part] = {
		Material = part.Material,
		Color = part.Color,
		Size = part.Size,
		Transparency = part.Transparency,
	}
end

local function restorePreview()
	for part, properties in pairs(originals) do
		if part.Parent then
			part.Material = properties.Material
			part.Color = properties.Color
			part.Size = properties.Size
			part.Transparency = properties.Transparency
		end
	end
	for clone in pairs(previewClones) do
		if clone.Parent then
			clone:Destroy()
		end
	end
	table.clear(originals)
	table.clear(previewClones)
	previewActive = false
end

local function beginPreview()
	if previewActive then
		return
	end
	for _, descendant in ipairs(orbItems:GetDescendants()) do
		if isEditableLayer(descendant) then
			captureOriginal(descendant)
		end
	end
	previewActive = true
end

local function getLayers()
	local layers = {}
	for _, descendant in ipairs(orbItems:GetDescendants()) do
		if isEditableLayer(descendant) then
			table.insert(layers, descendant)
		end
	end
	table.sort(layers, function(left, right)
		local leftDiameter = math.max(left.Size.X, left.Size.Y, left.Size.Z)
		local rightDiameter = math.max(right.Size.X, right.Size.Y, right.Size.Z)
		if math.abs(leftDiameter - rightDiameter) > 0.0001 then
			return leftDiameter < rightDiameter
		end
		return left.Name < right.Name
	end)
	return layers
end

local function getSelectedLayer(snapshot)
	local layers = getLayers()
	local index = math.clamp(math.round(snapshot.LayerIndex), 1, #layers)
	return layers[index], index, #layers
end

local function applyControls(part, snapshot)
	captureOriginal(part)
	part.Material = snapshot.LayerMaterial
	part.Color = snapshot.LayerColor
	part.Size = Vector3.new(snapshot.LayerDiameter, snapshot.LayerDiameter, snapshot.LayerDiameter)
	part.Transparency = snapshot.LayerTransparency
end

local function addLayer(snapshot)
	if #getLayers() >= MAX_LAYER_COUNT then
		warn(("HubOrbLayerPreview: preview is limited to %d layers"):format(MAX_LAYER_COUNT))
		return
	end

	local source = getSelectedLayer(snapshot)
	if not source then
		warn("HubOrbLayerPreview: no layer is available to clone")
		return
	end

	local clone = source:Clone()
	for _, child in ipairs(clone:GetChildren()) do
		child:Destroy()
	end
	clone.Name = string.format("DevOrbLayer%02d", nextCloneNumber)
	nextCloneNumber += 1
	clone:SetAttribute(ACTIVATED_CFRAME_ATTRIBUTE, nil)
	clone:SetAttribute(PREVIEW_LAYER_ATTRIBUTE, true)
	clone.Anchored = true
	clone.CanCollide = false
	clone.CanQuery = false
	clone.CanTouch = false
	clone.Massless = true
	clone.CFrame = core.CFrame
	applyControls(clone, snapshot)
	previewClones[clone] = true
	clone.Parent = orbItems
	print(("Orb layer preview added %s (%d total layers)"):format(clone.Name, #getLayers()))
end

local function applySelected(snapshot)
	local part, index, count = getSelectedLayer(snapshot)
	if not part then
		warn("HubOrbLayerPreview: no layer is available to edit")
		return
	end
	applyControls(part, snapshot)
	print(("Orb layer preview applied to layer %d/%d (%s)"):format(index, count, part.Name))
end

local function removeSelected(snapshot)
	local part, index, count = getSelectedLayer(snapshot)
	if not part then
		warn("HubOrbLayerPreview: no layer is available to remove")
		return
	end
	if part == core then
		warn("HubOrbLayerPreview: OrbCore is required and cannot be removed")
		return
	end

	if isPreviewClone(part) then
		previewClones[part] = nil
		part:Destroy()
	else
		captureOriginal(part)
		part.Transparency = 1
	end
	print(("Orb layer preview removed layer %d/%d (%s)"):format(index, count, part.Name))
end

Net.on(Net.Names.OrbLayerPreviewChanged, function(changedKey, snapshot)
	if type(changedKey) ~= "string" or type(snapshot) ~= "table" then
		return
	end

	if changedKey == "EditorEnabled" then
		if snapshot.EditorEnabled then
			beginPreview()
		else
			restorePreview()
		end
		return
	end

	if not snapshot.EditorEnabled then
		return
	end
	beginPreview()

	if changedKey == "TriggerAdd" then
		addLayer(snapshot)
	elseif changedKey == "TriggerApply" then
		applySelected(snapshot)
	elseif changedKey == "TriggerRemove" then
		removeSelected(snapshot)
	elseif changedKey == "TriggerReset" then
		restorePreview()
	end
end)
