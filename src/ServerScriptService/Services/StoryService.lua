local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local ServerScriptService = game:GetService("ServerScriptService")
local ServerStorage = game:GetService("ServerStorage")

local Services = ServerScriptService:WaitForChild("Services")
local SheetService = require(Services:WaitForChild("SheetService"))
local GooSkinService = require(Services:WaitForChild("GooSkinService"))
local MascotService = require(Services:WaitForChild("MascotService"))
local PlayerDataProjectionAudit = require(Services:WaitForChild("PlayerDataProjectionAudit"))
local PlayerDataService = require(Services:WaitForChild("PlayerDataService"))

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

local function getPersistent(player)
	local data = PlayerDataService.Get(player)
	local persistent = type(data) == "table" and data.Persistent
	return type(persistent) == "table" and persistent or nil
end

local function getStoryValue(player, field, fallback)
	local persistent = getPersistent(player)
	local value = persistent and persistent[field]
	if value == nil then
		return fallback
	end
	return value
end

local function setStoryValue(player, field, attribute, value)
	local persistent = getPersistent(player)
	if not persistent then
		return false
	end

	persistent[field] = value
	player:SetAttribute(attribute, persistent[field])
	return true
end

local function getHealingClicks(player)
	return tonumber(getStoryValue(player, "StoryHealingClicks", 0)) or 0
end

local function getMixerUnlocked(player)
	return getStoryValue(player, "MixerUnlocked", false) == true
end

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
	return getStoryValue(player, "StoryStep", StoryConfig.STEPS.Meteor)
end

local function getStoryTemplate(player)
	local selectedId = GooSkinService.GetSelectedSkinId(player)
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
		chapter = getStoryValue(player, "StoryChapter", StoryConfig.CHAPTER_ID),
		step = getStep(player),
		healingClicks = getHealingClicks(player),
		mixerUnlocked = getMixerUnlocked(player),
	})
end

local function setStep(player, step)
	if setStoryValue(player, "StoryStep", Attrs.StoryStep, step) then
		broadcastState(player)
	end
end

local function setMascotPresentation(player)
	local mascot = mascotByPlayer[player]
	if not mascot then
		return
	end

	local sheet = SheetService.GetPlayerSheet(player)
	local step = getStep(player)
	local healingClicks = getHealingClicks(player)
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
	local persistent = getPersistent(player)
	if not persistent then
		return
	end

	-- Preserve the existing loaded projection semantics, but normalize Data first so the
	-- attributes remain projections rather than inputs to the story state machine.
	persistent.IntroSeen = persistent.IntroSeen == true
	persistent.StoryChapter = StoryConfig.CHAPTER_ID
	persistent.StoryStep = persistent.StoryStep or StoryConfig.STEPS.Meteor
	persistent.StoryHealingClicks = tonumber(persistent.StoryHealingClicks) or 0
	persistent.MixerUnlocked = persistent.MixerUnlocked == true

	player:SetAttribute(Attrs.IntroSeen, persistent.IntroSeen)
	player:SetAttribute(Attrs.StoryChapter, persistent.StoryChapter)
	player:SetAttribute(Attrs.StoryStep, persistent.StoryStep)
	player:SetAttribute(Attrs.StoryHealingClicks, persistent.StoryHealingClicks)
	player:SetAttribute(Attrs.MixerUnlocked, persistent.MixerUnlocked)
	PlayerDataProjectionAudit.MarkStoryProjectionReady(player)

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
			and getHealingClicks(player) >= StoryConfig.HEALING_CLICKS
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

	local clicks = math.min(StoryConfig.HEALING_CLICKS, getHealingClicks(player) + 1)
	if not setStoryValue(player, "StoryHealingClicks", Attrs.StoryHealingClicks, clicks) then
		return
	end

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

function StoryService.MarkIntroSeen(player)
	if getStep(player) == StoryConfig.STEPS.Meteor then
		return false
	end
	return setStoryValue(player, "IntroSeen", Attrs.IntroSeen, true)
end

local function handleAction(player, action)
	if action == "RubbleCleared" and getStep(player) == StoryConfig.STEPS.Meteor then
		if transitioningByPlayer[player] then
			return
		end
		local transitionVersion = beginTransition(player)
		if not setStoryValue(player, "StoryHealingClicks", Attrs.StoryHealingClicks, 0) then
			finishTransition(player, transitionVersion)
			return
		end
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
			setStoryValue(player, "IntroSeen", Attrs.IntroSeen, true)
			-- If a cosmetic swap occurred during RevealFromSquash's yield, apply the new
			-- step to the replacement model instead of leaving it in the hidden Meteor pose.
			setMascotPresentation(player)
		end
		finishTransition(player, transitionVersion)
	elseif action == "CompleteLore" and getStep(player) == StoryConfig.STEPS.Lore then
		setStoryValue(player, "MixerUnlocked", Attrs.MixerUnlocked, true)
		setStep(player, StoryConfig.STEPS.BuildTask)
		setMascotPresentation(player)
	elseif action == "RequestState" then
		broadcastState(player)
	elseif action == "ResetChapter" then
		local persistent = getPersistent(player)
		if not persistent then
			return
		end
		transitionVersionByPlayer[player] = (transitionVersionByPlayer[player] or 0) + 1
		transitioningByPlayer[player] = nil

		-- Reset the canonical chapter as one group before publishing any projected changes.
		persistent.IntroSeen = false
		persistent.StoryChapter = StoryConfig.CHAPTER_ID
		persistent.StoryStep = StoryConfig.STEPS.Meteor
		persistent.StoryHealingClicks = 0
		persistent.MixerUnlocked = false

		player:SetAttribute(Attrs.IntroSeen, persistent.IntroSeen)
		player:SetAttribute(Attrs.StoryChapter, persistent.StoryChapter)
		player:SetAttribute(Attrs.StoryStep, persistent.StoryStep)
		player:SetAttribute(Attrs.StoryHealingClicks, persistent.StoryHealingClicks)
		player:SetAttribute(Attrs.MixerUnlocked, persistent.MixerUnlocked)
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
