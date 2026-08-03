-- One canonical read boundary for tracked copy, replay, and optional Help surfaces.

local QuestCopy = require(script.Parent.QuestCopy)

local QuestContentReader = {}

function QuestContentReader.RenderStep(content, definitionId, stepId, projection, context)
	local definition = content and content.DefinitionsById[definitionId]
	local step = definition and definition.StepById[stepId]
	if not step then return nil, "unknown quest step" end
	return QuestCopy.Render(step.Copy, projection, context)
end

function QuestContentReader.BuildHelp(content, definitionId, projectionsByStep, context)
	local definition = content and content.DefinitionsById[definitionId]
	if not definition or not definition.Help or definition.Help.Enabled ~= true then
		return nil, "help is not enabled"
	end
	local steps = {}
	for _, step in ipairs(definition.Steps) do
		local projection = projectionsByStep and projectionsByStep[step.Id]
		local objective = projection and QuestCopy.Render(step.Copy, projection, context) or nil
		table.insert(steps, {
			StepId = step.Id,
			Title = QuestCopy.ResolveLocalized(step.Title, context),
			Objective = objective,
		})
	end
	return {
		DefinitionId = definition.Id,
		Title = QuestCopy.ResolveLocalized(definition.Title, context),
		Lesson = QuestCopy.ResolveLocalized(definition.Lesson, context),
		Steps = steps,
	}
end

function QuestContentReader.BuildReplay(content, definitionId, projectionsByStep, context)
	local definition = content and content.DefinitionsById[definitionId]
	if not definition or not definition.Replay or definition.Replay.Enabled ~= true then
		return nil, "replay is not enabled"
	end
	local result, problem = QuestContentReader.BuildHelp(content, definitionId, projectionsByStep, context)
	if not result then return nil, problem end
	result.Terminal = QuestCopy.ResolveLocalized(definition.Replay.Terminal, context)
	result.RewardLabel = QuestCopy.ResolveLocalized(definition.Replay.RewardLabel, context)
	result.RewardValue = QuestCopy.ResolveLocalized(definition.Replay.RewardValue, context)
	return result
end

return table.freeze(QuestContentReader)
