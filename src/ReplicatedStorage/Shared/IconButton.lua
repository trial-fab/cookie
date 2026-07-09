-- Reusable icon-button component (docs/shared-modules-design.md, B2).
--
-- Before this module, three controllers hand-rolled the same icon-button plumbing:
--   * HelpController.createFrameHitbox -- ~100 lines of hover/press/active image-swap
--   * MenuProfileFaceController.createFrameHitbox -- a byte-identical copy (sans the swap)
--   * HelpController.resolveButton / UiStyleController.resolveButton -- identical button finders
--
-- This consolidates the three reusable pieces, behavior-preserving:
--   * IconButton.resolveButton(container, opts) -- find the GuiButton/ImageButton in a frame
--   * IconButton.createHitbox(container, visual) -- padding-aware invisible overlay button
--   * IconButton.new(container, visual, config)  -- hitbox + hover/press/active image states,
--       exposing .set(active) and an assignable .toggled callback (à la example/topbar button)
--
-- It owns LOGIC only -- it never authors layout/visual GuiObjects (project convention). The one
-- instance it creates, the "Hitbox", is a deliberately invisible input proxy, matching what the
-- old inline code already did.

local Attrs = require(script.Parent:WaitForChild("Attrs"))

local IconButton = {}

-- Find the interactive instance inside `container`.
-- opts.className     -- "GuiButton" (default) or "ImageButton"
-- opts.containerFirst -- if true, test the container itself before its descendants
-- Returns (button, owner) where owner is the container that was searched. button is nil if none.
function IconButton.resolveButton(container, opts)
	if not container then
		return nil, nil
	end

	opts = opts or {}
	local className = opts.className or "GuiButton"

	if opts.containerFirst and container:IsA(className) then
		return container, container
	end

	for _, descendant in ipairs(container:GetDescendants()) do
		if descendant:IsA(className) then
			return descendant, container
		end
	end

	if container:IsA(className) then
		return container, container
	end

	return nil, container
end

-- Write the Active attribute onto a button + its container, mirroring the old per-controller
-- setButtonActive: set Active on the container (or button), also on the button when distinct,
-- and -- for a non-IconOnly TextButton -- set its label text. `text` is optional.
function IconButton.setActive(button, container, active, text)
	local target = container or button
	if target then
		target:SetAttribute(Attrs.Active, active)
	end
	if button and button ~= target then
		button:SetAttribute(Attrs.Active, active)
	end

	if button and button:IsA("TextButton") and not button:GetAttribute(Attrs.IconOnly) and text ~= nil then
		button.Text = text
	end
end

-- Create (or reuse) an invisible, padding-aware TextButton sized to fully cover `container`,
-- so a framed icon gets a single reliable click/hover target. Returns the hitbox.
-- If the pairing isn't applicable (no real container frame, or visual isn't an ImageButton),
-- returns `visualButton` unchanged -- exactly like the old inline guards.
function IconButton.createHitbox(container, visualButton)
	if not container or not container:IsA("GuiObject") or container:IsA("GuiButton") then
		return visualButton
	end
	if not visualButton or not visualButton:IsA("ImageButton") then
		return visualButton
	end

	local hitbox = container:FindFirstChild("Hitbox")
	if not hitbox or not hitbox:IsA("TextButton") then
		if hitbox then
			hitbox:Destroy()
		end
		hitbox = Instance.new("TextButton")
		hitbox.Name = "Hitbox"
		hitbox.Parent = container
	end

	hitbox.BackgroundTransparency = 1
	hitbox.BorderSizePixel = 0
	hitbox.Text = ""
	hitbox.TextTransparency = 1
	hitbox.AutoButtonColor = false
	hitbox.Selectable = false
	hitbox:SetAttribute(Attrs.IconOnly, true)
	hitbox.ZIndex = math.max(container.ZIndex, visualButton.ZIndex) + 10

	local padding = container:FindFirstChildWhichIsA("UIPadding")
	if padding then
		hitbox.Position = UDim2.new(-padding.PaddingLeft.Scale, -padding.PaddingLeft.Offset, -padding.PaddingTop.Scale, -padding.PaddingTop.Offset)
		hitbox.Size = UDim2.new(
			1 + padding.PaddingLeft.Scale + padding.PaddingRight.Scale,
			padding.PaddingLeft.Offset + padding.PaddingRight.Offset,
			1 + padding.PaddingTop.Scale + padding.PaddingBottom.Scale,
			padding.PaddingTop.Offset + padding.PaddingBottom.Offset
		)
	else
		hitbox.Position = UDim2.fromScale(0, 0)
		hitbox.Size = UDim2.fromScale(1, 1)
	end

	return hitbox
