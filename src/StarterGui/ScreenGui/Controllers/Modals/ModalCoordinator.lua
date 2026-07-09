-- ModalCoordinator — single-open coordination for the Help / Settings / Profile
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
local Attrs = require(game:GetService("ReplicatedStorage"):WaitForChild("Shared"):WaitForChild("Attrs"))

local NONE = ""

-- name -> onForeignOpen callback ("you are no longer the open modal").
local registry = {}

local function current()
	return screenGui:GetAttribute(Attrs.OpenModal) or NONE
end

-- One shared observer drives every registered modal. When the slot changes, every
-- registered modal that is *not* the current owner is told to close itself. Each
-- callback self-guards on its own open state, so this is a no-op for modals that
-- are already closed (matches the old per-controller `and modal:GetAttribute(Open)`).
screenGui:GetAttributeChangedSignal(Attrs.OpenModal):Connect(function()
	local owner = current()
	for name, onForeignOpen in pairs(registry) do
		if name ~= owner then
			onForeignOpen()
		end
	end
end)

-- Register a modal under `name`. `onForeignOpen` is called whenever another modal
-- claims the single open slot (i.e. this modal should close). Returns a handle with
-- `open()` / `close()`.
function ModalCoordinator.register(name, onForeignOpen)
	assert(type(name) == "string" and name ~= NONE, "ModalCoordinator.register: name must be a non-empty string")
	assert(type(onForeignOpen) == "function", "ModalCoordinator.register: onForeignOpen must be a function")
	registry[name] = onForeignOpen

	return {
		-- Claim the single slot for this modal. Sibling modals are closed via the
		-- shared observer above.
		open = function()
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

return ModalCoordinator
