-- HudStoreTransition: hides the bottom-right HUD while the store band is up.
--
-- Logic only (the HUD is Studio-authored). The store band renders OVER the HUD (higher
-- ZIndex). The band is now translucent, so it no longer masks the HUD as it rises -- if we
-- deferred hiding the HUD until the band was fully up, it would be visible through the rising
-- band. So the HUD is snapped invisible (transparency 1) the instant the store opens, and
-- snapped back visible the instant it closes (before the band tweens down, so the descending
-- band reveals an already-visible HUD). No fade in either direction.
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
	-- Capture every animatable transparency in the HUD once (authored base), then snap
	-- to 1 (hidden) / back to base (shown). No tween -- the swap is hidden by the band.
	------------------------------------------------------------------
	local entries = {}
	local function capture(object)
		if object:IsA("GuiObject") and object.BackgroundTransparency < 1 then
			table.insert(
				entries,
				{ object = object, prop = "BackgroundTransparency", base = object.BackgroundTransparency }
			)
		end
		if object:IsA("TextLabel") or object:IsA("TextButton") then
			if object.TextTransparency < 1 then
				table.insert(entries, { object = object, prop = "TextTransparency", base = object.TextTransparency })
			end
			if object.TextStrokeTransparency < 1 then
				table.insert(
					entries,
					{ object = object, prop = "TextStrokeTransparency", base = object.TextStrokeTransparency }
				)
			end
		elseif object:IsA("ImageLabel") or object:IsA("ImageButton") then
			if object.ImageTransparency < 1 then
				table.insert(entries, { object = object, prop = "ImageTransparency", base = object.ImageTransparency })
			end
		elseif object:IsA("UIStroke") then
			if object.Transparency < 1 then
				table.insert(entries, { object = object, prop = "Transparency", base = object.Transparency })
			end
		end
	end

	capture(hud)
	for _, descendant in ipairs(hud:GetDescendants()) do
		capture(descendant)
	end

	local function setHidden(hidden)
		for _, entry in ipairs(entries) do
			if entry.object.Parent then
				entry.object[entry.prop] = hidden and 1 or entry.base
			end
		end
	end

	------------------------------------------------------------------
	-- Reactive driver: mirror StoreVisibilityController's predicate exactly.
	-- Store visible (band up) => HUD hidden underneath it.
	------------------------------------------------------------------
	local storeVisible = false

	local function applyState(visible)
		hud:SetAttribute(Attrs.HudStoreSuppressed, visible)
		if visible == storeVisible then
			return
		end
		storeVisible = visible
		-- Snap immediately in both directions -- a translucent band can't mask a deferred
		-- hide, so opening snaps the HUD out at once (no fade / no seeing it through the band)
		-- and closing snaps it back before the band descends.
		setHidden(visible)
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
