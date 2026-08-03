local GooSkin = { Kind = "GooSkin" }

function GooSkin.Validate(params)
	if type(params) ~= "table" then return false, "GooSkin parameters must be a table" end
	for key in pairs(params) do
		if key ~= "SkinId" and key ~= "DisplayName" and key ~= "MysteryDisplayName" and key ~= "Resolved" then
			return false, "unknown GooSkin parameter"
		end
	end
	return type(params.SkinId) == "string" and #params.SkinId > 0 and #params.SkinId <= 96
		and type(params.DisplayName) == "string" and #params.DisplayName > 0 and #params.DisplayName <= 96
		and type(params.MysteryDisplayName) == "string" and #params.MysteryDisplayName > 0 and #params.MysteryDisplayName <= 96
		and type(params.Resolved) == "boolean",
		"GooSkin needs bounded public names and boolean Resolved"
end

function GooSkin.Execute(adapter, player, params, effect)
	return adapter.GrantGooSkin(player, params.SkinId, effect)
end

function GooSkin.Project(params)
	return {
		SkinId = params.SkinId,
		DisplayName = params.DisplayName,
		MysteryDisplayName = params.MysteryDisplayName,
		Resolved = params.Resolved,
	}
end

return table.freeze(GooSkin)
