-- Closed, server-authored vocabulary accepted by the universal quest boundary.
-- Payloads contain committed primitive facts only; clients never name quest content.

local DomainEvents = {}
local UiObservations = require(script.Parent.UiObservations)

local MAX_ID_LENGTH = 96
local MAX_SOURCE_LENGTH = 48

local EVENT_KINDS = {
	StoryAdvanced = true,
	IntroCompleted = true,
	HealingProgressChanged = true,
	BuildingPlaced = true,
	BuildingCountChanged = true,
	BuildingSold = true,
	CookieBalanceChanged = true,
	UpgradePurchased = true,
	GemBalanceChanged = true,
	BoostPurchased = true,
	BoostFieldDropped = true,
	UiObservation = true,
}

local COMMIT_STATES = {
	Committed = true,
	PendingPurchase = true,
	RefundPending = true,
}

local function finite(value)
	return type(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge
end

local function integer(value, minimum, maximum)
	return finite(value) and value % 1 == 0 and value >= minimum and value <= maximum
end

local function id(value)
	return type(value) == "string"
		and #value > 0
		and #value <= MAX_ID_LENGTH
		and string.match(value, "^[%w_:%-%. ]+$") ~= nil
end

local function optionalId(value)
	return value == nil or id(value)
end

local function exactKeys(payload, allowed)
	if type(payload) ~= "table" then
		return false, "payload must be a table"
	end
	for key in pairs(payload) do
		if type(key) ~= "string" or not allowed[key] then
			return false, "unknown payload field " .. tostring(key)
		end
	end
	return true
end

local validators = {}

validators.StoryAdvanced = function(payload)
	local ok, problem = exactKeys(payload, { PreviousStep = true, StoryStep = true })
	if not ok then
		return false, problem
	end
	return id(payload.StoryStep) and optionalId(payload.PreviousStep), "invalid story step"
end

validators.IntroCompleted = function(payload)
	return exactKeys(payload, {})
end

validators.HealingProgressChanged = function(payload)
	local ok, problem = exactKeys(payload, { AcceptedClicks = true, SequenceCompleted = true })
	if not ok then
		return false, problem
	end
	if not integer(payload.AcceptedClicks, 0, 1000000) then
		return false, "invalid accepted click count"
	end
	if payload.SequenceCompleted ~= nil and type(payload.SequenceCompleted) ~= "boolean" then
		return false, "invalid sequence completion flag"
	end
	return true
end

local function validateUpgradeCount(payload, extra)
	local allowed = { UpgradeId = true, Count = true }
	for key in pairs(extra or {}) do
		allowed[key] = true
	end
	local ok, problem = exactKeys(payload, allowed)
	if not ok then
		return false, problem
	end
	if not id(payload.UpgradeId) then
		return false, "invalid upgrade id"
	end
	if not integer(payload.Count, 0, 1000000000) then
		return false, "invalid upgrade count"
	end
	return true
end

validators.BuildingPlaced = function(payload)
	local ok, problem = validateUpgradeCount(payload, { FloorId = true })
	if not ok then
		return false, problem
	end
	return optionalId(payload.FloorId), "invalid floor id"
end

validators.BuildingCountChanged = function(payload)
	return validateUpgradeCount(payload)
end

validators.BuildingSold = function(payload)
	local ok, problem = validateUpgradeCount(payload, { SoldCount = true })
	if not ok then
		return false, problem
	end
	return integer(payload.SoldCount, 1, 1000000000), "invalid sold count"
end

validators.CookieBalanceChanged = function(payload)
	local ok, problem = exactKeys(payload, { Balance = true, Source = true, CommitState = true })
	if not ok then
		return false, problem
	end
	if not finite(payload.Balance) or payload.Balance < 0 or payload.Balance > 1e300 then
		return false, "invalid cookie balance"
	end
	if type(payload.Source) ~= "string" or #payload.Source == 0 or #payload.Source > MAX_SOURCE_LENGTH then
		return false, "invalid cookie source"
	end
	if not COMMIT_STATES[payload.CommitState] then
		return false, "invalid cookie commit state"
	end
	return true
end

validators.UpgradePurchased = function(payload)
	return validateUpgradeCount(payload)
end

validators.GemBalanceChanged = function(payload)
	local ok, problem = exactKeys(payload, { Balance = true, Source = true })
	if not ok then return false, problem end
	return integer(payload.Balance, 0, 1000000000)
		and type(payload.Source) == "string"
		and #payload.Source > 0
		and #payload.Source <= MAX_SOURCE_LENGTH,
		"invalid gem balance change"
end

validators.BoostPurchased = function(payload)
	local ok, problem = exactKeys(payload, { ItemId = true, ChargeCount = true })
	if not ok then
		return false, problem
	end
	return id(payload.ItemId) and integer(payload.ChargeCount, 0, 1000000), "invalid boost purchase"
end

validators.BoostFieldDropped = function(payload)
	local ok, problem = exactKeys(payload, {
		ItemId = true,
		FloorId = true,
		OwnerUserId = true,
		DropperUserId = true,
	})
	if not ok then
		return false, problem
	end
	return id(payload.ItemId) and id(payload.FloorId) and integer(payload.OwnerUserId, 1, 9007199254740991) and integer(
		payload.DropperUserId,
		1,
		9007199254740991
	),
		"invalid boost field drop"
end

validators.UiObservation = function(payload)
	local ok, problem = exactKeys(payload, { Observation = true })
	if not ok then
		return false, problem
	end
	return id(payload.Observation) and UiObservations.IsAllowed(payload.Observation), "invalid or unallowlisted observation"
end

function DomainEvents.IsKnown(kind)
	return EVENT_KINDS[kind] == true
end

function DomainEvents.IsCommitted(event)
	return event.Kind ~= "CookieBalanceChanged" or event.Payload.CommitState == "Committed"
end

function DomainEvents.Validate(kind, payload, timestamp)
	if not EVENT_KINDS[kind] then
		return nil, "unknown domain event " .. tostring(kind)
	end
	if not finite(timestamp) or timestamp < 0 then
		return nil, "cause timestamp must be finite and non-negative"
	end
	local ok, problem = validators[kind](payload)
	if not ok then
		return nil, ("invalid %s payload: %s"):format(kind, tostring(problem))
	end
	return {
		Kind = kind,
		Payload = payload,
		Timestamp = timestamp,
	}
end

function DomainEvents.Kinds()
	local result = {}
	for kind in pairs(EVENT_KINDS) do
		table.insert(result, kind)
	end
	table.sort(result)
	return result
end

return table.freeze(DomainEvents)