end

-- Resolve/persist a cosmetic image triple onto the visual button, returning
-- default, hover, pressed. Mirrors HelpController's old derivation:
--   default <- prefix.."DefaultImage" attr, else current .Image
--   hover   <- prefix.."HoverImage"   attr, else .HoverImage (if set) else default
--   pressed <- prefix.."ActiveImage"  attr, else .PressedImage (if set) else hover
-- These per-button attrs stay string literals by design (Attrs.lua keeps cosmetic *Image
-- pairs out of the shared table); `prefix` namespaces them per call site.
local function resolveImageStates(visual, prefix)
	local default = visual:GetAttribute(prefix .. "DefaultImage")
	if typeof(default) ~= "string" or default == "" then
		default = visual.Image
		visual:SetAttribute(prefix .. "DefaultImage", default)
	end

	local hover = visual:GetAttribute(prefix .. "HoverImage")
	if typeof(hover) ~= "string" or hover == "" then
		hover = visual.HoverImage ~= "" and visual.HoverImage or default
		visual:SetAttribute(prefix .. "HoverImage", hover)
	end

	local pressed = visual:GetAttribute(prefix .. "ActiveImage")
	if typeof(pressed) ~= "string" or pressed == "" then
		pressed = visual.PressedImage ~= "" and visual.PressedImage or hover
		visual:SetAttribute(prefix .. "ActiveImage", pressed)
	end

	return default, hover, pressed
end

-- Build a full icon button over `container` + `visualButton`.
--
-- config:
--   imageAttrPrefix -- namespace for the persisted Default/Hover/Active image attrs (default "Icon")
--
-- Returns an object:
--   .container  -- the container that was wired
--   .button     -- the interactive instance (the Hitbox if one was created, else visualButton)
--   .set(active [, text]) -- write the Active attribute (drives the active image) and, for a
--                             non-IconOnly TextButton, optionally its .Text
--   .toggled    -- assignable callback; when set, clicking flips Active and calls it(newActive),
--                  matching example/topbar's `button(...).toggled`. Leave nil to drive .set yourself.
--
-- When no hitbox is applicable (e.g. the container is itself the button), the image-state
-- machine is skipped -- identical to the old code path, which only swapped images for the
-- framed-ImageButton case.
function IconButton.new(container, visualButton, config)
	config = config or {}
	local prefix = config.imageAttrPrefix or "Icon"

	local hitbox = IconButton.createHitbox(container, visualButton)
	local hasHitbox = hitbox ~= visualButton

	local obj = {
		container = container,
		button = hitbox,
		toggled = nil,
	}

	local function isActive()
		return (container and container:GetAttribute(Attrs.Active) == true)
			or (hitbox and hitbox:GetAttribute(Attrs.Active) == true)
	end

	local updateVisual = function() end

	if hasHitbox then
		local defaultImage, hoverImage, pressedImage = resolveImageStates(visualButton, prefix)

		-- The component now owns the visual states; clear the built-in swaps so they can't fight us.
		visualButton.AutoButtonColor = false
		visualButton.HoverImage = ""
		visualButton.PressedImage = ""

		local hovering = false
		local pressing = false

		updateVisual = function()
			if isActive() or pressing then
				visualButton.Image = pressedImage
			elseif hovering then
				visualButton.Image = hoverImage
			else
				visualButton.Image = defaultImage
			end
		end

		hitbox.MouseEnter:Connect(function()
			hovering = true
			updateVisual()
		end)
		hitbox.MouseLeave:Connect(function()
			hovering = false
			updateVisual()
		end)
		hitbox.MouseButton1Down:Connect(function()
			pressing = true
			updateVisual()
		end)
		hitbox.MouseButton1Up:Connect(function()
			pressing = false
			updateVisual()
		end)
		hitbox:GetAttributeChangedSignal(Attrs.Active):Connect(updateVisual)
		container:GetAttributeChangedSignal(Attrs.Active):Connect(updateVisual)
	end

	function obj.set(active, text)
		IconButton.setActive(hitbox, container, active, text)
		updateVisual()
	end

	if hitbox then
		hitbox.MouseButton1Click:Connect(function()
			if obj.toggled then
				local selected = not isActive()
				obj.set(selected)
				obj.toggled(selected)
			end
		end)
	end

	updateVisual()
	return obj
end

return IconButton
