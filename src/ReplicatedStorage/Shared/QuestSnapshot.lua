-- QuestSnapshot — the one place that answers "which quest is the card showing?".
--
-- The server sends every unlocked quest in authored order, so consumers must not assume
-- the tracked quest is the first entry. The selection is authoritative; the fallbacks
-- only matter for the frame between a quest completing and the next being selected.

local QuestSnapshot = {}

function QuestSnapshot.getTracked(snapshot)
	if type(snapshot) ~= "table" or type(snapshot.Arcs) ~= "table" then
		return nil, nil
	end

	local firstIncompleteArc, firstIncompleteQuest
	local lastArc, lastQuest
	for _, arc in ipairs(snapshot.Arcs) do
		for _, quest in ipairs(arc.Quests or {}) do
			if quest.Selected == true or (snapshot.SelectedQuestId ~= nil and quest.Id == snapshot.SelectedQuestId) then
				return arc, quest
			end
			if quest.Completed ~= true and not firstIncompleteQuest then
				firstIncompleteArc, firstIncompleteQuest = arc, quest
			end
			lastArc, lastQuest = arc, quest
		end
	end

	-- Nothing selected: the first quest still to do, else the last one seen so a fully
	-- completed arc has something coherent to render while its card closes.
	return firstIncompleteArc or lastArc, firstIncompleteQuest or lastQuest
end

return QuestSnapshot
