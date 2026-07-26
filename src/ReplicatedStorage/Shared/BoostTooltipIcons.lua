-- BoostTooltipIcons: keeps the Power/Speed icons chained just past the building name.
--
-- The name is auto-sized, so "just past it" is a different pixel for every building — 94px for
-- "Bakery", 137px for "Grandma's Kitchen" in a 140px row. A fixed authored X therefore leaves a
-- gap on short names and collides with long ones, which is why this is the one thing about these
-- icons that code owns.
--
-- Only X is driven. Size, Y, artwork and colour stay exactly as authored in Studio, so nudging an
-- icon up or down, or resizing it, is still a Studio edit.
--
-- The icons CHAIN rather than each measuring from the name: both can apply at once (a building
-- inside a Power and a Speed field is the x2.25 case), and two icons measured independently from
-- the same edge would sit on top of each other.

local BoostShopConfig = require(script.Parent:WaitForChild("BoostShopConfig"))

local BoostTooltipIcons = {}

-- The row's own scale factor. AbsoluteSize is post-UIScale (the touch tooltip has one), but the
-- positions we write are in the row's unscaled space, so widths have to come back out of it.
local function rowScale(row)
	local authored = row.Size.X.Offset
	if authored <= 0 or row.AbsoluteSize.X <= 0 then
		return 1
	end
	return row.AbsoluteSize.X / authored
end

-- Binds one tooltip container (the CursorTooltip's BuildingStats frame, or the touch
-- BuildingTooltip root). Safe to call on a container that has no icons.
function BoostTooltipIcons.bind(container)
	if not container then
		return false
	end
	local names = BoostShopConfig.TooltipBoostIcons
	local title = container:FindFirstChild(names.TitleName, true)
	local power = container:FindFirstChild(names.Power, true)
	local speed = container:FindFirstChild(names.Speed, true)
	if not (title and title:IsA("TextLabel") and power and speed) then
		return false
	end

	local row = power.Parent
	local ordered = { power, speed }

	local function layout()
		local authoredWidth = row.Size.X.Offset
		if authoredWidth <= 0 then
			return
		end
		local titleWidth = title.AbsoluteSize.X / rowScale(row)
		-- Derived from the title's own anchor and position rather than assuming it is centred, so
		-- re-anchoring the name in Studio does not silently break the chain.
		local titleLeft = authoredWidth * title.Position.X.Scale
			+ title.Position.X.Offset
			- titleWidth * title.AnchorPoint.X
		local x = titleLeft + titleWidth + names.TitleGap

		for _, icon in ipairs(ordered) do
			if icon.Visible then
				-- Left-anchored so the computed X is the icon's leading edge; Y is untouched.
				icon.AnchorPoint = Vector2.new(0, icon.AnchorPoint.Y)
				icon.Position = UDim2.new(0, math.round(x), icon.Position.Y.Scale, icon.Position.Y.Offset)
				x += icon.Size.X.Offset + names.IconGap
			end
		end
	end

	layout()
	-- The name's width changes when the text does, and the row's when the device scale does. A
	-- hidden icon has to reflow the ones after it, so visibility counts too.
	title:GetPropertyChangedSignal("AbsoluteSize"):Connect(layout)
	row:GetPropertyChangedSignal("AbsoluteSize"):Connect(layout)
	for _, icon in ipairs(ordered) do
		icon:GetPropertyChangedSignal("Visible"):Connect(layout)
	end
	return true
end

return BoostTooltipIcons
