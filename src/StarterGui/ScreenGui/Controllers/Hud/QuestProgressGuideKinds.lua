-- Reusable guide-kind/navigation coordinator for protocol v2. Low-level Studio
-- target lookup is injected by Stage E; this module owns no step IDs or UI trees.

local QuestProgressGuideKinds = {}
QuestProgressGuideKinds.__index = QuestProgressGuideKinds

local function clone(value)
	if type(value) ~= "table" then return value end
	local result = {}
	for key, child in pairs(value) do result[key] = clone(child) end
	return result
end

local function definitionAndStep(content, context)
	local instance = context and context.Instance
	local stepState = context and context.Step
	local definition = instance and content.DefinitionsById[instance.DefinitionId]
	return definition, definition and stepState and definition.StepById[stepState.StepId]
end

local function navigationPath(guide, projection)
	if guide.Kind == "StoreRow" then
		if projection and projection.Phase == "Saving" and guide.SavingTargetId then
			return {
				{ Kind = "Cookie", TargetId = guide.SavingTargetId, Style = "HighlightPointer", Frame = "CookieHighlight" },
			}
		end
		local path = {
			{ Kind = "StoreOpenPath", TargetId = guide.Surface or "Mixer", Style = "Pointer", Frame = "Pointer" },
		}
		if guide.Category then
			table.insert(path, {
				Kind = "UiControl",
				TargetId = guide.Category,
				Role = "StoreCategory",
				Style = "Pointer",
				Frame = "Pointer",
			})
		end
		table.insert(path, {
			Kind = "StoreRow",
			TargetId = guide.TargetId,
			CompletionRole = guide.PlacementControlId and "PlacementActive" or nil,
			Style = guide.Style,
			Frame = guide.Frame,
		})
		if guide.PlacementControlId then
			table.insert(path, {
				Kind = "UiControl",
				TargetId = guide.PlacementControlId,
				Role = "PlacementControl",
				Style = "Pointer",
				Frame = "Pointer",
			})
		end
		return path
	elseif guide.Kind == "UiControl" then
		local path = {}
		if guide.Surface then
			table.insert(path, {
				Kind = "StoreOpenPath",
				TargetId = guide.Surface,
				Style = "Pointer",
				Frame = "Pointer",
			})
		end
		table.insert(path, clone(guide))
		return path
	elseif guide.Kind == "PlacedBuilding" then
		local path = {}
		if guide.Surface then
			table.insert(path, {
				Kind = "StoreOpenPath",
				TargetId = guide.Surface,
				Style = "Pointer",
				Frame = "Pointer",
			})
		end
		if guide.ModeControlId then
			table.insert(path, {
				Kind = "UiControl",
				TargetId = guide.ModeControlId,
				Role = "ModeControl",
				Style = "Pointer",
				Frame = "Pointer",
			})
		end
		table.insert(path, clone(guide))
		return path
	end
	return { clone(guide) }
end

local function targetCall(targets, name, ...)
	local callback = targets and targets[name]
	if type(callback) ~= "function" then return nil end
	return callback(...)
end

local function resolveNode(targets, node, context)
	if node.Kind == "StoreOpenPath" then
		if targetCall(targets, "IsSurfaceOpen", node.TargetId, context) == true then return "Complete" end
		local target = targetCall(targets, "SurfaceControl", node.TargetId, context)
		return target and "Target" or "Unavailable", target
	elseif node.Kind == "UiControl" then
		if node.Role == "StoreCategory"
			and targetCall(targets, "IsCategoryActive", node.TargetId, context) == true
		then
			return "Complete"
		elseif node.Role == "ModeControl"
			and targetCall(targets, "IsModeActive", node.TargetId, context) == true
		then
			return "Complete"
		end
		local target = targetCall(targets, "UiControl", node.TargetId, node, context)
		return target and "Target" or "Unavailable", target
	elseif node.Kind == "StoreRow" then
		if targetCall(targets, "IsStoreRowComplete", node.TargetId, node, context) == true then
			return "Complete"
		end
		local target = targetCall(targets, "StoreRow", node.TargetId, node, context)
		return target and "Target" or "Unavailable", target
	elseif node.Kind == "Cookie" then
		local target = targetCall(targets, "Cookie", node, context)
		return target and "Target" or "Unavailable", target
	elseif node.Kind == "Dialogue" then
		local target = targetCall(targets, "Dialogue", node.TargetId, node, context)
		return target and "Target" or "Unavailable", target
	elseif node.Kind == "PlacedBuilding" then
		local target = targetCall(targets, "PlacedBuilding", node.UpgradeId, node, context)
		return target and "Target" or "Unavailable", target
	elseif node.Kind == "WorldPosition" or node.Kind == "WorldObject" or node.Kind == "OffscreenWorldTarget" then
		local target = targetCall(targets, node.Kind, node.TargetId, node, context)
		return target and "Target" or "Unavailable", target
	end
	return "Unavailable"
