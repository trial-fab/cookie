-- Approved player-upgrade icon presentation, captured from live DevTuning on
-- 2026-07-19. Only values that differ from the Studio-authored/default rows live
-- here; Clicking Power, Health, and all autoclick icons need no runtime layout.

return {
	Layouts = {
		["Offline Earnings"] = {
			Position = Vector2.new(0.5, 0.5),
			Anchor = Vector2.new(0.5, 0.5),
			Size = Vector2.new(70, 70),
			Color = Color3.fromRGB(209, 70, 0),
		},
		["Base Expansion"] = {
			Position = Vector2.new(0.5, 0.5),
			Anchor = Vector2.new(0.5, 0.5),
			Size = Vector2.new(60, 60),
			Color = Color3.fromRGB(209, 70, 0),
		},
	},
	MultiPlaceOffOffset = Vector2.new(0, 12),
}
