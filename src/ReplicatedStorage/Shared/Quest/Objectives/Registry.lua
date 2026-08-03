local DomainEvents = require(script.Parent.Parent.DomainEvents)
local StoryTransition = require(script.Parent.StoryTransition)
local ManualOwnerClickCount = require(script.Parent.ManualOwnerClickCount)
local BuildingPlaced = require(script.Parent.BuildingPlaced)
local BuildingCountAtLeast = require(script.Parent.BuildingCountAtLeast)
local BuildingSold = require(script.Parent.BuildingSold)
local CookieBalanceAtLeast = require(script.Parent.CookieBalanceAtLeast)
local UpgradePurchased = require(script.Parent.UpgradePurchased)
local ClientUiObservation = require(script.Parent.ClientUiObservation)
local BoostPurchased = require(script.Parent.BoostPurchased)
local BoostFieldDropped = require(script.Parent.BoostFieldDropped)

local Registry = {}

local PROGRESS_MODES = {
	Canonical = true,
	CapturedFact = true,
	Accumulated = true,
	ClientObservation = true,
}

local MODULES = {
	StoryTransition,
	ManualOwnerClickCount,
	BuildingPlaced,
	BuildingCountAtLeast,
	BuildingSold,
	CookieBalanceAtLeast,
	UpgradePurchased,
	ClientUiObservation,
	BoostPurchased,
	BoostFieldDropped,
}

local byKind = {}
local triggerToKinds = {}
local phaseRanksByKind = {}

local function fail(message)
	error("ObjectiveRegistry: " .. message, 3)
end

local function validateTriggers(module, field)
	local seen = {}
	local values = module[field]
	if type(values) ~= "table" or #values > 32 then
		fail(module.Kind .. " has invalid " .. field)
	end
	for _, trigger in ipairs(values) do
		if type(trigger) ~= "string" or not DomainEvents.IsKnown(trigger) then
			fail(module.Kind .. " names unknown trigger " .. tostring(trigger))
		end
		if seen[trigger] then
			fail(module.Kind .. " repeats trigger " .. trigger)
		end
		seen[trigger] = true
	end
end

for _, module in ipairs(MODULES) do
	if type(module.Kind) ~= "string" or module.Kind == "" or byKind[module.Kind] then
		fail("objective kinds must be unique non-empty strings")
	end
	if not PROGRESS_MODES[module.ProgressMode] then
		fail(module.Kind .. " has invalid progress mode")
	end
	if
		type(module.Validate) ~= "function"
		or type(module.Evaluate) ~= "function"
		or type(module.NormalizeProgress) ~= "function"
	then
		fail(module.Kind .. " is missing a registry function")
	end
	if type(module.CaptureBeforeActive) ~= "boolean" then
		fail(module.Kind .. " needs CaptureBeforeActive")
	end
	if module.CaptureBeforeActive and type(module.Capture) ~= "function" then
		fail(module.Kind .. " captures early without Capture")
	end
	validateTriggers(module, "Triggers")
	validateTriggers(module, "CopyTriggers")
	local phases = {}
	if type(module.Phases) ~= "table" or #module.Phases < 1 or #module.Phases > 16 then
		fail(module.Kind .. " has invalid phases")
	end
	for rank, phase in ipairs(module.Phases) do
		if type(phase) ~= "string" or phase == "" or phases[phase] then
			fail(module.Kind .. " has invalid phases")
		end
		phases[phase] = rank
	end
	phaseRanksByKind[module.Kind] = phases
	byKind[module.Kind] = module
	for _, trigger in ipairs(module.Triggers) do
		local kinds = triggerToKinds[trigger]
		if not kinds then
			kinds = {}
			triggerToKinds[trigger] = kinds
		end
		table.insert(kinds, module.Kind)
	end
end

function Registry.Get(kind)
	return byKind[kind]
end

function Registry.KindsForTrigger(trigger)
	return triggerToKinds[trigger] or {}
end

function Registry.ValidateObjective(objective)
	if type(objective) ~= "table" then
		return false, "objective must be a table"
	end
	for key in pairs(objective) do
		if key ~= "Kind" and key ~= "Params" then
			return false, "unknown objective field " .. tostring(key)
		end
	end
	local module = byKind[objective.Kind]
	if not module then
		return false, "unknown objective kind " .. tostring(objective.Kind)
	end
	return module.Validate(objective.Params)
end

