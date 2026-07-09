local screenGui = script:FindFirstAncestorOfClass("ScreenGui")
if not screenGui then
	return
end

local shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local Attrs = require(shared:WaitForChild("Attrs"))
local GuiNames = require(shared:WaitForChild("GuiNames"))
local IconButton = require(shared:WaitForChild("IconButton"))
local pill = screenGui:WaitForChild(GuiNames.MenuPill, 10)
if not pill then
	warn("MenuProfileFaceController: MenuPill not found")
	return
end

local FALLBACK_FACE_RIGHT = "rbxassetid://94711897768648"
local FALLBACK_FACE_LEFT = "rbxassetid://114955901579358"
local FALLBACK_FACE_SOFT_RIGHT = "rbxassetid://93713273151312"

local function findControl(...)
	local names = { ... }
	for _, name in ipairs(names) do
		local child = pill:FindFirstChild(name)
		if child then
			return child
		end
	end

	for _, name in ipairs(names) do
		local descendant = pill:FindFirstChild(name, true)
		if descendant then
			return descendant
		end
	end

	return nil
end

local profileContainer = findControl(GuiNames.Profile, GuiNames.ProfileButton)
local profileButton = IconButton.resolveButton(profileContainer, { className = "ImageButton", containerFirst = true })
if not profileButton then
	warn("MenuProfileFaceController: Profile image button not found")
	return
end
local profileHitbox = IconButton.createHitbox(profileContainer, profileButton)

local helpContainer = findControl(GuiNames.Help, GuiNames.ShowHelp)
local helpButton = IconButton.resolveButton(helpContainer, { containerFirst = true })
local settingsContainer = findControl(GuiNames.Settings, GuiNames.SettingsButton)
local settingsButton = IconButton.resolveButton(settingsContainer, { containerFirst = true })

local wheelContainer = findControl(GuiNames.Wheel, GuiNames.WheelButton)
local wheelButton = IconButton.resolveButton(wheelContainer, { containerFirst = true })

local faceDefault = profileButton:GetAttribute("FaceDefaultImage")
if typeof(faceDefault) ~= "string" or faceDefault == "" then
	faceDefault = profileButton.Image
	profileButton:SetAttribute("FaceDefaultImage", faceDefault)
end

local faceRight = profileButton:GetAttribute("FaceRightImage")
if typeof(faceRight) ~= "string" or faceRight == "" then
	faceRight = profileButton.HoverImage ~= "" and profileButton.HoverImage or faceDefault
	profileButton:SetAttribute("FaceRightImage", faceRight)
end
if faceRight == faceDefault and FALLBACK_FACE_RIGHT ~= "" then
	faceRight = FALLBACK_FACE_RIGHT
	profileButton:SetAttribute("FaceRightImage", faceRight)
end

local faceLeft = profileButton:GetAttribute("FaceLeftImage")
if typeof(faceLeft) ~= "string" or faceLeft == "" then
	faceLeft = profileButton.PressedImage ~= "" and profileButton.PressedImage or faceDefault
	profileButton:SetAttribute("FaceLeftImage", faceLeft)
end
if faceLeft == faceDefault and FALLBACK_FACE_LEFT ~= "" then
	faceLeft = FALLBACK_FACE_LEFT
	profileButton:SetAttribute("FaceLeftImage", faceLeft)
end

local faceSoftRight = profileButton:GetAttribute("FaceSoftRightImage")
if typeof(faceSoftRight) ~= "string" or faceSoftRight == "" then
	faceSoftRight = FALLBACK_FACE_SOFT_RIGHT ~= "" and FALLBACK_FACE_SOFT_RIGHT or faceRight
	profileButton:SetAttribute("FaceSoftRightImage", faceSoftRight)
end

-- Keep ProfileButton's own built-in states from overriding the face direction
-- while this controller is reacting to neighboring menu buttons.
profileButton.AutoButtonColor = false
profileButton.HoverImage = ""
profileButton.PressedImage = ""

local hoverTarget = nil
local activeTarget = nil

local function isActive(container, button)
	return (container and container:GetAttribute(Attrs.Active) == true)
		or (button and button:GetAttribute(Attrs.Active) == true)
end

local function refreshActiveTarget()
	if isActive(helpContainer, helpButton) then
		activeTarget = "Help"
	elseif isActive(wheelContainer, wheelButton) then
		activeTarget = "Wheel"
	elseif isActive(settingsContainer, settingsButton) then
		activeTarget = "Settings"
	else
		activeTarget = nil
	end
end

local function updateFace()
	local target = hoverTarget or activeTarget
	if target == "Help" then
		profileButton.Image = faceRight
	elseif target == "Wheel" then
		profileButton.Image = faceSoftRight
	elseif target == "Settings" then
		profileButton.Image = faceLeft
	else
		profileButton.Image = faceDefault
	end
end

local function connectHover(targetName, object)
	if not object or not object:IsA("GuiObject") then
		return
	end

	object.MouseEnter:Connect(function()
		hoverTarget = targetName
		updateFace()
	end)
	object.MouseLeave:Connect(function()
		if hoverTarget == targetName then
			hoverTarget = nil
			updateFace()
		end
	end)
end

local function connectActive(object)
	if not object then
		return
	end

	object:GetAttributeChangedSignal(Attrs.Active):Connect(function()
		refreshActiveTarget()
		updateFace()
	end)
end

-- Drive the face from exactly ONE hover source per neighbour: the full-frame "Hitbox" that each
-- icon controller lays over its frame (Settings via MenuSettingsIconController, Wheel via
-- MenuWheelIconController, Help via IconButton.new). These hitboxes are frame-sized, topmost, and
-- — as measured — butt up against each other with no gap, so crossing e.g. Help→Wheel fires one
-- Leave then one Enter and the face goes right→soft-right cleanly. Listening to the frame AND the
-- inset icon button at once (the old code) is what caused the centre flash: moving off the icon but
-- still inside the frame fired the button's MouseLeave and blanked the face even though the hitbox
-- was still hovered. One source = no dead zone.
local function waitForHitbox(container)
	if not container then
		return nil
	end
	return container:FindFirstChild("Hitbox") or container:WaitForChild("Hitbox", 10)
end

-- The profile's own hitbox already exists (created above); neighbour hitboxes are created by their
-- controllers, so resolve those off the main thread to avoid blocking the initial face render.
connectHover("Profile", profileHitbox)
task.spawn(function()
	connectHover("Settings", waitForHitbox(settingsContainer))
	connectHover("Wheel", waitForHitbox(wheelContainer))
	connectHover("Help", waitForHitbox(helpContainer))
end)

connectActive(helpContainer)
connectActive(helpButton)
connectActive(wheelContainer)
connectActive(wheelButton)
connectActive(settingsContainer)
connectActive(settingsButton)

refreshActiveTarget()
updateFace()
