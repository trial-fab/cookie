local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local ServerScriptService = game:GetService("ServerScriptService")
local ServerStorage = game:GetService("ServerStorage")

local Services = ServerScriptService:WaitForChild("Services")
local SheetService = require(Services:WaitForChild("SheetService"))
local MascotService = require(Services:WaitForChild("MascotService"))

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Attrs = require(Shared:WaitForChild("Attrs"))
local Net = require(Shared:WaitForChild("Net"))
local StoryConfig = require(Shared:WaitForChild("StoryConfig"))
local GooSkinAssets = require(Shared:WaitForChild("GooSkinAssets"))

local StoryService = {}
local mascotByPlayer = {}
local transitioningByPlayer = {}
local transitionVersionByPlayer = {}
local skinConnectionByPlayer = {}

local function beginTransition(player)
	local version = (transitionVersionByPlayer[player] or 0) + 1
	transitionVersionByPlayer[player] = version
	transitioningByPlayer[player] = true
	return version
end

local function transitionIsCurrent(player, version)
	return player.Parent ~= nil and transitionVersionByPlayer[player] == version
end

local function finishTransition(player, version)
	if transitionVersionByPlayer[player] == version then
		transitioningByPlayer[player] = nil
	end
end

local function getStep(player)
	return player:GetAttribute(Attrs.StoryStep) or StoryConfig.STEPS.Meteor
end

local function getStoryTemplate(player)
	local selectedId = player and player:GetAttribute(Attrs.SelectedGooSkinId)
	local selected = GooSkinAssets.Resolve(selectedId)
	if selected then
		return selected
	end

	-- Authoring fallback while the shared skin asset library is being synced into a place.
	local assets = ServerStorage:FindFirstChild("StoryAssets")
	local template = assets and assets:FindFirstChild("GooAlienTemplate")
	if template and template:IsA("Model") then
		return template
	end
	return nil
end

local function getAnchor(sheet, name)
	local center = sheet and sheet:FindFirstChild("Center")
	local anchor = center and center:FindFirstChild(name)
	if anchor and anchor:IsA("Attachment") then
		return anchor
	end
	return nil
end

local function broadcastState(player)
	Net.fireClient(Net.Names.StoryStateChanged, player, {
		chapter = player:GetAttribute(Attrs.StoryChapter),
		step = getStep(player),
		healingClicks = player:GetAttribute(Attrs.StoryHealingClicks) or 0,
		mixerUnlocked = player:GetAttribute(Attrs.MixerUnlocked) == true,
	})
end

local function setStep(player, step)
	player:SetAttribute(Attrs.StoryStep, step)
	broadcastState(player)
end

local function setMascotPresentation(player)
	local mascot = mascotByPlayer[player]
	if not mascot then
		return
	end

	local sheet = SheetService.GetPlayerSheet(player)
	local step = getStep(player)
	local healingClicks = player:GetAttribute(Attrs.StoryHealingClicks) or 0
	local idleAnchor = getAnchor(sheet, "AlienIdleAnchor")
	local revealAnchor = getAnchor(sheet, "AlienRevealAnchor")

	if step == StoryConfig.STEPS.Meteor then
		MascotService.SetVisible(mascot, false)
		if revealAnchor then
			MascotService.MoveToAnchor(mascot, revealAnchor)
		end
	elseif step == StoryConfig.STEPS.Healing then
		MascotService.SetVisible(mascot, true)
		MascotService.SetDizzy(mascot, true)
		MascotService.SetColorProgress(mascot, healingClicks / StoryConfig.HEALING_CLICKS, false)
		if revealAnchor then
			MascotService.MoveToAnchor(mascot, revealAnchor)
		end
	else
		MascotService.SetVisible(mascot, true)
		MascotService.SetDizzy(mascot, false)
		MascotService.SetColorProgress(mascot, 1, false)
		if idleAnchor then
			MascotService.MoveToAnchor(mascot, idleAnchor)
		end
	end
end

