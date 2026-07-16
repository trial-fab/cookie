-- ModalCoordinator — single-open coordination for the Help / Settings / Profile / Wheel
-- modals. Replaces the identical `OpenModal` attribute dance that used to be
-- copy-pasted into each controller (claim-on-open, release-on-close, and a
-- per-controller GetAttributeChangedSignal listener that closed the modal when a
-- sibling claimed the slot, gated by a `fromCoordinator` flag).
--
-- The single open slot is still backed by the ScreenGui `OpenModal` attribute, so
-- any un-migrated reader keeps working (same get-or-create interop idea as Net):
-- the attribute is the source of truth; this module is just the one place that
-- reads / writes / watches it.
--
-- Usage (per modal controller):
--   local Modals = require(script.Parent:WaitForChild("ModalCoordinator"))
--   local slot = Modals.register("Help", function()
--       -- another modal claimed the slot — close myself
--       if helpVisible then setHelpVisible(false) end
--   end)
--   -- on open:  slot.open()      -- claim the slot for "Help"
--   -- on close: slot.close()     -- release the slot iff "Help" still holds it
--
-- `slot.close()` is safe to call unconditionally from a close path: it only clears
-- the attribute when this modal currently owns it, so the foreign-close callback
-- can route through it without re-claiming or fighting the new owner.

local ModalCoordinator = {}

local screenGui = script:FindFirstAncestorOfClass("ScreenGui")
local shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local Attrs = require(shared:WaitForChild("Attrs"))
local MobileScale = require(shared:WaitForChild("MobileScale"))

local NONE = ""
local COMPACT_MAIN_MODAL_ROOTS = {
	Help = "Help",
	Settings = "SettingsModal",
	Profile = "ProfileModal",
	Wheel = "WheelModal",
}

-- name -> onForeignOpen callback ("you are no longer the open modal").
local registry = {}
local suspendedSurfaces = nil

if screenGui:GetAttribute(Attrs.BackgroundSurfacesSuspended) == nil then
	screenGui:SetAttribute(Attrs.BackgroundSurfacesSuspended, false)
end

local function current()
	return screenGui:GetAttribute(Attrs.OpenModal) or NONE
end

local function updateCompactState()
	local owner = current()
	local rootName = COMPACT_MAIN_MODAL_ROOTS[owner]
	local modal = rootName and screenGui:FindFirstChild(rootName)
	local closeButton = modal and modal:FindFirstChild("MobileClose")
	screenGui:SetAttribute(
		Attrs.CompactModalActive,
		closeButton ~= nil and closeButton:IsA("GuiButton") and MobileScale.shouldUseMobile(screenGui)
	)
end

local function suspendBackgroundSurfaces()
	if not suspendedSurfaces then
		suspendedSurfaces = {
			storeOpen = screenGui:GetAttribute(Attrs.StoreOpen) == true,
			leaderboardOpen = screenGui:GetAttribute(Attrs.LeaderboardOpen) == true,
		}
	end
	screenGui:SetAttribute(Attrs.BackgroundSurfacesSuspended, true)
	-- StoreOpen remains the logical state while the modal temporarily hides its surfaces.
	-- Writing it false here would make Auto Build treat Settings as a real Store close and
	-- exit Build View, then re-enter it when the modal restored the snapshot.
	screenGui:SetAttribute(Attrs.LeaderboardOpen, false)
end

local function restoreBackgroundSurfaces()
	local snapshot = suspendedSurfaces
	if not snapshot then
		return
	end
	suspendedSurfaces = nil
	screenGui:SetAttribute(Attrs.StoreOpen, snapshot.storeOpen)
	screenGui:SetAttribute(Attrs.LeaderboardOpen, snapshot.leaderboardOpen)
	screenGui:SetAttribute(Attrs.BackgroundSurfacesSuspended, false)
end

-- One shared observer drives every registered modal. When the slot changes, every
-- registered modal that is *not* the current owner is told to close itself. Each
-- callback self-guards on its own open state, so this is a no-op for modals that
-- are already closed (matches the old per-controller `and modal:GetAttribute(Open)`).
local lastOwner = current()
screenGui:GetAttributeChangedSignal(Attrs.OpenModal):Connect(function()
	local owner = current()
	updateCompactState()
	if owner == NONE and lastOwner ~= NONE then
		restoreBackgroundSurfaces()
	end
	lastOwner = owner
	for name, onForeignOpen in pairs(registry) do
		if name ~= owner then
			onForeignOpen()
		end
	end
end)

MobileScale.onViewportChanged(updateCompactState)

-- Register a modal under `name`. `onForeignOpen` is called whenever another modal
-- claims the single open slot (i.e. this modal should close). Set
-- options.suspendBackgroundSurfaces=false for Store-owned confirmations that must leave the
-- Store visible behind them. Returns a handle with `open()` / `close()`.
function ModalCoordinator.register(name, onForeignOpen, options)
	assert(type(name) == "string" and name ~= NONE, "ModalCoordinator.register: name must be a non-empty string")
	assert(type(onForeignOpen) == "function", "ModalCoordinator.register: onForeignOpen must be a function")
	options = type(options) == "table" and options or {}
	local shouldSuspendBackgroundSurfaces = options.suspendBackgroundSurfaces ~= false
	registry[name] = onForeignOpen

	return {
		-- Claim the single slot for this modal. Sibling modals are closed via the
		-- shared observer above. Capture Store/Leaderboard only on the first open so
		-- switching between registered modals keeps both suspended under one session.
		open = function()
			if shouldSuspendBackgroundSurfaces then
				suspendBackgroundSurfaces()
			end
			screenGui:SetAttribute(Attrs.OpenModal, name)
		end,
		-- Release the slot, but only if this modal still owns it. Safe to call from
		-- any close path: when a sibling already took the slot this is a no-op.
		close = function()
			if current() == name then
				screenGui:SetAttribute(Attrs.OpenModal, NONE)
			end
		end,
	}
end

-- Name of the modal that currently holds the open slot ("" if none).
function ModalCoordinator.current()
	return current()
end

-- True while any registered modal holds the open slot.
function ModalCoordinator.isOpen()
	return current() ~= NONE
end

-- Replace the active modal session with an explicitly requested background surface.
-- The saved pre-modal state is intentionally discarded: this is a new user choice,
-- not the normal last-modal close path that restores the snapshot.
function ModalCoordinator.overrideBackground(storeOpen, leaderboardOpen)
	suspendedSurfaces = nil
	screenGui:SetAttribute(Attrs.OpenModal, NONE)
	screenGui:SetAttribute(Attrs.BackgroundSurfacesSuspended, false)
	screenGui:SetAttribute(Attrs.StoreOpen, storeOpen == true)
	screenGui:SetAttribute(Attrs.LeaderboardOpen, leaderboardOpen == true)
end

return ModalCoordinator
