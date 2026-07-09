-- StoreStateIcon — renders a row's icon: the level/progression icon plus the toggle
-- "state" icon (on/off, owned/unowned) that overlays or sits beside the main Icon.
-- Handles the several template layouts by name-matching the state image, with a
-- structural fallback that picks the first non-excluded image in the row.
--
-- Extracted from StoreController's main chunk (Luau 200-local cap). The orchestrator
-- calls ctx.stateIcon.applyUpgradeIcon / ctx.stateIcon.updateUpgradeStateIcon from
-- updateRow — no top-level re-aliases (see WORKFLOW.md "Code organization").
--
-- ctx deps: placeholderIcon.

local StoreUpgradeIconProgression = require(script.Parent.StoreUpgradeIconProgression)

-- Images that must never be picked as the fallback "state" icon.
local STATE_ICON_EXCLUDED_NAMES = {
	IconFill = true,
	iconfill = true,
	FillIcon = true,
	IconBody = true,
	IconOutline = true,
	iconoutline = true,
	OutlineIcon = true,
	IconStroke = true,
	IconState = true,
	iconState = true,
	iconstate = true,
	IconDetail = true,
	icondetail = true,
	IconDetail1 = true,
	icondetail1 = true,
	IconDetail2 = true,
	icondetail2 = true,
	IconAccent = true,
	IconAccent1 = true,
	IconAccent2 = true,
	IconBadge = true,
	IconBadge1 = true,
	IconBadge2 = true,
	["imageCPM+"] = true,
	["imageCPM-"] = true,
	RobuxIcon = true,
	ProductIcon = true,
	PreviewPlaceholder = true,
	RequirementPreview = true,
}

local function findImageByNames(parent, names)
	for _, name in ipairs(names) do
		local object = parent:FindFirstChild(name, true)
		if object and (object:IsA("ImageLabel") or object:IsA("ImageButton")) then
			return object
		end
	end

	return nil
end

local function findMainIcon(row)
	return findImageByNames(row, { "Icon", "icon" })
end

local function isDescendantOf(object, ancestor)
	local current = object and object.Parent
	while current do
		if current == ancestor then
			return true
		end
		current = current.Parent
	end

	return false
end

local function getTopNestedZIndex(parent, fallback, exclude)
	local top = fallback
	for _, object in ipairs(parent:GetDescendants()) do
		if object ~= exclude and object:IsA("GuiObject") then
			top = math.max(top, object.ZIndex)
		end
	end

	return top
end

local function findFallbackStateImage(row)
	local mainIcon = findMainIcon(row)
	for _, object in ipairs(row:GetDescendants()) do
		if
			(object:IsA("ImageLabel") or object:IsA("ImageButton"))
			and object ~= mainIcon
			and not STATE_ICON_EXCLUDED_NAMES[object.Name]
			and not isDescendantOf(object, mainIcon)
		then
			return object
		end
	end

	return nil
end

local function createNestedStateImage(row, name)
	local mainIcon = findMainIcon(row)
	if not mainIcon then
		return nil
	end

	name = name or "IconState"
	for _, candidateName in ipairs({ name, "IconState", "iconState", "iconstate" }) do
		local stateIcon = mainIcon:FindFirstChild(candidateName)
		if stateIcon and (stateIcon:IsA("ImageLabel") or stateIcon:IsA("ImageButton")) then
			return stateIcon
		end
	end

	local stateIcon = Instance.new("ImageLabel")
	stateIcon.Name = name
	stateIcon.BackgroundTransparency = 1
	stateIcon.BorderSizePixel = 0
	stateIcon.Parent = mainIcon
	return stateIcon
end

local function hideStateImage(image)
	if image then
		image.Visible = false
	end
end

local LEGACY_STATE_ICON_NAMES = {
	StateIcon = true,
	ToggleStateIcon = true,
	StatusIcon = true,
	StateImage = true,
	ToggleIcon = true,
	OwnedIcon = true,
	ActiveIcon = true,
	TickIcon = true,
	CheckIcon = true,
	InactiveIcon = true,
	XIcon = true,
	iconState = true,
	iconstate = true,
	check = true,
	Check = true,
	x = true,
	X = true,
}

local function hideLegacyStateImages(row, primary)
	for _, object in ipairs(row:GetDescendants()) do
		if
			object ~= primary
			and LEGACY_STATE_ICON_NAMES[object.Name]
			and (object:IsA("ImageLabel") or object:IsA("ImageButton"))
		then
			hideStateImage(object)
		end
	end
end