end

function QuestProgressGuideKinds.new(config)
	assert(type(config) == "table" and type(config.Content) == "table", "guide kinds need content")
	assert(type(config.Show) == "function", "guide kinds need a visual adapter")
	assert(type(config.Targets) == "table" or type(config.Resolve) == "function", "guide kinds need target resolvers")
	return setmetatable({
		Content = config.Content,
		Resolve = config.Resolve or function(node, context)
			return resolveNode(config.Targets, node, context)
		end,
		Show = config.Show,
		Hide = config.Hide,
		Refresh = config.Refresh,
		ActiveCancel = nil,
	}, QuestProgressGuideKinds)
end

function QuestProgressGuideKinds:ResolvePath(context)
	local _, step = definitionAndStep(self.Content, context)
	local guide = step and step.Presentation and step.Presentation.Guide
	if not guide then return {}, nil end
	local projection = context.Step and context.Step.Projection
		or context.Transition and context.Transition.Projection
	return navigationPath(guide, projection), guide
end

function QuestProgressGuideKinds:Start(context, done)
	self:Stop(context, function() end)
	local path, guide = self:ResolvePath(context)
	if not guide then
		done("completed")
		return function() end
	end
	local visualCancel
	local refreshCancel
	local activeTarget
	local activeNode
	local finished = false
	local function sameTarget(first, second)
		if first == second then return true end
		return type(first) == "table" and type(second) == "table"
			and first.Kind == second.Kind and first.Value == second.Value
	end
	local function refresh()
		local nextNode, nextTarget
		for _, node in ipairs(path) do
			local status, target = self.Resolve(node, context)
			if status ~= "Complete" then
				if status == "Target" and target ~= nil then
					nextNode, nextTarget = node, target
				end
				break
			end
		end
		if nextNode == activeNode and sameTarget(nextTarget, activeTarget) then return end
		if visualCancel then pcall(visualCancel, "target-changed"); visualCancel = nil end
		activeNode, activeTarget = nextNode, nextTarget
		if nextNode then
			local cancel = self.Show(nextTarget, nextNode, context)
			visualCancel = type(cancel) == "function" and cancel or nil
		elseif self.Hide then
			pcall(self.Hide, "target-unavailable")
		end
	end
	local function cancel(reason)
		if finished then return end
		finished = true
		if refreshCancel then pcall(refreshCancel); refreshCancel = nil end
		if visualCancel then pcall(visualCancel, reason or "stopped"); visualCancel = nil end
		activeNode, activeTarget = nil, nil
	end
	refresh()
	if type(self.Refresh) == "function" then
		refreshCancel = self.Refresh(refresh)
		self.ActiveCancel = cancel
		done("completed")
		return cancel
	end
	if not activeNode then
		done("unavailable")
		return function() end
	end
	self.ActiveCancel = cancel
	done("completed")
	return cancel
end

function QuestProgressGuideKinds:Stop(_, done, reason)
	if self.ActiveCancel then
		pcall(self.ActiveCancel, reason or "stopped")
		self.ActiveCancel = nil
	end
	if type(self.Hide) == "function" then pcall(self.Hide, reason or "stopped") end
	if done then done("completed") end
end

return QuestProgressGuideKinds
