-- FloatingOrbs -- levitation, load response, and fresh-placement reveal for tagged boost cores.
--
-- A fresh field initially replicates as the complete solid canister shown by its placement ghost.
-- Its existing Cap hinges open, the Core rises into its hover, and the non-colliding casing fades.
-- Restored fields carry only a Core and start directly in the established floating pose.
--
-- Tagged cores stay ANCHORED. Their bob and capped load dip are client-side CFrame effects, like
-- FloatingRuins: the local player's footfall responds without a server round trip, while a crowd
-- can never push the platform farther than SagLimit. The server makes the Core collidable/queryable
-- so every client can stand on it and identify it with the same filtered downward ray model.
--
-- Optional per-core attributes:
--   OrbFloatPhase   cycle offset as a fraction of one (Power 0, Speed 0.5).
--   OrbRestOffsetY  fresh canister Core -> floor-rest correction; restored cores use zero.

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Attrs = require(Shared:WaitForChild("Attrs"))
local BoostShopConfig = require(Shared:WaitForChild("BoostShopConfig"))
local CharacterSupportProbe = require(Shared:WaitForChild("CharacterSupportProbe"))
local Config = require(Shared:WaitForChild("FloatingOrbConfig"))

local TAG = "FloatingOrb"
local EXTRA_PLAYER_SHARE = 0.35

local localPlayer = Players.LocalPlayer
local playerGui = localPlayer:WaitForChild("PlayerGui")
local screenGui = playerGui:WaitForChild("ScreenGui", 10)

local function reducedMotionEnabled()
	return screenGui and screenGui:GetAttribute(Attrs.ReducedMotionEnabled) == true
end

local orbs = {}
local orbCount = 0

local contactParams = RaycastParams.new()
contactParams.FilterType = Enum.RaycastFilterType.Include
contactParams.RespectCanCollide = true

-- One shared cycle position, 0..1, looping forever. Linear on purpose: the ease belongs to the
-- sine each orb takes of it, so every orb can sit at its own phase of the same wave.
local cycle = Instance.new("NumberValue")
cycle.Name = "FloatCycle"
cycle.Parent = script

local cycleTween

local function numberAttribute(instance, name, fallback)
	local value = instance:GetAttribute(name)
	return type(value) == "number" and value or fallback
end

local function clampProgress(elapsed, delay, seconds)
	return math.clamp((elapsed - delay) / math.max(seconds, 0.01), 0, 1)
end

local function easeOutCubic(alpha)
	return 1 - (1 - alpha) ^ 3
end

local function smoothStep(alpha)
	return alpha * alpha * (3 - 2 * alpha)
end

local function applyCanisterPose(orb, elapsed)
	local canister = orb.canister
	if not (canister and canister.Parent) then
		return
	end

	local lidAlpha = easeOutCubic(clampProgress(elapsed, 0, Config.PlacementLidSeconds))
	local fadeAlpha = smoothStep(clampProgress(elapsed, Config.PlacementFadeDelay, Config.PlacementFadeSeconds))
	local cap = orb.cap
	if cap and cap.Parent and orb.capRestCFrame then
		-- The canister's Cylinder axis is local X (world up). Hinging around local Z at one rim edge
		-- makes the flat Cap open like a lid instead of spinning around its centre.
		local hingeRadius = cap.Size.Y / 2
		cap.CFrame = orb.capRestCFrame
			* CFrame.new(0, hingeRadius, 0)
			* CFrame.Angles(0, 0, math.rad(Config.PlacementLidDegrees) * lidAlpha)
			* CFrame.new(0, -hingeRadius, 0)
	end

	for part, originalTransparency in pairs(orb.canisterParts) do
		if part.Parent then
			part.Transparency = originalTransparency + (1 - originalTransparency) * fadeAlpha
		end
	end
end

local function placementElapsed(orb)
	if not orb.placementStartedAt then
		return nil
	end
	return math.max(0, Workspace:GetServerTimeNow() - orb.placementStartedAt)
end

-- Reduced Motion stops the idle bob, not the lift or the physical response: the core must stay
-- above the buildings and under the feet regardless of that accessibility preference.
local function applyPose()
	local on = Config.Enabled == true
	local hover = on and Config.HoverHeight or 0
	local amplitude = (on and not reducedMotionEnabled()) and Config.Amplitude or 0
	for part, orb in pairs(orbs) do
		local targetRise = hover + orb.restOffsetY
		local riseAlpha = 1
		local elapsed = placementElapsed(orb)
		if elapsed then
			riseAlpha = easeOutCubic(clampProgress(elapsed, Config.PlacementRiseDelay, Config.PlacementRiseSeconds))
			applyCanisterPose(orb, elapsed)
		end

		local rise = targetRise * riseAlpha
		if amplitude > 0 then
			rise += math.sin((cycle.Value + orb.phase) * math.pi * 2) * amplitude * riseAlpha
		end
		local coreScale = 1 + (Config.CoreFinalScale - 1) * riseAlpha
		part.Size = orb.restSize * coreScale
		part.CFrame = orb.restCFrame * CFrame.new(0, rise + orb.sag * riseAlpha, 0)
	end
end

