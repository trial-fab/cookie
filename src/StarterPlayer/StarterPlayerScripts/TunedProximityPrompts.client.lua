-- Applies baked presentation values to selected Studio-authored ProximityPrompts.
-- Opt in with the "TunedProximityPrompt" tag plus TuningFeature and TuningKey attributes.

local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local BoostShopPresentationConfig =
	require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("BoostShopPresentationConfig"))

local TAG = "TunedProximityPrompt"

local function bind(prompt)
	if not prompt:IsA("ProximityPrompt") then
		return
	end

	local feature = prompt:GetAttribute("TuningFeature")
	local key = prompt:GetAttribute("TuningKey")
	if feature ~= "BoostShopLabels" or type(key) ~= "string" then
		warn(("Tuned proximity prompt %s is missing TuningFeature/TuningKey"):format(prompt:GetFullName()))
		return
	end

	local config = BoostShopPresentationConfig.Prompts[key]
	if not config then
		warn(("Tuned proximity prompt %s has unknown TuningKey %q"):format(prompt:GetFullName(), key))
		return
	end

	prompt.UIOffset = Vector2.new(config.OffsetX, config.OffsetY)
	prompt.ActionText = config.ActionText
	prompt.ObjectText = config.ObjectText
end

for _, prompt in ipairs(CollectionService:GetTagged(TAG)) do
	bind(prompt)
end
CollectionService:GetInstanceAddedSignal(TAG):Connect(bind)
