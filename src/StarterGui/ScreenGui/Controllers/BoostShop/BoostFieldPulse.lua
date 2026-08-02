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

local function collapseField(model, pulse)
	if pulse and pulse.stop then
		pulse.stop()
	end

	-- Cutting emission first makes the shrinking rings read as a power source shutting off rather
	-- than a healthy field merely changing size. Clear removes already-emitted sparkles too.
	for _, descendant in ipairs(model:GetDescendants()) do
		if descendant:IsA("ParticleEmitter") then
			descendant.Enabled = false
			descendant:Clear()
		end
	end

	local remaining = BoostShopConfig.Expiry.RingCollapseSeconds
	local function hideCollapsedPart(part)
		if not part.Parent then
			return
		end
		part.Transparency = 1
		for _, descendant in ipairs(part:GetDescendants()) do
			if descendant:IsA("Highlight") then
				descendant.Enabled = false
			end
		end
	end
	for _, name in ipairs({ BoostShopConfig.Pulse.RimPartName, BoostShopConfig.Pulse.SweepPartName }) do
		local part = model:FindFirstChild(name, true)
		if part and part:IsA("BasePart") then
			-- The discs are flat Cylinders: X is thickness and Y/Z are the two radial axes.
			local target = Vector3.new(
				part.Size.X,
				part.Size.Y * BoostShopConfig.Expiry.RingEndScale,
				part.Size.Z * BoostShopConfig.Expiry.RingEndScale
			)
			if remaining <= 0 then
				part.Size = target
				hideCollapsedPart(part)
			else
				local shrink = TweenService:Create(
					part,
					TweenInfo.new(remaining, Enum.EasingStyle.Quad, Enum.EasingDirection.In),
					{ Size = target }
				)
				shrink.Completed:Once(function(playbackState)
					if playbackState == Enum.PlaybackState.Completed then
						hideCollapsedPart(part)
					end
				end)
				shrink:Play()
			end
		end
	end
end

-- Watches every plot for dropped fields, gives each one the slower ping, then owns the radius
-- collapse when the server declares that field expired.
function BoostFieldPulse.bindWorld()
	local prefix = BoostShopConfig.FieldNamePrefix
	local states = setmetatable({}, { __mode = "k" })

	local function bind(instance)
		if states[instance] or not instance:IsA("Model") then
			return
		end
		if instance.Name:sub(1, #prefix) ~= prefix then
			return
		end
		-- Claimed before yielding so the DescendantAdded firing for this model's own children
		-- cannot start a second binding for it.
		local state = { ready = false, collapsing = false, pulse = nil }
		states[instance] = state

		local function collapseIfExpired()
			local startedAt = instance:GetAttribute(BoostShopConfig.Expiry.StartedAtAttribute)
			if not state.ready or state.collapsing or type(startedAt) ~= "number" then
				return
			end
			state.collapsing = true
			collapseField(instance, state.pulse)
			state.pulse = nil
		end
		instance:GetAttributeChangedSignal(BoostShopConfig.Expiry.StartedAtAttribute):Connect(collapseIfExpired)

		task.spawn(function()
			-- The server parents a field only after its parts exist, but REPLICATION does not
			-- preserve that: the model arrives on the client before its descendants, so the disc
			-- has to be waited for or a freshly dropped field silently never pings.
			local sweep = instance:WaitForChild(BoostShopConfig.Pulse.SweepPartName, 10)
			local rim = instance:WaitForChild(BoostShopConfig.Pulse.RimPartName, 10)
			if sweep and rim and instance.Parent then
				state.ready = true
				if instance:GetAttribute(BoostShopConfig.Expiry.StartedAtAttribute) == nil then
					state.pulse = BoostFieldPulse.attach(instance, BoostShopConfig.Pulse.Field)
				end
				collapseIfExpired()
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
