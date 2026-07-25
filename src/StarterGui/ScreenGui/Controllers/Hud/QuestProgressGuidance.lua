-- Optional, client-only guidance for the currently selected authoritative quest.
-- It moves only Studio-authored cue instances and never reports objective completion.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")

local Attrs = require(ReplicatedStorage.Shared.Attrs)

local QuestProgressGuidance = {}
local GUIDE_BLUE = Color3.fromRGB(0, 170, 255)
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
				cookieHighlight.FillColor = GUIDE_BLUE
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
	end

	local function stop()
		activeStepId = nil
		hideCues()
	end

	local function resolveTarget(stepId)
		if stepId == "help_goo_recover" then
			local sheet = findPlayerSheet(player)
			local cookie = sheet and sheet:FindFirstChild("Cookie")
			local camera = Workspace.CurrentCamera
			if cookie and cookie:IsA("BasePart") and camera then
				local projected, visible
				if screenGui.IgnoreGuiInset then
					projected, visible = camera:WorldToScreenPoint(cookie.Position)
				else
					projected, visible = camera:WorldToViewportPoint(cookie.Position)
				end
				if visible and projected.Z > 0 then
					return Vector2.new(projected.X, projected.Y)
				end
			end
		elseif stepId == "unlock_mixer" then
			local dialogue = screenGui:FindFirstChild("StoryDialogue")
			if not (dialogue and dialogue:IsA("GuiObject") and dialogue.Visible) then
				return nil
			end
			local continueButton = dialogue and dialogue:FindFirstChild("Continue", true)
			return centerOfGui(continueButton) or centerOfGui(dialogue)
		elseif stepId == "build_first_helper" then
			local hotbar = screenGui:FindFirstChild("Hotbar")
			if screenGui:GetAttribute(Attrs.PlacementActive) == true then
				return centerOfGui(hotbar and hotbar:FindFirstChild("SlotRight"))
			end
			if screenGui:GetAttribute(Attrs.StoreOpen) == true then
				return centerOfGui(findUpgradeRow(screenGui, "Noob Clicker"))
			end
			return centerOfGui(hotbar and hotbar:FindFirstChild("SlotCenter"))
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
			activeStepId == "build_first_helper"
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
		local screenPoint = resolveTarget(activeStepId)
		if not screenPoint then
			hideCues()
			return
		end
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
		local previousStepId = currentSnapshot
			and currentSnapshot.Arcs
			and currentSnapshot.Arcs[1]
			and currentSnapshot.Arcs[1].Quests[1]
			and currentSnapshot.Arcs[1].Quests[1].StepId
		currentSnapshot = snapshot
		local quest = snapshot
			and snapshot.Arcs
			and snapshot.Arcs[1]
			and snapshot.Arcs[1].Quests
			and snapshot.Arcs[1].Quests[1]
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
