-- Lazy goo collection state. It creates authored card clones only on first visibility,
-- then updates those cards in place so selection and ownership changes do not recreate
-- eleven ViewportFrames.
local HttpService = game:GetService("HttpService")

local WheelCollection = {}

local function fmtMult(value)
	return ("x%.2f"):format(tonumber(value) or 1)
end

local function setVisible(instance, visible)
	if instance and instance:IsA("GuiObject") then
		instance.Visible = visible
	end
end

function WheelCollection.bind(ctx)
	local state = {
		Owned = {},
		SelectedSkinId = ctx.config.DefaultGooSkinId,
		BestMultiplier = 1,
	}
	local cardsById = {}
	local built = false
	local dirty = true
	local visible = false
	local selecting = false

	local function decodeAttribute(name)
		local raw = ctx.player:GetAttribute(name)
		if type(raw) ~= "string" then
			return {}
		end
		local ok, decoded = pcall(HttpService.JSONDecode, HttpService, raw)
		return ok and type(decoded) == "table" and decoded or {}
	end

	local function updateBestBonus()
		local value = ctx.bestBonusPill and (ctx.bestBonusPill:FindFirstChild("Value", true) or ctx.bestBonusPill)
		if not (value and value:IsA("TextLabel")) then
			return
		end
		local best = tonumber(state.BestMultiplier) or 1
		local applied = tonumber(ctx.player:GetAttribute(ctx.attrs.GooSkinMultiplier)) or 1
		if not ctx.config.FeatureFlags.GooSkinsEnabled then
			value.Text = ("Unavailable • Best owned %s • Applied %s"):format(fmtMult(best), fmtMult(applied))
		elseif math.abs(best - applied) > 0.0001 then
			value.Text = ("Best owned %s • Applied %s"):format(fmtMult(best), fmtMult(applied))
		else
			value.Text = "Best bonus " .. fmtMult(best)
		end
	end

	local function calculateBestOwned(owned)
		local best = 1
		for _, def in ipairs(ctx.config.GooSkinDefinitions) do
			if owned[def.Id] and type(def.Multiplier) == "number" then
				best = math.max(best, def.Multiplier)
			end
		end
		return best
	end

	local function updateCard(card, def)
		local rarity = ctx.config.RarityById[def.RarityId]
		local owned = state.Owned[def.Id] == true
		local selected = owned and state.SelectedSkinId == def.Id
		local nameLabel = card:FindFirstChild("SkinName")
		local rarityTag = card:FindFirstChild("RarityTag")
		local multiplier = card:FindFirstChild("Multiplier")
		local selectButton = card:FindFirstChild("SelectButton")
		local stroke = card:FindFirstChildWhichIsA("UIStroke")

		if nameLabel and nameLabel:IsA("TextLabel") then
			nameLabel.Text = def.DisplayName or def.Id
		end
		if rarityTag and rarityTag:IsA("TextLabel") then
			rarityTag.Text = rarity and rarity.DisplayName or (def.RarityId or "")
			if rarity then
				rarityTag.TextColor3 = rarity.Color
			end
		end
		if multiplier and multiplier:IsA("TextLabel") then
			multiplier.Text = fmtMult(def.Multiplier) .. " universal"
		end
		if stroke and rarity then
			stroke.Color = rarity.Color
		end

		setVisible(card:FindFirstChild("LockMarker"), not owned)
		setVisible(card:FindFirstChild("OwnedMarker"), owned)
		setVisible(card:FindFirstChild("SelectedMarker"), selected)

		local preview = card:FindFirstChild("Preview")
		if preview and preview:IsA("ViewportFrame") then
			ctx.preview.Render(preview, def.Id, { Locked = not owned })
		end

		if selectButton and selectButton:IsA("GuiButton") then
			local available = ctx.config.FeatureFlags.GooSkinsEnabled and owned and not selected and not selecting
			selectButton.Active = available
			selectButton.AutoButtonColor = available
			selectButton:SetAttribute(ctx.attrs.Active, selected)
			if selectButton:IsA("TextButton") then
				ctx.applyButtonStyle(
					selectButton,
					selected and ctx.styles.selected or (available and ctx.styles.selectAvailable or ctx.styles.locked)
				)
				if not ctx.config.FeatureFlags.GooSkinsEnabled then
					selectButton.Text = "Unavailable"
				else
					selectButton.Text = selected and "Selected" or (owned and "Select" or "Locked")
				end
			end
		end
	end

	local function reconcile()
		if not visible or not (ctx.collection and ctx.cardTemplate) then
			return
		end
		if not built then
			for _, def in ipairs(ctx.config.GooSkinDefinitions) do
				local card = ctx.cardTemplate:Clone()
				card.Name = "SkinCard"
				card.LayoutOrder = def.Order
				card:SetAttribute("WheelClone", true)
				card.Visible = true
				card.Parent = ctx.collection
				cardsById[def.Id] = card

				local selectButton = card:FindFirstChild("SelectButton")
				if selectButton and selectButton:IsA("GuiButton") then
					selectButton.Activated:Connect(function()
						if selecting or not ctx.config.FeatureFlags.GooSkinsEnabled then
							return
						end
						if state.Owned[def.Id] ~= true or state.SelectedSkinId == def.Id then
							return
						end
						selecting = true
						updateCard(card, def)
						task.spawn(function()
							local ok, result = pcall(function()
								return ctx.net.invoke(ctx.net.Names.SelectGooSkin, def.Id)
							end)
							selecting = false
							if ok and type(result) == "table" and result.Success then
								-- Selection is response-driven exactly once; the server deliberately does
								-- not emit an equivalent inventory push for this operation.
								state = {
									Owned = type(result.Owned) == "table" and result.Owned or state.Owned,
									SelectedSkinId = result.SelectedSkinId or state.SelectedSkinId,
									BestMultiplier = tonumber(result.BestMultiplier) or state.BestMultiplier,
								}
							end
							dirty = true
							updateBestBonus()
							reconcile()
						end)
					end)
				end
			end
			built = true
		end

		if dirty then
			for _, def in ipairs(ctx.config.GooSkinDefinitions) do
				local card = cardsById[def.Id]
				if card then
					updateCard(card, def)
				end
			end
			dirty = false
		end
	end

	local function applyState(nextState)
		if type(nextState) ~= "table" then
			return
		end
		state = {
			Owned = type(nextState.Owned) == "table" and nextState.Owned or state.Owned,
			SelectedSkinId = nextState.SelectedSkinId or state.SelectedSkinId,
			BestMultiplier = tonumber(nextState.BestMultiplier) or state.BestMultiplier,
		}
		dirty = true
		updateBestBonus()
		reconcile()
	end

	ctx.net.on(ctx.net.Names.GooSkinInventoryChanged, applyState)
	ctx.player:GetAttributeChangedSignal(ctx.attrs.GooSkinMultiplier):Connect(updateBestBonus)

	return {
		loadFromAttributes = function()
			local owned = decodeAttribute(ctx.attrs.OwnedGooSkinsJson)
			applyState({
				Owned = owned,
				SelectedSkinId = ctx.player:GetAttribute(ctx.attrs.SelectedGooSkinId),
				BestMultiplier = calculateBestOwned(owned),
			})
		end,
		setVisible = function(nextVisible)
			visible = nextVisible == true
			if visible then
				reconcile()
			end
		end,
		markDirty = function()
			dirty = true
		end,
	}
end

return WheelCollection
