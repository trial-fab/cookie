-- Spinner/reward state machine. Reel cells are cloned only from the Studio-authored
-- template and pooled between idle/spin runs. The server result remains authoritative.
local HttpService = game:GetService("HttpService")

local WheelReel = {}

local REEL_CELLS = 45
local TARGET_OFFSET_FROM_END = 4
local IDLE_SPEED = 90
local BUTTON_TWEEN_DURATION = 0.16
local DEFAULT_IDLE_BUTTON_WIDTH = 84
local DEFAULT_HOVER_BUTTON_WIDTH = 104
local DEFAULT_SPINNING_BUTTON_WIDTH = 142

local function fmtMult(value)
	return ("x%.2f"):format(tonumber(value) or 1)
end

local function setVisible(instance, visible)
	if instance and instance:IsA("GuiObject") then
		instance.Visible = visible
	end
end

function WheelReel.bind(ctx)
	local reel = ctx.waitChild(ctx.spinPage, "Reel")
	local strip = ctx.waitChild(reel, "Strip")
	local cellTemplate = ctx.waitChild(strip, "CellTemplate")
	local pointer = reel and reel:FindFirstChild("Pointer")
	local rewardCard = ctx.spinPage and ctx.spinPage:FindFirstChild("RewardCard")
	local statusLabel = ctx.spinPage and ctx.spinPage:FindFirstChild("Status")
	local allSkinDefs = {}
	local cellPool = {}
	local activeCells = {}
	local spinning = false
	local spinHovered = false
	local pageVisible = false
	local idleRunning = false
	local idleTween
	local reelTween
	local buttonTween
	local buttonTargetWidth
	local idleGeneration = 0
	local requestOwnershipSnapshot = {}
	local displayOwnershipSnapshot = {}

	for _, def in ipairs(ctx.config.GooSkinDefinitions) do
		if def.Rollable then
			table.insert(allSkinDefs, def)
		end
	end

	if pointer then
		pointer.Visible = false
	end

	local function setStatus(text)
		if statusLabel and statusLabel:IsA("TextLabel") then
			statusLabel.Text = text or ""
		end
	end

	local function currentGc()
		return tonumber(ctx.player:GetAttribute(ctx.attrs.GoldenCookies)) or 0
	end

	local function canSpin()
		return ctx.config.FeatureFlags.GooSkinsEnabled and not spinning and currentGc() >= ctx.config.SpinCost
	end

	local function styleSpinButton()
		if not (ctx.spinButton and ctx.spinButton:IsA("GuiButton")) then
			return
		end
		local enabled = canSpin()
		ctx.spinButton.AutoButtonColor = false
		ctx.spinButton.Active = enabled

		local contentRow = ctx.spinButton:FindFirstChild("ContentRow")
		local label = contentRow and contentRow:FindFirstChild("Label")
		local icon = contentRow and contentRow:FindFirstChild("GcIcon") or ctx.spinButton:FindFirstChild("GcIcon")
		local text
		local targetWidth
		if not ctx.config.FeatureFlags.GooSkinsEnabled then
			text = "Unavailable"
			targetWidth = ctx.spinButton:GetAttribute("UnavailableWidth") or DEFAULT_SPINNING_BUTTON_WIDTH
		elseif spinning then
			text = "Spinning…"
			targetWidth = ctx.spinButton:GetAttribute("SpinningWidth") or DEFAULT_SPINNING_BUTTON_WIDTH
		elseif spinHovered then
			text = "Spin"
			targetWidth = ctx.spinButton:GetAttribute("HoverWidth") or DEFAULT_HOVER_BUTTON_WIDTH
		else
			text = ctx.numberFormat.abbreviate(ctx.config.SpinCost)
			targetWidth = ctx.spinButton:GetAttribute("IdleWidth") or DEFAULT_IDLE_BUTTON_WIDTH
		end

		if label and label:IsA("TextLabel") then
			label.Text = text
			if ctx.spinButton:IsA("TextButton") then
				ctx.spinButton.Text = ""
			end
		elseif ctx.spinButton:IsA("TextButton") then
			ctx.spinButton.Text = text
		end
		setVisible(icon, not spinning and not spinHovered and ctx.config.FeatureFlags.GooSkinsEnabled)

		if buttonTargetWidth ~= targetWidth then
			buttonTargetWidth = targetWidth
			if buttonTween then
				buttonTween:Cancel()
			end
			local size = ctx.spinButton.Size
			buttonTween = ctx.uiMotion.create(
				ctx.spinButton,
				TweenInfo.new(BUTTON_TWEEN_DURATION, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
				{ Size = UDim2.new(size.X.Scale, targetWidth, size.Y.Scale, size.Y.Offset) }
			)
			buttonTween.Completed:Once(function()
				buttonTween = nil
			end)
			buttonTween:Play()
		end
	end

	local function refreshGc()
		if ctx.gcValue and ctx.gcValue:IsA("TextLabel") then
			ctx.gcValue.Text = ctx.numberFormat.abbreviate(currentGc())
		end
		styleSpinButton()
	end

	local function randomDef()
		return allSkinDefs[math.random(1, #allSkinDefs)]
	end

	local function applyRarityAccent(container, rarity)
		if not (container and rarity) then
			return
		end
		local glowStroke = container:FindFirstChild("GlowStroke", true)
		if glowStroke and glowStroke:IsA("UIStroke") then
			glowStroke.Color = rarity.Color
		end
		for _, sparkle in ipairs(container:GetDescendants()) do
			if string.match(sparkle.Name, "^Sparkle") and (sparkle:IsA("ImageLabel") or sparkle:IsA("ImageButton")) then
				sparkle.ImageColor3 = rarity.Color
			end
		end
	end

	local function defFromResult(result)
		return ctx.config.GetSkinDef(result.SkinId)
			or {
				Id = result.SkinId,
				RarityId = result.RarityId,
				DisplayName = result.DisplayName,
				Multiplier = result.Multiplier,
				IsLimited = result.IsLimited,
			}
	end

	local function paintCell(cell, def, options)
		options = options or {}
		local rarity = def and ctx.config.RarityById[def.RarityId]
		local owned = def and displayOwnershipSnapshot[def.Id] == true
		local selected = owned and ctx.player:GetAttribute(ctx.attrs.SelectedGooSkinId) == def.Id
		local locked = not owned
		if options.Winning then
			locked = options.NewReward == true and options.Landed ~= true
			owned = not locked
		end

		local bg = cell:FindFirstChild("Bg") or cell
		local stroke = bg:FindFirstChildWhichIsA("UIStroke") or cell:FindFirstChildWhichIsA("UIStroke")
		if stroke and rarity then
			stroke.Color = rarity.Color
		end
		local label = cell:FindFirstChild("Label")
		if label and label:IsA("TextLabel") then
			label.Text = rarity and rarity.DisplayName or (def and def.RarityId) or ""
			if rarity then
				label.TextColor3 = rarity.Color
			end
		end
		setVisible(cell:FindFirstChild("LockMarker"), locked)
		setVisible(cell:FindFirstChild("OwnedMarker"), owned)
		setVisible(cell:FindFirstChild("SelectedMarker"), selected and not options.Winning)
		local winnerGlow = cell:FindFirstChild("WinnerGlow")
		setVisible(winnerGlow, options.Winning and options.Landed == true)
		applyRarityAccent(winnerGlow, rarity)

		local preview = cell:FindFirstChild("Preview")
		if preview and preview:IsA("ViewportFrame") and def then
			preview.Visible = true
			ctx.preview.Render(preview, def.Id, { Locked = locked, Lightweight = true })
		end
		cell:SetAttribute("WheelSkinId", def and def.Id or "")
	end

	local function acquireCell(order, def, options)
		local cell = table.remove(cellPool)
		if not cell then
			cell = cellTemplate:Clone()
		end
		cell.Name = "Cell"
		cell.LayoutOrder = order
		cell.Visible = true
		cell.Parent = strip
		paintCell(cell, def, options)
		table.insert(activeCells, cell)
		return cell
	end

	local function releaseCells()
		if reelTween then
			reelTween:Cancel()
			reelTween = nil
		end
		for _, cell in ipairs(activeCells) do
			cell.Visible = false
			cell.Parent = strip
			table.insert(cellPool, cell)
		end
		table.clear(activeCells)
	end

	local function reelPitch()
		local width = cellTemplate and cellTemplate.Size.X.Offset or 0
		if width <= 0 and cellTemplate then
			width = cellTemplate.AbsoluteSize.X
		end
		local layout = strip and strip:FindFirstChildOfClass("UIListLayout")
		return width + (layout and layout.Padding.Offset or 0), width
	end

	local function stopIdle()
		idleGeneration += 1
		idleRunning = false
		if idleTween then
			idleTween:Cancel()
			idleTween = nil
		end
	end

	local function populateIdleWindow()
		releaseCells()
		if not (reel and strip and cellTemplate) then
			return false
		end
		local pitch = reelPitch()
		local width = reel.AbsoluteSize.X > 0 and reel.AbsoluteSize.X or reel.Size.X.Offset
		if pitch <= 0 or width <= 0 then
			return false
		end
		strip.Position = UDim2.new(0, 0, strip.Position.Y.Scale, strip.Position.Y.Offset)
		local count = math.ceil(width / pitch) + 4
		for order = 1, count do
			acquireCell(order, randomDef())
		end
		return true
	end

	local function startIdle()
		if idleRunning or spinning or not pageVisible or not (reel and strip and cellTemplate) then
			return
		end
		if pointer then
			pointer.Visible = false
		end
		idleGeneration += 1
		local generation = idleGeneration
		task.spawn(function()
			local raw = ctx.player:GetAttribute(ctx.attrs.OwnedGooSkinsJson)
			local ok, decoded = pcall(HttpService.JSONDecode, HttpService, type(raw) == "string" and raw or "{}")
			displayOwnershipSnapshot = ok and type(decoded) == "table" and decoded or {}
			local deadline = tick() + 3
			while reel.AbsoluteSize.X <= 0 and tick() < deadline do
				task.wait()
			end
			if generation ~= idleGeneration or spinning or not pageVisible or not populateIdleWindow() then
				return
			end
			if ctx.uiMotion.isReduced(strip) then
				return
			end

			idleRunning = true
			local pitch = reelPitch()
			local nextOrder = #activeCells
			local stripY = strip.Position.Y
			local playSegment
			playSegment = function()
				if generation ~= idleGeneration or not idleRunning or #activeCells == 0 then
					return
				end
				local fromX = strip.Position.X.Offset
				idleTween = ctx.uiMotion.create(
					strip,
					TweenInfo.new(pitch / IDLE_SPEED, Enum.EasingStyle.Linear),
					{ Position = UDim2.new(0, fromX - pitch, stripY.Scale, stripY.Offset) }
				)
				idleTween.Completed:Once(function(playbackState)
					idleTween = nil
					if
						generation ~= idleGeneration
						or not idleRunning
						or playbackState ~= Enum.PlaybackState.Completed
					then
						return
					end
					local cell = table.remove(activeCells, 1)
					nextOrder += 1
					cell.LayoutOrder = nextOrder
					paintCell(cell, randomDef())
					table.insert(activeCells, cell)
					strip.Position = UDim2.new(0, strip.Position.X.Offset + pitch, stripY.Scale, stripY.Offset)
					playSegment()
				end)
				idleTween:Play()
			end
			playSegment()
		end)
	end

	local function pulseAuthored(instance)
		if not (instance and instance:IsA("GuiObject")) or ctx.uiMotion.isReduced(instance) then
			return
		end
		local scale = instance:FindFirstChildOfClass("UIScale")
		if not scale then
			return
		end
		scale.Scale = 0.82
		local tween = ctx.uiMotion.create(
			scale,
			TweenInfo.new(0.22, Enum.EasingStyle.Back, Enum.EasingDirection.Out),
			{ Scale = 1 }
		)
		tween:Play()
	end

	local function revealReward(result)
		if not rewardCard then
			return
		end
		local def = defFromResult(result)
		local rarity = ctx.config.RarityById[result.RarityId]
		local name = rewardCard:FindFirstChild("SkinName")
		local tag = rewardCard:FindFirstChild("RarityTag")
		local multiplier = rewardCard:FindFirstChild("Multiplier")
		local ownedLabel = rewardCard:FindFirstChild("OwnedLabel")
		if name and name:IsA("TextLabel") then
			name.Text = result.DisplayName or "?"
		end
		if tag and tag:IsA("TextLabel") then
			tag.Text = rarity and rarity.DisplayName or (result.RarityId or "")
			if rarity then
				tag.TextColor3 = rarity.Color
			end
		end
		if multiplier and multiplier:IsA("TextLabel") then
			multiplier.Text = type(result.Multiplier) == "number" and fmtMult(result.Multiplier) or "Cosmetic"
		end
		if ownedLabel and ownedLabel:IsA("TextLabel") then
			-- Duplicate/refund feedback lives in the gray Status label beneath the card.
			ownedLabel.Visible = false
			ownedLabel.Text = ""
		end
		local preview = rewardCard:FindFirstChild("Preview")
		if preview and preview:IsA("ViewportFrame") then
			preview.Visible = true
			ctx.preview.Render(preview, def.Id, { Lightweight = false })
		end
		setVisible(rewardCard:FindFirstChild("RewardGlow"), true)
		applyRarityAccent(rewardCard, rarity)
		rewardCard.Visible = true
		pulseAuthored(rewardCard:FindFirstChild("RewardGlow"))
	end

	local function spinReel(result, onComplete)
		if not (reel and strip and cellTemplate) then
			onComplete()
			return
		end
		stopIdle()
		releaseCells()
		if pointer then
			pointer.Visible = true
		end
		local winningDef = defFromResult(result)
		local targetIndex = REEL_CELLS - TARGET_OFFSET_FROM_END
		local winningCell
		local newReward = requestOwnershipSnapshot[result.SkinId] ~= true
		for order = 1, REEL_CELLS do
			if order == targetIndex then
				winningCell = acquireCell(order, winningDef, { Winning = true, NewReward = newReward })
			else
				acquireCell(order, randomDef())
			end
		end

		local pitch, cellWidth = reelPitch()
		local reelWidth = reel.AbsoluteSize.X > 0 and reel.AbsoluteSize.X or reel.Size.X.Offset
		local targetCenter = (targetIndex - 1) * pitch + cellWidth / 2
		local endOffset = reelWidth / 2 - targetCenter
		strip.Position = UDim2.new(0, pitch, strip.Position.Y.Scale, strip.Position.Y.Offset)

		local function landed()
			if winningCell then
				paintCell(winningCell, winningDef, { Winning = true, NewReward = newReward, Landed = true })
				if result.IsDuplicate then
					pulseAuthored(winningCell:FindFirstChild("OwnedMarker"))
				else
					pulseAuthored(winningCell:FindFirstChild("WinnerGlow"))
				end
			end
			onComplete()
		end

		-- A paid spin always uses the complete default reel animation. Reduced Motion only
		-- suppresses continuous/decorative work such as idle drift; it never shortens this
		-- gameplay wait. Only the separately granted game-pass entitlement may skip it.
		if ctx.player:GetAttribute(ctx.attrs.InstantWheelSpinEnabled) == true then
			strip.Position = UDim2.new(0, endOffset, strip.Position.Y.Scale, strip.Position.Y.Offset)
			task.defer(landed)
			return
		end
		reelTween = ctx.uiMotion.create(
			strip,
			TweenInfo.new(2.6, Enum.EasingStyle.Quart, Enum.EasingDirection.Out),
			{ Position = UDim2.new(0, endOffset, strip.Position.Y.Scale, strip.Position.Y.Offset) }
		)
		reelTween.Completed:Once(function()
			reelTween = nil
			landed()
		end)
		reelTween:Play()
	end

	local function onSpinResult(result)
		if type(result) ~= "table" then
			spinning = false
			styleSpinButton()
			startIdle()
			return
		end
		if not result.Success then
			spinning = false
			if result.Reason == "NotEnoughGoldenCookies" then
				setStatus(
					"Not enough golden cookies — you need " .. ctx.numberFormat.abbreviate(ctx.config.SpinCost) .. "."
				)
			elseif result.Reason == "Disabled" then
				setStatus("Goo skins are currently unavailable.")
			elseif result.Reason == "ConfigurationUnavailable" then
				setStatus("The wheel is temporarily unavailable.")
			elseif result.Reason == "NotReady" then
				setStatus("Not ready yet — try again in a moment.")
			else
				setStatus("Spin failed.")
			end
			styleSpinButton()
			startIdle()
			return
		end

		if rewardCard then
			rewardCard.Visible = false
		end
		setStatus("")
		spinReel(result, function()
			revealReward(result)
			if result.IsDuplicate then
				setStatus(
					("Owned duplicate. Refunded %s GC."):format(
						ctx.numberFormat.abbreviate(result.RefundGC or ctx.config.DuplicateRefundGC)
					)
				)
			else
				setStatus("New skin unlocked!")
			end
			spinning = false
			styleSpinButton()
			startIdle()
		end)
	end

	ctx.net.on(ctx.net.Names.SpinResult, onSpinResult)
	ctx.player:GetAttributeChangedSignal(ctx.attrs.GoldenCookies):Connect(refreshGc)

	if ctx.spinButton and ctx.spinButton:IsA("GuiButton") then
		ctx.spinButton.MouseEnter:Connect(function()
			spinHovered = true
			styleSpinButton()
		end)
		ctx.spinButton.MouseLeave:Connect(function()
			spinHovered = false
			styleSpinButton()
		end)
		ctx.spinButton.Activated:Connect(function()
			if not canSpin() then
				if not ctx.config.FeatureFlags.GooSkinsEnabled then
					setStatus("Goo skins are currently unavailable.")
				elseif not spinning then
					setStatus(
						"Not enough golden cookies — you need "
							.. ctx.numberFormat.abbreviate(ctx.config.SpinCost)
							.. "."
					)
				end
				return
			end
			local raw = ctx.player:GetAttribute(ctx.attrs.OwnedGooSkinsJson)
			local ok, decoded = pcall(HttpService.JSONDecode, HttpService, type(raw) == "string" and raw or "{}")
			requestOwnershipSnapshot = ok and type(decoded) == "table" and decoded or {}
			displayOwnershipSnapshot = requestOwnershipSnapshot
			spinning = true
			setStatus("")
			styleSpinButton()
			ctx.net.fireServer(ctx.net.Names.RequestSpin)
		end)
	end

	refreshGc()
	if not ctx.config.FeatureFlags.GooSkinsEnabled then
		setStatus("Goo skins are currently unavailable.")
	end

	return {
		refresh = refreshGc,
		setVisible = function(visible)
			pageVisible = visible == true
			if pageVisible then
				startIdle()
			else
				stopIdle()
			end
		end,
		stop = stopIdle,
		restartForMotionSetting = function()
			stopIdle()
			startIdle()
		end,
	}
end

return WheelReel
