-- BoostFieldLabels: the status panel standing over a dropped field.
--
-- Three rows, anchored to the fixed Rim at the field's centre and lifted clear of the buildings it
-- is boosting. The Core can bob and dip under a player's weight without moving this game text:
--
--   Power Field (SomePlayer)   <- the item, crediting whoever dropped it when that was not you
--   +50%                       <- what it is doing
--   4:32                       <- how long it has left
--
-- One panel per field on purpose. An earlier pass had a separate "from <player>" label anchored to
-- the same point, which meant two labels competing for one point in space; the attribution now rides
-- the name row instead.
--
-- The countdown is the SERVER's number. `RemainingSeconds` is written by BoostFieldService's timer
-- and replicates, so the panel never runs its own clock and can never drift from the field it is
-- describing — including the part that matters most, that the countdown only advances while the
-- plot owner is present (§12.6).
--
-- The panel itself is not built here: a Studio-authored template is cloned (the pattern store rows,
-- wheel cards and leaderboard rows already use) and handed to the existing WorldTrackedLabels
-- controller by tagging it, which already owns projection, distance scaling and the safe-inset
-- correction.

local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local shared = ReplicatedStorage:WaitForChild("Shared")
local BoostShopConfig = require(shared:WaitForChild("BoostShopConfig"))

local BoostFieldLabels = {}

local SHEETS_NAME = "CookieSheets"
local WORLD_LABEL_TAG = "WorldTrackedLabel"
local REPLICATION_WAIT_SECONDS = 5

-- The outer Rim never moves: unlike the Core it neither bobs nor sinks, and unlike Fill it does not
-- resize for the sonar sweep. Falling back to Fill still keeps the anchor's world position fixed.
local function anchorPart(field)
	local rim = field:FindFirstChild(BoostShopConfig.Pulse.RimPartName)
	if rim and rim:IsA("BasePart") then
		return rim
	end
	local sweep = field:FindFirstChild(BoostShopConfig.Pulse.SweepPartName)
	return sweep and sweep:IsA("BasePart") and sweep or nil
end

local function findRow(frame, name)
	local row = frame:FindFirstChild(name, true)
	return row and row:IsA("TextLabel") and row or nil
end

function BoostFieldLabels.bindWorld(screenGui)
	local template = screenGui:FindFirstChild(BoostShopConfig.FieldLabelTemplateName, true)
	if not (template and template:IsA("GuiObject")) then
		warn(
			("BoostFieldLabels: no `%s` under the ScreenGui — dropped fields will have no status panel."):format(
				BoostShopConfig.FieldLabelTemplateName
			)
		)
		return
	end

	local prefix = BoostShopConfig.FieldNamePrefix
	local labelled = setmetatable({}, { __mode = "k" })

	local function attach(field)
		local anchor = anchorPart(field)
		if not anchor then
			return
		end
		local item = BoostShopConfig.Items[field.Name:sub(#prefix + 1)]
		if not item then
			return
		end

		local frame = template:Clone()
		frame.Name = "BoostFieldLabel"
		frame:SetAttribute("AgentDraft", nil)

		local rows = BoostShopConfig.FieldLabelRows
		local nameRow = findRow(frame, rows.Name)
		if nameRow then
			-- A field dropped on someone else's plot credits its sender inline. A self-drop has
			-- nobody to credit, so the name stands alone.
			local fromUserId = tonumber(field:GetAttribute("FromUserId"))
			local ownerUserId = tonumber(field:GetAttribute("OwnerUserId"))
			local fromName = field:GetAttribute("FromDisplayName")
			if fromUserId and fromUserId ~= ownerUserId and type(fromName) == "string" then
				nameRow.Text = ("%s from %s"):format(item.DisplayName, fromName)
			else
				nameRow.Text = item.DisplayName
			end
		end

		local boostRow = findRow(frame, rows.Boost)
		if boostRow then
			local percent = tonumber(field:GetAttribute("StrengthPercent")) or item.StrengthPercent
			boostRow.Text = ("+%d%%"):format(percent)
		end

		local countdownRow = findRow(frame, rows.Countdown)
		local function refreshCountdown()
			if countdownRow then
				countdownRow.Text = BoostShopConfig.FormatDuration(field:GetAttribute("RemainingSeconds"))
			end
		end
		refreshCountdown()
		field:GetAttributeChangedSignal("RemainingSeconds"):Connect(refreshCountdown)

		-- Tint this panel with its own field colour. One template serves both items, so the colours
		-- are code's for the same reason the disc's and the ring's are.
		for rowKey, tinted in pairs(BoostShopConfig.FieldLabelTintedRows) do
			local row = tinted and findRow(frame, BoostShopConfig.FieldLabelRows[rowKey])
			if row then
				row.TextColor3 = item.FieldColor
			end
		end

		-- Lift by the item's place in Order so a Power and a Speed panel dropped on the same cluster
		-- stack instead of landing on top of each other.
		local stackIndex = table.find(BoostShopConfig.Order, item.Id) or 1
		local baseOffset = tonumber(template:GetAttribute("WorldOffsetY")) or 0
		frame:SetAttribute("WorldOffsetY", baseOffset + (stackIndex - 1) * BoostShopConfig.FieldLabelStackStuds)

		local anchorValue = frame:FindFirstChild("Anchor")
		if anchorValue and anchorValue:IsA("ObjectValue") then
			anchorValue.Value = anchor
		end
		-- Keep runtime clones beside their authored template inside the BoostShop UI group.
		frame.Parent = template.Parent
		-- Tagged only now, on the live clone. The template stays untagged so the copy that
		-- replicates into PlayerGui is never mistaken for a real label.
		CollectionService:AddTag(frame, WORLD_LABEL_TAG)

		-- The effect ends at the start of the collapse, so its status panel leaves then rather than
		-- hovering over a dead Core until the server removes the visual shell a moment later.
		local function destroyFrame()
			if frame.Parent then
				frame:Destroy()
			end
		end
		field:GetAttributeChangedSignal(BoostShopConfig.Expiry.StartedAtAttribute):Connect(function()
			if field:GetAttribute(BoostShopConfig.Expiry.StartedAtAttribute) ~= nil then
				destroyFrame()
			end
		end)
		field.Destroying:Connect(destroyFrame)
		if field:GetAttribute(BoostShopConfig.Expiry.StartedAtAttribute) ~= nil then
			destroyFrame()
		end
	end

	local function bind(instance)
		if labelled[instance] or not instance:IsA("Model") then
			return
		end
		if instance.Name:sub(1, #prefix) ~= prefix then
			return
		end
		labelled[instance] = true

		task.spawn(function()
			-- Replication delivers the model before its parts and attributes, so binding the instant
			-- it appears would read a nil anchor and a nil countdown. Polled against a deadline
			-- rather than waiting on the attribute signal, which would hang this thread forever if
			-- the value never arrived.
			if not anchorPart(instance) then
				instance:WaitForChild(BoostShopConfig.Pulse.RimPartName, REPLICATION_WAIT_SECONDS)
			end
			local deadline = os.clock() + REPLICATION_WAIT_SECONDS
			while instance:GetAttribute("RemainingSeconds") == nil and os.clock() < deadline and instance.Parent do
				task.wait()
			end
			if instance.Parent then
				attach(instance)
			end
		end)
	end

	task.spawn(function()
		local sheets = Workspace:WaitForChild(SHEETS_NAME)
		-- Fields already standing when this client joined count too, not just new drops.
		for _, descendant in ipairs(sheets:GetDescendants()) do
			bind(descendant)
		end
		sheets.DescendantAdded:Connect(bind)
	end)
end

return BoostFieldLabels
