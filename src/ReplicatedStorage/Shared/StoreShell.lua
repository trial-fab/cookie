-- StoreShell: single place that resolves the active store frame.
--
-- The store currently ships as one shell -- StoreBottom (the thin full-width bottom bar of
-- horizontal cards). The old sidebar (StoreSide) is preserved out of the active tree for a
-- possible future toggle. Every store controller (StoreController, StoreVisibilityController,
-- UiStyleController, BuildViewController) resolves the frame through getActive() rather than a
-- hard-coded name, so when the sidebar comes back this is the only spot that has to choose.
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local shared = ReplicatedStorage:WaitForChild("Shared")
local GuiNames = require(shared:WaitForChild("GuiNames"))

local StoreShell = {}

StoreShell.SIDE = GuiNames.StoreSide -- "StoreSide"
StoreShell.BOTTOM = GuiNames.StoreBottom -- "StoreBottom"

-- Resolve the active store frame. Prefers the bottom bar, then the sidebar, then the legacy
-- single-shell GuiNames.Store name, so a half-migrated place still resolves something.
function StoreShell.getActive(screenGui)
	return screenGui:FindFirstChild(StoreShell.BOTTOM)
		or screenGui:FindFirstChild(StoreShell.SIDE)
		or screenGui:FindFirstChild(GuiNames.Store)
end

return StoreShell
