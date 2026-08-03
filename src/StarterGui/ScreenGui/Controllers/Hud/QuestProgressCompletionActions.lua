-- Resolves declarative step-completion actions and dispatches them through
-- reusable client adapters. Transition identity selects content; quest IDs are
-- never special-cased here.

local QuestProgressCompletionActions = {}
QuestProgressCompletionActions.__index = QuestProgressCompletionActions

function QuestProgressCompletionActions.new(config)
	return setmetatable({
		Content = assert(config.Content, "completion actions need content"),
		Adapters = config.Adapters or {},
		OnDiagnostic = config.OnDiagnostic,
	}, QuestProgressCompletionActions)
end

function QuestProgressCompletionActions:Run(context)
	local transition = context and context.Transition or {}
	local definition = self.Content.DefinitionsById[transition.DefinitionId]
	local step = definition and definition.StepById[transition.StepId]
	local declaration = step and step.Presentation and step.Presentation.CompletionAction
	if not declaration then return true end
	local adapter = self.Adapters[declaration.Kind]
	if type(adapter) ~= "function" then
		if self.OnDiagnostic then self.OnDiagnostic("missing adapter for " .. tostring(declaration.Kind)) end
		return false
	end
	local ok, problem = pcall(adapter, declaration.Params, context)
	if not ok and self.OnDiagnostic then self.OnDiagnostic(tostring(problem)) end
	return ok
end

return QuestProgressCompletionActions
