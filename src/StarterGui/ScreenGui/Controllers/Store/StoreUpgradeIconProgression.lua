-- StoreUpgradeIconProgression: data-driven color progression for upgrade-row icons.
-- Supports Studio-authored icon layer slots under Icon:
--   * IconFill / IconOutline for tint-progressed layers.
--   * IconDetail1 / IconDetail2 for untinted art details.
-- The renderer only assigns images/colors/visibility. Studio owns layer size,
-- position, and ZIndex.
local StoreUpgradeIconProgression = {}

local DEFAULT_LONG_LINE_STEPS = 12
local MIN_DETAIL_SLOT_COUNT = 2
local UNTINTED_COLOR = Color3.fromRGB(255, 255, 255)

local COLOR_STEPS = {
	{
		Fill = Color3.fromRGB(255, 255, 255),
		Outline = Color3.fromRGB(16, 18, 24),
		Single = Color3.fromRGB(255, 255, 255),
	},
	{
		Fill = Color3.fromRGB(255, 255, 255),
		Outline = Color3.fromRGB(58, 145, 255),
		Single = Color3.fromRGB(58, 145, 255),
	},
	{
		Fill = Color3.fromRGB(255, 255, 255),
		Outline = Color3.fromRGB(255, 165, 48),
		Single = Color3.fromRGB(255, 165, 48),
	},
	{
		Fill = Color3.fromRGB(255, 255, 255),
		Outline = Color3.fromRGB(255, 72, 72),
		Single = Color3.fromRGB(255, 72, 72),
	},
	{
		Fill = Color3.fromRGB(255, 255, 255),
		Outline = Color3.fromRGB(176, 92, 255),
		Single = Color3.fromRGB(176, 92, 255),
	},
	{
		Fill = Color3.fromRGB(255, 255, 255),
		Outline = Color3.fromRGB(52, 205, 112),
		Single = Color3.fromRGB(52, 205, 112),
	},
	{
		Fill = Color3.fromRGB(214, 235, 255),
		Outline = Color3.fromRGB(20, 76, 180),
		Single = Color3.fromRGB(106, 190, 255),
	},
	{
		Fill = Color3.fromRGB(255, 224, 188),
		Outline = Color3.fromRGB(166, 80, 18),
		Single = Color3.fromRGB(255, 190, 92),
	},
	{
		Fill = Color3.fromRGB(255, 205, 224),
		Outline = Color3.fromRGB(172, 38, 112),
		Single = Color3.fromRGB(255, 116, 176),
	},
	{
		Fill = Color3.fromRGB(204, 255, 230),
		Outline = Color3.fromRGB(20, 122, 84),
		Single = Color3.fromRGB(92, 235, 165),
	},
	{
		Fill = Color3.fromRGB(255, 238, 146),
		Outline = Color3.fromRGB(106, 65, 210),
		Single = Color3.fromRGB(255, 224, 82),
	},
	{
		Fill = Color3.fromRGB(170, 245, 255),
		Outline = Color3.fromRGB(210, 52, 255),
		Single = Color3.fromRGB(123, 235, 255),
	},
}

local function findImage(parent, names)
	if not parent then
		return nil
	end

	for _, name in ipairs(names) do
		local object = parent:FindFirstChild(name, true)
		if object and (object:IsA("ImageLabel") or object:IsA("ImageButton")) then
			return object
		end
	end

	return nil
end

local function getImageString(config, key)
	local image = config[key]
	if type(image) == "string" and image ~= "" then
		return image
	end

	return nil
end

local function findDirectImage(parent, names)
	if not parent then
		return nil
	end

	for _, name in ipairs(names) do
		local object = parent:FindFirstChild(name)
		if object and (object:IsA("ImageLabel") or object:IsA("ImageButton")) then
			return object
		end
	end

	return nil
end

local function setLayerImage(layer, image, color)
	if not layer then
		return
	end

	if not image then
		layer.Visible = false
		layer.Image = ""
		return
	end

	layer.Visible = true
	layer.Image = image
	layer.ImageColor3 = color or UNTINTED_COLOR
	layer.ImageTransparency = 0
	layer.BackgroundTransparency = 1
	layer.BorderSizePixel = 0
end

local function getIconDetailNames(index)
	if index == 1 then
		return { "IconDetail1", "icondetail1", "IconDetail", "icondetail", "IconAccent", "IconBadge" }
	end

	return {
		"IconDetail" .. index,
		"icondetail" .. index,
		"IconAccent" .. index,
		"IconBadge" .. index,
	}
end

local function getDetailImages(config)
	if type(config.IconDetails) == "table" then
		local images = {}
		for _, image in ipairs(config.IconDetails) do
			if type(image) == "string" and image ~= "" then
				table.insert(images, image)
			end
		end

		return images
	end

	local detailImage = getImageString(config, "IconDetail")
	if detailImage then
		return { detailImage }
	end

	return {}
end

