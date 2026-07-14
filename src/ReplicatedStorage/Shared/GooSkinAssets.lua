-- One resolver/validator for the shared goo model library. World mascots and viewport
-- previews use the same fallback: requested variant -> shared Default -> unavailable.
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local GooSkinConfig = require(script.Parent.GooSkinConfig)

local GooSkinAssets = {}

GooSkinAssets.RequiredChildren = {
	{ Name = "SlimeBody", ClassName = "BasePart" },
	{ Name = "SlimeEyes", ClassName = "BasePart" },
	{ Name = "GooRoot", ClassName = "BasePart" },
	{ Name = "EyeRootLeft", ClassName = "BasePart" },
	{ Name = "EyeRootRight", ClassName = "BasePart" },
}

local function usefulColor(value)
	return typeof(value) == "Color3"
end

function GooSkinAssets.IsUsable(model)
	if not (model and model:IsA("Model")) then
		return false, "is missing or is not a Model"
	end
	for _, requirement in ipairs(GooSkinAssets.RequiredChildren) do
		local child = model:FindFirstChild(requirement.Name)
		if not (child and child:IsA(requirement.ClassName)) then
			return false, ("is missing required %s (%s)"):format(requirement.Name, requirement.ClassName)
		end
	end
	if not usefulColor(model:GetAttribute("DefaultBodyColor")) then
		return false, "does not have a useful Color3 DefaultBodyColor attribute"
	end
	local yaw = model:GetAttribute("PreviewYaw")
	if yaw ~= nil and typeof(yaw) ~= "number" then
		return false, "has a nonnumeric PreviewYaw attribute"
	end
	local scale = model:GetAttribute("PreviewScale")
	if scale ~= nil and (typeof(scale) ~= "number" or scale <= 0) then
		return false, "has a PreviewScale attribute that is not numeric and positive"
	end
	return true
end

function GooSkinAssets.Resolve(skinId)
	local library = ReplicatedStorage:FindFirstChild("GooSkinAssets")
	local def = GooSkinConfig.GetSkinDef(skinId)
	local requested = library and def and library:FindFirstChild(def.AssetName)
	if GooSkinAssets.IsUsable(requested) then
		return requested, false
	end

	local defaultDef = GooSkinConfig.GetSkinDef(GooSkinConfig.DefaultSkinId)
	local fallback = library and defaultDef and library:FindFirstChild(defaultDef.AssetName)
	if GooSkinAssets.IsUsable(fallback) then
		return fallback, true
	end
	return nil, true
end

function GooSkinAssets.Validate()
	local errors = {}
	local warnings = {}
	local library = ReplicatedStorage:FindFirstChild("GooSkinAssets")
	if not library then
		table.insert(errors, "ReplicatedStorage.GooSkinAssets is missing")
		return errors, warnings
	end

	for _, def in ipairs(GooSkinConfig.Definitions) do
		local model = library:FindFirstChild(def.AssetName)
		local ok, reason = GooSkinAssets.IsUsable(model)
		if not ok then
			local message = ("GooSkinAssets.%s %s; %s will use shared Default"):format(
				tostring(def.AssetName),
				reason,
				tostring(def.Id)
			)
			if def.Id == GooSkinConfig.DefaultSkinId then
				table.insert(errors, message)
			else
				table.insert(warnings, message)
			end
		elseif not model:FindFirstChild("DizzyBirds") then
			table.insert(warnings, ("GooSkinAssets.%s has no optional DizzyBirds"):format(def.AssetName))
		end
	end
	return errors, warnings
end

return GooSkinAssets
