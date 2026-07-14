local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local StarterGui = game:GetService("StarterGui")
local UiMotion = require(game:GetService("ReplicatedStorage"):WaitForChild("Shared"):WaitForChild("UiMotion"))
local UserInputService = game:GetService("UserInputService")
local NumberFormat = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("NumberFormat"))
local Attrs = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Attrs"))
local MobileScale = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("MobileScale"))

local screenGui = script:FindFirstAncestorOfClass("ScreenGui")
if not screenGui then
	warn("LeaderboardController must be inside a ScreenGui")
	return
end
if screenGui:GetAttribute("LeaderboardControllerRunning") then
	return
end
screenGui:SetAttribute("LeaderboardControllerRunning", true)

local ModalCoordinator = require(
	screenGui:WaitForChild("Controllers"):WaitForChild("Modals"):WaitForChild("ModalCoordinator")
)

local localPlayer = Players.LocalPlayer
local panel = screenGui:WaitForChild("Leaderboard", 10)
if not panel or not panel:IsA("GuiObject") then
	warn("LeaderboardController disabled: ScreenGui.Leaderboard was not found")
	return
end

local rowTemplate = panel:WaitForChild("RowTemplate", 10)
if not rowTemplate or not rowTemplate:IsA("GuiObject") then
	warn("LeaderboardController disabled: Leaderboard.RowTemplate was not found")
	return
end
rowTemplate.Visible = false

-- Scale the board on phones only: a fixed, gentle 0.78 on touch viewports and exactly 1 on PC (no
-- desktop shrink, even on sub-1080 windows). getClosedPosition() reads AbsoluteSize lazily, so the
-- off-screen slide stays correct at either scale.
MobileScale.applyMobileScale(panel, { mobileScale = 0.78 })

-- baseOpenPosition is the authored resting spot; openPosition folds in the mobile 10px nudge
-- (see the onViewportChanged hook below) and is what the slide tweens target.
local baseOpenPosition = panel.Position
local openPosition = MobileScale.shiftLeftOnMobile(baseOpenPosition, 10, panel)
local slideInfo = TweenInfo.new(0.22, Enum.EasingStyle.Quart, Enum.EasingDirection.Out)
local slideTween = nil
-- On mobile the HUD takes over this top-right slot, so the board starts closed there (the HUD
-- shows first, and opening the board hides it). On PC the authored spawn state is kept.
local leaderboardOpen = panel.Visible and not MobileScale.shouldUseMobile(panel)
screenGui:SetAttribute(Attrs.LeaderboardOpen, leaderboardOpen)

local function getClosedPosition()
	local hiddenX = panel.AnchorPoint.X * panel.AbsoluteSize.X + 16
	return UDim2.new(1, hiddenX, openPosition.Y.Scale, openPosition.Y.Offset)
end

local function getBoardToggle()
	local boardToggle = screenGui:FindFirstChild("BoardToggle")
	if boardToggle and boardToggle:IsA("GuiObject") then
		return boardToggle
	end
	return nil
end

local function setBoardToggleActive(active)
	local boardToggle = getBoardToggle()
	if not boardToggle then
		return
	end

	boardToggle:SetAttribute(Attrs.Open, active)
	boardToggle:SetAttribute(Attrs.Active, active)

	local hitbox = boardToggle:FindFirstChild("Hitbox")
	if hitbox then
		hitbox:SetAttribute(Attrs.Active, active)
	end
end

local function setLeaderboardVisible(visible, animate)
	if visible and ModalCoordinator.isOpen() then
		if screenGui:GetAttribute(Attrs.CompactModalActive) == true then
			return
		end
		ModalCoordinator.overrideBackground(false, true)
		return
	end
	leaderboardOpen = visible
	setBoardToggleActive(visible)
	-- Publish state so the bottom-right HUD (which shares this top-right slot on mobile) can hide
	-- itself while the board is open and reappear when it closes.
	screenGui:SetAttribute(Attrs.LeaderboardOpen, visible)

	if slideTween then
		slideTween:Cancel()
		slideTween = nil
	end

	local closedPosition = getClosedPosition()
	if visible then
		panel.Visible = true
		if animate then
			panel.Position = closedPosition
			slideTween = UiMotion.create(panel, slideInfo, { Position = openPosition })
			slideTween.Completed:Once(function()
				if slideTween then
					slideTween = nil
				end
			end)
			slideTween:Play()
		else
			panel.Position = openPosition
		end
	else
		if animate then
			slideTween = UiMotion.create(panel, slideInfo, { Position = closedPosition })
			slideTween.Completed:Once(function()
				if not leaderboardOpen then
					panel.Visible = false
				end
				if slideTween then
					slideTween = nil
				end
			end)
			slideTween:Play()
		else
			panel.Position = closedPosition
			panel.Visible = false
		end
	end
end

local function toggleLeaderboard()
	setLeaderboardVisible(not leaderboardOpen, true)
end

-- ModalCoordinator and StoreToggleController close the board through its published
-- attribute. Mirror external changes back into the controller's local animation state.
screenGui:GetAttributeChangedSignal(Attrs.LeaderboardOpen):Connect(function()
	local requestedOpen = screenGui:GetAttribute(Attrs.LeaderboardOpen) == true
	if requestedOpen ~= leaderboardOpen then
		setLeaderboardVisible(requestedOpen, true)
	end
end)

-- Keep the mobile nudge in sync across orientation changes; re-pin if resting open.
MobileScale.onViewportChanged(function()
	openPosition = MobileScale.shiftLeftOnMobile(baseOpenPosition, 10, panel)
	if leaderboardOpen and not slideTween then
		panel.Position = openPosition
	end
end)

