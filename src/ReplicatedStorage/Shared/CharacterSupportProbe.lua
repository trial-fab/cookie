-- CharacterSupportProbe -- footprint-aware test for the tagged surface supporting an avatar.
--
-- A vertical ray from HumanoidRootPart only represents the character's centre. That is adequate on
-- a broad slab, but it drops contact while an avatar still has a foot on a slab edge, and especially
-- while standing off-centre on a round Core. A small downward sphere cast represents the avatar's
-- horizontal footprint without extending the old vertical reach. Side-only contacts are rejected,
-- so brushing past a platform wall does not count as standing on it.

local Workspace = game:GetService("Workspace")

local CharacterSupportProbe = {}

local CONTACT_SLACK = 1.5
local FOOTPRINT_SCALE = 0.35
local MIN_FOOTPRINT_RADIUS = 0.45
local MAX_FOOTPRINT_RADIUS = 0.75
local MIN_SUPPORT_NORMAL_Y = 0.2

-- Returns a RaycastResult for the included collidable surface supporting `character`, or nil.
-- `params` remains caller-owned so each animation system can restrict hits to its own tagged parts.
function CharacterSupportProbe.find(character, params)
	local root = character and character:FindFirstChild("HumanoidRootPart")
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	if not (root and humanoid and humanoid.Health > 0) then
		return nil
	end

	-- Derived from the live avatar so R6, R15, and scaled characters keep the same semantics. The
	-- sphere widens the old centre ray but its bottom stops at the exact same vertical endpoint.
	local reach = humanoid.HipHeight + root.Size.Y / 2 + CONTACT_SLACK
	local radius =
		math.clamp(math.max(root.Size.X, root.Size.Z) * FOOTPRINT_SCALE, MIN_FOOTPRINT_RADIUS, MAX_FOOTPRINT_RADIUS)
	local castDistance = math.max(reach - radius, 0.05)
	local result = Workspace:Spherecast(root.Position, radius, Vector3.new(0, -castDistance, 0), params)
	if result and result.Normal.Y >= MIN_SUPPORT_NORMAL_Y then
		return result
	end
	return nil
end

return CharacterSupportProbe
