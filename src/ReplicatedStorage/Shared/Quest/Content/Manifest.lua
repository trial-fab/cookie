-- Shipping manifest for the protocol-v2 universal quest service.

local QuestSchema = require(script.Parent.Parent.QuestSchema)
local Objectives = require(script.Parent.Parent.Objectives.Registry)
local Rewards = require(script.Parent.Parent.Rewards.Registry)
local authored = require(script.Parent.OpeningTutorial)

return QuestSchema.ValidateManifest(authored, Objectives, Rewards)
