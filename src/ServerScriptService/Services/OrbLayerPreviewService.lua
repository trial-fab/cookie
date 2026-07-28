-- OrbLayerPreviewService: forwards authorized DevTuning applications only to the
-- applying player. The world preview is client-local and never mutates Studio or data.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local DevTuning = require(Shared:WaitForChild("DevTuning"):WaitForChild("DevTuning"))
local Net = require(Shared:WaitForChild("Net"))
local DevTuningService = require(ServerScriptService:WaitForChild("Services"):WaitForChild("DevTuningService"))

local OrbLayerPreviewService = {}

local FEATURE = "OrbLayers"
local KEYS = {
	"EditorEnabled",
	"LayerColor",
	"LayerDiameter",
	"LayerIndex",
	"LayerMaterial",
	"LayerTransparency",
	"TriggerAdd",
	"TriggerApply",
	"TriggerRemove",
	"TriggerReset",
}

local function buildSnapshot()
	local snapshot = {}
	for _, key in ipairs(KEYS) do
		snapshot[key] = DevTuning.get(FEATURE .. "." .. key)
	end
	return snapshot
end

function OrbLayerPreviewService.Init()
	if not DevTuning.Enabled then
		return
	end

	Net.event(Net.Names.OrbLayerPreviewChanged)

	for _, key in ipairs(KEYS) do
		local dottedId = FEATURE .. "." .. key
		DevTuningService.ObserveApply(dottedId, function(player)
			Net.fireClient(Net.Names.OrbLayerPreviewChanged, player, key, buildSnapshot())
		end)
	end
end

return OrbLayerPreviewService
