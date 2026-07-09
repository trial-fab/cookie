-- GoldenCookieService — the second economy (economy-rebalance-spec §6).
--
-- Golden cookies (GC) are earned ONLY through play and spent ONLY on wheel spins
-- (WheelService). No conversion to/from cookies or Robux ever (design invariants
-- 1 & 4). The earn rates, caps and odds below are a fixed spec contract — do not
-- change them without re-opening §6.
--
-- Sources:
--   • Clicking — 0.4% per *manual* validated click, rolling 25 GC/hour cap.
--     Autoclicks never reach here (CookieService gates on the `automated` flag).
--   • Map spawns — server-wide, every 4–6 min, 3–8 GC to the first toucher,
--     despawns after 60s.
--   • Daily streak — now a claim-based reward in the Lucky Spin → Daily tab
--     (DailyRewardService + DailyRewardConfig), not a silent grant here.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerStorage = game:GetService("ServerStorage")
local Workspace = game:GetService("Workspace")

local Net = require(ReplicatedStorage.Shared.Net)

local GoldenCookieService = {}

-- §6 earning constants (spec contract — do not retune here).
local CLICK_DROP_CHANCE = 0.004
local CLICK_HOURLY_CAP = 25
local ROLLING_WINDOW_SECONDS = 3600

local SPAWN_MIN_INTERVAL = 240 -- 4 min
local SPAWN_MAX_INTERVAL = 360 -- 6 min
local SPAWN_GC_MIN = 3
local SPAWN_GC_MAX = 8
local SPAWN_LIFETIME_SECONDS = 60
local SPAWN_CLICK_DISTANCE = 96

-- The downward probe used to rest the cookie on whatever surface is below the
-- chosen spot (the base, or the top of a building standing there). Starts well
-- above any plausible building height so tall structures are still detected.
local SPAWN_PROBE_HEIGHT = 200

-- The spawned golden cookie is a clone of this template (build/skin it in Studio,
-- swap in a mesh later). It can be a Model or a single BasePart. Lives in
-- ServerStorage so it isn't replicated until a clone is parented into Workspace.
local SPAWN_TEMPLATE_NAME = "GoldenCookieTemplate"

local GC_ATTRIBUTE = "GoldenCookies"

local random = Random.new()
local clickEarnTimestamps = {}
local cookieSheetsFolder
local spawnFolder

local function getOrCreateFolder(parent, name)
	local folder = parent:FindFirstChild(name)
	if folder then
		return folder
	end

	folder = Instance.new("Folder")
	folder.Name = name
	folder.Parent = parent
	return folder
end

function GoldenCookieService.GetGoldenCookies(player)
	local value = player:GetAttribute(GC_ATTRIBUTE)
	if typeof(value) == "number" then
		return math.max(0, math.floor(value))
	end
	return 0
end

function GoldenCookieService.SetGoldenCookies(player, amount)
	player:SetAttribute(GC_ATTRIBUTE, math.max(0, math.floor(amount)))
end

-- Adds GC to a player's balance and notifies the client (for toasts/UI). `source`
-- is informational only ("click" / "spawn" / "login" / "refund").
function GoldenCookieService.AddGoldenCookies(player, amount, source)
	amount = math.floor(tonumber(amount) or 0)
	if amount == 0 then
		return GoldenCookieService.GetGoldenCookies(player)
	end

	local newTotal = math.max(0, GoldenCookieService.GetGoldenCookies(player) + amount)
	player:SetAttribute(GC_ATTRIBUTE, newTotal)

	if amount > 0 then
		Net.fireClient(Net.Names.GoldenCookieEarned, player, amount, source or "unknown", newTotal)
	end

	return newTotal
end

-- Atomic spend used by WheelService. Single-threaded Luau guarantees the
-- read-check-write below is uninterrupted as long as it never yields.
function GoldenCookieService.TrySpend(player, amount)
	amount = math.floor(tonumber(amount) or 0)
	if amount <= 0 then
		return false
	end

	local balance = GoldenCookieService.GetGoldenCookies(player)
	if balance < amount then
		return false
	end

	player:SetAttribute(GC_ATTRIBUTE, balance - amount)
	return true
