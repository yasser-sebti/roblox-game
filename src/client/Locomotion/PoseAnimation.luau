--!strict

local TweenService = game:GetService("TweenService")

export type Pose = { [string]: CFrame }
export type SourceKeyframe = {
	Time: number,
	Values: Pose,
	EasingStyle: string,
	EasingDirection: string,
	Smooth: boolean?,
	GroundLock: boolean?,
}
export type SourceAnimation = {
	Duration: number,
	PlaybackSpeed: number?,
	Loop: boolean?,
	Interpolation: string?,
	Keyframes: { SourceKeyframe },
}
type TrackKey = {
	Time: number,
	Value: CFrame,
	EasingStyle: string,
	EasingDirection: string,
	Smooth: boolean,
}
export type CompiledAnimation = {
	Duration: number,
	PlaybackSpeed: number,
	Loop: boolean,
	Interpolation: string,
	Tracks: { [string]: { TrackKey } },
	GroundTrack: { TrackKey },
}

local PoseAnimation = {}

local STYLE_ENUMS: { [string]: Enum.EasingStyle } = {
	Linear = Enum.EasingStyle.Linear,
	Sine = Enum.EasingStyle.Sine,
	Quad = Enum.EasingStyle.Quad,
	Cubic = Enum.EasingStyle.Cubic,
}
local DIRECTION_ENUMS: { [string]: Enum.EasingDirection } = {
	In = Enum.EasingDirection.In,
	Out = Enum.EasingDirection.Out,
	InOut = Enum.EasingDirection.InOut,
}

local function smoothstep(alpha: number): number
	return alpha * alpha * (3 - 2 * alpha)
end

local function smartEasedAlpha(alpha: number, key: TrackKey, connectedBefore: boolean, connectedAfter: boolean): number
	local raw = math.clamp(alpha, 0, 1)
	local style = STYLE_ENUMS[key.EasingStyle] or Enum.EasingStyle.Linear
	local direction = DIRECTION_ENUMS[key.EasingDirection] or Enum.EasingDirection.InOut
	local eased = TweenService:GetValue(raw, style, direction)
	local influence = if connectedBefore and connectedAfter
		then 4 * raw * (1 - raw)
		elseif connectedBefore
		then smoothstep(raw)
		elseif connectedAfter
		then 1 - smoothstep(raw)
		else 1
	return raw + (eased - raw) * influence
end

local function hermiteVector(
	before: Vector3?, current: Vector3, following: Vector3, after: Vector3?,
	beforeTime: number?, currentTime: number, followingTime: number, afterTime: number?,
	alpha: number, connectedBefore: boolean, connectedAfter: boolean
): Vector3
	local duration = math.max(1e-5, followingTime - currentTime)
	local startTangent = (following - current) / duration
	local endTangent = startTangent
	if connectedBefore and before and beforeTime then
		startTangent = (following - before) / math.max(1e-5, followingTime - beforeTime)
	end
	if connectedAfter and after and afterTime then
		endTangent = (after - current) / math.max(1e-5, afterTime - currentTime)
	end
	local squared, cubed = alpha * alpha, alpha * alpha * alpha
	local h00, h10 = 2 * cubed - 3 * squared + 1, cubed - 2 * squared + alpha
	local h01, h11 = -2 * cubed + 3 * squared, cubed - squared
	return current * h00 + startTangent * (duration * h10) + following * h01 + endTangent * (duration * h11)
end

local function interpolateCFrame(
	before: TrackKey?, current: TrackKey, following: TrackKey, after: TrackKey?, alpha: number
): CFrame
	local connectedBefore = before ~= nil and before.Smooth
	local connectedAfter = after ~= nil and following.Smooth
	local eased = smartEasedAlpha(alpha, current, connectedBefore, connectedAfter)
	local beforeValue, afterValue = if before then before.Value else nil, if after then after.Value else nil
	local beforeTime, afterTime = if before then before.Time else nil, if after then after.Time else nil
	local position = hermiteVector(
		if beforeValue then beforeValue.Position else nil, current.Value.Position, following.Value.Position,
		if afterValue then afterValue.Position else nil, beforeTime, current.Time, following.Time, afterTime,
		eased, connectedBefore, connectedAfter
	)
	local right = hermiteVector(
		if beforeValue then beforeValue.RightVector else nil, current.Value.RightVector, following.Value.RightVector,
		if afterValue then afterValue.RightVector else nil, beforeTime, current.Time, following.Time, afterTime,
		eased, connectedBefore, connectedAfter
	)
	local up = hermiteVector(
		if beforeValue then beforeValue.UpVector else nil, current.Value.UpVector, following.Value.UpVector,
		if afterValue then afterValue.UpVector else nil, beforeTime, current.Time, following.Time, afterTime,
		eased, connectedBefore, connectedAfter
	)
	if right.Magnitude < 1e-5 or up.Magnitude < 1e-5 then return current.Value:Lerp(following.Value, eased) end
	right = right.Unit
	up -= right * up:Dot(right)
	if up.Magnitude < 1e-5 then return current.Value:Lerp(following.Value, eased) end
	up = up.Unit
	return CFrame.fromMatrix(position, right, up, right:Cross(up))
