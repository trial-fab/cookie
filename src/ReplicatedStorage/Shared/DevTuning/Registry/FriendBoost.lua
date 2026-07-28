local Config = require(script.Parent.Parent.Parent:WaitForChild("FriendBoostConfig"))

-- Server scope: only the server computes the multiplier, and it publishes the result on the
-- Player. Clients render the replicated number and never re-derive it from these values.
return {
	feature = "FriendBoost",
	collapsedByDefault = false,
	tunables = {
		{
			key = "PercentPerFriend",
			default = Config.PercentPerFriend,
			kind = "number",
			min = 0,
			max = Config.MaxPercentPerFriend,
			step = 1,
			scope = "server",
			description = "Production and manual-click bonus granted per qualifying friend in the server.",
		},
		{
			key = "MaxFriends",
			default = Config.MaxFriends,
			kind = "number",
			min = 0,
			max = Config.MaxFriendCap,
			step = 1,
			scope = "server",
			description = "Most friends that can be counted at once. Friends past this add nothing.",
		},
	},
}
