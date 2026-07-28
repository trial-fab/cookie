-- HudStoreTransition: hides the bottom-right HUD while the store band is up.
--
-- Logic only (the HUD is Studio-authored). The store band renders OVER the HUD (higher
-- ZIndex). The band is translucent, so the HUD is suppressed at its parent visibility
-- boundary the instant the store opens. Descendant animations and data refreshes may keep
-- updating while hidden without being able to leak individual text or stroke layers.
--
-- Mirrors StoreVisibilityController's visibility predicate (B key, build mode, placement).

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local shared = ReplicatedStorage:WaitForChild("Shared")
local Attrs = require(shared:WaitForChild("Attrs"))
local StoreShell = require(shared:WaitForChild("StoreShell"))

local HudStoreTransition = {}

function HudStoreTransition.start(ctx)
	local screenGui = ctx.screenGui
	local hud = ctx.hud
	if not (hud and hud:IsA("GuiObject")) then
		return
	end

	-- Render the store band over the HUD. ScreenGui uses Sibling ZIndexBehavior, so the
	-- two sibling subtrees are ordered purely by their root ZIndex -- lifting the band's
	-- root above the HUD's root puts the whole band subtree on top.
	local store = StoreShell.getActive(screenGui)
	if store and store:IsA("GuiObject") and store.ZIndex <= hud.ZIndex then
		store.ZIndex = hud.ZIndex + 1
	end

	------------------------------------------------------------------
	-- Reactive driver: mirror StoreVisibilityController's predicate exactly.
	-- Store visible (band up) => HUD hidden underneath it.
	------------------------------------------------------------------
	local function applyState(visible)
		if hud:GetAttribute(Attrs.HudStoreSuppressed) ~= visible then
			hud:SetAttribute(Attrs.HudStoreSuppressed, visible)
		end
	end

	local function refresh()
		local storeOpen = screenGui:GetAttribute(Attrs.StoreOpen) == true
		local buildMode = screenGui:GetAttribute(Attrs.BuildModeActive) == true
		local autoBuild = screenGui:GetAttribute(Attrs.AutoBuildMode) == true
		local placing = screenGui:GetAttribute(Attrs.PlacementActive) == true
		local backgroundSuspended = screenGui:GetAttribute(Attrs.BackgroundSurfacesSuspended) == true
		applyState((storeOpen or (buildMode and autoBuild)) and not placing and not backgroundSuspended)
	end

	for _, name in ipairs({
		Attrs.StoreOpen,
		Attrs.BuildModeActive,
		Attrs.AutoBuildMode,
		Attrs.PlacementActive,
		Attrs.BackgroundSurfacesSuspended,
	}) do
		screenGui:GetAttributeChangedSignal(name):Connect(function()
			refresh()
		end)
	end

	-- Seed initial state.
	refresh()
end

return HudStoreTransition
