-- Currency reward presentation owner. The historical filename is retained so the existing
-- Rojo-mapped LocalScript remains in place, but it now coordinates Cookies/GC/Gems across the
-- BottomRightHud, StoreBottom strip, and the generic reward-flight overlay.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local shared = ReplicatedStorage:WaitForChild("Shared")
local Attrs = require(shared:WaitForChild("Attrs"))
local CurrencyPill = require(shared:WaitForChild("CurrencyPill"))
local CurrencyRewardFlightConfig = require(shared:WaitForChild("CurrencyRewardFlightConfig"))
local Net = require(shared:WaitForChild("Net"))

local CurrencyRewardAnimator = require(script.Parent:WaitForChild("CurrencyRewardAnimator"))
local StoreCurrencyStrip = require(script.Parent:WaitForChild("StoreCurrencyStrip"))

local GOLDEN = "GoldenCookies"
local GEMS = "Gems"

local function getTuning(key)
	return CurrencyRewardFlightConfig[key]
end

local screenGui = script:FindFirstAncestorOfClass("ScreenGui")
if not screenGui then
	warn("Currency reward controller must be inside a ScreenGui")
	return
end
if screenGui:GetAttribute("CurrencyRewardControllerRunning") then
	return
end
screenGui:SetAttribute("CurrencyRewardControllerRunning", true)

local player = Players.LocalPlayer
local leaderstats = player:WaitForChild("leaderstats")
local cookiesValue = leaderstats:WaitForChild("Cookies")
local hud = screenGui:WaitForChild("BottomRightHud", 10)
local store = screenGui:WaitForChild("StoreBottom", 10)
local overlay = screenGui:WaitForChild("GoldenCookieToast", 10)
if not (hud and store and overlay and hud:IsA("GuiObject") and store:IsA("GuiObject") and overlay:IsA("GuiObject")) then
	warn("Currency reward controller disabled: HUD, StoreBottom, or reward overlay is missing")
	return
end

local template = overlay:FindFirstChild("Template")
local storeCounts = store:FindFirstChild("LiveCounts")
local storeCookie = storeCounts and storeCounts:FindFirstChild("LiveCookieCount")
local storeGolden = storeCounts and storeCounts:FindFirstChild("LiveGCCount")
local storeGems = storeCounts and storeCounts:FindFirstChild("LiveGemsCount")
local hudRight = hud:FindFirstChild("Right", true)
local hudCurrencyRow = hudRight and hudRight:FindFirstChild("cookieCount")
local hudGolden = hudCurrencyRow and hudCurrencyRow:FindFirstChild("goldenCookie")
local hudGems = hudCurrencyRow and hudCurrencyRow:FindFirstChild("gemCookie")
if
	not (
		template
		and template:IsA("GuiObject")
		and storeCounts
		and storeCounts:IsA("GuiObject")
		and storeCookie
		and storeGolden
		and storeGems
		and hudGolden
		and hudGems
	)
then
	warn("Currency reward controller disabled: one or more authored currency slots are missing")
	return
end

local storeScale = store:FindFirstChildOfClass("UIScale")
local hudScale = hud:FindFirstChildOfClass("UIScale")
local function scaleOf(scale)
	return scale and scale.Scale or 1
end

local strip = StoreCurrencyStrip.new({
	player = player,
	screenGui = screenGui,
	store = store,
	root = storeCounts,
	storeScale = storeScale,
	cookie = storeCookie,
	golden = storeGolden,
	gems = storeGems,
})

local bindings = { [GOLDEN] = {}, [GEMS] = {} }
local storeBindings = {}
local function refreshStripWidth(_, immediate)
	strip.refreshWidths(immediate)
end

storeBindings.cookie = CurrencyPill.bind(storeCookie, {
	getRootScale = function()
		return scaleOf(storeScale)
	end,
	onWidthChanged = refreshStripWidth,
})
storeBindings.golden = CurrencyPill.bind(storeGolden, {
	getRootScale = function()
		return scaleOf(storeScale)
	end,
	onWidthChanged = refreshStripWidth,
})
storeBindings.gems = CurrencyPill.bind(storeGems, {
	getRootScale = function()
		return scaleOf(storeScale)
	end,
	onWidthChanged = refreshStripWidth,
})
bindings[GOLDEN].store = storeBindings.golden
bindings[GEMS].store = storeBindings.gems
bindings[GOLDEN].hud = CurrencyPill.bind(hudGolden, {
	getRootScale = function()
		return scaleOf(hudScale)
	end,
})
bindings[GEMS].hud = CurrencyPill.bind(hudGems, {
	getRootScale = function()
		return scaleOf(hudScale)
	end,
})
strip.setBindings(storeBindings)