local function stopCycle()
	if cycleTween then
		cycleTween:Cancel()
		cycleTween = nil
	end
	cycle.Value = 0
end

local function refreshCycle()
	stopCycle()
	if orbCount == 0 or Config.Enabled ~= true or reducedMotionEnabled() or Config.Amplitude <= 0 then
		applyPose()
		return
	end
	cycleTween = TweenService:Create(
		cycle,
		TweenInfo.new(math.max(Config.CycleSeconds, 0.05), Enum.EasingStyle.Linear, Enum.EasingDirection.InOut, -1),
		{ Value = 1 }
	)
	cycleTween:Play()
	applyPose()
end

local function refreshContactFilter()
	local filter = {}
	for part in pairs(orbs) do
		table.insert(filter, part)
	end
	contactParams.FilterDescendantsInstances = filter
end

local contacts = {}

-- One filtered support-volume cast per living player asks what their footprint is actually standing
-- on. It still responds immediately for the local player, but unlike a centre ray it keeps contact
-- when only part of the avatar is supported near a round Core's edge.
local function gatherContacts()
	table.clear(contacts)
	for _, player in ipairs(Players:GetPlayers()) do
		local result = CharacterSupportProbe.find(player.Character, contactParams)
		if result and orbs[result.Instance] then
			contacts[result.Instance] = (contacts[result.Instance] or 0) + 1
		end
	end
end

local function updateLoad(deltaTime)
	if orbCount == 0 then
		return
	end
	gatherContacts()
	-- Clamp after a hitch so the explicit spring does not explode when Studio regains focus.
	local step = math.min(deltaTime, 1 / 15)
	local damping = math.exp(-Config.SagDamping * step)
	for part, orb in pairs(orbs) do
		local count = contacts[part] or 0
		local target = -math.min(Config.SagDepth * (1 + math.max(0, count - 1) * EXTRA_PLAYER_SHARE), Config.SagLimit)
		if count == 0 then
			target = 0
		end
		orb.sagVelocity += (target - orb.sag) * Config.SagStiffness * step
		orb.sagVelocity *= damping
		orb.sag += orb.sagVelocity * step
	end
	applyPose()
end

local function bindOrb(part)
	if not part:IsA("BasePart") or orbs[part] then
		return
	end

	local field = part.Parent
	local placementStartedAt = part:GetAttribute(BoostShopConfig.PlacementAnimationAttribute)
	local canister
	if type(placementStartedAt) == "number" and field then
		-- A tagged Core can arrive before its sibling casing. Waiting only on fresh-placement cores
		-- avoids delaying restored fields, which intentionally have no canister at all.
		canister = field:FindFirstChild(BoostShopConfig.PlacementCanisterName)
			or field:WaitForChild(BoostShopConfig.PlacementCanisterName, 2)
	end
	if type(placementStartedAt) ~= "number" or not (canister and canister:IsA("Model")) then
		placementStartedAt = nil
		canister = nil
	end

	local orb = {
		-- Captured once. The optional correction maps the canister-height starting core back to the
		-- same floor-rest pose used by restored fields before HoverHeight is added.
		restCFrame = part.CFrame,
		restSize = part.Size,
		restOffsetY = numberAttribute(part, BoostShopConfig.OrbRestOffsetAttribute, 0),
		phase = numberAttribute(part, "OrbFloatPhase", 0),
		sag = 0,
		sagVelocity = 0,
		placementStartedAt = placementStartedAt,
		canister = canister,
		canisterParts = {},
		cap = nil,
		capRestCFrame = nil,
		canisterAddedConn = nil,
	}
	orbs[part] = orb

	local function rememberCanisterPart(descendant)
		if not descendant:IsA("BasePart") then
			return
		end
		orb.canisterParts[descendant] = descendant.Transparency
		if descendant.Name == BoostShopConfig.PlacementCanisterCapPartName then
			orb.cap = descendant
			orb.capRestCFrame = descendant.CFrame
		end
	end
	if canister then
		for _, descendant in ipairs(canister:GetDescendants()) do
			rememberCanisterPart(descendant)
		end
		orb.canisterAddedConn = canister.DescendantAdded:Connect(rememberCanisterPart)
	end

	orbCount += 1
	refreshContactFilter()
	refreshCycle()
end

local function unbindOrb(part)
	local orb = orbs[part]
	if not orb then
		return
	end
	orbs[part] = nil
	orbCount -= 1
	if orb.canisterAddedConn then
		orb.canisterAddedConn:Disconnect()
	end
	if part.Parent then
		part.CFrame = orb.restCFrame
		part.Size = orb.restSize
	end
	refreshContactFilter()
	refreshCycle()
end

cycle:GetPropertyChangedSignal("Value"):Connect(applyPose)

for _, part in ipairs(CollectionService:GetTagged(TAG)) do
	bindOrb(part)
end
CollectionService:GetInstanceAddedSignal(TAG):Connect(bindOrb)
CollectionService:GetInstanceRemovedSignal(TAG):Connect(unbindOrb)

if screenGui then
	screenGui:GetAttributeChangedSignal(Attrs.ReducedMotionEnabled):Connect(refreshCycle)
end

RunService.Heartbeat:Connect(updateLoad)
refreshCycle()
