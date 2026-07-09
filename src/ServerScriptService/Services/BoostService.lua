-- BoostService: server-wide, time-limited production boost (purchased via the Robux Server
-- Boost product). Implemented by parking a NumberValue under ReplicatedStorage's
-- WorldEventMultipliers folder, which both click income (CookieService) and idle production
-- (ProductionFormula.GetEventMultiplier) already multiply into every player's earnings. So a
-- single value here boosts the whole server with no changes to the production math.
--
-- The remaining time is published as a synced attribute (ServerBoostEndsAt, in
-- workspace:GetServerTimeNow() units) so clients can show a countdown.
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local BoostService = {}

local FOLDER_NAME = "WorldEventMultipliers"
local VALUE_NAME = "ServerBoost"
local ENDS_AT_ATTR = "ServerBoostEndsAt"
local DEFAULT_MULTIPLIER = 2
local DEFAULT_DURATION_SECONDS = 300

local expiresAt = 0
local timerRunning = false

local function getFolder()
	local folder = ReplicatedStorage:FindFirstChild(FOLDER_NAME)
	if not folder then
		folder = Instance.new("Folder")
		folder.Name = FOLDER_NAME
		folder.Parent = ReplicatedStorage
	end
	return folder
end

local function getValue(create)
	local folder = getFolder()
	local value = folder:FindFirstChild(VALUE_NAME)
	if not value and create then
		value = Instance.new("NumberValue")
		value.Name = VALUE_NAME
		value.Value = 1
		value.Parent = folder
	end
	return value
end

local function clearBoost()
	local value = getValue(false)
	if value then
		value:Destroy()
	end
	ReplicatedStorage:SetAttribute(ENDS_AT_ATTR, nil)
end

local function startTimer()
	if timerRunning then
		return
	end
	timerRunning = true

	task.spawn(function()
		while true do
			local remaining = expiresAt - Workspace:GetServerTimeNow()
			if remaining <= 0 then
				break
			end
			task.wait(math.min(remaining, 1))
		end
		timerRunning = false
		-- Only clear if it wasn't extended by another purchase while we were waiting.
		if Workspace:GetServerTimeNow() >= expiresAt then
			clearBoost()
		end
	end)
end

-- Activates (or extends) the server-wide boost. Stacking re-purchases extend the duration
-- from the current expiry rather than overwriting it.
function BoostService.Activate(multiplier, durationSeconds)
	multiplier = multiplier or DEFAULT_MULTIPLIER
	durationSeconds = durationSeconds or DEFAULT_DURATION_SECONDS

	local now = Workspace:GetServerTimeNow()
	expiresAt = math.max(now, expiresAt) + durationSeconds

	local value = getValue(true)
	value.Value = multiplier
	ReplicatedStorage:SetAttribute(ENDS_AT_ATTR, expiresAt)

	startTimer()
end

function BoostService.IsActive()
	return Workspace:GetServerTimeNow() < expiresAt
end

function BoostService.GetRemainingSeconds()
	return math.max(0, expiresAt - Workspace:GetServerTimeNow())
end

function BoostService.Init()
	-- Ensure the multiplier folder exists so other systems can rely on it.
	getFolder()
end

return BoostService
