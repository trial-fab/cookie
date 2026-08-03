local DomainEvents = require(script.Parent.Parent.DomainEvents)
local Util = require(script.Parent.Util)
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

local LIVE_PROGRESS_SOURCES = {
	CookieBalance = true,
	GemBalance = true,
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

local function triggerSet(values)
	local result = {}
	for _, trigger in ipairs(values) do result[trigger] = true end
	return result
end

local function validateLiveProgress(module, phases)
	local declaration = module.LiveProgress
	if declaration == nil then return end
	if type(declaration) ~= "table" then fail(module.Kind .. " has invalid LiveProgress") end
	for key in pairs(declaration) do
		if key ~= "Source" and key ~= "Phases" then
			fail(module.Kind .. " LiveProgress has unknown field " .. tostring(key))
		end
	end
	if not LIVE_PROGRESS_SOURCES[declaration.Source] then
		fail(module.Kind .. " has unknown live progress source " .. tostring(declaration.Source))
	end
	if type(declaration.Phases) ~= "table" or #declaration.Phases < 1 or #declaration.Phases > 16 then
		fail(module.Kind .. " has invalid live progress phases")
	end
	local seen = {}
	for _, phase in ipairs(declaration.Phases) do
		if type(phase) ~= "string" or not phases[phase] or seen[phase] then
			fail(module.Kind .. " has unknown or duplicate live progress phase")
		end
		seen[phase] = true
	end
end

local function validatePhaseSubset(module, field, phases)
	local values = module[field]
	if values == nil then return end
	if type(values) ~= "table" or #values < 1 or #values > 16 then
		fail(module.Kind .. " has invalid " .. field)
	end
	local seen = {}
	for _, phase in ipairs(values) do
		if type(phase) ~= "string" or not phases[phase] or seen[phase] then
			fail(module.Kind .. " has unknown or duplicate " .. field .. " phase")
		end
		seen[phase] = true
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
	validateTriggers(module, "ActiveTriggers")
	validateTriggers(module, "CaptureTriggers")
	local activeTriggerSet = triggerSet(module.ActiveTriggers)
	for _, trigger in ipairs(module.CaptureTriggers) do
		if not activeTriggerSet[trigger] then
			fail(module.Kind .. " capture trigger is not active: " .. trigger)
		end
	end
	if #module.CaptureTriggers > 0 and type(module.Capture) ~= "function" then
		fail(module.Kind .. " declares capture triggers without Capture")
	end
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
	validateLiveProgress(module, phases)
	validatePhaseSubset(module, "ProgressBarPhases", phases)
	phaseRanksByKind[module.Kind] = phases
	byKind[module.Kind] = module
	for _, trigger in ipairs(module.ActiveTriggers) do
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
	if type(module.ActiveTriggers) ~= "table" or type(module.CaptureTriggers) ~= "table" then
		return false, "invalid triggers"
	end
	local activeTriggers = {}
	for _, field in ipairs({ "ActiveTriggers", "CaptureTriggers" }) do
		local seen = {}
		for _, trigger in ipairs(module[field]) do
			if not DomainEvents.IsKnown(trigger) or seen[trigger] then
				return false, "unknown or duplicate trigger"
			end
			seen[trigger] = true
			if field == "ActiveTriggers" then activeTriggers[trigger] = true end
			if field == "CaptureTriggers" and not activeTriggers[trigger] then
				return false, "capture trigger is not active"
			end
		end
	end
	if #module.CaptureTriggers > 0 and type(module.Capture) ~= "function" then
		return false, "missing capture function"
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
	if module.LiveProgress ~= nil then
		if type(module.LiveProgress) ~= "table" or not LIVE_PROGRESS_SOURCES[module.LiveProgress.Source]
			or type(module.LiveProgress.Phases) ~= "table" or #module.LiveProgress.Phases < 1
		then
			return false, "invalid live progress"
		end
		local seen = {}
		for _, phase in ipairs(module.LiveProgress.Phases) do
			if not phases[phase] or seen[phase] then return false, "invalid live progress phase" end
			seen[phase] = true
		end
		for key in pairs(module.LiveProgress) do
			if key ~= "Source" and key ~= "Phases" then return false, "invalid live progress field" end
		end
	end
	if module.ProgressBarPhases ~= nil then
		if type(module.ProgressBarPhases) ~= "table" or #module.ProgressBarPhases < 1 then
			return false, "invalid progress bar phases"
		end
		local seen = {}
		for _, phase in ipairs(module.ProgressBarPhases) do
			if not phases[phase] or seen[phase] then return false, "invalid progress bar phase" end
			seen[phase] = true
		end
	end
	return true
end

function Registry.ShowsProgressBar(objective, projection)
	local module = type(objective) == "table" and byKind[objective.Kind]
	if module and module.ProgressBarPhases then
		for _, phase in ipairs(module.ProgressBarPhases) do
			if projection and projection.Phase == phase then return true end
		end
		return false
	end
	return (tonumber(projection and projection.Target) or 1) > 1
end

function Registry.ResolveLiveProgress(objective, projection, liveFacts)
	local module = type(objective) == "table" and byKind[objective.Kind]
	local declaration = module and module.LiveProgress
	if not declaration or type(projection) ~= "table" or type(liveFacts) ~= "table" then return projection end
	local enabled = false
	for _, phase in ipairs(declaration.Phases) do
		if projection.Phase == phase then
			enabled = true
			break
		end
	end
	if not enabled then return projection end
	local live = tonumber(liveFacts[declaration.Source])
	local target = tonumber(projection.Target)
	if not Util.finite(live) or not Util.finite(target) or target <= 0 then return projection end
	local current = math.clamp(math.floor(live), 0, target)
	if current == tonumber(projection.Current) then return projection end
	local result = {}
	for key, value in pairs(projection) do result[key] = value end
	result.Current = current
	result.ProgressFraction = nil
	if type(projection.Tokens) == "table" then
		result.Tokens = {}
		for key, value in pairs(projection.Tokens) do result.Tokens[key] = value end
		result.Tokens.Current = current
	end
	return result
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