end

function PoseAnimation.compile(source: SourceAnimation): CompiledAnimation
	local tracks: { [string]: { TrackKey } } = {}
	local groundTrack: { TrackKey } = {}
	for _, key in source.Keyframes do
		table.insert(groundTrack, {
			Time = key.Time,
			Value = CFrame.new(0, if key.GroundLock ~= false then 1 else 0, 0),
			EasingStyle = key.EasingStyle,
			EasingDirection = key.EasingDirection,
			Smooth = key.Smooth ~= false,
		})
		for joint, value in key.Values do
			local track = tracks[joint]
			if not track then track = {}; tracks[joint] = track end
			table.insert(track, {
				Time = key.Time,
				Value = value,
				EasingStyle = key.EasingStyle,
				EasingDirection = key.EasingDirection,
				Smooth = key.Smooth ~= false,
			})
		end
	end
	for _, track in tracks do table.sort(track, function(a, b) return a.Time < b.Time end) end
	table.sort(groundTrack, function(a, b) return a.Time < b.Time end)
	return {
		Duration = math.max(0.001, source.Duration),
		PlaybackSpeed = source.PlaybackSpeed or 1,
		Loop = source.Loop ~= false,
		Interpolation = source.Interpolation or "Smooth",
		Tracks = tracks,
		GroundTrack = groundTrack,
	}
end

local function sampleTime(animation: CompiledAnimation, time: number): number
	return if animation.Loop then time % animation.Duration else math.clamp(time, 0, animation.Duration)
end

function PoseAnimation.evaluate(animation: CompiledAnimation, time: number, output: Pose): Pose
	table.clear(output)
	local currentTime = sampleTime(animation, time)
	for joint, track in animation.Tracks do
		local first = track[1]
		if not first then continue end
		if currentTime <= first.Time then output[joint] = first.Value; continue end
		local previous, previousIndex = first, 1
		local following: TrackKey? = nil
		for index = 2, #track do
			local candidate = track[index]
			if candidate.Time <= currentTime then previous, previousIndex = candidate, index else following = candidate; break end
		end
		if animation.Interpolation == "Smooth" and previous.Smooth and following and following.Time > previous.Time then
			output[joint] = interpolateCFrame(
				track[previousIndex - 1], previous, following, track[previousIndex + 2],
				(currentTime - previous.Time) / (following.Time - previous.Time)
			)
		else
			output[joint] = previous.Value
		end
	end
	return output
end

function PoseAnimation.evaluateGroundLock(animation: CompiledAnimation, time: number): number
	local track = animation.GroundTrack
	local first = track[1]
	if not first then return 1 end
	local currentTime = sampleTime(animation, time)
	if currentTime <= first.Time then return first.Value.Position.Y end
	local previous, previousIndex = first, 1
	local following: TrackKey? = nil
	for index = 2, #track do
		local candidate = track[index]
		if candidate.Time <= currentTime then previous, previousIndex = candidate, index else following = candidate; break end
	end
	local from = previous.Value.Position.Y
	if animation.Interpolation ~= "Smooth" or not previous.Smooth or not following or following.Time <= previous.Time then return from end
	local target = following.Value.Position.Y
	if math.abs(target - from) < 1e-6 then return from end
	local alpha = (currentTime - previous.Time) / (following.Time - previous.Time)
	local eased = smartEasedAlpha(alpha, previous, track[previousIndex - 1] ~= nil and track[previousIndex - 1].Smooth, track[previousIndex + 2] ~= nil and following.Smooth)
	return math.clamp(from + (target - from) * eased, 0, 1)
end

return PoseAnimation
