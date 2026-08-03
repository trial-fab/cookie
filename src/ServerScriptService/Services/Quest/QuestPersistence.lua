-- Owns only the fresh universal quest field. It never reads or migrates QuestState v3.

local QuestPersistence = {}
QuestPersistence.__index = QuestPersistence

function QuestPersistence.new(config)
	assert(type(config) == "table" and type(config.GetData) == "function", "QuestPersistence needs GetData")
	assert(type(config.Schema) == "table" and type(config.Content) == "table", "QuestPersistence needs schema/content")
	return setmetatable(config, QuestPersistence)
end

function QuestPersistence:Load(player, reason)
	local data = self.GetData(player)
	local persistent = type(data) == "table" and data.Persistent
	if type(persistent) ~= "table" then
		return nil
	end
	if reason == "Reset" then
		persistent.UniversalQuestState = nil
	end
	local ok, state, contentChanged = pcall(self.Schema.NormalizeState, persistent.UniversalQuestState, self.Content)
	if not ok then
		warn("Universal quest state rejected: " .. tostring(state))
		return nil
	end
	persistent.UniversalQuestState = state
	return {
		Data = data,
		Persistent = persistent,
		State = state,
		ContentChanged = contentChanged,
	}
end

function QuestPersistence:Save(_, context)
	if type(context) ~= "table" or type(context.Persistent) ~= "table" or type(context.State) ~= "table" then
		return false
	end
	context.Persistent.UniversalQuestState = context.State
	return true
end

return QuestPersistence
