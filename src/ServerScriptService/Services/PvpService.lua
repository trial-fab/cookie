-- PvpService — server-side enforcement of the PVP pause (see Shared.PvpConfig).
-- Currently its only job is to hide the auto-equipped StarterPack weapons while
-- PVP is paused; the store/purchase/shield guards live in their own services.
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerStorage = game:GetService("ServerStorage")
local StarterPack = game:GetService("StarterPack")

local PvpConfig = require(ReplicatedStorage.Shared.PvpConfig)

local PvpService = {}

-- Move the PVP StarterPack tools into ServerStorage so they're never copied into
-- any player's Backpack/StarterGear on spawn. Reparenting (not deleting) keeps
-- them intact and reversible — the place file still has them under StarterPack,
-- so flipping PvpConfig.Enabled back on restores them next session.
local function hideStarterTools()
	for _, toolName in ipairs(PvpConfig.PausedStarterTools) do
		local tool = StarterPack:FindFirstChild(toolName)
		if tool then
			tool.Parent = ServerStorage
		end
	end
end

function PvpService.Init()
	if PvpConfig.IsActive() then
		print("PvpService: PVP enabled, no pause applied")
		return
	end

	hideStarterTools()
	print("PvpService initialized (PVP paused)")
end

return PvpService