end

-- ── Clicking source ──────────────────────────────────────────────────────────

local function pruneClickTimestamps(timestamps, now)
	local cutoff = now - ROLLING_WINDOW_SECONDS
	local kept = {}
	for _, timestamp in ipairs(timestamps) do
		if timestamp >= cutoff then
			table.insert(kept, timestamp)
		end
	end
	return kept
end

-- Called for every *manual* validated click (CookieService). Rolls the 0.4% drop
-- and enforces the rolling 25 GC/hour cap so autoclicker-style spam earns nothing
-- extra. Returns the GC granted (0 or 1).
function GoldenCookieService.RollClickDrop(player)
	local now = os.clock()
	local timestamps = pruneClickTimestamps(clickEarnTimestamps[player] or {}, now)
	clickEarnTimestamps[player] = timestamps

	if #timestamps >= CLICK_HOURLY_CAP then
		return 0
	end

	if random:NextNumber() >= CLICK_DROP_CHANCE then
		return 0
	end

	table.insert(timestamps, now)
	GoldenCookieService.AddGoldenCookies(player, 1, "click")
	return 1
end

-- ── Map-spawn source ─────────────────────────────────────────────────────────

local function getOwnedSheetBases()
	local bases = {}
	if not cookieSheetsFolder then
		return bases
	end

	for _, sheet in ipairs(cookieSheetsFolder:GetChildren()) do
		local owner = sheet:FindFirstChild("SheetOwner")
		local base = sheet:FindFirstChild("Base")
		if owner and owner:IsA("ObjectValue") and owner.Value ~= nil and base and base:IsA("BasePart") then
			table.insert(bases, base)
		end
	end

	return bases
end

-- The parts a spawn may rest on: the base itself plus every placed building on
-- that sheet (Models carrying an Owner ObjectValue, same marker ProductionService
-- uses). Restricting the raycast to these means the cookie lands on the base or
-- on top of a building, never on the floating cookie/shield decorations.
local function collectSurfaceParts(sheet, base)
	local parts = { base }
	for _, child in ipairs(sheet:GetChildren()) do
		if child:IsA("Model") and child:FindFirstChild("Owner") then
			for _, descendant in ipairs(child:GetDescendants()) do
				if descendant:IsA("BasePart") then
					table.insert(parts, descendant)
				end
			end
		end
	end
	return parts
end

