-- MusicRandom -- deterministic pseudo-random source for automatic selection.
--
-- The engine never calls Random.new or math.random directly: an injectable,
-- clonable generator is what lets the shuffled bag, Up Next preview, and the
-- unit tests produce identical sequences from identical state. xorshift32 is
-- more than good enough for picking songs and needs no Roblox globals.

local MusicRandom = {}
MusicRandom.__index = MusicRandom

local MASK = 0xFFFFFFFF
local SCALE = 4294967296 -- 2^32

local function normalizeSeed(seed)
	local value = tonumber(seed)
	if not value or value ~= value then
		value = os.time() * 1000 + math.floor(os.clock() * 1000)
	end
	value = math.floor(math.abs(value)) % SCALE
	if value == 0 then
		value = 0x9E3779B9
	end
	return bit32.band(value, MASK)
end

function MusicRandom.new(seed)
	return setmetatable({ _state = normalizeSeed(seed) }, MusicRandom)
end

function MusicRandom:clone()
	return setmetatable({ _state = self._state }, MusicRandom)
end

function MusicRandom:getState()
	return self._state
end

function MusicRandom:setState(state)
	self._state = normalizeSeed(state)
end

function MusicRandom:nextInteger32()
	local state = self._state
	state = bit32.bxor(state, bit32.lshift(state, 13))
	state = bit32.bxor(state, bit32.rshift(state, 17))
	state = bit32.bxor(state, bit32.lshift(state, 5))
	self._state = state
	return state
end

-- Uniform in [0, 1).
function MusicRandom:nextNumber()
	return self:nextInteger32() / SCALE
end

-- Uniform integer in [min, max].
function MusicRandom:nextInteger(min, max)
	if max < min then
		min, max = max, min
	end
	local span = max - min + 1
	return min + (self:nextInteger32() % span)
end

return MusicRandom
