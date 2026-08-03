-- BoostShopPrompts — binds the Studio-authored counter prompts at the Hub boost stall.
--
-- World side of the shop: it finds `Workspace…BoostStall`, walks the canister models named in
-- BoostShopConfig, and wires each canister's `ViewPrompt`:
--   Triggered              -> onTriggered(item)  (the orchestrator opens the purchase window)
--   PromptShown/Hidden     -> its authored `SelectHighlight` toggles, for the in-range
--                             outlined-selection look (docs/boost-shop-design.md §6).
--
-- Logic only: the stall, canisters, prompts, and highlight are Studio-authored instances this
-- module never creates or restyles. Prompt offsets/text come from the baked
-- BoostShopPresentationConfig via StarterPlayerScripts/TunedProximityPrompts.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local BoostShopConfig = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("BoostShopConfig"))
local QuestProgressObservationBus = require(
	script.Parent.Parent:WaitForChild("Hud"):WaitForChild("QuestProgressObservationBus")
)

-- The stall is authored content present at load (no streaming), but the client can run before
-- Workspace has finished replicating, so poll briefly instead of binding to nothing.
local FIND_TIMEOUT = 20
local FIND_INTERVAL = 0.5

local BoostShopPrompts = {}

local function findStall()
	local deadline = os.clock() + FIND_TIMEOUT
	repeat
		local stall = Workspace:FindFirstChild(BoostShopConfig.StallName, true)
		if stall then
			return stall
		end
		task.wait(FIND_INTERVAL)
	until os.clock() >= deadline
	return nil
end

local function bindCanister(canister, item, onTriggered)
	local prompt = canister:FindFirstChild(BoostShopConfig.PromptName, true)
	if not (prompt and prompt:IsA("ProximityPrompt")) then
		warn(
			("BoostShopPrompts: %s has no `%s` ProximityPrompt — %s cannot be opened from the counter."):format(
				canister:GetFullName(),
				BoostShopConfig.PromptName,
				item.DisplayName
			)
		)
		return false
	end

	local highlight = canister:FindFirstChild(BoostShopConfig.HighlightName, true)
	prompt.PromptShown:Connect(function()
		QuestProgressObservationBus.Publish("BoostShopApproached")
	end)
	if highlight then
		highlight.Enabled = false
		prompt.PromptShown:Connect(function()
			highlight.Enabled = true
		end)
		prompt.PromptHidden:Connect(function()
			highlight.Enabled = false
		end)
	end

	prompt.Triggered:Connect(function()
		onTriggered(item)
	end)
	return true
end

-- Wires every configured canister prompt. `onTriggered(item)` receives the BoostShopConfig item.
-- Yields while waiting for the stall to replicate, so call it from a task/thread that may block.
function BoostShopPrompts.bind(onTriggered)
	local stall = findStall()
	if not stall then
		warn(
			("BoostShopPrompts: no `%s` found in Workspace — the boost shop prompts are unwired."):format(
				BoostShopConfig.StallName
			)
		)
		return 0
	end

	local bound = 0
	for _, id in ipairs(BoostShopConfig.Order) do
		local item = BoostShopConfig.Items[id]
		local canister = stall:FindFirstChild(item.CanisterName, true)
		if not canister then
			warn(
				("BoostShopPrompts: %s has no `%s` model — %s is unwired."):format(
					stall:GetFullName(),
					item.CanisterName,
					item.DisplayName
				)
			)
		elseif bindCanister(canister, item, onTriggered) then
			bound += 1
		end
	end
	return bound
end

return BoostShopPrompts