storeBindings.cookie.setValue(cookiesValue.Value, true)
cookiesValue:GetPropertyChangedSignal("Value"):Connect(function()
	storeBindings.cookie.setValue(cookiesValue.Value)
end)

local currencyState = {
	[GOLDEN] = {
		attribute = Attrs.GoldenCookies,
		authoritative = math.max(0, math.floor(tonumber(player:GetAttribute(Attrs.GoldenCookies)) or 0)),
		displayed = 0,
		overrideRevision = 0,
		positiveToken = 0,
	},
	[GEMS] = {
		attribute = Attrs.Gems,
		authoritative = math.max(0, math.floor(tonumber(player:GetAttribute(Attrs.Gems)) or 0)),
		displayed = 0,
		overrideRevision = 0,
		positiveToken = 0,
	},
}

local function setDisplayed(currency, value, immediate)
	local state = currencyState[currency]
	value = math.max(0, math.floor(tonumber(value) or 0))
	state.displayed = value
	for _, binding in pairs(bindings[currency]) do
		binding.setValue(value, immediate)
	end
end

for currency, state in pairs(currencyState) do
	setDisplayed(currency, state.authoritative, true)
	player:GetAttributeChangedSignal(state.attribute):Connect(function()
		local nextValue = math.max(0, math.floor(tonumber(player:GetAttribute(state.attribute)) or 0))
		local previous = state.authoritative
		state.authoritative = nextValue
		state.positiveToken += 1
		local token = state.positiveToken
		if nextValue <= previous then
			state.overrideRevision += 1
			setDisplayed(currency, nextValue)
			return
		end

		-- A real earn event normally arrives in the same replication turn and cancels this
		-- correlation timer. Direct corrections still reconcile after this bounded grace period.
		task.delay(getTuning("EventMatchSeconds"), function()
			if state.positiveToken ~= token or state.authoritative ~= nextValue then
				return
			end
			state.overrideRevision += 1
			setDisplayed(currency, nextValue)
		end)
	end)
end

local function isVisibleIcon(icon)
	if not (icon and icon:IsA("GuiObject") and icon.Parent and icon.Visible and icon.AbsoluteSize.Magnitude > 0) then
		return false
	end
	local current = icon.Parent
	while current and current ~= screenGui do
		if current:IsA("GuiObject") and not current.Visible then
			return false
		end
		current = current.Parent
	end
	return current == screenGui
end

local function slotIcon(slot)
	if not slot then
		return nil
	end
	for _, child in ipairs(slot:GetChildren()) do
		if child:IsA("ImageLabel") or child:IsA("ImageButton") then
			return child
		end
	end
	return nil
end

local storeIcons = {
	[GOLDEN] = slotIcon(storeGolden),
	[GEMS] = slotIcon(storeGems),
}
local hudIcons = {
	[GOLDEN] = slotIcon(hudGolden),
	[GEMS] = slotIcon(hudGems),
}

local function resolveDestination(currency)
	local storeIcon = storeIcons[currency]
	if strip.isStoreVisible() and isVisibleIcon(storeIcon) then
		return storeIcon
	end
	local hudIcon = hudIcons[currency]
	if isVisibleIcon(hudIcon) and hudIcon.ImageTransparency < 0.99 then
		return hudIcon
	end
	return nil
end

local function prepareDestination(currency)
	if strip.isStoreVisible() then
		strip.setRewardActive(true)
	end
	return resolveDestination(currency)
end

local function resolveUiSource(key)
	local wheel = screenGui:FindFirstChild("WheelModal")
	if key == "DailyClaim" then
		return wheel and wheel:FindFirstChild("ClaimButton", true) or nil
	elseif key == "WheelReward" then
		return wheel and wheel:FindFirstChild("RewardCard", true) or nil
	end
	return nil
end

local function getIconSource(currency)
	return hudIcons[currency] or storeIcons[currency]
end

local queue = {}
local processing = false
local pendingBatch
local batchGeneration = 0

