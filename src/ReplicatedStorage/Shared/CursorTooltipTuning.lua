-- CursorTooltipTuning: approved CursorTooltip content and section visibility.
-- Baked from the live CursorTooltip DevTuning registry on 2026-07-16.
-- Description copy is intentionally retained while its switches are off so a future
-- opt-in detailed-help setting can expose it without recreating the text.

local CursorTooltipTuning = {}

local HINTS = {
	Menu = {
		enabled = true,
		showTitle = true,
		title = "Menu",
		showDescription = false,
		descriptionOff = "Open Help, Profile, Rewards, and Settings.",
		descriptionOn = "Close the menu.",
	},
	Help = {
		enabled = true,
		showTitle = true,
		title = "Help",
		showDescription = false,
		description = "Read controls, tips, and game information.",
	},
	Profile = {
		enabled = true,
		showTitle = true,
		title = "Profile",
		showDescription = false,
		description = "View your progress, stats, and achievements.",
	},
	Rewards = {
		enabled = true,
		showTitle = true,
		title = "Rewards",
		showDescription = false,
		description = "Spend golden cookies on rewards and view your collection.",
	},
	Settings = {
		enabled = true,
		showTitle = true,
		title = "Settings",
		showDescription = false,
		description = "Adjust audio, controls, and accessibility options.",
	},
	Leaderboard = {
		enabled = true,
		showTitle = true,
		title = "Leaderboard",
		showKeybind = true,
		keybind = "Tab",
		showDescription = false,
		descriptionOff = "View player rankings in this server.",
		descriptionOn = "Close the player leaderboard.",
	},
	MixerClosed = {
		enabled = true,
		showTitle = true,
		title = "Mixer",
		showKeybind = true,
		keybind = "B",
		showDescription = false,
		description = "Open the Mixer to buy and place buildings and upgrades.",
	},
	MixerOpen = {
		enabled = true,
		showTitle = true,
		title = "Mixer",
		showKeybind = true,
		keybind = "B",
		showDescription = false,
		description = "Close the Mixer and return to the game.",
	},
	BuildView = {
		enabled = true,
		showTitle = true,
		title = "Build View",
		showKeybind = true,
		keybind = "V",
		showDescription = false,
		descriptionOff = "Switch to the top-down placement camera to arrange your buildings.",
		descriptionOn = "Return to the normal character camera.",
	},
	StatsEye = {
		enabled = true,
		showTitle = true,
		title = "Stats",
		showDescription = false,
		descriptionOff = "Show every building card's stats.",
		descriptionOn = "Hide every building card's stats.",
	},
	MultiPlaceToolbar = {
		enabled = true,
		showTitle = true,
		title = "Multi-place",
		showDescription = false,
	},
	StoreBuildSell = {
		enabled = true,
		showTitle = true,
		titleOff = "Build",
		titleOn = "Sell",
		showDescription = false,
	},
	PlacementCancel = {
		enabled = true,
		showTitle = false,
		title = "Cancel",
		showKeybind = true,
		keybind = "X",
		showDescription = false,
	},
	PlacementRotate = {
		enabled = true,
		showTitle = false,
		title = "Rotate",
		showKeybind = true,
		keybind = "R",
		showDescription = false,
	},
	PlacementPlace = {
		enabled = true,
		showTitle = false,
		title = "Place",
		showKeybind = true,
		keybind = "C",
		showDescription = false,
	},
}

local BUILDING_STATS = {
	enabled = true,
	showTitle = true,
	showOwned = true,
	showProduction = true,
	showMultiplier = true,
}

function CursorTooltipTuning.getHint(target, active)
	local config = HINTS[target]
	if not config or not config.enabled then
		return nil
	end

	local description = config.description
	if config.descriptionOn then
		description = active and config.descriptionOn or config.descriptionOff
	end
	local title = config.title
	if config.titleOn then
		title = active and config.titleOn or config.titleOff
	end

	return {
		mode = "Hint",
		title = config.showTitle and title or nil,
		keybind = config.showKeybind and config.keybind or nil,
		description = config.showDescription and description or nil,
	}
end

function CursorTooltipTuning.getBuildingStatsSections()
	return BUILDING_STATS
end

return CursorTooltipTuning