local function spawnMascot(player)
	local sheet = SheetService.GetPlayerSheet(player)
	if not sheet then
		return nil
	end

	local old = sheet:FindFirstChild("GooAlien")
	if old then
		MascotService.Unregister(old)
		old:Destroy()
	end

	local template = getStoryTemplate(player)
	if not template then
		warn("StoryService: ServerStorage.StoryAssets.GooAlienTemplate is missing.")
		return nil
	end

	local mascot = template:Clone()
	mascot.Name = "GooAlien"
	mascot:SetAttribute("StoryOwnerUserId", player.UserId)
	mascot.Parent = sheet
	mascotByPlayer[player] = mascot
	MascotService.Register(mascot)
	setMascotPresentation(player)
	return mascot
end

local function finishHealing(player)
	if getStep(player) ~= StoryConfig.STEPS.Healing or transitioningByPlayer[player] then
		return
	end
	local transitionVersion = beginTransition(player)
	task.spawn(function()
		local mascot = mascotByPlayer[player]
		if mascot then
			MascotService.SetDizzy(mascot, false)
			MascotService.PlayRainbow(mascot)
		end
		if not transitionIsCurrent(player, transitionVersion) then
			return
		end

		-- A cosmetic selection may replace the full model during the rainbow yield. Always
		-- reacquire the current mascot before the hop instead of retaining a stale instance.
		mascot = mascotByPlayer[player]
		local sheet = SheetService.GetPlayerSheet(player)
		local idleAnchor = getAnchor(sheet, "AlienIdleAnchor")
		if mascot and idleAnchor then
			MascotService.SetDizzy(mascot, false)
			MascotService.HopToAuthoredAnchor(mascot, idleAnchor)
		end
		if transitionIsCurrent(player, transitionVersion) and getStep(player) == StoryConfig.STEPS.Healing then
			setStep(player, StoryConfig.STEPS.Lore)
		end
		finishTransition(player, transitionVersion)
	end)
end

function StoryService.SetupPlayer(player)
	player:SetAttribute(Attrs.StoryChapter, StoryConfig.CHAPTER_ID)
	if player:GetAttribute(Attrs.StoryStep) == nil then
		player:SetAttribute(Attrs.StoryStep, StoryConfig.STEPS.Meteor)
	end
	if player:GetAttribute(Attrs.StoryHealingClicks) == nil then
		player:SetAttribute(Attrs.StoryHealingClicks, 0)
	end
	if player:GetAttribute(Attrs.MixerUnlocked) == nil then
		player:SetAttribute(Attrs.MixerUnlocked, false)
	end
	spawnMascot(player)
	if skinConnectionByPlayer[player] then
		skinConnectionByPlayer[player]:Disconnect()
	end
	skinConnectionByPlayer[player] = player:GetAttributeChangedSignal(Attrs.SelectedGooSkinId):Connect(function()
		-- Cosmetic selection is independent from the best-owned production bonus. Replacing the
		-- full authored model also makes healing settle toward that skin's DefaultBodyColor.
		spawnMascot(player)
		if
			getStep(player) == StoryConfig.STEPS.Healing
			and (player:GetAttribute(Attrs.StoryHealingClicks) or 0) >= StoryConfig.HEALING_CLICKS
			and not transitioningByPlayer[player]
		then
			finishHealing(player)
		end
	end)
	broadcastState(player)
end

function StoryService.OnCookieClicked(player)
	if getStep(player) ~= StoryConfig.STEPS.Healing or transitioningByPlayer[player] then
		return
	end

	local clicks = math.min(StoryConfig.HEALING_CLICKS, (player:GetAttribute(Attrs.StoryHealingClicks) or 0) + 1)
	player:SetAttribute(Attrs.StoryHealingClicks, clicks)

	local mascot = mascotByPlayer[player]
	if mascot then
		MascotService.SetColorProgress(mascot, clicks / StoryConfig.HEALING_CLICKS, true)
	end

	if clicks >= StoryConfig.HEALING_CLICKS then
		finishHealing(player)
	else
		broadcastState(player)
	end
end

