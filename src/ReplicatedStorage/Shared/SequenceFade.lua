-- SequenceFade — fades an authored NumberSequence toward fully transparent.
--
-- Beam.Transparency and Trail.Transparency are NumberSequences, so fading one means rebuilding the
-- whole curve: there is no scalar alpha to write. Callers keep the authored keypoints as the shape
-- of the fade and supply an alpha for its depth, which is what lets a Studio-authored template own
-- the look while runtime code owns only visibility -- the same split the arrow trail already uses
-- for its per-part transparency.
--
-- Writes are quantised because each rebuild allocates a sequence. Without that, an effect that is
-- visibly holding still would still churn one allocation per instance per frame.

local SequenceFade = {}

local STEPS = 64

-- Applies `alpha` to `instance[property]`, skipping the write when it would not change the result.
-- Returns the quantised alpha to hand back as `lastQuantised` next time; 0 means fully clear, so
-- callers can drive an Enabled flag from it without tracking alpha separately.
function SequenceFade.apply(instance, property, authored, alpha, lastQuantised)
	local quantised = math.floor(math.clamp(alpha, 0, 1) * STEPS + 0.5)
	if quantised == lastQuantised then return quantised end

	local scale = quantised / STEPS
	local points = table.create(#authored)
	for index, keypoint in ipairs(authored) do
		points[index] = NumberSequenceKeypoint.new(keypoint.Time, 1 - scale * (1 - keypoint.Value), keypoint.Envelope)
	end
	instance[property] = NumberSequence.new(points)
	return quantised
end

return SequenceFade
