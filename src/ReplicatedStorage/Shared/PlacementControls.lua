-- PlacementControls: the single answer to "does this placement session use the on-screen
-- Cancel / Rotate / Confirm faces, or classic follow-the-mouse-and-click?"
--
-- `PlacementControlsEnabled` is the player's SETTING (device-defaulted, persisted per device). It
-- is not the whole answer, because a gamepad can satisfy neither half of classic mode: there is no
-- cursor for the ghost to follow and no MouseButton1 to commit with. So a gamepad always gets the
-- screen controls, whatever the saved preference says -- the same rule touch already has, arrived
-- at for the same reason.
--
-- Keeping that derivation here (rather than forcing the attribute) leaves the stored preference
-- untouched: a player who plays on both a controller and a mouse keeps their PC choice, and the
-- Settings toggle still reflects what they picked.

local GuiService = game:GetService("GuiService")
local UserInputService = game:GetService("UserInputService")

local Attrs = require(script.Parent.Attrs)

local PlacementControls = {}

function PlacementControls.isGamepad()
	return UserInputService.PreferredInput == Enum.PreferredInput.Gamepad
end

function PlacementControls.screenControlsActive(screenGui)
	return screenGui:GetAttribute(Attrs.PlacementControlsEnabled) == true or PlacementControls.isGamepad()
end

-- Fires `callback` whenever the answer above could have changed -- the setting OR the input device.
-- Returns the connections so a caller that needs to can drop them; most bind for the session.
function PlacementControls.observe(screenGui, callback)
	return {
		screenGui:GetAttributeChangedSignal(Attrs.PlacementControlsEnabled):Connect(callback),
		UserInputService:GetPropertyChangedSignal("PreferredInput"):Connect(callback),
	}
end

-- Gamepad focus. A controller has no pointer, so the placement faces are reachable only as the
-- engine's selected object: ButtonA then fires their ordinary `Activated`, which is exactly the
-- path the touch buttons already use. On any other input device this is a no-op, so callers can
-- call it unconditionally on entry and exit.
function PlacementControls.setGamepadFocus(button)
	if not PlacementControls.isGamepad() then
		return false
	end
	if not (button and button:IsA("GuiButton")) then
		return false
	end
	button.Selectable = true
	GuiService.SelectedObject = button
	return true
end

-- Drops focus if (and only if) it still sits on the placement button we put it on, so a teardown
-- never steals a selection some later UI has already claimed.
function PlacementControls.clearGamepadFocus(button)
	if button and GuiService.SelectedObject == button then
		GuiService.SelectedObject = nil
	end
end

return PlacementControls
