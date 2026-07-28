local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local GlobalLeaderboardConfig = require(Shared:WaitForChild("GlobalLeaderboardConfig"))
local Net = require(Shared:WaitForChild("Net"))
local NumberFormat = require(Shared:WaitForChild("NumberFormat"))

local player = Players.LocalPlayer
local system = workspace:WaitForChild("HubPlazaDraft", 30)
system = system and system:WaitForChild("LeaderboardSystem", 30)
if not system then
	warn("GlobalLeaderboards disabled: Workspace.HubPlazaDraft.LeaderboardSystem was not found")
	return
end

local boardsByMetricId = {}

local function findText(row, name)
	local label = row and row:FindFirstChild(name)
	return label and label:IsA("TextLabel") and label or nil
end

local function setRow(row, rank, playerName, score)
	if not row then
		return
	end
	local rankLabel = findText(row, "Rank")
	local nameLabel = findText(row, "PlayerName")
	local scoreLabel = findText(row, "Score")
	if rankLabel then
		rankLabel.Text = rank
	end
	if nameLabel then
		nameLabel.Text = playerName
	end
	if scoreLabel then
		scoreLabel.Text = score
	end
end

local function formatScore(definition, score)
	if definition.Format == "Rate" then
		return NumberFormat.rate(score) .. "/s"
	end
	return NumberFormat.abbreviate(score)
end

local function bindBoards()
	for _, definition in ipairs(GlobalLeaderboardConfig.Definitions) do
		local hud = system:FindFirstChild(definition.HudName)
		local panel
		if hud then
			for _, child in ipairs(hud:GetChildren()) do
				if child:IsA("BasePart") and child:FindFirstChildWhichIsA("SurfaceGui") then
					panel = child
					break
				end
			end
		end
		local surfaceGui = panel and panel:FindFirstChildWhichIsA("SurfaceGui")
		local backdrop = surfaceGui and surfaceGui:FindFirstChild("Backdrop")
		local heading = backdrop and backdrop:FindFirstChild("Heading")
		local rows = backdrop and backdrop:FindFirstChild("Rows")
		if not (heading and heading:IsA("TextLabel") and rows and rows:IsA("Frame")) then
			warn(("GlobalLeaderboards: authored HUD contract is incomplete for %s"):format(definition.HudName))
			continue
		end

		heading.Text = definition.Heading
		for rank = 1, GlobalLeaderboardConfig.TopCount do
			setRow(rows:FindFirstChild(("Rank%02d"):format(rank)), "", "", "")
		end
		setRow(rows:FindFirstChild("YourRank"), "--", player.DisplayName, "--")
		boardsByMetricId[definition.Id] = {
			definition = definition,
			rows = rows,
		}
	end
end

local function renderUnavailable(message)
	for _, board in pairs(boardsByMetricId) do
		for rank = 1, GlobalLeaderboardConfig.TopCount do
			setRow(board.rows:FindFirstChild(("Rank%02d"):format(rank)), "", "", "")
		end
		setRow(board.rows:FindFirstChild("Rank01"), "--", message, "--")
		setRow(board.rows:FindFirstChild("YourRank"), "--", player.DisplayName, "--")
	end
end

local function renderSnapshot(snapshot)
	for metricId, board in pairs(boardsByMetricId) do
		local metric = snapshot.Metrics and snapshot.Metrics[metricId]
		if metric then
			for rank = 1, GlobalLeaderboardConfig.TopCount do
				local row = board.rows:FindFirstChild(("Rank%02d"):format(rank))
				local entry = metric.Top and metric.Top[rank]
				if entry then
					setRow(row, "#" .. tostring(entry.Rank), entry.Name, formatScore(board.definition, entry.Score))
				else
					setRow(row, "", "", "")
				end
			end

			local current = metric.CurrentPlayer
			setRow(
				board.rows:FindFirstChild("YourRank"),
				current and "#" .. tostring(current.Rank) or "--",
				player.DisplayName,
				current and formatScore(board.definition, current.Score) or "--"
			)
		end
	end
end

local function refresh()
	local success, snapshot = pcall(Net.invoke, Net.Names.GetGlobalLeaderboards)
	if not success or type(snapshot) ~= "table" or snapshot.Success ~= true then
		local message = type(snapshot) == "table" and snapshot.Message or "Data unavailable"
		renderUnavailable(message or "Data unavailable")
		return false
	end
	renderSnapshot(snapshot)
	return true
end

bindBoards()

task.spawn(function()
	while not refresh() do
		task.wait(5)
	end
	while true do
		task.wait(GlobalLeaderboardConfig.RefreshSeconds)
		refresh()
	end
end)
