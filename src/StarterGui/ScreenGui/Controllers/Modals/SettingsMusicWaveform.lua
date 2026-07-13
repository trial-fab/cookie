local RunService = game:GetService("RunService")
local UiMotion = require(game:GetService("ReplicatedStorage"):WaitForChild("Shared"):WaitForChild("UiMotion"))

local SettingsMusicWaveform = {}

local UPDATE_INTERVAL = 1 / 30
local ATTACK_DURATION = 0.18
local REST_HEIGHT = 2
local MAX_HEIGHTS = { 10, 16, 22, 26, 22, 16, 10 }
local SETTLE_TWEEN_INFO = TweenInfo.new(0.14, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)

local function withHeight(bar, height)
	return UDim2.new(bar.Size.X.Scale, bar.Size.X.Offset, 0, height)
end

function SettingsMusicWaveform.new(body)
	local row = body:FindFirstChild("Music", true)
	local glyph = row and row:FindFirstChild("Glyph", true)
	local bars = {}
	if glyph then
		for index = 1, #MAX_HEIGHTS do
			local bar = glyph:FindFirstChild("Bar" .. index)
			if bar and bar:IsA("GuiObject") then
				table.insert(bars, bar)
			end
		end
	end
	if #bars ~= #MAX_HEIGHTS then
		return {
			setState = function() end,
		}
	end

	for _, bar in ipairs(bars) do
		bar.Size = withHeight(bar, REST_HEIGHT)
	end

	local mode = "off"
	local connection = nil
	local settleTweens = {}
	local random = Random.new()

	local function cancelSettleTweens()
		for _, tween in ipairs(settleTweens) do
			tween:Cancel()
		end
		table.clear(settleTweens)
	end

	local function stop()
		if connection then
			connection:Disconnect()
			connection = nil
		end
		cancelSettleTweens()
		for _, bar in ipairs(bars) do
			local tween = UiMotion.create(bar, SETTLE_TWEEN_INFO, {
				Size = withHeight(bar, REST_HEIGHT),
			})
			table.insert(settleTweens, tween)
			tween:Play()
		end
	end

	local function start()
		cancelSettleTweens()
		local elapsed = 0
		local accumulator = 0
		connection = RunService.Heartbeat:Connect(function(deltaTime)
			elapsed += deltaTime
			accumulator += deltaTime
			if accumulator < UPDATE_INTERVAL then
				return
			end
			accumulator %= UPDATE_INTERVAL

			local attack = math.clamp(elapsed / ATTACK_DURATION, 0, 1)
			for index, bar in ipairs(bars) do
				local phase = (index - 1) * 0.82
				local wave = 0.5 + 0.3 * math.sin(elapsed * 7 + phase) + 0.2 * math.sin(elapsed * 11 - phase * 1.7)
				local amount = math.clamp(wave, 0, 1) * attack
				local height = REST_HEIGHT + (MAX_HEIGHTS[index] - REST_HEIGHT) * amount
				bar.Size = withHeight(bar, height)
			end
		end)
	end

	local function showStaticWaveform()
		if connection then
			connection:Disconnect()
			connection = nil
		end
		cancelSettleTweens()
		for index, bar in ipairs(bars) do
			local amount = random:NextNumber(0.35, 1)
			local height = REST_HEIGHT + (MAX_HEIGHTS[index] - REST_HEIGHT) * amount
			bar.Size = withHeight(bar, height)
		end
	end

	local function setState(enabled, animate)
		local nextMode = if enabled ~= true then "off" elseif animate == true then "animated" else "static"
		if mode == nextMode then
			return
		end
		mode = nextMode
		if mode == "animated" then
			start()
		elseif mode == "static" then
			showStaticWaveform()
		else
			stop()
		end
	end

	return {
		setState = setState,
	}
end

return SettingsMusicWaveform
