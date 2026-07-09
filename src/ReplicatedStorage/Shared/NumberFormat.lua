local NumberFormat = {}

local SUFFIXES = {
	"k", "M", "B", "T", "Qa", "Qi", "Sx", "Sp", "Oc", "No",
	"Dc", "Ud", "Dd", "Td", "Qad", "Qid", "Sxd", "Spd", "Ocd", "Nod",
	"Vg", "Uvg", "Dvg", "Tvg", "Qavg", "Qivg", "Sxvg", "Spvg", "Ocvg", "Novg",
	"Tg", "Utg", "Dtg", "Ttg", "Qatg", "Qitg", "Sxtg", "Sptg", "Octg", "Notg",
	"Qag", "Uqag", "Dqag", "Tqag", "Qaqag", "Qiqag", "Sxqag", "Spqag", "Ocqag", "Noqag",
	"Qig", "Uqig", "Dqig", "Tqig", "Qaqig", "Qiqig", "Sxqig", "Spqig", "Ocqig", "Noqig",
	"Sxg", "Usxg", "Dsxg", "Tsxg", "Qasxg", "Qisxg", "Sxsxg", "Spsxg", "Ocsxg", "Nosxg",
	"Spg", "Uspg", "Dspg", "Tspg", "Qaspg", "Qispg", "Sxspg", "Spspg", "Ocspg", "Nospg",
	"Ocg", "Uocg", "Docg", "Tocg", "Qaocg", "Qiocg", "Sxocg", "Spocg", "Ococg", "Noocg",
	"Nog", "Unog", "Dnog", "Tnog", "Qanog", "Qinog", "Sxnog", "Spnog", "Ocnog", "Nonog",
	"Ce",
}

local function trimTrailingZeroes(text)
	return text:gsub("(%..-)0+$", "%1"):gsub("%.$", "")
end

local function formatCompact(compactValue, decimals)
	local formatString = "%." .. tostring(decimals) .. "f"
	return trimTrailingZeroes(string.format(formatString, compactValue))
end

local function getSuffix(index, lowercaseThousands)
	if index == 1 and lowercaseThousands ~= false then
		return "k"
	end

	return SUFFIXES[index]
end

function NumberFormat.abbreviate(value, options)
	options = options or {}
	value = tonumber(value) or 0

	if value ~= value then
		return "0"
	end
	if value == math.huge then
		return "inf"
	elseif value == -math.huge then
		return "-inf"
	end

	local sign = value < 0 and "-" or ""
	local absolute = math.abs(value)
	if absolute < 1000 then
		if options.decimals then
			return sign .. formatCompact(absolute, options.decimals)
		end
		return sign .. tostring(math.floor(absolute + 0.5))
	end

	local suffixIndex = math.floor(math.log(absolute) / math.log(1000) + 1e-10)
	local suffix = getSuffix(suffixIndex, options.lowercaseThousands)
	if not suffix then
		local exponent = math.floor(math.log(absolute) / math.log(10) + 1e-10)
		return sign .. formatCompact(absolute / (10 ^ exponent), 2) .. "e" .. tostring(exponent)
	end

	local compactValue = absolute / (10 ^ (suffixIndex * 3))
	local decimals = options.decimals
	if decimals == nil then
		if compactValue >= 100 then
			decimals = 0
		elseif compactValue >= 10 then
			decimals = 1
		else
			decimals = 2
		end
	end

	return sign .. formatCompact(compactValue, decimals) .. suffix
end

-- Full, un-abbreviated integer with thousands separators (e.g. 1234567 -> "1,234,567").
-- For the live store cookie counter, where players want the exact total. Uses %.0f so
-- large doubles render without scientific notation.
function NumberFormat.exact(value)
	value = tonumber(value) or 0
	if value ~= value then
		return "0"
	end
	if value == math.huge then
		return "inf"
	elseif value == -math.huge then
		return "-inf"
	end

	local sign = value < 0 and "-" or ""
	local digits = string.format("%.0f", math.abs(value))
	local grouped = digits:reverse():gsub("(%d%d%d)", "%1,"):reverse()
	if grouped:sub(1, 1) == "," then
		grouped = grouped:sub(2)
	end

	return sign .. grouped
end

function NumberFormat.rate(value)
	value = tonumber(value) or 0
	local absolute = math.abs(value)

	if absolute >= 1000 then
		return NumberFormat.abbreviate(value)
	elseif value == math.floor(value) then
		return tostring(value)
	elseif absolute >= 10 then
		return formatCompact(value, 1)
	end

	return formatCompact(value, 2)
end

function NumberFormat.multiplier(value)
	value = tonumber(value) or 1
	if value < 0 then
		value = 0
	end

	local text
	if value >= 1000 then
		text = NumberFormat.abbreviate(value)
	elseif value >= 100 then
		text = formatCompact(value, 0)
	elseif value >= 10 then
		text = formatCompact(value, 1)
	else
		text = formatCompact(value, 2)
	end

	return "x" .. text
end

NumberFormat.compact = NumberFormat.abbreviate

-- Currency is no longer rendered as a text symbol. The two surfaces that used to show
-- a ₵ / ₲₵ prefix (the sell-all confirm popup and the lucky-spin / GC UI) now show a
-- bare abbreviated amount next to a Studio-authored cookie / golden-cookie ImageLabel.
-- Everywhere else already used the plain abbreviate. So NumberFormat owns numbers only.

return NumberFormat
