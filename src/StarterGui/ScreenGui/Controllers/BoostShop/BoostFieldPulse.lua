-- BoostFieldPulse: the sonar ping on a boost field's radius disc.
--
-- The authored disc is two parts: `Rim`, the fainter outer edge, and `Fill`, the inner disc. Only
-- Fill animates. It starts as a small disc at the centre, expands out to the full radius, and fades
-- as it gets there — a ping leaving the drop point — while Rim holds at full size the whole time.
--
-- The ring is the `PingOutline` Highlight on Fill, fill switched off so only the outline draws. A
-- Highlight traces its adornee's silhouette, and Fill is a flat Cylinder, so the silhouette is a
-- circle: a genuine ring outline without a union or a mesh. The part's own transparency stays as
-- the soft wash travelling behind that ring.
--
-- That split is the point. Scaling the WHOLE disc made the coverage edge move, and where the edge
-- falls is exactly the decision the player is making. The boundary has to be the still thing.
--
-- Driven by looping Tweens, never a per-frame loop: some clients freeze per-frame writes when the
-- window goes idle, which stops a Heartbeat/RenderStepped animation dead while a tween keeps
-- playing. The tweens do NOT reverse — a sonar wave only ever travels outward, and the snap back to
-- the centre is invisible because the fade has already taken the disc to fully transparent.
--
-- Only the RADIAL axes move. The disc is a Cylinder laid flat, so X is its thickness and Y/Z are
-- its diameter; scaling all three would make the ping visibly fatten as it travelled.

local TweenService = game:GetService("TweenService")
local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local shared = ReplicatedStorage:WaitForChild("Shared")
local BoostShopConfig = require(shared:WaitForChild("BoostShopConfig"))
local UiMotion = require(shared:WaitForChild("UiMotion"))

local BoostFieldPulse = {}

local SHEETS_NAME = "CookieSheets"

local function findSweepPart(model)
	local part = model:FindFirstChild(BoostShopConfig.Pulse.SweepPartName, true)
	return part and part:IsA("BasePart") and part or nil
end

-- Attaches the ping to a disc model. `settings` is BoostShopConfig.Pulse.Ghost or .Field. Returns
-- nil when there is nothing to animate or the player has asked for reduced motion.
function BoostFieldPulse.attach(model, settings)
	local sweep = findSweepPart(model)
	if not sweep or UiMotion.isReduced(sweep) then
		return nil
	end

	local outline = sweep:FindFirstChild(BoostShopConfig.Pulse.OutlineName)
	if outline and not outline:IsA("Highlight") then
		outline = nil
	end

	local fullSize = sweep.Size
	local restTransparency = sweep.Transparency
	local restOutlineTransparency = outline and outline.OutlineTransparency or nil
	local start = BoostShopConfig.Pulse.StartScale

	sweep.Size = Vector3.new(fullSize.X, fullSize.Y * start, fullSize.Z * start)
	sweep.Transparency = settings.FillTransparency
	if outline then
		outline.OutlineTransparency = settings.OutlineTransparency
	end

	-- Quad/Out on the size: the wave leaves the centre quickly and eases into the boundary, which is
	-- what makes it read as travelling rather than inflating.
	local tweens = {
		TweenService:Create(
			sweep,
			TweenInfo.new(settings.Seconds, Enum.EasingStyle.Quad, Enum.EasingDirection.Out, -1, false),
			{ Size = fullSize }
		),
		-- Quint/In on both fades: they hold full strength for most of the sweep and drop away only
		-- at the very end. A linear fade would leave the ping washed out for its whole journey, and
		-- it is the fade reaching 1 that hides the loop's snap back to the centre.
		TweenService:Create(
			sweep,
			TweenInfo.new(settings.Seconds, Enum.EasingStyle.Quint, Enum.EasingDirection.In, -1, false),
			{ Transparency = 1 }
		),
	}
	if outline then
		table.insert(
			tweens,
			TweenService:Create(
				outline,
				TweenInfo.new(settings.Seconds, Enum.EasingStyle.Quint, Enum.EasingDirection.In, -1, false),
				{ OutlineTransparency = 1 }
			)
		)
	end
	for _, tween in ipairs(tweens) do
		tween:Play()
	end

	return {
		stop = function()
			for _, tween in ipairs(tweens) do
				tween:Cancel()
			end
			table.clear(tweens)
			-- Hand everything back exactly as authored, in case the model outlives the ping.
			sweep.Size = fullSize
			sweep.Transparency = restTransparency
			if outline and restOutlineTransparency then
				outline.OutlineTransparency = restOutlineTransparency
			end
		end,
	}
end

-- Watches every plot for dropped fields and gives each one the slower ping. Fields are
-- server-owned, so this only ever reads them.
function BoostFieldPulse.bindWorld()
	local prefix = BoostShopConfig.FieldNamePrefix
	local pulsed = setmetatable({}, { __mode = "k" })

	local function bind(instance)
		if pulsed[instance] or not instance:IsA("Model") then
			return
		end
		if instance.Name:sub(1, #prefix) ~= prefix then
			return
		end
		-- Claimed before yielding so the DescendantAdded firing for this model's own children
		-- cannot start a second binding for it.
		pulsed[instance] = true

		task.spawn(function()
			-- The server parents a field only after its parts exist, but REPLICATION does not
			-- preserve that: the model arrives on the client before its descendants, so the disc
			-- has to be waited for or a freshly dropped field silently never pings.
			local sweep = instance:WaitForChild(BoostShopConfig.Pulse.SweepPartName, 10)
			if sweep and instance.Parent then
				pulsed[instance] = BoostFieldPulse.attach(instance, BoostShopConfig.Pulse.Field) or true
			end
		end)
	end

	task.spawn(function()
		local sheets = Workspace:WaitForChild(SHEETS_NAME)
		-- Fields already on the ground when this client joined (a rejoin restores them, and other
		-- players' plots keep theirs) get the ping too, not just ones dropped from now on.
		for _, descendant in ipairs(sheets:GetDescendants()) do
			bind(descendant)
		end
		sheets.DescendantAdded:Connect(bind)
	end)
end

return BoostFieldPulse
