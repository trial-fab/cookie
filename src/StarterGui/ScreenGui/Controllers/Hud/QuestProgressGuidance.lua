-- Optional, client-only guidance for the currently selected authoritative quest.
-- It moves only Studio-authored cue instances and never reports objective completion.

local GuiService = game:GetService("GuiService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")

local Attrs = require(ReplicatedStorage.Shared.Attrs)
local GuiNames = require(ReplicatedStorage.Shared.GuiNames)
local QuestSnapshot = require(ReplicatedStorage.Shared.QuestSnapshot)

local QuestProgressGuidance = {}
local CATCH_REST_TRANSPARENCY = 0.88
local CATCH_PULSE_TRANSPARENCY = 0.58
local MIXER_FLIGHT_SECONDS = 2
local MIXER_FLIGHT_START_HOLD_SECONDS = 0.2
local MIXER_FLIGHT_LANDING_HOLD_SECONDS = 0.35
local MIXER_FLIGHT_RESOLVE_SECONDS = 3
local MIXER_FLIGHT_FADE_SECONDS = 0.22

local function findPlayerSheet(player)
	local sheets = Workspace:FindFirstChild("CookieSheets")
	if not sheets then
		return nil
	end
	for _, sheet in ipairs(sheets:GetChildren()) do
		local owner = sheet:FindFirstChild("SheetOwner")
		if owner and owner:IsA("ObjectValue") and owner.Value == player then
			return sheet
		end
	end
	return nil
end

local function centerOfGui(instance)
	if instance and instance:IsA("GuiObject") and instance.Visible and instance.AbsoluteSize.Magnitude > 0 then
		return instance.AbsolutePosition + instance.AbsoluteSize / 2
	end
	return nil
end

-- AbsolutePosition is measured inside each ScreenGui's own inset frame, so a target that
-- lives in a ScreenGui with a different IgnoreGuiInset (Build View sits in the topbar GUI)
-- has to gain or lose the topbar inset before it can be compared with our root.
local function screenPointOfGui(instance, screenGui)
	local point = centerOfGui(instance)
	if not point then
		return nil
	end
	local owner = instance:FindFirstAncestorOfClass("ScreenGui")
	if owner and owner ~= screenGui and owner.IgnoreGuiInset ~= screenGui.IgnoreGuiInset then
		local inset = GuiService:GetGuiInset()
		point = owner.IgnoreGuiInset and point - inset or point + inset
	end
	return point
end

local function screenPointOfWorldPosition(position, screenGui)
	local camera = Workspace.CurrentCamera
	if not camera then
		return nil
	end
	local projected, visible
	if screenGui.IgnoreGuiInset then
		projected, visible = camera:WorldToScreenPoint(position)
	else
		projected, visible = camera:WorldToViewportPoint(position)
	end
	if visible and projected.Z > 0 then
		return Vector2.new(projected.X, projected.Y)
	end
	return nil
end

-- The most recently placed building of a type on the player's own sheet. Sell guidance
-- must point at the world object: the store card sells every one of them.
local function findPlacedBuilding(player, upgradeId)
	local sheet = findPlayerSheet(player)
	if not sheet then
		return nil
	end
	local found
	for _, child in ipairs(sheet:GetChildren()) do
		if child:IsA("Model") and child:GetAttribute(Attrs.UpgradeId) == upgradeId then
			found = child
		end
	end
	return found
end

local function findUpgradeRow(screenGui, upgradeId)
	local fallback
	for _, descendant in ipairs(screenGui:GetDescendants()) do
		if
			descendant:IsA("GuiObject")
			and descendant:GetAttribute(Attrs.UpgradeId) == upgradeId
			and descendant.Visible
		then
			fallback = fallback or descendant
			local candidate = descendant
			while candidate and candidate ~= screenGui do
				if candidate:IsA("GuiObject") and candidate.Visible and candidate:FindFirstChild("Catch", true) then
					return candidate
				end
				candidate = candidate.Parent
			end
		end
	end
	return fallback
end

