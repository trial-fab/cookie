-- Single source of truth for the cross-file instance-attribute names.
-- Reference an attribute as `Attrs.OpenModal` instead of the string literal `"OpenModal"`.
-- A typo'd key resolves to `nil`, which `:GetAttribute(nil)` / `:SetAttribute(nil, ...)`
-- rejects with a loud error at the call site -- instead of the old failure mode where a
-- misspelled string literal silently read back `nil` and desynced two controllers.
--
-- Scope: only attributes shared across 2+ files (server writes / client reads, or written and
-- watched by separate controllers) plus a few doc-named singles. Per-file private flags
-- (e.g. `*ControllerRunning` init guards, cosmetic `*Image` pairs) intentionally stay as
-- literals -- they carry no cross-file desync risk. See docs/shared-modules-design.md (B1).
return {
	-- UI / button state (read+written across menu, store, modal, social controllers)
	Active = "Active",
	IconOnly = "IconOnly",
	Open = "Open",
	-- True while the leaderboard panel is open (LeaderboardController owns it). On mobile the
	-- bottom-right HUD moves into the leaderboard's top-right slot, so it hides itself while the
	-- board is open and reappears when it closes (BottomRightHudController reads this).
	LeaderboardOpen = "LeaderboardOpen",
	Hovering = "Hovering",
	OpenModal = "OpenModal",
	-- True while a main modal has temporarily taken ownership of Store and Leaderboard
	-- visibility. Store-owned confirmations do not set this because their background remains live.
	BackgroundSurfacesSuspended = "BackgroundSurfacesSuspended",
	-- True only while one of the four main menu modals owns the slot on a compact touch viewport.
	-- HUD owners compose this into visibility/input rules, while the menu uses it to switch to its
	-- transparent modal presentation. Tablets and desktop-sized touch devices remain false.
	CompactModalActive = "CompactModalActive",
	CompactMenuRestoreRequested = "CompactMenuRestoreRequested",
	-- Accessibility/performance preference: pauses selected continuous decorative motion while
	-- leaving ordinary UI transitions and gameplay/world animation intact.
	ReducedMotionEnabled = "ReducedMotionEnabled",
	-- Server-granted game-pass entitlement. Unlike Reduced Motion, this is the only state
	-- allowed to skip the wheel animation entirely.
	InstantWheelSpinEnabled = "InstantWheelSpinEnabled",
	MusicEnabled = "MusicEnabled",
	SfxEnabled = "SfxEnabled",
	-- Server flips this after persisted preferences have been mirrored onto the Player. The
	-- Settings client waits for it before replacing device-aware ScreenGui defaults.
	SettingsLoaded = "SettingsLoaded",
	-- Optional Studio-authored Sound attribute. Set to "Music" or "SoundEffect" to
	-- route the Sound through the matching settings-controlled SoundGroup.
	AudioCategory = "AudioCategory",
	HideStatus = "HideStatus",
	UiStyleWired = "UiStyleWired",

	-- store / placement / build
	UpgradeId = "UpgradeId",
	CountAdjusted = "CountAdjusted",
	PlacementActive = "PlacementActive",
	-- Mobile always uses the fixed placement hotbar. On PC this preference lets players opt into
	-- the same screen-space controls instead of click-to-place plus keyboard shortcuts.
	PlacementControlsEnabled = "PlacementControlsEnabled",
	-- Transient one-shot handoff intent. StorePlacement sets this for a successful single
	-- placement so HotbarPlacementMode clears its controls before StoreBottom returns.
	PlacementInstantExit = "PlacementInstantExit",
	PlacementRotationY = "PlacementRotationY",
	-- Stable vertical-floor identity. The server writes FloorId on every placed
	-- building; placement clients own ActiveFloorId locally until floor-selection UI ships.
	FloorId = "FloorId",
	FloorOrder = "FloorOrder",
	FloorUnlocked = "FloorUnlocked",
	UnlockedFloorCount = "UnlockedFloorCount",
	ActiveFloorId = "ActiveFloorId",
	-- Stable radial slot identity for a generated CookieSheet and its matching crater sector.
	PlotSlotIndex = "PlotSlotIndex",
	MultiPlaceEnabled = "MultiPlaceEnabled",
	-- Client-owned state for one live Multi Place run. The active flag controls the desktop
	-- session affordances; the count increments only after a successful server purchase.
	MultiPlaceSessionActive = "MultiPlaceSessionActive",
	MultiPlaceSessionCount = "MultiPlaceSessionCount",
	UpgradeRemindersEnabled = "UpgradeRemindersEnabled",
	CurrentCategory = "CurrentCategory",
	UseGeneratedMenu = "UseGeneratedMenu",
	BuildViewNudgeDisabled = "BuildViewNudgeDisabled",
	-- True while the player is in build mode (BuildViewController owns it). The free-fly
	-- placement camera is active. The store band is shown when (StoreOpen or BuildModeActive)
	-- and not PlacementActive (StoreVisibilityController reacts).
	BuildModeActive = "BuildModeActive",
	-- True while the StoreBottom band is open (StoreToggleController owns it). Independent of
	-- build mode: B / the cookie toggle drive it directly; entering build mode also opens it.
	StoreOpen = "StoreOpen",
	-- When true, opening the store also enters build mode (and closing exits). Device-aware
	-- default: off on PC, on on mobile. Owned by SettingsController; BuildViewController reads.
	AutoBuildMode = "AutoBuildMode",
	-- True while the store's Sell mode is on (StoreController owns it). StoreToggleAnimator
	-- watches it to swap the active toggle's Build/Sell label.
	SellMode = "SellMode",

	-- onboarding: server writes from persisted data, IntroController (client) reads to decide
	-- whether to play the first-time meteor cutscene; client flips it once via MarkIntroSeen.
	IntroSeen = "IntroSeen",
	StoryChapter = "StoryChapter",
	StoryStep = "StoryStep",
	StoryHealingClicks = "StoryHealingClicks",
	-- Whether the alien's dough tool (the "Mixer") is unlocked — gates building/the build shop.
	-- Formerly "Crumbforge"; PlayerDataService migrates the old CrumbforgeUnlocked save key.
	MixerUnlocked = "MixerUnlocked",

	-- player stats / persisted data (server writes, client + server read)
	Cps = "Cps",
	Xp = "Xp",
	GoldenCookies = "GoldenCookies",
	-- Lifetime profile metrics. PlayerMetricsService owns these server-written,
	-- persistent counters; ProfileController only reads their replicated values.
	LifetimeCookiesEarned = "LifetimeCookiesEarned",
	ManualClicks = "ManualClicks",
	ManualCookiesEarned = "ManualCookiesEarned",
	BuildingCookiesEarned = "BuildingCookiesEarned",
	AutoclickCookiesEarned = "AutoclickCookiesEarned",
	OfflineCookiesEarned = "OfflineCookiesEarned",
	RewardCookiesEarned = "RewardCookiesEarned",
	StolenCookiesEarned = "StolenCookiesEarned",
	OtherCookiesEarned = "OtherCookiesEarned",
	CookiesSpent = "CookiesSpent",
	CookiesLostToTheft = "CookiesLostToTheft",
	HighestCps = "HighestCps",
	GoldenCookiesEarned = "GoldenCookiesEarned",
	GoldenCookiesSpent = "GoldenCookiesSpent",
	BuildingsPlaced = "BuildingsPlaced",
	LifetimeFloorUnlocks = "LifetimeFloorUnlocks",
	HighestFloorUnlocked = "HighestFloorUnlocked",
	BonusFloorBuildingsPlaced = "BonusFloorBuildingsPlaced",
	WheelSpins = "WheelSpins",
	BestLoginStreak = "BestLoginStreak",
	LongestSessionSeconds = "LongestSessionSeconds",
	LoginStreak = "LoginStreak",
	LastLoginDay = "LastLoginDay",
	LastSeenTimestamp = "LastSeenTimestamp",
	UnlockedBuildingsJson = "UnlockedBuildingsJson",
	OwnedSkinsJson = "OwnedSkinsJson",
	EquippedSkinsJson = "EquippedSkinsJson",
	OwnedGooSkinsJson = "OwnedGooSkinsJson",
	SelectedGooSkinId = "SelectedGooSkinId",
	GooSkinMultiplier = "GooSkinMultiplier",
	AchievementsJson = "AchievementsJson",
}