task.spawn(function()
	for _ = 1, 10 do
		local ok = pcall(function()
			StarterGui:SetCoreGuiEnabled(Enum.CoreGuiType.PlayerList, false)
		end)
		if ok then
			return
		end
		task.wait(0.5)
	end
end)

local rowsByPlayer = {}
local connectionsByPlayer = {}
local resortScheduled = false

local function formatPlayTime(totalSeconds)
	local hours = math.floor(totalSeconds / 3600)
	local minutes = math.floor((totalSeconds % 3600) / 60)
	local seconds = totalSeconds % 60

	if totalSeconds >= 3600 then
		return string.format("%02d:%02d", hours, minutes)
	end

	return string.format("%02d:%02d", minutes, seconds)
end

local function findText(row, name)
	local instance = row:FindFirstChild(name, true)
	if instance and (instance:IsA("TextLabel") or instance:IsA("TextButton")) then
		return instance
	end

	return nil
end

local function setText(label, text)
	if label then
		label.Text = text
	end
end

local function scheduleResort()
	if resortScheduled then
		return
	end

	resortScheduled = true
	task.defer(function()
		resortScheduled = false

		local entries = {}
		for player, row in pairs(rowsByPlayer) do
			table.insert(entries, { player = player, cookies = row.cookies })
		end

		table.sort(entries, function(left, right)
			if left.cookies ~= right.cookies then
				return left.cookies > right.cookies
			end
			return left.player.Name < right.player.Name
		end)

		for rank, entry in ipairs(entries) do
			local row = rowsByPlayer[entry.player]
			if row then
				row.frame.LayoutOrder = rank
				setText(row.rankLabel, "#" .. rank)
			end
		end
	end)
end

local function createRow(player)
	local frame = rowTemplate:Clone()
	frame.Name = player.Name
	frame:SetAttribute("GeneratedByLeaderboardController", true)
	frame.LayoutOrder = 999
	frame.Visible = true
	frame.Parent = panel

	local nameLabel = findText(frame, "PlayerName")
	local rankLabel = findText(frame, "Rank")
	local timeLabel = findText(frame, "PlayTime")
	local costLabel = findText(frame, "Cost")

	setText(nameLabel, player.DisplayName)
	setText(rankLabel, "#-")
	setText(timeLabel, "00:00")
	setText(costLabel, "0")

	return {
		frame = frame,
		rankLabel = rankLabel,
		timeLabel = timeLabel,
		costLabel = costLabel,
		cookies = 0,
		playTimeBase = 0,
		playTimeBaseAt = os.clock(),
	}
end

local function watchPlayer(player)
	if rowsByPlayer[player] then
		return
	end

	local row = createRow(player)
	rowsByPlayer[player] = row
	local connections = {}
	connectionsByPlayer[player] = connections
	scheduleResort()

	task.spawn(function()
		local leaderstats = player:WaitForChild("leaderstats", 30)
		local cookies = leaderstats and leaderstats:WaitForChild("Cookies", 30)
		if not cookies or rowsByPlayer[player] ~= row then
			return
		end

		local function updateCookies()
			row.cookies = cookies.Value
			setText(row.costLabel, NumberFormat.abbreviate(cookies.Value))
			scheduleResort()
		end

		table.insert(connections, cookies.Changed:Connect(updateCookies))
		updateCookies()
	end)

	task.spawn(function()
		local realPlayTime = player:WaitForChild("RealPlayTime", 30)
		if not realPlayTime or rowsByPlayer[player] ~= row then
			return
		end

		local function updateBase()
			row.playTimeBase = realPlayTime.Value
			row.playTimeBaseAt = os.clock()
		end

		table.insert(connections, realPlayTime.Changed:Connect(updateBase))
		updateBase()
	end)
end

local function forgetPlayer(player)
	local connections = connectionsByPlayer[player]
	if connections then
		for _, connection in ipairs(connections) do
			connection:Disconnect()
		end
		connectionsByPlayer[player] = nil
	end

	local row = rowsByPlayer[player]
	if row then
		rowsByPlayer[player] = nil
		row.frame:Destroy()
		scheduleResort()
	end
end

for _, player in ipairs(Players:GetPlayers()) do
	watchPlayer(player)
end
Players.PlayerAdded:Connect(watchPlayer)
Players.PlayerRemoving:Connect(forgetPlayer)

task.spawn(function()
	while true do
		task.wait(1)
		for _, row in pairs(rowsByPlayer) do
			local estimated = row.playTimeBase + math.floor(os.clock() - row.playTimeBaseAt)
			setText(row.timeLabel, formatPlayTime(estimated))
		end
	end
end)

task.spawn(function()
	local deadline = os.clock() + 10
	local boardToggle
	local hitbox
	repeat
		boardToggle = getBoardToggle()
		hitbox = boardToggle and boardToggle:FindFirstChild("Hitbox")
		if not hitbox then
			task.wait(0.25)
		end
	until hitbox or os.clock() > deadline

	setLeaderboardVisible(leaderboardOpen, false)

	if hitbox and hitbox:IsA("GuiButton") then
		hitbox.Activated:Connect(function()
			toggleLeaderboard()
		end)
	end
end)

UserInputService.InputBegan:Connect(function(input, gameProcessed)
	if gameProcessed then
		return
	end
	if input.KeyCode == Enum.KeyCode.Tab then
		toggleLeaderboard()
	end
end)
