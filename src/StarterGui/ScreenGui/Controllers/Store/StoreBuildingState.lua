-- StoreBuildingState — a building's persistent lock state + the "alien name" reveal.
--
--   • Lock state: a building is LOCKED until it has ever been purchased. Unlock is a
--     persistent server fact (Attrs.UnlockedBuildingsJson), mirrored here; selling back to
--     zero keeps it unlocked. StorePreview reads this for the silhouette (via ctx.isBuildingLocked).
--   • Name reveal: while a building is locked its name is shown as scrambled "alien" glyphs;
--     when it first unlocks the name de-scrambles left-to-right over a short animation, driven
--     from the orchestrator's RenderStepped tick (ctx.buildingState.updateBuildingNameReveals()).
--   • isBuildingUpgradeRevealed: a leveled building-upgrade row only appears once its target
--     building is owned.
--
-- Extracted from StoreController's main chunk (Luau 200-local cap). The orchestrator reaches
-- it through ctx.buildingState.* / ctx.isBuildingLocked / ctx.startLockedBuildingNameReveal —
-- no top-level re-aliases (see WORKFLOW.md "Code organization").
--
-- ctx deps: player, UpgradeConfig, getOwnedCount, setText.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local HttpService = game:GetService("HttpService")
local Attrs = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Attrs"))

local ALIEN_NAME_LENGTH = 9
local NAME_REVEAL_DELAY_SECONDS = 0.1
local NAME_FLIP_DELAY_SECONDS = 0.06
local SAFE_ALIEN_CHARS = {
	"#", "@", "%", "*", "+", "=", "?", "!", "/", "\\", "|",
	"[", "]", "{", "}", "(", ")", ":", ";", ".", ",",
	"^", "_", "~", "-",
}

local StoreBuildingState = {}

function StoreBuildingState.new(ctx)
	local player = ctx.player
	local UpgradeConfig = ctx.UpgradeConfig
	local getOwnedCount = ctx.getOwnedCount
	local setText = ctx.setText

	-- §4a: reveal a leveled building upgrade once the player owns at least one of
	-- the target building, then keep it locked until the next level's threshold.
	-- Once any level is owned it stays visible (showing the next level or MAXED).
	local function isBuildingUpgradeRevealed(upgradeId, config)
		local levels = config.Levels
		if not levels or #levels == 0 then
			return false
		end

		if getOwnedCount(upgradeId) > 0 then
			return true
		end

		return getOwnedCount(config.TargetBuilding) >= 1
	end

	-- Persistent unlocked-building set, mirrored from the UnlockedBuildingsJson attribute.
	local unlockedBuildings = {}
	local function refreshUnlockedBuildings()
		local ok, decoded = pcall(function()
			return HttpService:JSONDecode(player:GetAttribute(Attrs.UnlockedBuildingsJson) or "{}")
		end)
		unlockedBuildings = (ok and type(decoded) == "table") and decoded or {}
	end
	refreshUnlockedBuildings()

	-- A building is locked until it has ever been purchased (stays unlocked after sells).
	local function isBuildingLocked(upgradeId, config)
		return config.TemplateKind == "Building" and not unlockedBuildings[upgradeId]
	end

	local alienNameRandom = Random.new()
	local alienNamesByUpgradeId = {}
	local nameRevealAnimations = {}
	local function randomizeAlienBuildingName(upgradeId)
		local characters = table.create(ALIEN_NAME_LENGTH)
		for index = 1, ALIEN_NAME_LENGTH do
			local previousCharacter = characters[index - 1]
			local character
			repeat
				character = SAFE_ALIEN_CHARS[alienNameRandom:NextInteger(1, #SAFE_ALIEN_CHARS)]
			until character ~= previousCharacter
			characters[index] = character
		end

		alienNamesByUpgradeId[upgradeId] = characters
		return table.concat(characters)
	end

	local function getAlienBuildingName(upgradeId)
		local characters = alienNamesByUpgradeId[upgradeId]
		return characters and table.concat(characters) or randomizeAlienBuildingName(upgradeId)
	end

	local function generateScrambleCharacters(target, revealedCount)
		local characters = table.create(#target)
		for index = 1, #target do
			local targetCharacter = string.sub(target, index, index)
			if index <= revealedCount or targetCharacter == " " then
				characters[index] = targetCharacter
			else
				local previousCharacter = characters[index - 1]
				local character
				repeat
					character = SAFE_ALIEN_CHARS[alienNameRandom:NextInteger(1, #SAFE_ALIEN_CHARS)]
				until character ~= previousCharacter
				characters[index] = character
			end
		end

		return characters
	end

	local function startBuildingNameReveal(upgradeId, row, target)
		if not row or target == "" then
			return
		end

		local now = os.clock()
		local scrambleCharacters = generateScrambleCharacters(target, 0)
		nameRevealAnimations[upgradeId] = {
			row = row,
			target = target,
			startedAt = now,
			lastFlipAt = now,
			revealedCount = 0,
			scrambleCharacters = scrambleCharacters,
		}
		setText(row, "UpgradeName", table.concat(scrambleCharacters))
	end

	local function startLockedBuildingNameReveal(upgradeId, row)
		local config = UpgradeConfig[upgradeId]
		if row and config and isBuildingLocked(upgradeId, config) then
			startBuildingNameReveal(upgradeId, row, getAlienBuildingName(upgradeId))
		end
	end

	local function updateBuildingNameReveals()
		local now = os.clock()
		for upgradeId, animation in pairs(nameRevealAnimations) do
			if not animation.row.Parent then
				nameRevealAnimations[upgradeId] = nil
				continue
			end

			local targetLength = #animation.target
			local revealedCount = math.min(targetLength, math.floor((now - animation.startedAt) / NAME_REVEAL_DELAY_SECONDS))
			if revealedCount >= targetLength then
				setText(animation.row, "UpgradeName", animation.target)
				nameRevealAnimations[upgradeId] = nil
				continue
			end

			if revealedCount ~= animation.revealedCount or now - animation.lastFlipAt >= NAME_FLIP_DELAY_SECONDS then
				animation.revealedCount = revealedCount
				animation.lastFlipAt = now
				animation.scrambleCharacters = generateScrambleCharacters(animation.target, revealedCount)
				setText(animation.row, "UpgradeName", table.concat(animation.scrambleCharacters))
			end
		end
	end

	-- updateRow suppresses its own name write while a reveal animation is running for this row.
	local function isNameRevealing(upgradeId)
		return nameRevealAnimations[upgradeId] ~= nil
	end

	return {
		isBuildingUpgradeRevealed = isBuildingUpgradeRevealed,
		refreshUnlockedBuildings = refreshUnlockedBuildings,
		isBuildingLocked = isBuildingLocked,
		getAlienBuildingName = getAlienBuildingName,
		startBuildingNameReveal = startBuildingNameReveal,
		startLockedBuildingNameReveal = startLockedBuildingNameReveal,
		updateBuildingNameReveals = updateBuildingNameReveals,
		isNameRevealing = isNameRevealing,
	}
end

return StoreBuildingState
