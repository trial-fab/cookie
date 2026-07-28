-- Preview-only editor commands for the Ancient Core's concentric visual layers.
-- These values are neutral tool inputs, not baked presentation defaults. Nothing happens
-- until EditorEnabled and an explicit Trigger* control are applied.

local MATERIAL_OPTIONS = {
	Enum.Material.Glass,
	Enum.Material.ForceField,
	Enum.Material.Neon,
	Enum.Material.SmoothPlastic,
	Enum.Material.Plastic,
	Enum.Material.Ice,
}

return {
	feature = "OrbLayers",
	collapsedByDefault = false,
	tunables = {
		{
			key = "EditorEnabled",
			default = false,
			kind = "boolean",
			scope = "client",
			description = "Preview only: snapshot this session's orb layers. OFF restores that snapshot and removes preview-added layers.",
		},
		{
			key = "LayerColor",
			default = Color3.new(0, 0, 0),
			kind = "Color3",
			scope = "client",
			description = "Color applied by TriggerApply or assigned to the new layer made by TriggerAdd.",
		},
		{
			key = "LayerDiameter",
			default = 3.2,
			kind = "number",
			min = 0.25,
			max = 20,
			step = 0.05,
			scope = "client",
			description = "Uniform diameter applied by TriggerApply or TriggerAdd; this does not change Studio defaults.",
		},
		{
			key = "LayerIndex",
			default = 1,
			kind = "number",
			min = 1,
			max = 16,
			step = 1,
			scope = "client",
			description = "Target layer, sorted smallest diameter to largest. The core is normally layer 1.",
		},
		{
			key = "LayerMaterial",
			default = Enum.Material.Glass,
			kind = "enum",
			options = MATERIAL_OPTIONS,
			scope = "client",
			description = "Material applied by TriggerApply or assigned to the layer made by TriggerAdd.",
		},
		{
			key = "LayerTransparency",
			default = 0.5,
			kind = "number",
			min = 0,
			max = 1,
			step = 0.05,
			scope = "client",
			description = "Transparency applied by TriggerApply or TriggerAdd.",
		},
		{
			key = "TriggerAdd",
			default = false,
			kind = "boolean",
			scope = "client",
			description = "Toggle to clone the selected layer locally and apply the current material, color, diameter, and transparency.",
		},
		{
			key = "TriggerApply",
			default = false,
			kind = "boolean",
			scope = "client",
			description = "Toggle to apply the current controls to LayerIndex. A previously removed layer becomes visible again.",
		},
		{
			key = "TriggerRemove",
			default = false,
			kind = "boolean",
			scope = "client",
			description = "Toggle to remove LayerIndex from this preview. The required OrbCore cannot be removed.",
		},
		{
			key = "TriggerReset",
			default = false,
			kind = "boolean",
			scope = "client",
			description = "Toggle to restore the session snapshot and discard all preview-added layers without saving anything.",
		},
	},
}