function StoryService.OnBuildingPlaced(player, upgradeId)
	if getStep(player) ~= StoryConfig.STEPS.BuildTask or upgradeId ~= StoryConfig.FIRST_BUILDING_ID then
		return
	end

	setStep(player, StoryConfig.STEPS.Complete)
	local mascot = mascotByPlayer[player]
	if mascot then
		task.spawn(function()
			MascotService.PlayJoy(mascot)
		end)
	end
end

local function playDebugJoy(player)
	if not RunService:IsStudio() then
		return
	end

	local mascot = mascotByPlayer[player] or spawnMascot(player)
	if not mascot then
		return
	end

	local sheet = SheetService.GetPlayerSheet(player)
	local idleAnchor = getAnchor(sheet, "AlienIdleAnchor")
	MascotService.SetDizzy(mascot, false)
	MascotService.SetColorProgress(mascot, 1, false)
	if idleAnchor then
		MascotService.MoveToAnchor(mascot, idleAnchor)
	end
	MascotService.ResetShape(mascot)
	MascotService.SetVisible(mascot, true)

	task.spawn(function()
		MascotService.PlayJoy(mascot)
	end)
end

local function handleAction(player, action)
	if action == "RubbleCleared" and getStep(player) == StoryConfig.STEPS.Meteor then
		if transitioningByPlayer[player] then
			return
		end
		local transitionVersion = beginTransition(player)
		player:SetAttribute(Attrs.StoryHealingClicks, 0)
		local mascot = mascotByPlayer[player]
		local sheet = SheetService.GetPlayerSheet(player)
		local revealAnchor = getAnchor(sheet, "AlienRevealAnchor")
		if mascot and revealAnchor then
			MascotService.SetDizzy(mascot, true)
			MascotService.SetColorProgress(mascot, 0, false)
			MascotService.RevealFromSquash(mascot, revealAnchor)
		end
		if transitionIsCurrent(player, transitionVersion) and getStep(player) == StoryConfig.STEPS.Meteor then
			setStep(player, StoryConfig.STEPS.Healing)
			-- StoryStep advances before IntroSeen, with no yield between the writes. A save at any
			-- boundary is therefore either replay-safe (Meteor + unseen) or a valid Healing state.
			player:SetAttribute(Attrs.IntroSeen, true)
			-- If a cosmetic swap occurred during RevealFromSquash's yield, apply the new
			-- step to the replacement model instead of leaving it in the hidden Meteor pose.
			setMascotPresentation(player)
		end
		finishTransition(player, transitionVersion)
	elseif action == "CompleteLore" and getStep(player) == StoryConfig.STEPS.Lore then
		player:SetAttribute(Attrs.MixerUnlocked, true)
		setStep(player, StoryConfig.STEPS.BuildTask)
		setMascotPresentation(player)
	elseif action == "RequestState" then
		broadcastState(player)
	elseif action == "ResetChapter" then
		transitionVersionByPlayer[player] = (transitionVersionByPlayer[player] or 0) + 1
		transitioningByPlayer[player] = nil
		player:SetAttribute(Attrs.IntroSeen, false)
		player:SetAttribute(Attrs.StoryChapter, StoryConfig.CHAPTER_ID)
		player:SetAttribute(Attrs.StoryStep, StoryConfig.STEPS.Meteor)
		player:SetAttribute(Attrs.StoryHealingClicks, 0)
		player:SetAttribute(Attrs.MixerUnlocked, false)
		setMascotPresentation(player)
		broadcastState(player)
	elseif action == "DebugPlayJoy" then
		playDebugJoy(player)
	end
end

function StoryService.Init()
	Net.event(Net.Names.StoryStateChanged)
	Net.on(Net.Names.StoryAction, handleAction)

	Players.PlayerRemoving:Connect(function(player)
		local mascot = mascotByPlayer[player]
		if mascot then
			MascotService.Unregister(mascot)
		end
		mascotByPlayer[player] = nil
		if skinConnectionByPlayer[player] then
			skinConnectionByPlayer[player]:Disconnect()
		end
		skinConnectionByPlayer[player] = nil
		transitioningByPlayer[player] = nil
		transitionVersionByPlayer[player] = nil
	end)

	print("StoryService initialized")
end

return StoryService
