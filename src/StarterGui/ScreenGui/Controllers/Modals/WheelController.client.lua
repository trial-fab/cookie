-- WheelController — logic only. The Cookie Wheel modal (StarterGui.ScreenGui.
-- WheelModal) — header + GC pill, a Spin/Skins TabBar, a slot-reel spin page and a
-- per-building skins page — is authored in Studio. Golden amounts show as a bare number
-- next to a Studio-authored gold-tinted `GcIcon` ImageLabel in three standalone spots: the
-- GC pill `Value`, the `SpinButton`, and each daily `DayCardTemplate` reward label. This
-- controller only writes the number (and hides the spin button's icon while "Spinning…");
-- it never builds or styles the icon. Mid-sentence status toasts keep the worded "GC". This drives it from the live
-- WheelService backend: it fires RequestSpin / EquipSkin, consumes SpinResult /
-- SkinInventoryChanged, and reads the GoldenCookies attribute for the 75-GC spin
-- gate. All odds, colors, names, cost and refund come from Shared/WheelConfig — the
-- UI never hardcodes them. The reel is purely cosmetic: the server result is
-- authoritative and already known before the strip eases to its rarity. Only one of
-- Help/Settings/Profile/Wheel is open at a time via the shared OpenModal slot.
--
-- The controller is defensive by subsystem: the Spin and Skins sections each wire
-- only the named children that exist, so it loads clean while the Studio frame is
-- still being authored slice by slice.
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local HttpService = game:GetService("HttpService")

local ModalOutsideClose = require(script.Parent:WaitForChild("ModalOutsideClose"))
local ModalCoordinator = require(script.Parent:WaitForChild("ModalCoordinator"))
local ModalPageTransition = require(script.Parent:WaitForChild("ModalPageTransition"))

local MY = "Wheel"
local ACTIVE_COLOR = Color3.fromRGB(0, 170, 255)
local MUTED = Color3.fromRGB(150, 160, 175)

local screenGui = script:FindFirstAncestorOfClass("ScreenGui")
if not screenGui then
	warn("WheelController must live inside a ScreenGui")
	return
end
if screenGui:GetAttribute("WheelControllerRunning") then
	return
end
screenGui:SetAttribute("WheelControllerRunning", true)

local player = Players.LocalPlayer
local modal = screenGui:WaitForChild("WheelModal", 10)
if not modal then
	warn("WheelController disabled: WheelModal not found")
	return
end

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Net = require(Shared:WaitForChild("Net"))
local Attrs = require(Shared:WaitForChild("Attrs"))
local GuiNames = require(Shared:WaitForChild("GuiNames"))
local UiMotion = require(Shared:WaitForChild("UiMotion"))
local NumberFormat = require(Shared:WaitForChild("NumberFormat"))
local MobileScale = require(Shared:WaitForChild("MobileScale"))
local WheelConfig = require(Shared:WaitForChild("WheelConfig"))
local UpgradeConfig = require(Shared:WaitForChild("UpgradeConfig"))
local DailyRewardConfig = require(Shared:WaitForChild("DailyRewardConfig"))

-- Structural lookups use WaitForChild, not FindFirstChild: in a *published* place the
-- ScreenGui replicates to the client progressively, so deeply-nested descendants (Reel/
-- Strip/CellTemplate, the pages, the tabs) are often not present yet when this controller
-- runs. A one-shot FindFirstChild would capture nil permanently and the idle reel would
-- never start (works in Studio only because the tree is instant). WaitForChild with a
-- timeout still degrades gracefully (returns nil) while the frame is authored slice by slice.
local WAIT_TIMEOUT = 10
local function waitChild(parent, name)
	if not parent then return nil end
	return parent:WaitForChild(name, WAIT_TIMEOUT)
end

local function fmtMult(m)
	return ("×%.2f"):format(tonumber(m) or 1)
end

local function buildingName(buildingId)
	local cfg = buildingId and UpgradeConfig[buildingId]
	return (cfg and cfg.DisplayName) or buildingId or "Unknown"
end

-- ── GC pill + spin gate ────────────────────────────────────────────────────────
local header = waitChild(modal, "Header")
local gcValue = header and header:FindFirstChild("GcPill", true)
gcValue = gcValue and (gcValue:FindFirstChild("Value") or gcValue)
local spinPage = waitChild(modal, "SpinPage")
local spinButton = waitChild(spinPage, "SpinButton") or (spinPage and spinPage:FindFirstChild("SpinButton", true))

local spinning = false

local function currentGc()
	return tonumber(player:GetAttribute(Attrs.GoldenCookies)) or 0
end

local function canSpin()
	return not spinning and currentGc() >= WheelConfig.SpinCost
end

local function styleSpinButton()
	if not (spinButton and spinButton:IsA("GuiButton")) then return end
	local enabled = canSpin()
	spinButton.AutoButtonColor = enabled
	spinButton.Active = enabled
	if spinButton:IsA("TextButton") then
		spinButton.Text = spinning and "Spinning…" or ("Spin " .. NumberFormat.abbreviate(WheelConfig.SpinCost))
		spinButton.TextTransparency = enabled and 0 or 0.45
	end
	-- The cost icon (Studio-authored `GcIcon` child) only makes sense beside the cost
	-- number; hide it while the button reads "Spinning…".
	local spinIcon = spinButton:FindFirstChild("GcIcon")
	if spinIcon and spinIcon:IsA("GuiObject") then
		spinIcon.Visible = not spinning
	end
end

local function refreshGc()
	if gcValue and gcValue:IsA("TextLabel") then
		gcValue.Text = NumberFormat.abbreviate(currentGc())
	end
	styleSpinButton()
end

player:GetAttributeChangedSignal(Attrs.GoldenCookies):Connect(refreshGc)

-- ── Tabs ───────────────────────────────────────────────────────────────────────
local tabBar = waitChild(modal, "TabBar")
local skinsPage = waitChild(modal, "SkinsPage")
local dailyPage = waitChild(modal, "DailyPage")
local spinTab = tabBar and tabBar:FindFirstChild("SpinTab")
local skinsTab = tabBar and tabBar:FindFirstChild("SkinsTab")
local dailyTab = tabBar and tabBar:FindFirstChild("DailyTab")

-- Implemented in the Daily section below; called on open and when the Daily tab is shown.
local refreshDaily

local function styleTab(tab, active)
	if not (tab and tab:IsA("TextButton")) then return end
	tab.TextColor3 = active and ACTIVE_COLOR or MUTED
	local underline = tab:FindFirstChild("Underline")
	if underline then underline.Visible = active end
end

local function setTab(name)
	if spinPage then spinPage.Visible = (name == "Spin") end
	if skinsPage then skinsPage.Visible = (name == "Skins") end
	if dailyPage then dailyPage.Visible = (name == "Daily") end
	styleTab(spinTab, name == "Spin")
	styleTab(skinsTab, name == "Skins")
	styleTab(dailyTab, name == "Daily")
	if name == "Daily" and refreshDaily then refreshDaily() end
end

if spinTab and spinTab:IsA("TextButton") then
	spinTab.MouseButton1Click:Connect(function() setTab("Spin") end)
end
if skinsTab and skinsTab:IsA("TextButton") then
	skinsTab.MouseButton1Click:Connect(function() setTab("Skins") end)
end
if dailyTab and dailyTab:IsA("TextButton") then
	dailyTab.MouseButton1Click:Connect(function() setTab("Daily") end)
end

-- ── Spin flow + slot reel ────────────────────────────────────────────────────────
local reel = waitChild(spinPage, "Reel")
local strip = waitChild(reel, "Strip")
local cellTemplate = waitChild(strip, "CellTemplate")
local pointer = reel and reel:FindFirstChild("Pointer")
local rewardCard = spinPage and spinPage:FindFirstChild("RewardCard")
local statusLabel = spinPage and spinPage:FindFirstChild("Status")

-- The pointer only marks the landing slot during an actual spin; it stays hidden
-- while the reel is just idle-drifting to preview rarities.
if pointer then pointer.Visible = false end

-- Hidden library of building silhouettes (one ImageLabel per buildingId, plus one
-- per limited skin id), authored in Studio. The user fills in the images; the
-- controller copies the matching one onto a cell/card's "Preview" ImageLabel so a
-- reel cell is a tinted building variant, not just a colored box. Missing slot →
-- the Preview is simply hidden (graceful while art is still being made).
local previewLib = modal:FindFirstChild("SkinPreviews")

local REEL_CELLS = 45 -- total cells in a spin run
local TARGET_OFFSET_FROM_END = 4 -- winning cell sits this many cells from the end
local IDLE_SPEED = 90 -- px/sec the reel drifts while idle, so rarities are always previewing
local reelTween

-- Flat list of every skin that can actually be WON on the wheel, for random idle/filler
-- cells. Excludes exclusive (mythical) skins: those are daily-streak rewards, never rolled
-- here, so they must never appear in the preview reel. Limited IS a real 1% wheel outcome,
-- so it stays.
local allSkinDefs = {}
for _, def in pairs(WheelConfig.SkinRegistry) do
	if not def.IsExclusive then
		allSkinDefs[#allSkinDefs + 1] = def
	end
end

local function randomDef()
	return allSkinDefs[math.random(1, #allSkinDefs)]
end

local function defFromResult(result)
	return WheelConfig.GetSkinDef(result.SkinId) or {
		Id = result.SkinId,
		RarityId = result.RarityId,
		BuildingId = result.BuildingId,
		DisplayName = result.DisplayName,
		Multiplier = result.Multiplier,
		IsLimited = result.IsLimited,
	}
end

-- Copy the authored silhouette for `def` onto a holder's "Preview" ImageLabel.
local function applyPreview(holder, def)
	if not holder then return end
	local preview = holder:FindFirstChild("Preview")
	if not (preview and preview:IsA("ImageLabel")) then return end
	local key = def and (def.BuildingId or def.Id)
	local src = key and previewLib and previewLib:FindFirstChild(key)
	if src and src:IsA("ImageLabel") and src.Image ~= "" then
		preview.Image = src.Image
		preview.ImageColor3 = src.ImageColor3
		preview.ImageTransparency = src.ImageTransparency
		preview.ImageRectOffset = src.ImageRectOffset
		preview.ImageRectSize = src.ImageRectSize
		preview.ScaleType = src.ScaleType
		preview.Visible = true
	else
		preview.Image = ""
		preview.Visible = false
	end
end

local function paintCell(cell, def)
	local rarity = def and WheelConfig.RarityById[def.RarityId]
	local bg = cell:FindFirstChild("Bg") or cell
	if rarity and bg:IsA("GuiObject") then bg.BackgroundColor3 = rarity.Color end
	local label = cell:FindFirstChild("Label")
	if label and label:IsA("TextLabel") then
		label.Text = rarity and rarity.DisplayName or (def and def.RarityId) or ""
	end
	applyPreview(cell, def)
end

local function makeCell(order, def)
	local cell = cellTemplate:Clone()
	cell.Name = "Cell"
	cell.LayoutOrder = order
	cell.Visible = true
	paintCell(cell, def)
	cell.Parent = strip
	return cell
end

-- Reel geometry in offset units (avoids AbsoluteSize timing on the cells).
local function reelPitch()
	local cellW = cellTemplate.Size.X.Offset
	if cellW <= 0 then cellW = cellTemplate.AbsoluteSize.X end
	local layout = strip:FindFirstChildOfClass("UIListLayout")
	local pad = layout and layout.Padding.Offset or 0
	return cellW + pad, cellW
end

-- ── Idle drift: the reel always scrolls at a fixed rate so the player can see the
-- rarities/variants on offer. Cells are recycled: as the leftmost slides off, it is
-- re-parented to the tail (bumped LayoutOrder) and repainted, while Position is nudged
-- back by one pitch so the on-screen cells never jump. Resumes seamlessly from wherever
-- a spin landed, so there is no pop after a reveal.
-- The drift is driven by a looping TweenService animation, NOT a per-frame manual write.
-- Reason: some clients throttle their update loop to ~0 fps when the scene is "idle" (no
-- input, no active tween) to save power — there a Heartbeat/RenderStepped that just sets
-- Position never visibly moves (the player had to physically drag the OS window to force
-- repaints). An active Tween keeps the client awake and rendering (the spin tween worked
-- for exactly this reason), so the idle reel is a chain of one-pitch tweens that recycle a
-- cell at each boundary.
local idleCells = {}
local idleTween -- the current one-pitch drift tween (nil between segments / when stopped)
local idleSegmentStartX -- strip X offset the live segment began at, for clean cancellation
local idleRunning = false
-- Bumped by every startIdle/stopIdle. A startIdle's async geometry wait captures the
-- generation it began with and bails if it changed, so a second startIdle (or a stopIdle)
-- during that wait can never start a duplicate tween loop — two loops sharing idleCells
-- would drain it twice and underflow table.remove.
local idleGen = 0

local function collectCells()
	local cells = {}
	for _, c in ipairs(strip:GetChildren()) do
		if c ~= cellTemplate and c.Name == "Cell" and c:IsA("GuiObject") then
			cells[#cells + 1] = c
		end
	end
	table.sort(cells, function(a, b) return a.LayoutOrder < b.LayoutOrder end)
	return cells
end

local function clearCells()
	if reelTween then reelTween:Cancel(); reelTween = nil end
	for _, child in ipairs(strip:GetChildren()) do
		if child ~= cellTemplate and child:IsA("GuiObject") then
			child:Destroy()
		end
	end
	idleCells = {}
end

local function stopIdle()
	idleGen += 1 -- abort any in-flight startIdle still waiting on geometry
	idleRunning = false
	if idleTween then
		idleTween:Cancel()
		idleTween = nil
		-- A cancelled segment never ran its recycle + snap-back, so the strip is parked
		-- partway through a pitch. Restore the offset the segment started at to undo the
		-- partial slide; otherwise repeated open/close accumulates a leftward drift and a
		-- one-cell gap opens at the right edge. Works for both pure idle (baseline 0) and a
		-- post-spin resume (baseline at the landed offset).
		if idleSegmentStartX and strip then
			strip.Position = UDim2.new(0, idleSegmentStartX, strip.Position.Y.Scale, strip.Position.Y.Offset)
		end
	end
end

local function startIdle()
	if idleRunning or spinning or not (reel and strip and cellTemplate) then return end
	if pointer then pointer.Visible = false end -- hidden again once we're back to idle drift
	idleGen += 1
	local myGen = idleGen
	task.spawn(function()
		-- wait for the reel to have real geometry (it may open before a layout pass)
		local pitch, reelW
		local deadline = tick() + 3
		repeat
			pitch = select(1, reelPitch())
			reelW = reel.AbsoluteSize.X
			if pitch > 0 and reelW > 0 then break end
			task.wait()
		until tick() > deadline
		-- bail if another startIdle/stopIdle superseded us, a spin started, or geometry never came
		if myGen ~= idleGen or idleRunning or spinning then return end
		if not pitch or pitch <= 0 then return end
		if reelW <= 0 then reelW = reel.Size.X.Offset end

		idleCells = collectCells()
		local nextOrder = 0
		for _, c in ipairs(idleCells) do nextOrder = math.max(nextOrder, c.LayoutOrder) end

		if #idleCells == 0 then
			strip.Position = UDim2.new(0, 0, strip.Position.Y.Scale, strip.Position.Y.Offset)
			local windowCount = math.ceil(reelW / pitch) + 4
			for _ = 1, windowCount do
				nextOrder += 1
				idleCells[#idleCells + 1] = makeCell(nextOrder, randomDef())
			end
		end

		if myGen ~= idleGen then return end -- a stop/restart slipped in while we built cells
		if UiMotion.isReduced(strip) then
			-- Reduced Motion keeps the reel populated as a stationary preview. It must remain
			-- non-running so a player-triggered spin can replace these cells immediately.
			idleRunning = false
			idleTween = nil
			idleSegmentStartX = strip.Position.X.Offset
			return
		end

		local stripY = strip.Position.Y
		-- Rebuild a fresh window at the origin (used on start if empty, and as a self-heal if a
		-- race ever drains the recycle pool).
		local function rebuildWindow()
			strip.Position = UDim2.new(0, 0, stripY.Scale, stripY.Offset)
			for _, c in ipairs(strip:GetChildren()) do
				if c ~= cellTemplate and c.Name == "Cell" then c:Destroy() end
			end
			idleCells = {}
			local liveW = reel.AbsoluteSize.X
			if liveW > 0 then reelW = liveW end
			local windowCount = math.ceil(reelW / pitch) + 4
			for _ = 1, windowCount do
				nextOrder += 1
				idleCells[#idleCells + 1] = makeCell(nextOrder, randomDef())
			end
		end

		-- One drift segment = slide the strip left by exactly one pitch over a fixed duration,
		-- then recycle the cell that scrolled off the left to the tail and snap the strip back by
		-- one pitch so the motion reads as a seamless infinite scroll. Chaining these keeps an
		-- active tween alive at all times, which is what keeps power-throttling clients rendering.
		idleRunning = true
		local playSegment
		playSegment = function()
			if myGen ~= idleGen or not idleRunning then return end
			if #idleCells == 0 then rebuildWindow() end

			local fromX = strip.Position.X.Offset
			idleSegmentStartX = fromX
			idleTween = UiMotion.create(
				strip,
				TweenInfo.new(pitch / IDLE_SPEED, Enum.EasingStyle.Linear),
				{ Position = UDim2.new(0, fromX - pitch, stripY.Scale, stripY.Offset) }
			)
			idleTween.Completed:Once(function(state)
				idleTween = nil
				if myGen ~= idleGen or not idleRunning or state ~= Enum.PlaybackState.Completed then
					return
				end
				-- recycle the leftmost cell to the tail, then snap back one pitch (seamless)
				local cell = table.remove(idleCells, 1)
				if cell then
					nextOrder += 1
					cell.LayoutOrder = nextOrder
					paintCell(cell, randomDef())
					idleCells[#idleCells + 1] = cell
				end
				strip.Position = UDim2.new(0, strip.Position.X.Offset + pitch, stripY.Scale, stripY.Offset)
				playSegment()
			end)
			idleTween:Play()
		end
		playSegment()
	end)
end

local function setStatus(text)
	if statusLabel and statusLabel:IsA("TextLabel") then statusLabel.Text = text or "" end
end

local function revealReward(result)
	if not rewardCard then return end
	local def = defFromResult(result)
	local rarity = WheelConfig.RarityById[result.RarityId]
	local name = rewardCard:FindFirstChild("SkinName")
	local tag = rewardCard:FindFirstChild("RarityTag")
	local mult = rewardCard:FindFirstChild("Multiplier")
	if name and name:IsA("TextLabel") then name.Text = result.DisplayName or "?" end
	if tag and tag:IsA("TextLabel") then
		tag.Text = rarity and rarity.DisplayName or (result.RarityId or "")
		if rarity then tag.TextColor3 = rarity.Color end
	end
	if mult and mult:IsA("TextLabel") then
		mult.Text = result.IsLimited and "Cosmetic" or fmtMult(result.Multiplier)
	end
	applyPreview(rewardCard, def)
	rewardCard.Visible = true
end

-- Builds a fresh run of reel cells ending on the won skin and eases the strip so that
-- cell stops centered under the reel viewport. Cosmetic only — the server result is
-- authoritative. Stops the idle drift first; the caller resumes it after the reveal.
local function spinReel(result, onComplete)
	if not (reel and strip and cellTemplate) then
		onComplete()
		return
	end
	stopIdle()
	clearCells()
	if pointer then pointer.Visible = true end -- show the landing marker for the spin

	local winningDef = defFromResult(result)
	local targetIndex = REEL_CELLS - TARGET_OFFSET_FROM_END
	for i = 1, REEL_CELLS do
		makeCell(i, (i == targetIndex) and winningDef or randomDef())
	end

	local pitch, cellW = reelPitch()
	local reelW = reel.AbsoluteSize.X
	if reelW <= 0 then reelW = reel.Size.X.Offset end

	-- Center the (targetIndex-1)-th cell (0-based) under the reel midpoint.
	local targetCenter = (targetIndex - 1) * pitch + cellW / 2
	local endOffset = reelW / 2 - targetCenter
	local startOffset = pitch -- begin a hair in so motion reads left-to-right

	strip.Position = UDim2.new(0, startOffset, strip.Position.Y.Scale, strip.Position.Y.Offset)
	reelTween = UiMotion.create(
		strip,
		TweenInfo.new(2.6, Enum.EasingStyle.Quart, Enum.EasingDirection.Out),
		{ Position = UDim2.new(0, endOffset, strip.Position.Y.Scale, strip.Position.Y.Offset) }
	)
	reelTween.Completed:Once(function()
		reelTween = nil
		onComplete()
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
			setStatus("Not enough golden cookies — you need " .. NumberFormat.abbreviate(WheelConfig.SpinCost) .. ".")
		elseif result.Reason == "NotReady" then
			setStatus("Not ready yet — try again in a moment.")
		else
			setStatus("Spin failed.")
		end
		styleSpinButton()
		startIdle()
		return
	end

	if rewardCard then rewardCard.Visible = false end
	setStatus("")
	spinReel(result, function()
		revealReward(result)
		if result.IsDuplicate then
			setStatus("Duplicate — refunded " .. NumberFormat.abbreviate(result.RefundGC or WheelConfig.DuplicateRefundGC) .. " GC.")
		else
			setStatus("New skin unlocked!")
		end
		spinning = false
		styleSpinButton()
		startIdle() -- resume the idle drift from where the strip landed
	end)
end

Net.on(Net.Names.SpinResult, onSpinResult)

if spinButton and spinButton:IsA("GuiButton") then
	spinButton.MouseButton1Click:Connect(function()
		if not canSpin() then
			if not spinning then
				setStatus("Not enough golden cookies — you need " .. NumberFormat.abbreviate(WheelConfig.SpinCost) .. ".")
			end
			return
		end
		spinning = true
		setStatus("")
		styleSpinButton()
		Net.fireServer(Net.Names.RequestSpin)
	end)
end

-- ── Skins page (per-building inventory + equip) ───────────────────────────────────
local sectionTemplate = waitChild(skinsPage, "BuildingSectionTemplate")
local emptyLabel = skinsPage and skinsPage:FindFirstChild("Empty")
local LIMITED_GROUP = "__limited"

local function decodeAttr(name)
	local raw = player:GetAttribute(name)
	if type(raw) ~= "string" then return {} end
	local ok, decoded = pcall(function() return HttpService:JSONDecode(raw) end)
	return (ok and type(decoded) == "table") and decoded or {}
end

local function clearSkinClones()
	if not skinsPage then return end
	for _, child in ipairs(skinsPage:GetChildren()) do
		if child:GetAttribute("WheelClone") then child:Destroy() end
	end
end

local function fillCard(card, skinId, def, equipped)
	card.Name = "SkinCard"
	card:SetAttribute("WheelClone", true)
	card.Visible = true

	local rarity = WheelConfig.RarityById[def.RarityId]
	local nameL = card:FindFirstChild("SkinName")
	local tag = card:FindFirstChild("RarityTag")
	local mult = card:FindFirstChild("Multiplier")
	local equipBtn = card:FindFirstChild("EquipButton")

	if nameL and nameL:IsA("TextLabel") then nameL.Text = def.DisplayName or skinId end
	if tag and tag:IsA("TextLabel") then
		tag.Text = rarity and rarity.DisplayName or (def.RarityId or "")
		if rarity then tag.TextColor3 = rarity.Color end
	end
	if mult and mult:IsA("TextLabel") then
		mult.Text = def.IsLimited and "Cosmetic" or fmtMult(def.Multiplier)
	end
	applyPreview(card, def)

	if equipBtn and equipBtn:IsA("GuiButton") then
		if def.IsLimited or not def.BuildingId then
			-- Limited cosmetics aren't equippable to a producer.
			equipBtn.Visible = false
		else
			local isEquipped = equipped[def.BuildingId] == skinId
			equipBtn.Visible = true
			if equipBtn:IsA("TextButton") then
				equipBtn.Text = isEquipped and "Equipped" or "Equip"
			end
			equipBtn:SetAttribute(Attrs.Active, isEquipped)
			equipBtn.MouseButton1Click:Connect(function()
				if equipped[def.BuildingId] == skinId then
					Net.fireServer(Net.Names.EquipSkin, def.BuildingId, nil)
				else
					Net.fireServer(Net.Names.EquipSkin, def.BuildingId, skinId)
				end
			end)
		end
	end
end

local function rebuildSkins(owned, equipped)
	if not (skinsPage and sectionTemplate) then return end
	owned = type(owned) == "table" and owned or {}
	equipped = type(equipped) == "table" and equipped or {}

	clearSkinClones()

	-- group owned skin ids by building (limited cosmetics into one fixed group)
	local groups = {}
	local order = {}
	local hasAny = false
	for skinId, isOwned in pairs(owned) do
		local def = isOwned and WheelConfig.GetSkinDef(skinId)
		if def then
			hasAny = true
			local key = def.BuildingId or LIMITED_GROUP
			if not groups[key] then
				groups[key] = {}
				order[#order + 1] = key
			end
			table.insert(groups[key], { id = skinId, def = def })
		end
	end

	table.sort(order, function(a, b)
		if a == LIMITED_GROUP then return false end
		if b == LIMITED_GROUP then return true end
		return buildingName(a) < buildingName(b)
	end)

	if emptyLabel then emptyLabel.Visible = not hasAny end

	for index, key in ipairs(order) do
		local section = sectionTemplate:Clone()
		section:SetAttribute("WheelClone", true)
		section.Name = "Section"
		section.LayoutOrder = index
		section.Visible = true

		local title = section:FindFirstChild("BuildingName")
		if title and title:IsA("TextLabel") then
			title.Text = (key == LIMITED_GROUP) and "Limited Cosmetics" or buildingName(key)
		end

		local cards = section:FindFirstChild("Cards") or section
		local cardTemplate = cards:FindFirstChild("SkinCardTemplate")
		if cardTemplate then
			for cardIndex, entry in ipairs(groups[key]) do
				local card = cardTemplate:Clone()
				card.LayoutOrder = cardIndex
				card.Parent = cards
				fillCard(card, entry.id, entry.def, equipped)
			end
		end

		section.Parent = skinsPage
	end
end

Net.on(Net.Names.SkinInventoryChanged, rebuildSkins)

local function rebuildFromAttrs()
	rebuildSkins(decodeAttr(Attrs.OwnedSkinsJson), decodeAttr(Attrs.EquippedSkinsJson))
end

-- ── Daily rewards page (claim-based login streak) ─────────────────────────────────
-- Mirrors DailyRewardService: once-per-UTC-day gate, streak from the LoginStreak/
-- LastLoginDay attributes, rewards from the shared DailyRewardConfig. The Daily UI
-- (DailyPage with a Days holder, a DayCardTemplate, a ClaimButton, a Status + Streak
-- label) is authored in Studio; this only drives it.
local daysHolder = waitChild(dailyPage, "Days")
local dayCardTemplate = waitChild(dailyPage, "DayCardTemplate")
local claimButton = waitChild(dailyPage, "ClaimButton")
local dailyStatus = waitChild(dailyPage, "Status")
local streakLabel = waitChild(dailyPage, "Streak")

local function currentUtcDay()
	return math.floor(os.time() / 86400)
end

local function readDailyInt(attr)
	local v = player:GetAttribute(attr)
	return typeof(v) == "number" and math.floor(v) or 0
end

-- Same gate/streak logic the server uses, so the page previews exactly what a claim grants.
local function dailyState()
	local today = currentUtcDay()
	local lastDay = readDailyInt(Attrs.LastLoginDay)
	local streak = readDailyInt(Attrs.LoginStreak)
	local pendingStreak
	if lastDay == today then
		pendingStreak = math.max(1, streak)
	elseif lastDay == today - 1 then
		pendingStreak = streak + 1
	else
		pendingStreak = 1
	end
	return {
		canClaim = lastDay ~= today,
		streak = streak,
		pendingStreak = pendingStreak,
		dayInCycle = DailyRewardConfig.GetDayInCycle(pendingStreak),
	}
end

local function formatCountdown(seconds)
	seconds = math.max(0, math.floor(seconds))
	local h = math.floor(seconds / 3600)
	local m = math.floor((seconds % 3600) / 60)
	if h > 0 then
		return string.format("%dh %dm", h, m)
	end
	return string.format("%dm", math.max(1, m))
end

local function updateDailyStatus(state)
	if not (dailyStatus and dailyStatus:IsA("TextLabel")) then return end
	if state.canClaim then
		dailyStatus.Text = "Your daily reward is ready!"
	else
		dailyStatus.Text = "Next reward in " .. formatCountdown(86400 - (os.time() % 86400))
	end
end

local dayCards = {}
local function buildDayCards()
	if #dayCards > 0 or not (dayCardTemplate and daysHolder) then return end
	for i = 1, DailyRewardConfig.CycleLength do
		local reward = DailyRewardConfig.Cycle[i]
		local card = dayCardTemplate:Clone()
		card.Name = "DayCard"
		card.LayoutOrder = i
		card.Visible = true

		local dayLabel = card:FindFirstChild("DayLabel")
		if dayLabel and dayLabel:IsA("TextLabel") then
			dayLabel.Text = "Day " .. i
		end

		local rewardLabel = card:FindFirstChild("Reward")
		if rewardLabel and rewardLabel:IsA("TextLabel") then
			local gc = (reward and reward.Gc) or 0
			rewardLabel.Text = "+" .. NumberFormat.abbreviate(gc) .. ((reward and reward.SkinId) and " + Skin" or "")
		end

		-- The mythical day shows the building silhouette; other days hide the preview.
		if reward and reward.SkinId then
			applyPreview(card, WheelConfig.GetSkinDef(reward.SkinId))
		else
			local preview = card:FindFirstChild("Preview")
			if preview and preview:IsA("ImageLabel") then preview.Visible = false end
		end

		card.Parent = daysHolder
		dayCards[i] = card
	end
end

refreshDaily = function()
	buildDayCards()
	local state = dailyState()
	-- Days up to (and including, once claimed today) the current day show as claimed.
	local claimedThrough = state.canClaim and (state.dayInCycle - 1) or state.dayInCycle
	for i, card in ipairs(dayCards) do
		local check = card:FindFirstChild("Check")
		local highlight = card:FindFirstChild("Highlight")
		if check then check.Visible = i <= claimedThrough end
		if highlight then highlight.Visible = (i == state.dayInCycle) and state.canClaim end
	end

	if streakLabel and streakLabel:IsA("TextLabel") then
		streakLabel.Text = ("Day streak: %d"):format(state.streak)
	end

	if claimButton and claimButton:IsA("GuiButton") then
		claimButton.Active = state.canClaim
		claimButton.AutoButtonColor = state.canClaim
		if claimButton:IsA("TextButton") then
			claimButton.Text = state.canClaim and ("Claim Day %d"):format(state.dayInCycle) or "Claimed"
			claimButton.TextTransparency = state.canClaim and 0 or 0.45
		end
	end

	updateDailyStatus(state)
end

local claiming = false
if claimButton and claimButton:IsA("GuiButton") then
	claimButton.MouseButton1Click:Connect(function()
		if claiming or not dailyState().canClaim then return end
		claiming = true
		if claimButton:IsA("TextButton") then claimButton.Text = "Claiming…" end
		-- Net.invoke blocks the calling thread; spawn so the UI stays responsive.
		task.spawn(function()
			local ok, result = pcall(function() return Net.invoke(Net.Names.ClaimDailyReward) end)
			claiming = false
			if dailyStatus and dailyStatus:IsA("TextLabel") then
				if ok and type(result) == "table" and result.Success then
					local msg = "Claimed +" .. NumberFormat.abbreviate(result.RewardGC or 0) .. " GC!"
					if result.SkinId and result.SkinGranted then
						msg = msg .. " Mythical skin unlocked!"
					end
					dailyStatus.Text = msg
				elseif ok and type(result) == "table" and result.Reason == "AlreadyClaimed" then
					dailyStatus.Text = "Already claimed today."
				else
					dailyStatus.Text = "Claim failed — try again."
				end
			end
			refreshDaily()
		end)
	end)
end

-- Live countdown while the Daily tab is open and the reward isn't ready yet.
task.spawn(function()
	while true do
		task.wait(1)
		if dailyPage and dailyPage.Visible then
			local state = dailyState()
			if not state.canClaim then
				updateDailyStatus(state)
			end
		end
	end
end)

-- ── Open / close (+ single-open coordination) ─────────────────────────────────────
-- Reuse the modal's single authored UIScale for responsive layout only; opening and
-- closing never animate it. Fall back to creating one if Studio has none.
local function getResponsiveScale()
	local s = modal:FindFirstChildOfClass("UIScale")
	if not s then
		s = Instance.new("UIScale")
		s.Name = "AnimScale"
		s.Scale = 1
		s.Parent = modal
	end
	return s
end

-- Resting scale of the modal: the shared continuous responsive factor.
-- Captured once before the first resolveModal call (which rewrites modal.Size on mobile).
local designSize = Vector2.new(modal.Size.X.Offset, modal.Size.Y.Offset)
local function restScale()
	-- Match the other main modals on smaller desktop Studio viewports without
	-- changing Wheel's established mobile scale.
	return MobileScale.resolveModal(modal, designSize, { nativeTextDesktop = true })
end

-- The launcher icon's open-state look (gold WheelCookie) is owned entirely by
-- MenuWheelIconController, which renders it from the Wheel container's Active attribute that
-- setVisible writes below. This controller no longer tints the icon itself — a no-op kept so
-- the call sites read clearly.
local function setIconActive(_active) end

local function resolveButton()
	local container = screenGui:FindFirstChild(GuiNames.Wheel, true)
	if not container then return nil, nil end
	local hitbox = container:FindFirstChild("Hitbox")
	if hitbox and hitbox:IsA("GuiButton") then return hitbox, container end
	for _, d in ipairs(container:GetDescendants()) do
		if d:IsA("GuiButton") then return d, container end
	end
	return nil, container
end

local setVisible
local modalSlot = ModalCoordinator.register(MY, function()
	if modal:GetAttribute(Attrs.Open) then
		setVisible(false)
	end
end)

local activeTween
function setVisible(value)
	local previousOwner = ModalCoordinator.current()
	modal:SetAttribute(Attrs.Open, value)
	local _, container = resolveButton()
	if container then container:SetAttribute(Attrs.Active, value) end
	setIconActive(value)

	if value then
		modalSlot.open()
	else
		modalSlot.close()
	end

	if activeTween then activeTween:Cancel(); activeTween = nil end
	local scale = getResponsiveScale()
	local rest = restScale()
	local restPosition = modal.Position
	scale.Scale = rest
	if value then
		setTab("Spin")
		refreshGc()
		rebuildFromAttrs()
		modal.Visible = true
		startIdle()
		local switched
		activeTween, switched = ModalPageTransition.open(screenGui, modal, previousOwner, MY, restPosition)
		if not switched then
			activeTween = ModalPageTransition.openSession(scale, rest)
		end
	else
		stopIdle()
		local function finishClose()
			if not modal:GetAttribute(Attrs.Open) then
				modal.Visible = false
			end
		end
		local switched
		activeTween, switched = ModalPageTransition.close(
			screenGui,
			modal,
			MY,
			ModalCoordinator.current(),
			restPosition,
			finishClose
		)
		if not switched then
			activeTween = ModalPageTransition.closeSession(scale, rest, finishClose)
		end
	end
end

screenGui:GetAttributeChangedSignal(Attrs.ReducedMotionEnabled):Connect(function()
	stopIdle()
	if modal:GetAttribute(Attrs.Open) == true then
		startIdle()
	end
end)

modal.Visible = false
modal:SetAttribute(Attrs.Open, false)
do
	local _, container = resolveButton()
	if container then container:SetAttribute(Attrs.Active, false) end
end

-- Keep responsive layout stable without snapping a page during a swipe.
MobileScale.onViewportChanged(function()
	if activeTween and activeTween.PlaybackState == Enum.PlaybackState.Playing then return end
	getResponsiveScale().Scale = restScale()
end)

-- No in-header close button: the modal dismisses via ModalOutsideClose (clicking inert
-- background), the same shared behaviour as Help/Settings/Profile, or by toggling the
-- launcher icon.

task.defer(function()
	local button = select(1, resolveButton())
	if not button then
		local deadline = tick() + 8
		repeat task.wait(0.1); button = select(1, resolveButton()) until button or tick() > deadline
	end
	if button then
		button.Activated:Connect(function()
			setVisible(not (modal:GetAttribute(Attrs.Open) == true))
		end)
	else
		warn("WheelController: Wheel button not found")
	end
end)

ModalOutsideClose.bind({
	modal = modal,
	isOpen = function()
		return modal:GetAttribute(Attrs.Open) == true
	end,
	close = function()
		setVisible(false)
	end,
	getIgnoreRoots = function()
		local button, container = resolveButton()
		return { button, container }
	end,
})
