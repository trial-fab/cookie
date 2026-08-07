-- MusicQueue -- explicit playback order, repeat mode, and Previous history.
--
-- This module owns only what the player arranged: the explicit "Next in Queue"
-- list, the repeat/shuffle preferences, and the bounded history behind Previous.
-- Now Playing belongs to the director and the automatic "Up Next" tail belongs
-- to the selector, which is why shuffle can regenerate the tail without ever
-- reordering an explicit choice.
--
-- Queue command semantics (docs/music.md):
--   Play Now      plays immediately and leaves the upcoming explicit queue alone
--   Play Next     inserts at the front, so the newest choice is next and the
--                 previous ones keep their relative order behind it
--   Add to Queue  appends in selection order; duplicate track ids are allowed
--   Clear Queue   clears upcoming entries without stopping Now Playing
--   Repeat All    recycles consumed explicit entries so the list loops

local MusicTypes = require(script.Parent.MusicTypes)
local MusicConfig = require(script.Parent.MusicConfig)

local MusicQueue = {}
MusicQueue.__index = MusicQueue

function MusicQueue.new(config)
	return setmetatable({
		_config = config or MusicConfig.new(),
		_explicit = {},
		_recycled = {},
		_history = {},
		_repeatMode = MusicTypes.RepeatMode.Off,
		_shuffleEnabled = true,
	}, MusicQueue)
end

--[[ Explicit queue ]]

function MusicQueue:count()
	return #self._explicit
end

function MusicQueue:isEmpty()
	return #self._explicit == 0
end

function MusicQueue:list()
	return table.clone(self._explicit)
end

function MusicQueue:peek()
	return self._explicit[1]
end

function MusicQueue:isFull()
	return #self._explicit >= self._config.maxExplicitQueue
end

-- Play Next: front insert.
function MusicQueue:insertNext(trackId)
	if self:isFull() then
		return false
	end
	table.insert(self._explicit, 1, trackId)
	return true
end

-- Add to Queue: append.
function MusicQueue:append(trackId)
	if self:isFull() then
		return false
	end
	table.insert(self._explicit, trackId)
	return true
end

function MusicQueue:remove(index)
	index = tonumber(index)
	if not index or index < 1 or index > #self._explicit then
		return nil
	end
	return table.remove(self._explicit, index)
end

function MusicQueue:move(fromIndex, toIndex)
	fromIndex, toIndex = tonumber(fromIndex), tonumber(toIndex)
	local count = #self._explicit
	if not fromIndex or not toIndex then
		return false
	end
	if fromIndex < 1 or fromIndex > count or toIndex < 1 or toIndex > count or fromIndex == toIndex then
		return false
	end
	local entry = table.remove(self._explicit, fromIndex)
	table.insert(self._explicit, toIndex, entry)
	return true
end

function MusicQueue:clearUpcoming()
	local removed = #self._explicit
	self._explicit = {}
	self._recycled = {}
	return removed
end

-- Replaces the whole explicit queue (resume restore). Entries are assumed to be
-- already validated against the catalog and the player's unlocks.
function MusicQueue:setExplicit(trackIds)
	local result = {}
	for _, trackId in ipairs(trackIds or {}) do
		if type(trackId) == "string" and #result < self._config.maxExplicitQueue then
			table.insert(result, trackId)
		end
	end
	self._explicit = result
	self._recycled = {}
	return #result
end

-- Pops the next explicit entry. Under Repeat All consumed entries are recycled,
-- so an explicit list loops instead of draining into the station.
function MusicQueue:takeNext()
	if #self._explicit == 0 then
		if self._repeatMode == MusicTypes.RepeatMode.All and #self._recycled > 0 then
			self._explicit = self._recycled
			self._recycled = {}
		else
			return nil
		end
	end

	local trackId = table.remove(self._explicit, 1)
	if trackId and self._repeatMode == MusicTypes.RepeatMode.All then
		table.insert(self._recycled, trackId)
	end
	return trackId
end

--[[ Preferences ]]

function MusicQueue:setRepeatMode(mode)
	if not MusicTypes.RepeatMode[mode] or self._repeatMode == mode then
		return false
	end
	self._repeatMode = mode
	if mode ~= MusicTypes.RepeatMode.All then
		self._recycled = {}
	end
	return true
end

function MusicQueue:getRepeatMode()
	return self._repeatMode
end

function MusicQueue:setShuffleEnabled(enabled)
	enabled = enabled and true or false
	if self._shuffleEnabled == enabled then
		return false
	end
	self._shuffleEnabled = enabled
	return true
end

function MusicQueue:isShuffleEnabled()
	return self._shuffleEnabled
end

--[[ Previous history ]]

-- Story cues never enter this history: Previous walks the player's own listening
-- line, not the authored score.
function MusicQueue:pushHistory(trackId)
	if type(trackId) ~= "string" then
		return false
	end
	table.insert(self._history, 1, trackId)
	while #self._history > self._config.historyLimit do
		table.remove(self._history)
	end
	return true
end

function MusicQueue:popHistory()
	return table.remove(self._history, 1)
end

function MusicQueue:historyList()
	return table.clone(self._history)
end

function MusicQueue:historyCount()
	return #self._history
end

function MusicQueue:clearHistory()
	self._history = {}
end

return MusicQueue
