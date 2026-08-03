-- Concrete, content-addressed guide targets for the approved quest HUD. The
-- adapter understands reusable target kinds/roles and contains no quest step IDs.

local GuiService = game:GetService("GuiService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local Attrs = require(ReplicatedStorage.Shared.Attrs)
local BoostShopConfig = require(ReplicatedStorage.Shared.BoostShopConfig)
local GuiNames = require(ReplicatedStorage.Shared.GuiNames)
local StoreShell = require(ReplicatedStorage.Shared.StoreShell)
local UiMotion = require(ReplicatedStorage.Shared.UiMotion)

local QuestProgressGuideTargets = {}

local function visibleGui(value)
	return value and value:IsA("GuiObject") and value.Visible and value.AbsoluteSize.Magnitude > 0
end

local function findPlayerSheet(player)
	local sheets = Workspace:FindFirstChild("CookieSheets")
	if not sheets then return nil end
	for _, sheet in ipairs(sheets:GetChildren()) do
		local owner = sheet:FindFirstChild("SheetOwner")
		if owner and owner:IsA("ObjectValue") and owner.Value == player then return sheet end
	end
	return nil
end

local function findUpgradeRow(screenGui, upgradeId)
	-- StoreController gives every generated card a stable identity on the row
	-- itself. Preview descendants cannot be used as the primary identity: stat
	-- cards may have no UpgradeId, while building-upgrade previews identify the
	-- target building instead of the upgrade being purchased.
	local activeStore = StoreShell.getActive(screenGui)
	for _, candidate in ipairs(activeStore and activeStore:GetDescendants() or {}) do
		if candidate:IsA("GuiObject")
			and candidate.Visible
			and candidate.Name == upgradeId
			and candidate:GetAttribute("GeneratedByStoreController") == true
			and candidate:FindFirstChild("Catch", true)
		then
			return candidate
		end
	end

	-- Compatibility fallback for non-generated focused fixtures.
	local fallback
	for _, candidate in ipairs(screenGui:GetDescendants()) do
		if candidate:IsA("GuiObject") and candidate.Visible and candidate:GetAttribute(Attrs.UpgradeId) == upgradeId then
			fallback = fallback or candidate
			local row = candidate
			while row and row ~= screenGui do
				if row:IsA("GuiObject") and row.Visible and (row:FindFirstChild("Catch", true) or row:FindFirstChild("UpgradeNudge", true)) then
					return row
				end
				row = row.Parent
			end
		end
	end
	return fallback
end

local function pointDescriptor(value)
	if visibleGui(value) then return { Kind = "Gui", Value = value } end
	if value and (value:IsA("BasePart") or value:IsA("Model")) then return { Kind = "World", Value = value } end
	return nil
end

function QuestProgressGuideTargets.new(screenGui, root)
	local player = Players.LocalPlayer
	local pointer = root:FindFirstChild("GuidePointer", true)
	local pointerScale = pointer and pointer:FindFirstChild("GuideScale")
	local cookieHighlight = root:FindFirstChild("CookieGuideHighlight", true)
	local activeConnection
	local activeTween
	local catchState
	local authoredZ = root.ZIndex

	if pointer and pointer:IsA("GuiObject") then pointer.Visible = false end
	if cookieHighlight and cookieHighlight:IsA("Highlight") then cookieHighlight.Enabled = false end

	local function stopVisual()
		if activeConnection then activeConnection:Disconnect(); activeConnection = nil end
		if activeTween then activeTween:Cancel(); activeTween = nil end
		if catchState and catchState.Instance.Parent then
			catchState.Instance.BackgroundColor3 = catchState.Color
			catchState.Instance.BackgroundTransparency = catchState.Transparency
		end
		catchState = nil
		if pointer and pointer:IsA("GuiObject") then pointer.Visible = false end
		if pointerScale and pointerScale:IsA("UIScale") then pointerScale.Scale = 1 end
		if cookieHighlight and cookieHighlight:IsA("Highlight") then
			cookieHighlight.Enabled = false
			cookieHighlight.Adornee = nil
		end
		root.ZIndex = authoredZ
	end

	local function store()
		return StoreShell.getActive(screenGui)
	end

	local targets = {}

	function targets.IsSurfaceOpen(targetId)
		return targetId == "Mixer" and screenGui:GetAttribute(Attrs.StoreOpen) == true
	end

	function targets.SurfaceControl(targetId)
		if targetId ~= "Mixer" then return nil end
		local hotbar = screenGui:FindFirstChild("Hotbar")
		return pointDescriptor(hotbar and hotbar:FindFirstChild("SlotCenter"))
	end

	function targets.IsCategoryActive(targetId)
		local current = store()
		return current ~= nil and current:GetAttribute(Attrs.CurrentCategory) == targetId
	end

	function targets.IsModeActive(targetId)
		return targetId == "SellButton" and screenGui:GetAttribute(Attrs.SellMode) == true
	end

	function targets.UiControl(targetId, node)
		if node.Role == "StoreCategory" then
			local current = store()
			local tabBar = current and current:FindFirstChild("TabBar")
			local tabName = targetId == "Building" and "BuildingsTab" or targetId == "Upgrade" and "UpgradesTab"
			return pointDescriptor(tabName and tabBar and tabBar:FindFirstChild(tabName))
		elseif targetId == "BuildView" then
			local playerGui = screenGui:FindFirstAncestorOfClass("PlayerGui")
			local topbar = playerGui and playerGui:FindFirstChild(GuiNames.TopbarHudGui)
			local frame = topbar and topbar:FindFirstChild(GuiNames.BuildModeFrame, true)
			return pointDescriptor(frame and (frame:FindFirstChild("Hitbox", true) or frame))
		elseif targetId == "BoostPurchaseConfirm" then
			local modal = screenGui:FindFirstChild(BoostShopConfig.ModalName, true)
			return pointDescriptor(modal and modal.Visible and modal:FindFirstChild("ConfirmButton", true))
		elseif targetId == "BoostFieldCharge" then
			local hotbar = screenGui:FindFirstChild("Hotbar")
			for _, itemId in ipairs(BoostShopConfig.Order) do
				local item = BoostShopConfig.Items[itemId]
				if (tonumber(player:GetAttribute(item.OwnedAttribute)) or 0) > 0 then
					local slotName = itemId == "PowerField" and "SlotLeft" or "SlotRight"
					return pointDescriptor(hotbar and hotbar:FindFirstChild(slotName))
				end
			end
			return nil
		elseif targetId == "UpgradeNudge" then
			local row = findUpgradeRow(screenGui, node.UpgradeId)
			return pointDescriptor(row and row:FindFirstChild("UpgradeNudge", true))
		end
		return pointDescriptor(screenGui:FindFirstChild(targetId, true))
	end

	function targets.StoreRow(targetId)
		return pointDescriptor(findUpgradeRow(screenGui, targetId))
	end

	function targets.IsStoreRowComplete(_, node)
		return node.CompletionRole == "PlacementActive" and screenGui:GetAttribute(Attrs.PlacementActive) == true
	end

	function targets.Cookie()
		local sheet = findPlayerSheet(player)
		return pointDescriptor(sheet and sheet:FindFirstChild("Cookie", true))
	end

	function targets.Dialogue(targetId)
		local dialogue = screenGui:FindFirstChild("StoryDialogue")
		if not visibleGui(dialogue) then return nil end
		return pointDescriptor(dialogue:FindFirstChild(targetId, true) or dialogue)
	end

	function targets.PlacedBuilding(upgradeId)
		local sheet = findPlayerSheet(player)
		local found
		for _, candidate in ipairs(sheet and sheet:GetChildren() or {}) do
			if candidate:IsA("Model") and candidate:GetAttribute(Attrs.UpgradeId) == upgradeId then found = candidate end
		end
		return pointDescriptor(found)
	end

	function targets.WorldPosition(targetId)
		return pointDescriptor(Workspace:FindFirstChild(targetId, true))
	end
	targets.WorldObject = targets.WorldPosition
	targets.OffscreenWorldTarget = targets.WorldPosition

	local function worldPosition(value)
		if value:IsA("BasePart") then return value.Position end
		if value:IsA("Model") then return value:GetPivot().Position end
		return nil
	end

	local function screenPoint(descriptor)
		if descriptor.Kind == "Gui" then
			local value = descriptor.Value
			if not visibleGui(value) then return nil end
			local point = value.AbsolutePosition + value.AbsoluteSize / 2
			local owner = value:FindFirstAncestorOfClass("ScreenGui")
			if owner and owner ~= screenGui and owner.IgnoreGuiInset ~= screenGui.IgnoreGuiInset then
				local inset = GuiService:GetGuiInset()
				point = owner.IgnoreGuiInset and point - inset or point + inset
			end
			return point
		end
		local position = descriptor.Value.Parent and worldPosition(descriptor.Value)
		local camera = Workspace.CurrentCamera
		if not (position and camera) then return nil end
		local projected = screenGui.IgnoreGuiInset and camera:WorldToScreenPoint(position) or camera:WorldToViewportPoint(position)
		local viewport = camera.ViewportSize
		-- Roblox returns mirrored viewport coordinates for targets behind the
		-- camera. Flip those coordinates before clamping so an offscreen guide
		-- points toward the target instead of appearing on the opposite edge.
		if projected.Z < 0 then
			projected = Vector3.new(viewport.X - projected.X, viewport.Y - projected.Y, -projected.Z)
		end
		return Vector2.new(math.clamp(projected.X, 24, viewport.X - 24), math.clamp(projected.Y, 24, viewport.Y - 24))
	end

	local function show(descriptor, node)
		stopVisual()
		if not descriptor then return nil end
		-- ScreenGui uses sibling Z ordering, so a very high child ZIndex cannot
		-- escape a lower-Z top-level parent. Lift the active guide overlay above
		-- every sibling HUD surface, including the Boost Shop and StoreBottom.
		local guideZ = authoredZ
		for _, sibling in ipairs(root.Parent:GetChildren()) do
			if sibling ~= root and sibling:IsA("GuiObject") then
				guideZ = math.max(guideZ, sibling.ZIndex + 1)
			end
		end
		root.ZIndex = guideZ
		if node.Style == "CatchPulse" and descriptor.Kind == "Gui" then
			local catch = descriptor.Value:FindFirstChild("Catch", true)
			if catch and catch:IsA("GuiObject") then
				catchState = { Instance = catch, Color = catch.BackgroundColor3, Transparency = catch.BackgroundTransparency }
				catch.BackgroundColor3 = Color3.new(1, 1, 1)
				catch.BackgroundTransparency = UiMotion.isReduced(catch) and 0.7 or 0.88
				if not UiMotion.isReduced(catch) then
					activeTween = UiMotion.create(catch, TweenInfo.new(0.75, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, -1, true), { BackgroundTransparency = 0.58 })
					activeTween:Play()
				end
				return stopVisual
			end
		end
		if node.Kind == "Cookie" and descriptor.Kind == "World" and cookieHighlight then
			cookieHighlight.Adornee = descriptor.Value
			cookieHighlight.FillTransparency = 1
			cookieHighlight.OutlineTransparency = 0
			cookieHighlight.Enabled = true
		end
		if not (pointer and pointer:IsA("GuiObject")) then return nil end
		local function place()
			if screenGui:GetAttribute(Attrs.CompactModalActive) == true then pointer.Visible = false; return end
			local point = screenPoint(descriptor)
			if not point then pointer.Visible = false; return end
			pointer.Position = UDim2.fromOffset(point.X - root.AbsolutePosition.X, point.Y - root.AbsolutePosition.Y)
			pointer.Visible = true
		end
		place()
		activeConnection = RunService.RenderStepped:Connect(place)
		if pointerScale and pointerScale:IsA("UIScale") and not UiMotion.isReduced(pointer) then
			pointerScale.Scale = 0.9
			activeTween = UiMotion.create(pointerScale, TweenInfo.new(0.65, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, -1, true), { Scale = 1.12 })
			activeTween:Play()
		end
		return stopVisual
	end

	return {
		Targets = targets,
		Show = show,
		Hide = stopVisual,
		Refresh = function(callback)
			local connection = RunService.RenderStepped:Connect(callback)
			return function() connection:Disconnect() end
		end,
		Destroy = stopVisual,
	}
end

return QuestProgressGuideTargets