local function applyDetailLayerOrder(icon, config, detailIcon, index, detailCount, fillIcon, outlineIcon)
	local order = config.IconDetailLayerOrder
	if order ~= "Under" and order ~= "Over" then
		return
	end

	local fillZIndex = fillIcon and fillIcon.ZIndex or icon.ZIndex
	local outlineZIndex = outlineIcon and outlineIcon.ZIndex or icon.ZIndex
	if order == "Under" then
		local baseZIndex = math.min(fillZIndex, outlineZIndex)
		detailIcon.ZIndex = baseZIndex - detailCount + index - 1
	else
		local baseZIndex = math.max(fillZIndex, outlineZIndex)
		detailIcon.ZIndex = baseZIndex + index
	end
end

local function applyIconDetails(icon, config, detailImages, fillIcon, outlineIcon)
	local detailCount = math.max(#detailImages, MIN_DETAIL_SLOT_COUNT)
	for index = 1, detailCount do
		local detailImage = detailImages[index]
		local detailIcon = findDirectImage(icon, getIconDetailNames(index))
		setLayerImage(detailIcon, detailImage, UNTINTED_COLOR)
		if detailIcon and detailImage then
			applyDetailLayerOrder(icon, config, detailIcon, index, detailCount, fillIcon, outlineIcon)
		end
	end
end

local function getMaxLevel(config, maxLevel)
	if type(maxLevel) == "number" and maxLevel > 0 then
		return maxLevel
	end

	if type(config) == "table" then
		if type(config.IconProgressionSteps) == "number" and config.IconProgressionSteps > 0 then
			return config.IconProgressionSteps
		end
		if type(config.MaxCount) == "number" and config.MaxCount > 0 then
			return config.MaxCount
		end
	end

	return DEFAULT_LONG_LINE_STEPS
end

local function getStep(level, maxLevel)
	level = math.max(1, math.floor(tonumber(level) or 1))
	maxLevel = math.max(1, math.floor(tonumber(maxLevel) or 1))

	if maxLevel <= 1 then
		return COLOR_STEPS[1]
	end

	local alpha = math.clamp((level - 1) / (maxLevel - 1), 0, 1)
	local index = math.floor(alpha * (#COLOR_STEPS - 1) + 0.5) + 1
	return COLOR_STEPS[index]
end

function StoreUpgradeIconProgression.apply(row, config, level, maxLevel, placeholderIcon)
	if not row or type(config) ~= "table" then
		return
	end

	local icon = findImage(row, { "Icon", "icon" })
	local fillIcon = icon and findDirectImage(icon, { "IconFill", "iconfill", "FillIcon", "IconBody" }) or nil
	local outlineIcon = icon and findDirectImage(icon, { "IconOutline", "iconoutline", "OutlineIcon", "IconStroke" }) or nil
	local fillImage = getImageString(config, "IconFill")
	local outlineImage = getImageString(config, "IconOutline")
	local detailImages = getDetailImages(config)
	local singleImage = getImageString(config, "Icon")
	local hasAuthoredFillAndOutlineLayers = fillIcon and outlineIcon and fillImage and outlineImage
	local hasFillChildLayer = fillIcon and fillImage and outlineImage
	local hasOutlineChildLayer = outlineIcon and fillImage and outlineImage

	if not icon then
		return
	end

	icon.Visible = true

	local shouldTint = config.IconTint ~= false
	local step = shouldTint and getStep(level, getMaxLevel(config, maxLevel)) or COLOR_STEPS[1]

	if hasAuthoredFillAndOutlineLayers then
		icon.Image = ""
		setLayerImage(fillIcon, fillImage, shouldTint and step.Fill or UNTINTED_COLOR)
		setLayerImage(outlineIcon, outlineImage, shouldTint and step.Outline or UNTINTED_COLOR)
		applyIconDetails(icon, config, detailImages, fillIcon, outlineIcon)
		return
	end

	if hasFillChildLayer then
		icon.Image = outlineImage
		icon.ImageColor3 = shouldTint and step.Outline or UNTINTED_COLOR
		icon.ImageTransparency = 0
		setLayerImage(fillIcon, fillImage, shouldTint and step.Fill or UNTINTED_COLOR)
		applyIconDetails(icon, config, detailImages, fillIcon, nil)
		return
	end

	if hasOutlineChildLayer then
		icon.Image = fillImage
		icon.ImageColor3 = shouldTint and step.Fill or UNTINTED_COLOR
		icon.ImageTransparency = 0
		setLayerImage(outlineIcon, outlineImage, shouldTint and step.Outline or UNTINTED_COLOR)
		applyIconDetails(icon, config, detailImages, nil, outlineIcon)
		return
	end

	setLayerImage(outlineIcon, nil)
	setLayerImage(fillIcon, nil)
	applyIconDetails(icon, config, detailImages, fillIcon, outlineIcon)

	if singleImage then
		icon.Image = singleImage
		icon.ImageColor3 = step.Single
	elseif type(placeholderIcon) == "string" and placeholderIcon ~= "" then
		icon.Image = placeholderIcon
		icon.ImageColor3 = Color3.fromRGB(255, 255, 255)
	else
		icon.Image = ""
		icon.ImageColor3 = Color3.fromRGB(255, 255, 255)
	end
end

return StoreUpgradeIconProgression
