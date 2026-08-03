-- Generic named completion boundary for feature-owned Mixer/world/UI presentations.
-- It remembers completion so a late waiter can never be stranded.

local QuestProgressPresentationSignals = {}
QuestProgressPresentationSignals.__index = QuestProgressPresentationSignals

local function validName(name)
	return type(name) == "string" and #name > 0 and #name <= 96 and string.match(name, "^[%w_:%-%.]+$") ~= nil
end

function QuestProgressPresentationSignals.new()
	return setmetatable({
		Completed = {},
		Unavailable = {},
		Waiters = {},
	}, QuestProgressPresentationSignals)
end

function QuestProgressPresentationSignals:Wait(name, callback)
	assert(validName(name), "invalid presentation signal name")
	assert(type(callback) == "function", "presentation signal callback required")
	if self.Completed[name] ~= nil then
		callback("already-completed", self.Completed[name])
		return function() end
	end
	if self.Unavailable[name] ~= nil then
		callback("unavailable", self.Unavailable[name])
		return function() end
	end
	local waiters = self.Waiters[name]
	if not waiters then
		waiters = {}
		self.Waiters[name] = waiters
	end
	local entry = { Callback = callback, Active = true }
	table.insert(waiters, entry)
	return function()
		entry.Active = false
	end
end

function QuestProgressPresentationSignals:_resolve(name, status, payload)
	assert(validName(name), "invalid presentation signal name")
	if status == "completed" then
		self.Completed[name] = payload == nil and true or payload
		self.Unavailable[name] = nil
	else
		self.Unavailable[name] = payload == nil and true or payload
		self.Completed[name] = nil
	end
	local waiters = self.Waiters[name]
	self.Waiters[name] = nil
	for _, entry in ipairs(waiters or {}) do
		if entry.Active then
			entry.Active = false
			entry.Callback(status, payload)
		end
	end
end

function QuestProgressPresentationSignals:Complete(name, payload)
	self:_resolve(name, "completed", payload)
end

function QuestProgressPresentationSignals:UnavailableSignal(name, reason)
	self:_resolve(name, "unavailable", reason)
end

function QuestProgressPresentationSignals:Reset(name)
	assert(validName(name), "invalid presentation signal name")
	self.Completed[name] = nil
	self.Unavailable[name] = nil
end

function QuestProgressPresentationSignals:IsCompleted(name)
	return self.Completed[name] ~= nil
end

return QuestProgressPresentationSignals