local function getStateIconColor(config)
	local color = config.StateIconColor
	if typeof(color) == "Color3" then
		return color
	end

	return Color3.fromRGB(255, 255, 255)
end

local function setStateImage(image, assetId, visible, color)
	if not image then
		return
	end

	image.Visible = visible
	image.Image = assetId or ""
	image.ImageColor3 = color or Color3.fromRGB(255, 255, 255)
	image.ImageTransparency = visible and 0 or 1
end

local function syncStateIconToMainIcon(stateIcon, row)
	local mainIcon = findMainIcon(row)
	if not stateIcon or not mainIcon then
		return
	end

	if stateIcon.Parent == mainIcon then
		stateIcon.AnchorPoint = Vector2.new(0, 0)
		stateIcon.Position = UDim2.fromScale(0, 0)
		stateIcon.Size = UDim2.fromScale(1, 1)
		stateIcon.Rotation = 0
	else
		stateIcon.AnchorPoint = mainIcon.AnchorPoint
		stateIcon.Position = mainIcon.Position
		stateIcon.Size = mainIcon.Size
		stateIcon.Rotation = mainIcon.Rotation
	end
	stateIcon.BackgroundTransparency = 1
	stateIcon.BorderSizePixel = 0
	if stateIcon.Parent == mainIcon then
		stateIcon.ZIndex = getTopNestedZIndex(mainIcon, mainIcon.ZIndex, stateIcon) + 1
	else
		stateIcon.ZIndex = mainIcon.ZIndex + 1
	end
end

local StoreStateIcon = {}

function StoreStateIcon.new(ctx)
	local placeholderIcon = ctx.placeholderIcon

	local function applyUpgradeIcon(row, config, displayLevel, maxLevel)
		-- BuildingUpgrade rows render a static building preview into the Icon slot
		-- (StorePreview.ensureUpgradePreview) and hide the icon art. Skip the icon redraw so it
		-- doesn't paint back over the preview — ensureViewport owns these rows' visuals.
		if row and row:GetAttribute("BuildingPreviewActive") then
			return
		end
		StoreUpgradeIconProgression.apply(row, config, displayLevel, maxLevel, placeholderIcon)
	end

	local function updateUpgradeStateIcon(row, config, active)
		local activeIcon = type(config.ActiveIcon) == "string" and config.ActiveIcon or nil
		local inactiveIcon = type(config.InactiveIcon) == "string" and config.InactiveIcon or nil
		if not activeIcon and not inactiveIcon then
			return
		end

		local configuredName = type(config.StateIconName) == "string" and config.StateIconName or nil
		if config.CreateStateIcon == true then
			local stateIcon = createNestedStateImage(row, configuredName or "IconState")
			if stateIcon then
				syncStateIconToMainIcon(stateIcon, row)
				local image = active and activeIcon or inactiveIcon
				setStateImage(stateIcon, image, true, getStateIconColor(config))
				hideLegacyStateImages(row, stateIcon)
				row:SetAttribute("StateIconActive", active == true)
				row:SetAttribute("StateIconImage", image or "")
				stateIcon:SetAttribute("StateIconActive", active == true)
				stateIcon:SetAttribute("StateIconImage", image or "")
			end
			return
		end

		local stateIcon = configuredName and findImageByNames(row, { configuredName }) or nil
		stateIcon = stateIcon
			or findImageByNames(row, { "StateIcon", "ToggleStateIcon", "StatusIcon", "StateImage", "ToggleIcon", "OwnedIcon" })
			or findFallbackStateImage(row)
		if stateIcon then
			syncStateIconToMainIcon(stateIcon, row)
			local image = active and activeIcon or inactiveIcon
			setStateImage(stateIcon, image, true)
			row:SetAttribute("StateIconActive", active == true)
			row:SetAttribute("StateIconImage", image or "")
			stateIcon:SetAttribute("StateIconActive", active == true)
			stateIcon:SetAttribute("StateIconImage", image or "")
		end

		local activeImage = findImageByNames(row, { "ActiveIcon", "TickIcon", "CheckIcon" })
		local inactiveImage = findImageByNames(row, { "InactiveIcon", "XIcon" })
		if activeImage or inactiveImage then
			local color = getStateIconColor(config)
			setStateImage(activeImage, activeIcon, active, color)
			setStateImage(inactiveImage, inactiveIcon, not active, color)
		end
	end

	return {
		applyUpgradeIcon = applyUpgradeIcon,
		updateUpgradeStateIcon = updateUpgradeStateIcon,
		findImageByNames = findImageByNames,
	}
end

return StoreStateIcon
