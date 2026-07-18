-- BuildSuggestionNudge: the first-placement Build View nudge (BuildViewSuggestion frame).
-- Shown the first time a placement starts this session, unless the player permanently
-- disabled it (server-persisted player attribute). Split out of BuildViewController.
--
-- ctx: { player, screenGui, enterBuildView, isBuildViewActive }. Exposes maybeShow(),
-- hide(), and onEnterBuildView() (hide + suppress for the rest of the session).
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local shared = ReplicatedStorage:WaitForChild("Shared")
local Net = require(shared:WaitForChild("Net"))
local Attrs = require(shared:WaitForChild("Attrs"))

local BuildSuggestionNudge = {}
local PLACEMENT_CONTROLS_GAP_PIXELS = 8

function BuildSuggestionNudge.new(ctx)
	local player = ctx.player
	local screenGui = ctx.screenGui
	local enterBuildView = ctx.enterBuildView
	local isBuildViewActive = ctx.isBuildViewActive

	-- Remembered for the whole session: once the player dismisses (or uses) the nudge we
	-- never auto-suggest again until a fresh session reloads this script.
	local suggestionDismissedThisSession = false

	local suggestion = screenGui:FindFirstChild("BuildViewSuggestion")
	local suggestionEnter = suggestion and suggestion:FindFirstChild("Enter")
	local suggestionDismiss = suggestion and suggestion:FindFirstChild("Dismiss")
	local suggestionDontShowAgain = suggestion and suggestion:FindFirstChild("DontShowAgain")
	if suggestionDontShowAgain and not suggestionDontShowAgain:IsA("GuiButton") then
		suggestionDontShowAgain = nil
	end
	local suggestionDontShowCheck = suggestionDontShowAgain and suggestionDontShowAgain:FindFirstChild("check")
	local hotbar = screenGui:FindFirstChild("Hotbar")
	local defaultSuggestionPosition = suggestion and suggestion.Position

	local function placementControlsExist()
		if not (hotbar and hotbar:IsA("GuiObject")) then
			return false
		end
		if screenGui:GetAttribute(Attrs.PlacementControlsEnabled) == true then
			for _, slotName in ipairs({ "SlotLeft", "SlotCenter", "SlotRight" }) do
				local slot = hotbar:FindFirstChild(slotName)
				if slot and slot:FindFirstChild("PlacementFace") then
					return true
				end
			end
		end
		if screenGui:GetAttribute(Attrs.MultiPlaceSessionActive) == true then
			local centerSlot = hotbar:FindFirstChild("SlotCenter")
			return centerSlot and centerSlot:FindFirstChild("MultiPlaceFace") ~= nil
		end
		return false
	end

	local function updateSuggestionPosition()
		if not (suggestion and defaultSuggestionPosition) then
			return
		end
		if placementControlsExist() then
			local hotbarTopOffset = hotbar.Position.Y.Offset - hotbar.AbsoluteSize.Y * hotbar.AnchorPoint.Y
			suggestion.Position = UDim2.new(
				defaultSuggestionPosition.X.Scale,
				defaultSuggestionPosition.X.Offset,
				hotbar.Position.Y.Scale,
				math.round(hotbarTopOffset - PLACEMENT_CONTROLS_GAP_PIXELS)
			)
		else
			suggestion.Position = defaultSuggestionPosition
		end
	end
	if suggestion then
		updateSuggestionPosition()
		suggestion.Visible = false
	end

	-- Whether the player has ticked "don't show again" on THIS open nudge (applied when the
	-- nudge closes). Mirrors the checkmark graphic when present.
	local dontShowAgainChecked = false
	local function setDontShowAgainChecked(checked)
		dontShowAgainChecked = checked
		if suggestionDontShowCheck and suggestionDontShowCheck:IsA("GuiObject") then
			suggestionDontShowCheck.Visible = checked
		end
	end
	setDontShowAgainChecked(false)

	local function hideSuggestion()
		if suggestion then
			suggestion.Visible = false
		end
	end

	-- Persisted "never nudge me again" choice, replicated by the server as a player
	-- attribute (see PlayerSetupService). Read live so it reflects an earlier session.
	local function isNudgePermanentlyDisabled()
		return player:GetAttribute(Attrs.BuildViewNudgeDisabled) == true
	end

	-- Apply whatever the player ticked on the nudge before it closes. If "don't show
	-- again" was checked, tell the server to persist it (it stays hidden forever after).
	local function commitDontShowAgain()
		if dontShowAgainChecked then
			Net.fireServer(Net.Names.DisableBuildViewNudge)
		end
		setDontShowAgainChecked(false)
	end

	local function maybeShowSuggestion()
		if not suggestion then
			return
		end
		if isBuildViewActive() or suggestionDismissedThisSession or isNudgePermanentlyDisabled() then
			return
		end
		-- Shown on PC and mobile the first time a placement starts this session.
		setDontShowAgainChecked(false)
		updateSuggestionPosition()
		suggestion.Visible = true
	end

	for _, attribute in ipairs({ Attrs.PlacementControlsEnabled, Attrs.MultiPlaceSessionActive }) do
		screenGui:GetAttributeChangedSignal(attribute):Connect(updateSuggestionPosition)
	end
	if hotbar and hotbar:IsA("GuiObject") then
		hotbar:GetPropertyChangedSignal("Position"):Connect(updateSuggestionPosition)
		hotbar:GetPropertyChangedSignal("AbsoluteSize"):Connect(updateSuggestionPosition)
	end

	if suggestionDontShowAgain then
		suggestionDontShowAgain.Activated:Connect(function()
			setDontShowAgainChecked(not dontShowAgainChecked)
		end)
	end

	if suggestionEnter and suggestionEnter:IsA("GuiButton") then
		suggestionEnter.Activated:Connect(function()
			commitDontShowAgain()
			hideSuggestion()
			enterBuildView()
		end)
	end

	if suggestionDismiss and suggestionDismiss:IsA("GuiButton") then
		suggestionDismiss.Activated:Connect(function()
			suggestionDismissedThisSession = true
			commitDontShowAgain()
			hideSuggestion()
		end)
	end

	local function onEnterBuildView()
		-- Entering counts as "answered": hide the nudge and suppress it this session.
		suggestionDismissedThisSession = true
		hideSuggestion()
	end

	return {
		maybeShow = maybeShowSuggestion,
		hide = hideSuggestion,
		onEnterBuildView = onEnterBuildView,
	}
end

return BuildSuggestionNudge
