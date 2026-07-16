-- Policy: pure authorization helper. The authoritative allowlist remains server-owned.

local Policy = {}

function Policy.isAllowedUserId(userId, allowedUserIds)
	return type(userId) == "number"
		and userId == userId
		and type(allowedUserIds) == "table"
		and allowedUserIds[userId] == true
end

return Policy
