-- Schema: pure validation and deterministic normalization for DevTuning registries.
-- RegistryLoader supplies plain definition tables; this module has no DataModel dependencies.

local Schema = {}

local VALID_KINDS = {
	number = true,
	boolean = true,
	Color3 = true,
	enum = true,
	string = true,
}

local MAX_STRING_LENGTH = 500

local VALID_SCOPES = {
	server = true,
	client = true,
	shared = true,
}

local function isFiniteNumber(value)
	return type(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge
end

local function isIdentifier(value)
	return type(value) == "string" and string.match(value, "^[%a_][%w_]*$") ~= nil
end

local function isArray(value)
	if type(value) ~= "table" then
		return false
	end

	local count = 0
	for key in pairs(value) do
		if type(key) ~= "number" or key < 1 or key % 1 ~= 0 then
			return false
		end
		count += 1
	end

	return count == #value
end

local function fail(sourceName, message)
	return nil, ("DevTuning registry %q: %s"):format(sourceName, message)
end

local function validateDefault(sourceName, fullId, tunable)
	if tunable.kind == "number" then
		if not isFiniteNumber(tunable.default) then
			return fail(sourceName, fullId .. " default must be a finite number")
		end
		if not isFiniteNumber(tunable.min) or not isFiniteNumber(tunable.max) then
			return fail(sourceName, fullId .. " min and max must be finite numbers")
		end
		if tunable.min > tunable.max then
			return fail(sourceName, fullId .. " min must not exceed max")
		end
		if tunable.default < tunable.min or tunable.default > tunable.max then
			return fail(sourceName, fullId .. " default must be inside min/max")
		end
		if not isFiniteNumber(tunable.step) or tunable.step <= 0 then
			return fail(sourceName, fullId .. " step must be a positive finite number")
		end
	elseif tunable.kind == "boolean" then
		if type(tunable.default) ~= "boolean" then
			return fail(sourceName, fullId .. " default must be a boolean")
		end
	elseif tunable.kind == "string" then
		if type(tunable.default) ~= "string" then
			return fail(sourceName, fullId .. " default must be a string")
		end
		if
			type(tunable.maxLength) ~= "number"
			or tunable.maxLength % 1 ~= 0
			or tunable.maxLength < 1
			or tunable.maxLength > MAX_STRING_LENGTH
		then
			return fail(sourceName, fullId .. " maxLength must be an integer from 1 to 500")
		end
		local defaultLength = utf8.len(tunable.default)
		if not defaultLength then
			return fail(sourceName, fullId .. " default must be valid UTF-8")
		end
		if defaultLength > tunable.maxLength then
			return fail(sourceName, fullId .. " default exceeds maxLength")
		end
	elseif tunable.kind == "Color3" then
		if typeof(tunable.default) ~= "Color3" then
			return fail(sourceName, fullId .. " default must be a Color3")
		end
	elseif tunable.kind == "enum" then
		if typeof(tunable.default) ~= "EnumItem" then
			return fail(sourceName, fullId .. " default must be an EnumItem")
		end
		if not isArray(tunable.options) or #tunable.options == 0 then
			return fail(sourceName, fullId .. " options must be a non-empty array")
		end

		local defaultFound = false
		local seenOptions = {}
		for _, option in ipairs(tunable.options) do
			if typeof(option) ~= "EnumItem" then
				return fail(sourceName, fullId .. " options must contain only EnumItems")
			end
			if option.EnumType ~= tunable.default.EnumType then
				return fail(sourceName, fullId .. " options must use the default's EnumType")
			end
			if seenOptions[option] then
				return fail(sourceName, fullId .. " options must not contain duplicates")
			end
			seenOptions[option] = true
			if option == tunable.default then
				defaultFound = true
			end
		end
		if not defaultFound then
			return fail(sourceName, fullId .. " default must appear in options")
		end
	end

	return true
end

function Schema.validate(moduleDefinitions)
	if not isArray(moduleDefinitions) then
		return nil, "DevTuning registry definitions must be an array"
	end

	local catalog = {
		byId = {},
		features = {},
	}
	local seenFeatures = {}

	for index, record in ipairs(moduleDefinitions) do
		if type(record) ~= "table" or type(record.definition) ~= "table" then
			return nil, ("DevTuning registry record %d must contain a definition table"):format(index)
		end

		local sourceName = type(record.sourceName) == "string" and record.sourceName or ("record_%d"):format(index)
		local definition = record.definition
		if not isIdentifier(definition.feature) then
			return fail(sourceName, "feature must be a non-empty Luau identifier")
		end
		if seenFeatures[definition.feature] then
			return fail(sourceName, ("duplicate feature name %q"):format(definition.feature))
		end
		seenFeatures[definition.feature] = true
		if definition.collapsedByDefault ~= nil and type(definition.collapsedByDefault) ~= "boolean" then
			return fail(sourceName, "collapsedByDefault must be a boolean when provided")
		end

		if not isArray(definition.tunables) or #definition.tunables == 0 then
			return fail(sourceName, "tunables must be a non-empty array")
		end

		local featureRecord = {
			name = definition.feature,
			collapsedByDefault = definition.collapsedByDefault == true,
			tunables = {},
		}

		for tunableIndex, tunable in ipairs(definition.tunables) do
			if type(tunable) ~= "table" then
				return fail(sourceName, ("tunable %d must be a table"):format(tunableIndex))
			end
			if not isIdentifier(tunable.key) then
				return fail(sourceName, ("tunable %d key must be a non-empty Luau identifier"):format(tunableIndex))
			end

			local fullId = definition.feature .. "." .. tunable.key
			if catalog.byId[fullId] then
				return fail(sourceName, ("duplicate full key %q"):format(fullId))
			end
			if not VALID_KINDS[tunable.kind] then
				return fail(sourceName, fullId .. " has an invalid or missing kind")
			end
			if not VALID_SCOPES[tunable.scope] then
				return fail(sourceName, fullId .. " has an invalid or missing scope")
			end
			if type(tunable.description) ~= "string" or tunable.description == "" then
				return fail(sourceName, fullId .. " must have a description")
			end

			local valid, validationError = validateDefault(sourceName, fullId, tunable)
			if not valid then
				return nil, validationError
			end

			local normalized = {
				feature = definition.feature,
				key = tunable.key,
				fullId = fullId,
				default = tunable.default,
				kind = tunable.kind,
				min = tunable.min,
				max = tunable.max,
				step = tunable.step,
				maxLength = tunable.maxLength,
				options = tunable.options,
				scope = tunable.scope,
				description = tunable.description,
			}
			catalog.byId[fullId] = normalized
			table.insert(featureRecord.tunables, normalized)
		end

		table.sort(featureRecord.tunables, function(left, right)
			return left.key < right.key
		end)
		table.insert(catalog.features, featureRecord)
	end

	table.sort(catalog.features, function(left, right)
		return left.name < right.name
	end)

	return catalog
end

return Schema
