-- Single source of truth for the cross-controller GUI *instance* names that several
-- controllers resolve by string (the menu pill and its buttons, the store frame + toggles).
-- Reference one as `GuiNames.ShowHelp` instead of the literal `"ShowHelp"`.
--
-- These names are the second stringly-typed footgun in this codebase (after attribute
-- names -- see Shared/Attrs.lua). A bare `FindFirstChild("Help")` that doesn't match silently
-- returns `nil`, or -- worse -- matches the WRONG instance: exactly how the help modal broke
-- (`FindFirstChild("Help", true)` resolved to an unintended descendant), and the same latent
-- twin sat in StoreVisibilityController. Routing through `GuiNames` makes a typo'd key a `nil`
-- (a loud error at the call site) and gives every controller one agreed spelling.
--
-- Scope: only the menu-control / button / store names shared across controllers. Deep,
-- single-file structural lookups (store row templates, preview/requirement nodes, HUD card
-- internals) stay as local literals -- they carry no cross-controller ambiguity. See
-- docs/shared-modules-design.md (B1).
return {
	-- the menu pill container + its buttons
	MenuPill = "MenuPill",
	Help = "Help",
	ShowHelp = "ShowHelp",
	Settings = "Settings",
	SettingsButton = "SettingsButton",
	Profile = "Profile",
	ProfileButton = "ProfileButton",
	Wheel = "Wheel",
	WheelButton = "WheelButton",
	InviteModal = "InviteModal",
	InviteButton = "InviteButton",

	-- The custom item hotbar / carousel (Phase 1). NOT the golden-cookie Wheel above -- that
	-- name collision is why this is a distinct key. The container is a ScreenGui-level Frame
	-- holding round slot buttons (SlotLeft/SlotCenter/SlotRight, resolved as local literals in
	-- HotbarCarousel since they're single-module structural lookups). SlotCenter is the mixer.
	Hotbar = "Hotbar",

	-- store frame + its open/close toggles
	-- Store is the legacy single-shell name (kept as a fallback). The store now has two
	-- authored shells -- StoreSide (sidebar) and StoreBottom (bottom bar) -- selected at
	-- runtime by Shared/StoreShell from the StoreBottomLayout preference attribute.
	Store = "Store",
	StoreSide = "StoreSide",
	StoreBottom = "StoreBottom",
	ShowStore = "ShowStore",
	StoreButton = "StoreButton",
	Shop = "Shop",
	Close = "Close",

	-- The store open/close cookie toggles (authored in StoreBottom.TopBar). StoreBottomOff is
	-- the closed-state cookie launcher (opens the band); StoreBottomOn is the open-state active
	-- toggle (closes it). These were formerly named buildModeToggleOff/On when the band was
	-- driven by build mode; StoreToggleAnimator resolves the legacy names as a fallback.
	StoreBottomOff = "StoreBottomOff",
	StoreBottomOn = "StoreBottomOn",

	-- Build mode (store is hidden during normal play, so its entry point lives on the HUD):
	-- TopbarHudGui is the separate ScreenGui for BuildModeFrame. BuildModeTopbarPosition reads
	-- GuiService.TopbarInset at runtime so it sits beside Roblox's dynamic top-left CoreGui
	-- buttons (including the optional mic button).
	-- BuildButton is the floating entry button (with a .hitbox GuiButton); BuildControls is
	-- the optional on-screen frame holding .Up/.Down height buttons for touch. BuildModeFrame is
	-- the topbar toggle container; its inner BuildModeButton ImageButton carries the art.
	-- All authored in Studio; the controllers bind them and degrade gracefully when absent.
	TopbarHudGui = "TopbarHudGui",
	BuildButton = "BuildButton",
	BuildControls = "BuildControls",
	BuildModeFrame = "BuildModeFrame",
	BuildModeButton = "BuildModeButton",
}
