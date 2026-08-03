-- Inactive Stage D Help adapter. Stage E may bind an authored Help surface; this
-- module supplies only canonical content and never constructs UI.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Content = require(ReplicatedStorage.Shared.Quest.Content.Manifest)
local ContentReader = require(ReplicatedStorage.Shared.Quest.QuestContentReader)

local QuestProgressHelp = {}

function QuestProgressHelp.Build(definitionId, projectionsByStep, context)
	return ContentReader.BuildHelp(Content, definitionId, projectionsByStep, context)
end

return QuestProgressHelp