function Registry.ValidateKindContract(module)
	if type(module) ~= "table" or type(module.Kind) ~= "string" or module.Kind == "" then
		return false, "invalid objective kind"
	end
	if not PROGRESS_MODES[module.ProgressMode] then
		return false, "invalid progress mode"
	end
	if type(module.Triggers) ~= "table" or type(module.CopyTriggers) ~= "table" then
		return false, "invalid triggers"
	end
	for _, field in ipairs({ "Triggers", "CopyTriggers" }) do
		local seen = {}
		for _, trigger in ipairs(module[field]) do
			if not DomainEvents.IsKnown(trigger) or seen[trigger] then
				return false, "unknown or duplicate trigger"
			end
			seen[trigger] = true
		end
	end
	if type(module.Phases) ~= "table" or #module.Phases < 1 then
		return false, "invalid phases"
	end
	local phases = {}
	for _, phase in ipairs(module.Phases) do
		if type(phase) ~= "string" or phase == "" or phases[phase] then
			return false, "invalid phases"
		end
		phases[phase] = true
	end
	return true
end

function Registry.ValidateResult(kind, result)
	local module = byKind[kind]
	if not module or type(result) ~= "table" then
		return false, "unknown kind or invalid result"
	end
	local phaseRanks = phaseRanksByKind[kind]
	if type(result.Satisfied) ~= "boolean" or not phaseRanks[result.Phase] then
		return false, "invalid result phase"
	end
	for _, field in ipairs({ "Current", "Target", "ProgressFraction" }) do
		local value = result[field]
		if
			value ~= nil and (type(value) ~= "number" or value ~= value or value == math.huge or value == -math.huge)
		then
			return false, "non-finite result"
		end
	end
	local tokenCount = 0
	for key, value in pairs(result.Tokens or {}) do
		tokenCount += 1
		if
			tokenCount > 16
			or type(key) ~= "string"
			or not ({ string = true, number = true, boolean = true })[type(value)]
			or type(value) == "number" and (value ~= value or value == math.huge or value == -math.huge)
			or type(value) == "string" and #value > 256
		then
			return false, "invalid result tokens"
		end
	end
	return true
end

function Registry.NormalizeProgress(objective, progress)
	local module = byKind[objective.Kind]
	if not module then
		return nil, "unknown objective kind"
	end
	return module.NormalizeProgress(progress, objective.Params)
end

function Registry.Capture(objective, progress, cause)
	local module = byKind[objective.Kind]
	if not module or type(module.Capture) ~= "function" then
		return progress or {}
	end
	return module.Capture(objective.Params, progress or {}, cause)
end

function Registry.Evaluate(objective, facts, progress)
	local module = byKind[objective.Kind]
	if not module then
		return nil, "unknown objective kind"
	end
	local result = module.Evaluate(objective.Params, facts or {}, progress or {})
	if type(result) ~= "table" then
		return nil, "evaluation must return a table"
	end
	for key in pairs(result) do
		if key ~= "Satisfied" and key ~= "Current" and key ~= "Target" and key ~= "ProgressFraction"
			and key ~= "Phase" and key ~= "Tokens"
		then
			return nil, "evaluation returned unknown field " .. tostring(key)
		end
	end
	if type(result.Satisfied) ~= "boolean" then
		return nil, "evaluation needs boolean Satisfied"
	end
	local phaseRanks = phaseRanksByKind[objective.Kind]
	if type(result.Phase) ~= "string" or not phaseRanks[result.Phase] then
		return nil, "evaluation returned an undeclared phase"
	end
	for _, field in ipairs({ "Current", "Target", "ProgressFraction" }) do
		local value = result[field]
		if
			value ~= nil and (type(value) ~= "number" or value ~= value or value == math.huge or value == -math.huge)
		then
			return nil, "evaluation returned non-finite " .. field
		end
	end
	if result.ProgressFraction ~= nil and (result.ProgressFraction < 0 or result.ProgressFraction > 1) then
		return nil, "evaluation returned out-of-range ProgressFraction"
	end
	if result.Tokens ~= nil and type(result.Tokens) ~= "table" then
		return nil, "evaluation Tokens must be a table"
	end
	local tokenCount = 0
	for key, value in pairs(result.Tokens or {}) do
		tokenCount += 1
		if
			tokenCount > 16
			or type(key) ~= "string"
			or not ({ string = true, number = true, boolean = true })[type(value)]
			or type(value) == "number" and (value ~= value or value == math.huge or value == -math.huge)
			or type(value) == "string" and #value > 256
		then
			return nil, "evaluation returned invalid Tokens"
		end
	end
	return result, phaseRanks[result.Phase]
end

function Registry.All()
	return MODULES
end

return table.freeze(Registry)
