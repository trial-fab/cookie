-- Localization-ready quest copy validation and fallback rendering. Authority sends
-- structured projections only; this module resolves typed tokens on the client.

local QuestCopy = {}

local INPUT_KINDS = {
	Default = true,
	Keyboard = true,
	Touch = true,
	Gamepad = true,
}

local TOKEN_TYPES = {
	String = true,
	Number = true,
	Boolean = true,
	UpgradeDisplayName = true,
}

local function exactKeys(value, allowed, label)
	if type(value) ~= "table" then
		return false, label .. " must be a table"
	end
	for key in pairs(value) do
		if type(key) ~= "string" or not allowed[key] then
			return false, label .. " has unknown field " .. tostring(key)
		end
	end
	return true
end

local function localized(value, label)
	local ok, problem = exactKeys(value, { Key = true, Fallback = true }, label)
	if not ok then
		return false, problem
	end
	if type(value.Key) ~= "string" or #value.Key < 1 or #value.Key > 160 then
		return false, label .. " has an invalid localization key"
	end
	if type(value.Fallback) ~= "string" or #value.Fallback < 1 or #value.Fallback > 500 then
		return false, label .. " has an invalid localization fallback"
	end
	return true
end

local function tokenName(value)
	return type(value) == "string" and #value <= 48 and string.match(value, "^[A-Z][A-Za-z0-9]*$") ~= nil
end

local function validatePhrase(phrase, label, root)
	local allowed = { Default = true, Variants = true }
	if root then
		allowed.Phases = true
		allowed.Tokens = true
		allowed.Progress = true
	end
	local ok, problem = exactKeys(phrase, allowed, label)
	if not ok then
		return false, problem
	end
	ok, problem = localized(phrase.Default, label .. " default")
	if not ok then
		return false, problem
	end
	if phrase.Variants ~= nil then
		if type(phrase.Variants) ~= "table" then
			return false, label .. " variants must be a table"
		end
		for inputKind, value in pairs(phrase.Variants) do
			if inputKind == "Default" or not INPUT_KINDS[inputKind] then
				return false, label .. " has an invalid device variant"
			end
			ok, problem = localized(value, label .. " " .. inputKind)
			if not ok then
				return false, problem
			end
		end
	end
	return true
end

local function eachFallback(copy, callback)
	local function phraseFallbacks(phrase)
		callback(phrase.Default.Fallback)
		for _, variant in pairs(phrase.Variants or {}) do
			callback(variant.Fallback)
		end
	end
	phraseFallbacks(copy)
	for _, phrase in pairs(copy.Phases or {}) do
		phraseFallbacks(phrase)
	end
	if copy.Progress then
		callback(copy.Progress.Template.Fallback)
	end
end

function QuestCopy.Validate(copy, validPhases)
	local ok, problem = exactKeys(copy, {
		Default = true,
		Variants = true,
		Phases = true,
		Tokens = true,
		Progress = true,
	}, "copy")
	if not ok then
		return false, problem
	end
	ok, problem = validatePhrase(copy, "copy", true)
	if not ok then
		return false, problem
	end

	if type(copy.Tokens) ~= "table" then
		return false, "copy needs typed tokens"
	end
	local tokenCount = 0
	for name, descriptor in pairs(copy.Tokens) do
		tokenCount += 1
		if tokenCount > 16 or not tokenName(name) then
			return false, "copy has an invalid or unbounded token name"
		end
		ok, problem = exactKeys(descriptor, { Type = true, Source = true, Value = true }, "copy token")
		if not ok then
			return false, problem
		end
		local hasSource = descriptor.Source ~= nil
		local hasValue = descriptor.Value ~= nil
		if not TOKEN_TYPES[descriptor.Type]
			or hasSource == hasValue
			or hasSource and not tokenName(descriptor.Source)
			or hasValue and not ({ string = true, number = true, boolean = true })[type(descriptor.Value)]
		then
			return false, "copy token has an invalid type or source"
		end
	end

	for phase, phrase in pairs(copy.Phases or {}) do
		if type(validPhases) ~= "table" or not validPhases[phase] then
			return false, "copy names an unknown objective phase " .. tostring(phase)
		end
		ok, problem = validatePhrase(phrase, "phase copy")
		if not ok then
			return false, problem
		end
	end

	if copy.Progress ~= nil then
		ok, problem = exactKeys(copy.Progress, { Kind = true, Template = true, Phases = true }, "structural progress")
		if not ok then
			return false, problem
		end
		if copy.Progress.Kind ~= "CountUp" and copy.Progress.Kind ~= "CountDown" then
			return false, "unknown structural progress kind"
		end
		ok, problem = localized(copy.Progress.Template, "structural progress template")
		if not ok then
			return false, problem
		end
		if copy.Progress.Phases ~= nil then
			if type(copy.Progress.Phases) ~= "table" or #copy.Progress.Phases < 1 or #copy.Progress.Phases > 16 then
				return false, "structural progress phases must be a bounded array"
			end
			local seen = {}
			for _, phase in ipairs(copy.Progress.Phases) do
				if seen[phase] or type(validPhases) ~= "table" or not validPhases[phase] then
					return false, "structural progress names an unknown or duplicate phase"
				end
				seen[phase] = true
			end
		end
	end

	local referenced = {}
	eachFallback(copy, function(fallback)
		for name in string.gmatch(fallback, "{([A-Za-z][A-Za-z0-9]*)}") do
			referenced[name] = true
		end
		if string.find(fallback, "{", 1, true) or string.find(fallback, "}", 1, true) then
			local stripped = string.gsub(fallback, "{[A-Za-z][A-Za-z0-9]*}", "")
			if string.find(stripped, "{", 1, true) or string.find(stripped, "}", 1, true) then
				referenced.__Invalid = true
			end
		end
	end)
	if referenced.__Invalid then
		return false, "copy has malformed token syntax"
	end
	for name in pairs(referenced) do
		if not copy.Tokens[name] then
			return false, "copy references undeclared token " .. tostring(name)
		end
	end
	for name in pairs(copy.Tokens) do
		if not referenced[name] then
			return false, "copy declares unused token " .. name
		end
	end
	return true