function QuestProgressGuidance.new(screenGui, root)
	local player = Players.LocalPlayer
	local pointer = root:FindFirstChild("GuidePointer", true)
	local pointerScale = pointer and pointer:FindFirstChild("GuideScale")
	local cookieHighlight = root:FindFirstChild("CookieGuideHighlight", true)
	local flight = root:FindFirstChild("MixerUnlockFlight", true)
	local activeStepId
	local currentSnapshot
	local pulseTween
	local catchTween
	local catchState
	local mixerFlightPlayed = false
	local mixerFlightPending = false
	local mixerFlightGeneration = 0
	local connections = {}
	local authoredRootZIndex = root.ZIndex

	if pointer and pointer:IsA("GuiObject") then
		pointer.Visible = false
	end
	if flight and flight:IsA("GuiObject") then
		flight.Visible = false
	end
	if cookieHighlight and cookieHighlight:IsA("Highlight") then
		cookieHighlight.Enabled = false
	end

	local function reducedMotion()
		return screenGui:GetAttribute(Attrs.ReducedMotionEnabled) == true
	end

	local function setCookieHighlight(enabled)
		if not (cookieHighlight and cookieHighlight:IsA("Highlight")) then
			return
		end
		if enabled then
			local sheet = findPlayerSheet(player)
			local cookie = sheet and sheet:FindFirstChild("Cookie", true)
			if cookie and (cookie:IsA("BasePart") or cookie:IsA("Model")) then
				cookieHighlight.Adornee = cookie
				-- Outline only. A filled highlight repaints the cookie and hides the art the
				-- player is being asked to click.
				cookieHighlight.FillTransparency = 1
				cookieHighlight.OutlineTransparency = 0
				cookieHighlight.OutlineColor = Color3.new(1, 1, 1)
				cookieHighlight.DepthMode = Enum.HighlightDepthMode.Occluded
				cookieHighlight.Enabled = true
				return
			end
		end
		cookieHighlight.Enabled = false
		cookieHighlight.Adornee = nil
	end

	local function stopCatchPulse()
		if catchTween then
			catchTween:Cancel()
			catchTween = nil
		end
		if catchState and catchState.Instance and catchState.Instance.Parent then
			local catch = catchState.Instance
			catch.BackgroundColor3 = catchState.BackgroundColor3
			catch.BackgroundTransparency = catchState.BackgroundTransparency
			if catch:IsA("GuiButton") then
				catch.AutoButtonColor = catchState.AutoButtonColor
			end
		end
		catchState = nil
	end

	local function startCatchPulse(row)
		local catch = row and row:FindFirstChild("Catch", true)
		if not (catch and catch:IsA("GuiObject")) then
			return false
		end
		if catchState and catchState.Instance == catch then
			return true
		end
		stopCatchPulse()
		catchState = {
			Instance = catch,
			BackgroundColor3 = catch.BackgroundColor3,
			BackgroundTransparency = catch.BackgroundTransparency,
			AutoButtonColor = catch:IsA("GuiButton") and catch.AutoButtonColor or false,
		}
		catch.BackgroundColor3 = Color3.new(1, 1, 1)
		catch.BackgroundTransparency = if reducedMotion() then 0.7 else CATCH_REST_TRANSPARENCY
		if catch:IsA("GuiButton") then
			catch.AutoButtonColor = false
		end
		if not reducedMotion() then
			catchTween = TweenService:Create(
				catch,
				TweenInfo.new(0.75, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, -1, true),
				{ BackgroundTransparency = CATCH_PULSE_TRANSPARENCY }
			)
			catchTween:Play()
		end
		return true
	end

	-- ZIndexBehavior is Sibling, so the pointer's stacking is decided by the ZIndex of the
	-- whole QuestProgress subtree against the target's own top-level frame, not by the
	-- pointer's own ZIndex. Raise the root over that frame while a cue is live and put the
	-- authored value straight back afterwards, the way MenuBehaviorController raises the
	-- pill for a modal. Targets in another ScreenGui are ordered by DisplayOrder instead,
	-- so they pass no instance and this is a no-op for them.
	local function liftRootAbove(target)
		local desired = authoredRootZIndex
		if target and target:IsA("GuiObject") then
			local top = target
			while top.Parent and top.Parent ~= screenGui do
				top = top.Parent
			end
			if top.Parent == screenGui and top ~= root and top:IsA("GuiObject") and top.ZIndex >= desired then
				desired = top.ZIndex + 1
			end
		end
		if root.ZIndex ~= desired then
			root.ZIndex = desired
		end
	end

	local function hideCues()
		if pulseTween then
			pulseTween:Cancel()
			pulseTween = nil
		end
		stopCatchPulse()
		setCookieHighlight(false)
		if pointer and pointer:IsA("GuiObject") then
			pointer.Visible = false
		end
		if pointerScale and pointerScale:IsA("UIScale") then
			pointerScale.Scale = 1
		end
		liftRootAbove(nil)
	end

	local function stop()
		activeStepId = nil
		hideCues()
	end

	-- Every target resolver returns the screen point AND the instance it came from, so the
	-- pointer can guarantee it draws above whatever it is pointing at.
	local function pointAt(instance)
		return centerOfGui(instance), instance
	end

	-- Reaching a surface is guidance's job, not a step's, so every in-Mixer step falls back
	-- to pointing at the Mixer itself while the store is closed.
	local function mixerSlotTarget()
		local hotbar = screenGui:FindFirstChild("Hotbar")
		return pointAt(hotbar and hotbar:FindFirstChild("SlotCenter"))
	end

	local function buyNoobClickerTarget()
		local hotbar = screenGui:FindFirstChild("Hotbar")
		if screenGui:GetAttribute(Attrs.PlacementActive) == true then
			return pointAt(hotbar and hotbar:FindFirstChild("SlotRight"))
		end
		if screenGui:GetAttribute(Attrs.StoreOpen) == true then
			return pointAt(findUpgradeRow(screenGui, "Noob Clicker"))
		end
		return mixerSlotTarget()
	end

	local function resolveTarget(stepId)
		if stepId == "help_goo_recover" then
			local sheet = findPlayerSheet(player)
			local cookie = sheet and sheet:FindFirstChild("Cookie")
			if cookie and cookie:IsA("BasePart") then
				return screenPointOfWorldPosition(cookie.Position, screenGui)
			end
		elseif stepId == "unlock_mixer" then
			local dialogue = screenGui:FindFirstChild("StoryDialogue")
			if not (dialogue and dialogue:IsA("GuiObject") and dialogue.Visible) then
				return nil
			end
			local continueButton = dialogue:FindFirstChild("Continue", true)
			if centerOfGui(continueButton) then
				return pointAt(continueButton)
			end
			return pointAt(dialogue)
		elseif stepId == "build_first_helper" or stepId == "hire_another_noob" then
			return buyNoobClickerTarget()
		elseif stepId == "see_the_numbers" then
			if screenGui:GetAttribute(Attrs.StoreOpen) ~= true then
				return mixerSlotTarget()
			end
			return pointAt(screenGui:FindFirstChild("StatsEyeToggle", true))
		elseif stepId == "look_from_above" then
			if screenGui:GetAttribute(Attrs.BuildModeActive) == true then
				return nil
			end
			local playerGui = screenGui:FindFirstAncestorOfClass("PlayerGui")
			local topbar = playerGui and playerGui:FindFirstChild(GuiNames.TopbarHudGui)
			local frame = topbar and topbar:FindFirstChild(GuiNames.BuildModeFrame, true)
			local target = frame and frame:FindFirstChild("Hitbox", true) or frame
			-- A different ScreenGui, so ordering is DisplayOrder's job, not ZIndex's.
			return screenPointOfGui(target, screenGui), nil
		elseif stepId == "undo_a_purchase" then
			if screenGui:GetAttribute(Attrs.StoreOpen) ~= true then
				return mixerSlotTarget()
			end
			if screenGui:GetAttribute(Attrs.SellMode) ~= true then
				return pointAt(screenGui:FindFirstChild("SellButton", true))
			end
			-- Sell mode is on: point at the placed building, never the card. Clicking the
			-- card routes to SellAll and would take every Noob Clicker the player owns.
			local building = findPlacedBuilding(player, "Noob Clicker")
			if building then
				return screenPointOfWorldPosition(building:GetPivot().Position, screenGui)
			end
		end
		return nil
	end

	local pulse

	local function placePointer()
		if not activeStepId or not (pointer and pointer:IsA("GuiObject")) then
			return
		end
		if screenGui:GetAttribute(Attrs.CompactModalActive) == true then
			hideCues()
			return
		end
		if activeStepId == "build_first_helper" and screenGui:GetAttribute(Attrs.MixerUnlockPresented) ~= true then
			hideCues()
			return
		end
		setCookieHighlight(activeStepId == "help_goo_recover")
		if
			(activeStepId == "build_first_helper" or activeStepId == "hire_another_noob")
			and screenGui:GetAttribute(Attrs.StoreOpen) == true
			and screenGui:GetAttribute(Attrs.PlacementActive) ~= true
		then
			local row = findUpgradeRow(screenGui, "Noob Clicker")
			if startCatchPulse(row) then
				pointer.Visible = false
				return
			end
		end
		stopCatchPulse()
		local screenPoint, targetInstance = resolveTarget(activeStepId)
		if not screenPoint then
			hideCues()
			return
		end
		liftRootAbove(targetInstance)
		local localPoint = screenPoint - root.AbsolutePosition
		pointer.Position = UDim2.fromOffset(localPoint.X, localPoint.Y)
		local wasVisible = pointer.Visible
		pointer.Visible = true
		if not wasVisible then
			pulse()
		end
	end

	pulse = function()
		if reducedMotion() or not (pointerScale and pointerScale:IsA("UIScale")) then
			return
		end
		if pulseTween then
			pulseTween:Cancel()
		end
		pointerScale.Scale = 0.9
		pulseTween = TweenService:Create(
			pointerScale,
			TweenInfo.new(0.65, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, -1, true),
			{ Scale = 1.12 }
		)
		pulseTween:Play()
	end

	local function activate(stepId)
		if activeStepId ~= stepId then
			stop()
			activeStepId = stepId
		end
		placePointer()
	end

	local function completeMixerUnlockPresentation()
		if player:GetAttribute(Attrs.MixerUnlocked) == true then
			screenGui:SetAttribute(Attrs.MixerUnlockPresented, true)
		end
	end

	local function playMixerUnlockFlight()
		if mixerFlightPlayed or mixerFlightPending then
			return
		end
		if not (flight and flight:IsA("ImageLabel")) then
			completeMixerUnlockPresentation()
			return
		end
		screenGui:SetAttribute(Attrs.MixerUnlockPresented, false)
		mixerFlightPending = true
		mixerFlightGeneration += 1
		local generation = mixerFlightGeneration
		task.spawn(function()
			local mascot
			local slot
			local icon
			local camera
			local destination
			local projected
			local deadline = os.clock() + MIXER_FLIGHT_RESOLVE_SECONDS
			repeat
				local sheet = findPlayerSheet(player)
				mascot = sheet and sheet:FindFirstChild("GooAlien")
				local hotbar = screenGui:FindFirstChild("Hotbar")
				slot = hotbar and hotbar:FindFirstChild("SlotCenter")
				icon = slot and slot:FindFirstChild("icon")
				camera = Workspace.CurrentCamera
				destination = centerOfGui(slot)
				local slotReady = screenGui:GetAttribute(Attrs.MixerUnlockSlotReady) == true
				if mascot and camera and destination then
					projected = camera:WorldToViewportPoint(mascot:GetPivot().Position)
				end
				if mascot and camera and destination and slotReady and projected and projected.Z > 0 then
					break
				end
				task.wait(0.1)
			until os.clock() >= deadline or generation ~= mixerFlightGeneration

			if
				generation ~= mixerFlightGeneration
				or not (mascot and camera and destination and screenGui:GetAttribute(Attrs.MixerUnlockSlotReady) == true and projected and projected.Z > 0)
				or not flight.Parent
			then
				mixerFlightPending = false
				if generation == mixerFlightGeneration then
					completeMixerUnlockPresentation()
				end
				return
			end

			mixerFlightPending = false
			mixerFlightPlayed = true
			local visual = flight:FindFirstChild("MixerUnlock", true)
			if not (visual and (visual:IsA("ImageLabel") or visual:IsA("ImageButton"))) then
				visual = flight
			end
			if visual ~= flight then
				flight.ImageTransparency = 0
			elseif visual.Image == "" and icon and (icon:IsA("ImageLabel") or icon:IsA("ImageButton")) then
				visual.Image = icon.Image
				visual.ImageColor3 = icon.ImageColor3
			end
			flight.AnchorPoint = Vector2.new(0.5, 0.5)
			flight.BackgroundTransparency = 1
			flight.Position =
				UDim2.fromOffset(projected.X - root.AbsolutePosition.X, projected.Y - root.AbsolutePosition.Y)
			flight.Visible = true
			visual.Visible = true
			visual.ImageTransparency = 0
			visual.ZIndex = math.max(visual.ZIndex, flight.ZIndex + 1)

			task.wait(MIXER_FLIGHT_START_HOLD_SECONDS)
			if generation ~= mixerFlightGeneration or not flight.Parent then
				return
			end
			local targetPosition =
				UDim2.fromOffset(destination.X - root.AbsolutePosition.X, destination.Y - root.AbsolutePosition.Y)
			if reducedMotion() then
				flight.Position = targetPosition
				task.wait(MIXER_FLIGHT_SECONDS)
			else
				local tween = TweenService:Create(
					flight,
					TweenInfo.new(MIXER_FLIGHT_SECONDS, Enum.EasingStyle.Quad, Enum.EasingDirection.InOut),
					{ Position = targetPosition }
				)
				tween:Play()
				tween.Completed:Wait()
			end
			if generation ~= mixerFlightGeneration or not flight.Parent then
				return
			end
			flight.Position = targetPosition
			task.wait(MIXER_FLIGHT_LANDING_HOLD_SECONDS)
			if generation == mixerFlightGeneration and flight.Parent then
				if reducedMotion() then
					visual.ImageTransparency = 1
				else
					local fade = TweenService:Create(
						visual,
						TweenInfo.new(MIXER_FLIGHT_FADE_SECONDS, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
						{ ImageTransparency = 1 }
					)
					fade:Play()
					fade.Completed:Wait()
				end
			end
			if generation == mixerFlightGeneration and flight.Parent then
				flight.Visible = false
				completeMixerUnlockPresentation()
			end
		end)
	end

	local function setSnapshot(snapshot)
		local _, previousQuest = QuestSnapshot.getTracked(currentSnapshot)
		local previousStepId = previousQuest and previousQuest.StepId
		currentSnapshot = snapshot
		local _, quest = QuestSnapshot.getTracked(snapshot)
		local nextStepId = quest and quest.StepId
		if activeStepId and activeStepId ~= nextStepId then
			stop()
		end
		if nextStepId ~= "build_first_helper" then
			mixerFlightGeneration += 1
			mixerFlightPending = false
			mixerFlightPlayed = false
			if flight and flight:IsA("GuiObject") then
				flight.Visible = false
			end
			if quest and quest.Completed == true then
				completeMixerUnlockPresentation()
			end
		elseif
			quest
			and quest.Completed ~= true
			and previousStepId ~= "build_first_helper"
			and nextStepId == "build_first_helper"
		then
			playMixerUnlockFlight()
		end

		if quest and quest.Completed ~= true and quest.GuideEnabled == true then
			activate(nextStepId)
		else
			stop()
		end
	end

	table.insert(connections, RunService.RenderStepped:Connect(placePointer))
	table.insert(connections, player.CharacterAdded:Connect(hideCues))
	table.insert(connections, UserInputService:GetPropertyChangedSignal("PreferredInput"):Connect(placePointer))
	table.insert(connections, screenGui:GetAttributeChangedSignal(Attrs.StoreOpen):Connect(placePointer))
	table.insert(connections, screenGui:GetAttributeChangedSignal(Attrs.PlacementActive):Connect(placePointer))
	table.insert(connections, screenGui:GetAttributeChangedSignal(Attrs.CompactModalActive):Connect(placePointer))
	table.insert(
		connections,
		screenGui:GetAttributeChangedSignal(Attrs.ReducedMotionEnabled):Connect(function()
			if activeStepId then
				stopCatchPulse()
				placePointer()
				if reducedMotion() then
					if pulseTween then
						pulseTween:Cancel()
						pulseTween = nil
					end
					if pointerScale and pointerScale:IsA("UIScale") then
						pointerScale.Scale = 1
					end
				else
					pulse()
				end
			end
		end)
	)

	return {
		stop = stop,
		setSnapshot = setSnapshot,
		destroy = function()
			stop()
			for _, connection in ipairs(connections) do
				connection:Disconnect()
			end
		end,
	}
end

return QuestProgressGuidance
