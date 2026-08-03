-- Animates the Studio-authored quest-description completion strokes.
-- Each rendered text line owns a thin Frame that grows from left to right, so wrapped
-- lines begin crossing out together without depending on RichText strike rendering.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TextService = game:GetService("TextService")

local UiMotion = require(ReplicatedStorage.Shared.UiMotion)

local QuestProgressCompletionStrike = {}
local STRIKE_TWEEN_INFO = TweenInfo.new(0.36, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local MAX_LINES = 2
local STRIKE_HEIGHT = 1
local STRIKE_Y_RATIO = 0.56

local function measureWidth(description, text): number
	local ok, bounds = pcall(
		TextService.GetTextSize,
		TextService,
		tostring(text or ""),
		description.TextSize,
		description.Font,
		Vector2.new(10000, 10000)
	)
	return if ok then tonumber(bounds.X) or 0 else tonumber(description.AbsoluteSize.X) or 0
end

local function wrappedLineWidths(description, text, maxWidth: number)
	local widths = {}
	local currentLine = ""

	for word in tostring(text or ""):gmatch("%S+") do
		local candidate = if currentLine == "" then word else currentLine .. " " .. word
		if currentLine == "" or measureWidth(description, candidate) <= maxWidth then
			currentLine = candidate
		elseif #widths >= MAX_LINES - 1 then
			table.insert(widths, maxWidth)
			return widths
		else
			table.insert(widths, math.min(maxWidth, math.ceil(measureWidth(description, currentLine))))
			currentLine = word
		end
	end

	if currentLine ~= "" and #widths < MAX_LINES then
		table.insert(widths, math.min(maxWidth, math.ceil(measureWidth(description, currentLine))))
	end
	if #widths == 0 then
		table.insert(widths, 0)
	end
	return widths
end

function QuestProgressCompletionStrike.bind(description)
	local reveal = description and description:FindFirstChild("QuestDescriptionStrikeReveal")
	local lines = {
		reveal and reveal:FindFirstChild("StrikeLine01"),
		reveal and reveal:FindFirstChild("StrikeLine02"),
	}
	if
		not (
			description
			and description:IsA("TextLabel")
			and reveal
			and reveal:IsA("Frame")
			and lines[1]
			and lines[1]:IsA("Frame")
			and lines[2]
			and lines[2]:IsA("Frame")
		)
	then
		warn("Quest completion strike disabled: the Studio-authored line overlay is missing")
		return nil
	end

	local currentText
	local completed = false
	local generation = 0
	local tweens = {}
	local safeCompletion

	local function cancelAnimation()
		if safeCompletion then
			local finish = safeCompletion
			safeCompletion = nil
			finish("cancelled")
		end
		generation += 1
		for _, tween in ipairs(tweens) do
			tween:Cancel()
		end
		table.clear(tweens)
		reveal.Visible = false
		reveal.Size = UDim2.fromOffset(0, 0)
		for _, line in ipairs(lines) do
			line.Visible = false
			line.Size = UDim2.fromOffset(0, STRIKE_HEIGHT)
		end
	end

	local function prepareLines(text, useFullWidths)
		local width = math.max(0, description.AbsoluteSize.X)
		local height = math.max(0, description.AbsoluteSize.Y)
		local lineWidths = wrappedLineWidths(description, text, width)
		local renderedLineCount = math.clamp(#lineWidths, 1, MAX_LINES)
		local rowHeight = if renderedLineCount > 0 then height / renderedLineCount else height

		reveal.Position = UDim2.fromOffset(0, 0)
		reveal.Size = UDim2.fromOffset(width, height)
		reveal.Visible = true
		for index, line in ipairs(lines) do
			local lineWidth = lineWidths[index] or 0
			line.BackgroundColor3 = description.TextColor3
			line.BackgroundTransparency = description.TextTransparency
			line.Position =
				UDim2.fromOffset(0, math.floor((index - 1) * rowHeight + description.TextSize * STRIKE_Y_RATIO))
			line.Size = UDim2.fromOffset(useFullWidths and lineWidth or 0, STRIKE_HEIGHT)
			line.Visible = lineWidth > 0
		end
		return lineWidths, width, height
	end

	local function showNormal(text)
		cancelAnimation()
		currentText = text
		completed = false
		description.RichText = false
		description.Text = text
	end

	local function showCompleted(text)
		cancelAnimation()
		currentText = text
		completed = true
		description.RichText = false
		description.Text = text
		local showGeneration = generation
		task.defer(function()
			if showGeneration == generation and description.Parent then
				prepareLines(text, true)
			end
		end)
	end

	local function play(text, onCompleted)
		cancelAnimation()
		currentText = text
		completed = true
		description.RichText = false
		description.Text = text
		local playGeneration = generation

		task.defer(function()
			if playGeneration ~= generation or not description.Parent then
				return
			end
			local lineWidths, width, height = prepareLines(text, false)
			-- The label is measured from AbsoluteSize, which is a frame behind whenever this
			-- text change also re-flowed the label. Measuring zero used to fall straight
			-- through to the snap below, which draws the finished strike in one go and reads
			-- as "it didn't animate". Give the layout a frame before giving up on the tween.
			if width <= 0 or height <= 0 then
				task.wait()
				if playGeneration ~= generation or not description.Parent then
					return
				end
				lineWidths, width, height = prepareLines(text, false)
			end
			if UiMotion.isReduced(description) or width <= 0 or height <= 0 then
				if not UiMotion.isReduced(description) then
					-- Reduced Motion snapping is intended; an unmeasurable label is not, and it
					-- is indistinguishable on screen from the animation silently not running.
					warn("Quest completion strike snapped: the description could not be measured")
				end
				for index, line in ipairs(lines) do
					line.Size = UDim2.fromOffset(lineWidths[index] or 0, STRIKE_HEIGHT)
				end
				if onCompleted then
					onCompleted()
				end
				return
			end

			local remainingTweens = 0
			for index, line in ipairs(lines) do
				local lineWidth = lineWidths[index] or 0
				if lineWidth > 0 then
					local tween = UiMotion.create(line, STRIKE_TWEEN_INFO, {
						Size = UDim2.fromOffset(lineWidth, STRIKE_HEIGHT),
					})
					table.insert(tweens, tween)
					remainingTweens += 1
					tween.Completed:Connect(function(playbackState)
						if playbackState == Enum.PlaybackState.Completed and playGeneration == generation then
							remainingTweens -= 1
							if remainingTweens == 0 and onCompleted then
								onCompleted()
							end
						end
					end)
				end
			end
			if remainingTweens == 0 and onCompleted then
				onCompleted()
			end
			for _, tween in ipairs(tweens) do
				tween:Play()
			end
		end)
	end

	return {
		clear = function(text)
			showNormal(tostring(text or description.Text or ""))
		end,
		render = function(text, isCompleted, animate, onCompleted)
			text = tostring(text or "")
			if isCompleted then
				if animate then
					play(text, onCompleted)
				elseif not completed or currentText ~= text then
					showCompleted(text)
				end
			elseif completed or currentText ~= text then
				showNormal(text)
			end
		end,
		-- Protocol-v2 adapter boundary. Unlike the legacy render callback, this
		-- completion is guaranteed on cancellation/destroy as well as success.
		playWithCompletion = function(text, onCompleted)
			local active = true
			local function finish(outcome)
				if not active then
					return
				end
				active = false
				if safeCompletion == finish then
					safeCompletion = nil
				end
				if onCompleted then
					onCompleted(outcome or "completed")
				end
			end
			play(tostring(text or ""), function()
				finish("completed")
			end)
			safeCompletion = finish
			return function(reason)
				if active then
					cancelAnimation()
					finish(reason or "cancelled")
				end
			end
		end,
		destroy = function()
			cancelAnimation()
		end,
	}
end

return QuestProgressCompletionStrike
