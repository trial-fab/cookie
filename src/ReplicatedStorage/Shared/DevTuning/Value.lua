-- Value: pure candidate validation, numeric canonicalization, and live/default resolution.

local Value = {}

local function isFiniteNumber(value)
	return type(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge
end

local function containsOption(options, candidate)
	for _, option in ipairs(options) do
		if option == candidate then
			return true
		end
	end
	return false
end

function Value.canonicalize(definition, candidateValue)
	if type(definition) ~= "table" then
		return false, nil, "UnknownTunable"
	end

	if definition.kind == "number" then
		if not isFiniteNumber(candidateValue) then
			return false, nil, "ExpectedFiniteNumber"
		end

		local clamped = math.clamp(candidateValue, definition.min, definition.max)
		local stepCount = math.floor(((clamped - definition.min) / definition.step) + 0.5)
		local quantized = definition.min + stepCount * definition.step
		quantized = math.clamp(quantized, definition.min, definition.max)
		if math.abs(quantized) < 1e-12 then
			quantized = 0
		end
		return true, quantized
	elseif definition.kind == "boolean" then
		if type(candidateValue) ~= "boolean" then
			return false, nil, "ExpectedBoolean"
		end
		return true, candidateValue
	elseif definition.kind == "string" then
		if type(candidateValue) ~= "string" then
			return false, nil, "ExpectedString"
		end
		-- Reject obviously oversized payloads before UTF-8 traversal. A valid UTF-8
		-- codepoint uses at most four bytes, so this does not reject a valid value.
		if #candidateValue > definition.maxLength * 4 then
			return false, nil, "StringTooLong"
		end
		local length = utf8.len(candidateValue)
		if not length then
			return false, nil, "InvalidUtf8"
		end
		if length > definition.maxLength then
			return false, nil, "StringTooLong"
		end
		return true, candidateValue
	elseif definition.kind == "Color3" then
		if typeof(candidateValue) ~= "Color3" then
			return false, nil, "ExpectedColor3"
		end
		return true, candidateValue
	elseif definition.kind == "enum" then
		if typeof(candidateValue) ~= "EnumItem" or not containsOption(definition.options, candidateValue) then
			return false, nil, "InvalidEnumOption"
		end
		return true, candidateValue
	end

	return false, nil, "UnsupportedKind"
end

function Value.resolve(enabled, definition, liveValue)
	if not enabled or liveValue == nil then
		return definition.default
	end

	local valid, canonical = Value.canonicalize(definition, liveValue)
	if not valid then
		return definition.default
	end
	return canonical
end

return Value
