-- OfflineEarningsController — the "While you were away…" claim popup (spec §9).
-- Logic only: the popup is authored in Studio (StarterGui.ScreenGui → OfflineEarnings
-- with children Card[.Amount/.Detail/.Collect]). The cookies are already granted
-- server-side (OfflineEarningsService); this just fills the text, shows the card and
-- dismisses it.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local shared = ReplicatedStorage:WaitForChild("Shared")
local NumberFormat = require(shared:WaitForChild("NumberFormat"))
local Net = require(shared:WaitForChild("Net"))

local screenGui = script:FindFirstAncestorOfClass("ScreenGui")
if not screenGui then
	warn("OfflineEarningsController must be inside a ScreenGui")
	return
end
if screenGui:GetAttribute("OfflineEarningsControllerRunning") then
	return
end
screenGui:SetAttribute("OfflineEarningsControllerRunning", true)

local overlay = screenGui:WaitForChild("OfflineEarnings", 10)
if not overlay then
	warn("OfflineEarningsController disabled: ScreenGui.OfflineEarnings was not found")
	return
end

local card = overlay:FindFirstChild("Card", true)
local amountLabel = overlay:FindFirstChild("Amount", true)
local detail = overlay:FindFirstChild("Detail", true)
local collect = overlay:FindFirstChild("Collect", true)
if not (card and amountLabel and detail and collect) then
	warn("OfflineEarningsController disabled: OfflineEarnings is missing Card/Amount/Detail/Collect")
	return
end

local TWEEN_INFO = TweenInfo.new(0.22, Enum.EasingStyle.Quart, Enum.EasingDirection.Out)
local cardOpenPosition = card.Position

local function formatAway(seconds)
	seconds = math.max(0, math.floor(seconds))
	local hours = math.floor(seconds / 3600)
	local minutes = math.floor((seconds % 3600) / 60)
	if hours > 0 then
		return string.format("%dh %dm", hours, minutes)
	end
	if minutes > 0 then
		return string.format("%dm", minutes)
	end
	return string.format("%ds", seconds % 60)
end

local function hide()
	overlay.Visible = false
end

collect.MouseButton1Click:Connect(hide)

local function show(payload)
	if type(payload) ~= "table" then
		return
	end

	local amount = tonumber(payload.Amount) or 0
	if amount <= 0 then
		return
	end

	amountLabel.Text = "+" .. NumberFormat.abbreviate(amount) .. " cookies"

	local detailText = "Your bases baked at 50% for " .. formatAway(payload.AwaySeconds or 0) .. " away."
	if payload.Capped then
		detailText = detailText .. " (capped at " .. tostring(math.floor((payload.CapHours or 8) + 0.5)) .. "h)"
	end
	detail.Text = detailText

	overlay.Visible = true
	card.Position = cardOpenPosition + UDim2.fromScale(0, 0.04)
	TweenService:Create(card, TWEEN_INFO, { Position = cardOpenPosition }):Play()
end

Net.on(Net.Names.OfflineEarningsClaim, show)