-- Picks a random spot over a base and returns the world point of the surface
-- directly below it (top of a building if one stands there, otherwise the base
-- top). Callers rest the cookie's underside on this Y so it sits flat.
local function pickSpawnSurface()
	local bases = getOwnedSheetBases()
	if #bases == 0 then
		return nil
	end

	local base = bases[random:NextInteger(1, #bases)]
	local sheet = base.Parent
	local halfX = (base.Size.X * 0.5) * 0.6
	local halfZ = (base.Size.Z * 0.5) * 0.6
	local x = base.Position.X + random:NextNumber(-halfX, halfX)
	local z = base.Position.Z + random:NextNumber(-halfZ, halfZ)
	local baseTop = base.Position.Y + base.Size.Y * 0.5

	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Include
	params.FilterDescendantsInstances = collectSurfaceParts(sheet, base)

	local origin = Vector3.new(x, baseTop + SPAWN_PROBE_HEIGHT, z)
	local result = Workspace:Raycast(origin, Vector3.new(0, -(SPAWN_PROBE_HEIGHT + base.Size.Y + 5), 0), params)

	local surfaceY = result and result.Position.Y or baseTop
	return Vector3.new(x, surfaceY, z)
end

local function getSpawnTemplate()
	local template = ServerStorage:FindFirstChild(SPAWN_TEMPLATE_NAME)
	if template and (template:IsA("Model") or template:IsA("BasePart")) then
		return template
	end
	return nil
end

-- The part used for click/touch interaction and positioning. For a Model this is
-- its PrimaryPart (or the first BasePart found); for a BasePart it's itself.
local function getInteractionPart(instance)
	if instance:IsA("BasePart") then
		return instance
	end
	return instance.PrimaryPart or instance:FindFirstChildWhichIsA("BasePart", true)
end

-- Rests `instance` flat on the surface at `surfacePoint` (the world point the
-- spawn raycast landed on) by sitting its underside on that Y.
local function restOnSurface(instance, surfacePoint)
	if instance:IsA("Model") then
		local pivot = instance:GetPivot()
		local boxCFrame, boxSize = instance:GetBoundingBox()
		local pivotToBottom = pivot.Position.Y - (boxCFrame.Position.Y - boxSize.Y * 0.5)
		instance:PivotTo(CFrame.new(surfacePoint.X, surfacePoint.Y + pivotToBottom, surfacePoint.Z))
	else
		instance.Position = Vector3.new(surfacePoint.X, surfacePoint.Y + instance.Size.Y * 0.5, surfacePoint.Z)
	end
end

local function spawnGoldenCookie()
	if #Players:GetPlayers() == 0 then
		return
	end

	local template = getSpawnTemplate()
	if not template then
		warn(
			"GoldenCookie spawn skipped: ServerStorage."
				.. SPAWN_TEMPLATE_NAME
				.. " (Model or BasePart) is missing."
		)
		return
	end

	local surfacePoint = pickSpawnSurface()
	if not surfacePoint then
		return
	end

	local instance = template:Clone()
	local interactionPart = getInteractionPart(instance)
	if not interactionPart then
		warn("GoldenCookie template has no BasePart to interact with; spawn skipped.")
		instance:Destroy()
		return
	end

	local reward = random:NextInteger(SPAWN_GC_MIN, SPAWN_GC_MAX)
	instance.Name = "GoldenCookie"
	instance:SetAttribute("RewardGC", reward)

	-- Anchor in place and make walk-through so a touch (or click) can claim it.
	for _, descendant in ipairs(instance:GetDescendants()) do
		if descendant:IsA("BasePart") then
			descendant.Anchored = true
		end
	end
	interactionPart.CanCollide = false

	restOnSurface(instance, surfacePoint)

	local clickDetector = interactionPart:FindFirstChildOfClass("ClickDetector")
	if not clickDetector then
		clickDetector = Instance.new("ClickDetector")
		clickDetector.Parent = interactionPart
	end
	clickDetector.MaxActivationDistance = SPAWN_CLICK_DISTANCE

	instance.Parent = spawnFolder

	local claimed = false
	local function claim(player)
		if claimed or not player or not player.Parent then
			return
		end
		claimed = true
		GoldenCookieService.AddGoldenCookies(player, reward, "spawn")
		instance:Destroy()
	end

	clickDetector.MouseClick:Connect(claim)
	interactionPart.Touched:Connect(function(hit)
		local character = hit and hit.Parent
		local player = character and Players:GetPlayerFromCharacter(character)
		if player then
			claim(player)
		end
	end)

	task.delay(SPAWN_LIFETIME_SECONDS, function()
		if not claimed and instance.Parent then
			instance:Destroy()
		end
	end)
end

local function startSpawnLoop()
	task.spawn(function()
		while true do
			task.wait(random:NextNumber(SPAWN_MIN_INTERVAL, SPAWN_MAX_INTERVAL))
			local ok, err = pcall(spawnGoldenCookie)
			if not ok then
				warn("GoldenCookie spawn failed: " .. tostring(err))
			end
		end
	end)
end

-- ── Player teardown ──────────────────────────────────────────────────────────

local function forgetPlayer(player)
	clickEarnTimestamps[player] = nil
end

function GoldenCookieService.Init()
	cookieSheetsFolder = Workspace:WaitForChild("CookieSheets")
	spawnFolder = getOrCreateFolder(Workspace, "GoldenCookieSpawns")

	-- Pre-create the server->client push channel so a client that boots first finds it
	-- immediately instead of hanging at WaitForChild until the first golden cookie earn.
	Net.event(Net.Names.GoldenCookieEarned)

	Players.PlayerRemoving:Connect(forgetPlayer)

	startSpawnLoop()
	print("GoldenCookieService initialized")
end

return GoldenCookieService
