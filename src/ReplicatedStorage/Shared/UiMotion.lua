-- UiMotion -- shared gateway for ordinary UI tweens.
--
-- Use UiMotion.create(guiInstance, tweenInfo, goals) for every UI tween. It has
-- the same return shape as TweenService:Create, so callers may Play, Cancel, and
-- listen to Completed normally. Reduced Motion intentionally does NOT suppress
-- these inexpensive, short-lived transitions. Continuous/decorative animation
-- controllers use UiMotion.isReduced(instance) to pause themselves explicitly.
--
-- Do not use this for camera, character, tool, or world-object motion.

local Players = game:GetService("Players")
local TweenService = game:GetService("TweenService")

local Attrs = require(script.Parent:WaitForChild("Attrs"))

local UiMotion = {}

local function findScreenGui(instance)
	local current = instance
	local nearestScreenGui = nil
	while current do
		if current:IsA("ScreenGui") then
			nearestScreenGui = nearestScreenGui or current
			if current:GetAttribute(Attrs.ReducedMotionEnabled) ~= nil then
				return current
			end
		end
		current = current.Parent
	end

	local player = Players.LocalPlayer
	local playerGui = player and player:FindFirstChildOfClass("PlayerGui")
	if not playerGui then
		return nil
	end

	for _, child in ipairs(playerGui:GetChildren()) do
		if child:IsA("ScreenGui") and child:GetAttribute(Attrs.ReducedMotionEnabled) ~= nil then
			return child
		end
	end
	return playerGui:FindFirstChild("ScreenGui") or nearestScreenGui
end

function UiMotion.isReduced(instance)
	local screenGui = findScreenGui(instance)
	return screenGui ~= nil and screenGui:GetAttribute(Attrs.ReducedMotionEnabled) == true
end

function UiMotion.create(instance, tweenInfo, goals)
	return TweenService:Create(instance, tweenInfo, goals)
end

return UiMotion