end

local function choosePhrase(copy, phase)
	return type(copy.Phases) == "table" and copy.Phases[phase] or copy
end

local function chooseLocalized(phrase, inputKind)
	return type(phrase.Variants) == "table" and phrase.Variants[inputKind] or phrase.Default
end

local function sourceValue(projection, source)
	if source == "Remaining" then
		local current = tonumber(projection and projection.Current) or 0
		local target = tonumber(projection and projection.Target) or 0
		return math.max(0, target - current)
	end
	if type(projection) ~= "table" then
		return nil
	end
	if projection[source] ~= nil then
		return projection[source]
	end
	return type(projection.Tokens) == "table" and projection.Tokens[source] or nil
end

local function resolveTokens(copy, projection, context)
	local result = {}
	for name, descriptor in pairs(copy.Tokens) do
		local value = descriptor.Value
		if value == nil then value = sourceValue(projection, descriptor.Source) end
		if descriptor.Type == "UpgradeDisplayName" then
			local resolver = context and context.ResolveUpgradeDisplayName
			value = type(resolver) == "function" and resolver(value) or nil
		end
		if descriptor.Type == "Number" then
			value = tonumber(value)
			if value == nil or value ~= value or value == math.huge or value == -math.huge then
				return nil, "copy token " .. name .. " is not a finite number"
			end
			local formatter = context and context.FormatNumber
			value = type(formatter) == "function" and formatter(value) or tostring(value)
		elseif descriptor.Type == "Boolean" then
			if type(value) ~= "boolean" then
				return nil, "copy token " .. name .. " is not boolean"
			end
			value = tostring(value)
		elseif type(value) ~= "string" or value == "" then
			return nil, "copy token " .. name .. " is not a non-empty string"
		end
		result[name] = value
	end
	return result
end

local function interpolate(fallback, tokens)
	return (string.gsub(fallback, "{([A-Za-z][A-Za-z0-9]*)}", function(name)
		return tokens[name] or ""
	end))
end

local function localize(value, context)
	local resolver = context and context.Localize
	if type(resolver) == "function" then
		local resolved = resolver(value.Key, value.Fallback)
		if type(resolved) == "string" and resolved ~= "" then
			return resolved
		end
	end
	return value.Fallback
end

function QuestCopy.Render(copy, projection, context)
	context = context or {}
	local tokens, problem = resolveTokens(copy, projection or {}, context)
	if not tokens then
		return nil, problem
	end
	local phase = projection and projection.Phase
	local phrase = choosePhrase(copy, phase)
	local inputKind = INPUT_KINDS[context.InputKind] and context.InputKind or "Default"
	local text = interpolate(localize(chooseLocalized(phrase, inputKind), context), tokens)
	local progress = copy.Progress
	if progress then
		local show = progress.Phases == nil
		for _, allowedPhase in ipairs(progress.Phases or {}) do
			if allowedPhase == phase then
				show = true
			end
		end
		if show then
			text ..= " " .. interpolate(localize(progress.Template, context), tokens)
		end
	end
	return text
end

function QuestCopy.Fallback(localizedValue)
	return type(localizedValue) == "table" and localizedValue.Fallback or ""
end

function QuestCopy.ResolveLocalized(localizedValue, context)
	if type(localizedValue) ~= "table" then return "" end
	return localize(localizedValue, context or {})
end

function QuestCopy.ProjectLocal(localProgress, current)
	if type(localProgress) ~= "table" or type(localProgress.Target) ~= "number" then
		return nil, "invalid local progress declaration"
	end
	local target = localProgress.Target
	current = math.clamp(math.floor(tonumber(current) or 0), 0, target)
	return {
		Satisfied = current >= target,
		Current = current,
		Target = target,
		Phase = current >= target and "Satisfied" or "Collecting",
		Tokens = { Current = current, Target = target },
	}
end

return table.freeze(QuestCopy)