local function sourceKey(anchor)
	if type(anchor) ~= "table" then
		return "ScreenCenter"
	end
	if anchor.Kind == "WorldBounds" and typeof(anchor.CFrame) == "CFrame" then
		local p = anchor.CFrame.Position
		return ("WorldBounds:%d:%d:%d"):format(math.round(p.X), math.round(p.Y), math.round(p.Z))
	end
	if anchor.Kind == "World" and typeof(anchor.Position) == "Vector3" then
		local p = anchor.Position
		return ("World:%d:%d:%d"):format(math.round(p.X), math.round(p.Y), math.round(p.Z))
	end
	return tostring(anchor.Kind) .. ":" .. tostring(anchor.Key or "")
end

local animator

local function countToArrival(item, duration)
	local state = currencyState[item.currency]
	if item.invalidated or item.overrideRevision ~= state.overrideRevision or state.authoritative < item.newTotal then
		return
	end
	local startValue = state.displayed
	local target = item.newTotal
	if target <= startValue then
		return
	end
	local firstValue = math.min(target, startValue + 1)
	setDisplayed(item.currency, firstValue)
	if duration <= 0 or firstValue == target then
		setDisplayed(item.currency, target)
		return
	end
	task.spawn(function()
		local started = os.clock()
		while item.overrideRevision == state.overrideRevision do
			local alpha = math.clamp((os.clock() - started) / duration, 0, 1)
			local value = math.floor(firstValue + (target - firstValue) * alpha + 0.5)
			setDisplayed(item.currency, value)
			if alpha >= 1 then
				break
			end
			RunService.RenderStepped:Wait()
		end
	end)
end

animator = CurrencyRewardAnimator.new({
	screenGui = screenGui,
	overlay = overlay,
	template = template,
	getTuning = getTuning,
	resolveUiSource = resolveUiSource,
	resolveDestination = resolveDestination,
	prepareDestination = prepareDestination,
	getIconSource = getIconSource,
	onArrival = countToArrival,
})

local function processQueue()
	if processing then
		return
	end
	processing = true
	task.spawn(function()
		while #queue > 0 do
			local item = table.remove(queue, 1)
			animator.play(item)
		end
		processing = false
		if not pendingBatch then
			task.wait(getTuning("StorePostLandingHoldSeconds"))
			if #queue == 0 and not pendingBatch then
				strip.setRewardActive(false)
			end
		end
	end)
end

local function flushBatch(generation)
	if generation and generation ~= batchGeneration then
		return
	end
	if not pendingBatch then
		return
	end
	table.insert(queue, pendingBatch)
	pendingBatch = nil
	processQueue()
end

local function enqueueEarn(currency, amount, source, newTotal, sourceAnchor)
	amount = math.max(0, math.floor(tonumber(amount) or 0))
	newTotal = math.max(0, math.floor(tonumber(newTotal) or 0))
	if amount <= 0 then
		return
	end
	local state = currencyState[currency]
	state.positiveToken += 1
	local currentAttribute = math.max(0, math.floor(tonumber(player:GetAttribute(state.attribute)) or 0))
	state.authoritative = currentAttribute
	local key = currency .. ":" .. tostring(source) .. ":" .. sourceKey(sourceAnchor)
	if pendingBatch and pendingBatch.key == key then
		pendingBatch.amount += amount
		pendingBatch.newTotal = newTotal
		pendingBatch.invalidated = currentAttribute < newTotal
	else
		flushBatch()
		pendingBatch = {
			key = key,
			currency = currency,
			amount = amount,
			source = source,
			newTotal = newTotal,
			sourceAnchor = type(sourceAnchor) == "table" and sourceAnchor or { Kind = "ScreenCenter" },
			overrideRevision = state.overrideRevision,
			invalidated = currentAttribute < newTotal,
		}
	end
	batchGeneration += 1
	local generation = batchGeneration
	if source == "spawn" then
		-- Ground cookies are singular, contested pickups and should react on the first server
		-- confirmation frame. They gain nothing from the ordinary rapid-reward batch window.
		flushBatch(generation)
	else
		task.delay(getTuning("BatchWindowSeconds"), function()
			flushBatch(generation)
		end)
	end
end

Net.on(Net.Names.GoldenCookieEarned, function(amount, source, newTotal, sourceAnchor)
	enqueueEarn(GOLDEN, amount, source, newTotal, sourceAnchor)
end)
Net.on(Net.Names.GemEarned, function(amount, source, newTotal, sourceAnchor)
	enqueueEarn(GEMS, amount, source, newTotal, sourceAnchor)
end)
