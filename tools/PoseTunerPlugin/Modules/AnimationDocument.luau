--!strict

local TweenService = game:GetService("TweenService")

export type Pose = { [string]: CFrame }
export type EasingStyle = "Linear" | "Sine" | "Quad" | "Cubic"
export type EasingDirection = "In" | "Out" | "InOut"
export type Keyframe = {
	Id: string,
	Time: number,
	Values: Pose,
	EasingStyle: EasingStyle,
	EasingDirection: EasingDirection,
	GroundLock: boolean,
	Smooth: boolean,
}
export type AnimationDocument = {
	Duration: number,
	PlaybackSpeed: number,
	FPS: number,
	Loop: boolean,
	Interpolation: "Step" | "Smooth",
	AutoKey: boolean,
	Keyframes: { Keyframe },
}

local STYLE_ENUMS: { [string]: Enum.EasingStyle } = {
	Linear = Enum.EasingStyle.Linear, Sine = Enum.EasingStyle.Sine, Quad = Enum.EasingStyle.Quad,
	Cubic = Enum.EasingStyle.Cubic,
}
local DIRECTION_ENUMS: { [string]: Enum.EasingDirection } = {
	In = Enum.EasingDirection.In, Out = Enum.EasingDirection.Out, InOut = Enum.EasingDirection.InOut,
}

local Document = {}
local idCounter = 0

function Document.copyPose(source: Pose): Pose
	local result: Pose = {}
	for name, transform in source do result[name] = transform end
	return result
end

function Document.copyKeyframe(source: Keyframe): Keyframe
	return {
		Id = source.Id, Time = source.Time, Values = Document.copyPose(source.Values),
		EasingStyle = source.EasingStyle, EasingDirection = source.EasingDirection,
		GroundLock = source.GroundLock ~= false, Smooth = source.Smooth ~= false,
	}
end

function Document.copy(source: AnimationDocument): AnimationDocument
	local keys: { Keyframe } = {}
	for _, key in source.Keyframes do table.insert(keys, Document.copyKeyframe(key)) end
	return {
		Duration = source.Duration, PlaybackSpeed = source.PlaybackSpeed, FPS = source.FPS,
		Loop = source.Loop, Interpolation = source.Interpolation, AutoKey = source.AutoKey,
		Keyframes = keys,
	}
end

function Document.new(): AnimationDocument
	return {
		Duration = 2, PlaybackSpeed = 1, FPS = 30, Loop = true,
		Interpolation = "Smooth", AutoKey = true, Keyframes = {},
	}
end

function Document.newId(): string
	idCounter += 1
	return string.format("key_%d_%d", math.floor(os.clock() * 1000), idCounter)
end

function Document.sort(document: AnimationDocument)
	table.sort(document.Keyframes, function(a, b)
		if math.abs(a.Time - b.Time) < 1e-7 then return a.Id < b.Id end
		return a.Time < b.Time
	end)
end

function Document.findById(document: AnimationDocument, id: string): Keyframe?
	for _, key in document.Keyframes do if key.Id == id then return key end end
	return nil
end

function Document.findAtTime(document: AnimationDocument, time: number, tolerance: number?): Keyframe?
	local epsilon = tolerance or 1e-5
	for _, key in document.Keyframes do if math.abs(key.Time - time) <= epsilon then return key end end
	return nil
end

function Document.ensureAtTime(document: AnimationDocument, time: number): Keyframe
	local clamped = math.clamp(time, 0, document.Duration)
	local existing = Document.findAtTime(document, clamped)
	if existing then return existing end
	local key: Keyframe = {
		Id = Document.newId(), Time = clamped, Values = {},
		EasingStyle = "Sine", EasingDirection = "InOut", GroundLock = true, Smooth = true,
	}
	table.insert(document.Keyframes, key)
	Document.sort(document)
	return key
end

function Document.keyPose(document: AnimationDocument, time: number, pose: Pose): Keyframe
	local key = Document.ensureAtTime(document, time)
	key.Values = Document.copyPose(pose)
	return key
end

function Document.keyJoint(document: AnimationDocument, time: number, joint: string, transform: CFrame, groundLock: boolean?, smooth: boolean?): Keyframe
	local existing = Document.findAtTime(document, time)
	local key = Document.ensureAtTime(document, time)
	key.Values[joint] = transform
	if not existing and groundLock ~= nil then key.GroundLock = groundLock end
	if not existing and smooth ~= nil then key.Smooth = smooth end
	return key
end

function Document.earliestTime(document: AnimationDocument): number
	if #document.Keyframes == 0 then return 0 end
	Document.sort(document)
	return document.Keyframes[1].Time
end

function Document.evaluateGroundLock(document: AnimationDocument, time: number, fallback: boolean?): boolean
	if #document.Keyframes == 0 then return fallback ~= false end
	Document.sort(document)
	local clamped = math.clamp(time, 0, document.Duration)
	local active = document.Keyframes[1]
	for _, key in document.Keyframes do
		if key.Time <= clamped + 1e-7 then active = key else break end
	end
	return active.GroundLock ~= false
end

function Document.evaluateSmooth(document: AnimationDocument, time: number, fallback: boolean?): boolean
	if #document.Keyframes == 0 then return fallback ~= false end
	Document.sort(document)
	local clamped = math.clamp(time, 0, document.Duration)
	local active = document.Keyframes[1]
	for _, key in document.Keyframes do
		if key.Time <= clamped + 1e-7 then active = key else break end
	end
	return active.Smooth ~= false
end

local function easedAlpha(alpha: number, key: Keyframe): number
	local style = STYLE_ENUMS[key.EasingStyle] or Enum.EasingStyle.Linear
	local direction = DIRECTION_ENUMS[key.EasingDirection] or Enum.EasingDirection.InOut
	return TweenService:GetValue(math.clamp(alpha, 0, 1), style, direction)
end

local function smoothStep(alpha: number): number return alpha * alpha * (3 - 2 * alpha) end

function Document.smartEasedAlpha(alpha: number, key: Keyframe, connectedBefore: boolean, connectedAfter: boolean): number
	local raw = math.clamp(alpha, 0, 1)
	local eased = easedAlpha(raw, key)
	local influence: number
	if connectedBefore and connectedAfter then
		-- Preserve unit speed at both boundaries while retaining the chosen
		-- easing through the middle of the segment.
		influence = 4 * raw * (1 - raw)
	elseif connectedBefore then
		-- Keep velocity from the incoming segment, ease into the next key.
		influence = smoothStep(raw)
	elseif connectedAfter then
		-- Ease away from this key, preserve velocity into the following segment.
		influence = 1 - smoothStep(raw)
	else
		influence = 1
	end
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
	if connectedBefore and before and beforeTime then startTangent = (following - before) / math.max(1e-5, followingTime - beforeTime) end
	if connectedAfter and after and afterTime then endTangent = (after - current) / math.max(1e-5, afterTime - currentTime) end
	local u2, u3 = alpha * alpha, alpha * alpha * alpha
	local h00 = 2 * u3 - 3 * u2 + 1; local h10 = u3 - 2 * u2 + alpha
	local h01 = -2 * u3 + 3 * u2; local h11 = u3 - u2
	return current * h00 + startTangent * (duration * h10) + following * h01 + endTangent * (duration * h11)
end

local function smartCFrame(
	before: CFrame?, current: CFrame, following: CFrame, after: CFrame?,
	beforeTime: number?, currentTime: number, followingTime: number, afterTime: number?,
	alpha: number, connectedBefore: boolean, connectedAfter: boolean
): CFrame
	local position = hermiteVector(if before then before.Position else nil, current.Position, following.Position, if after then after.Position else nil,
		beforeTime, currentTime, followingTime, afterTime, alpha, connectedBefore, connectedAfter)
	local right = hermiteVector(if before then before.RightVector else nil, current.RightVector, following.RightVector, if after then after.RightVector else nil,
		beforeTime, currentTime, followingTime, afterTime, alpha, connectedBefore, connectedAfter)
	local up = hermiteVector(if before then before.UpVector else nil, current.UpVector, following.UpVector, if after then after.UpVector else nil,
		beforeTime, currentTime, followingTime, afterTime, alpha, connectedBefore, connectedAfter)
	if right.Magnitude < 1e-5 or up.Magnitude < 1e-5 then return current:Lerp(following, alpha) end
	right = right.Unit; up = up - right * up:Dot(right)
	if up.Magnitude < 1e-5 then return current:Lerp(following, alpha) end
	up = up.Unit
	return CFrame.fromMatrix(position, right, up, right:Cross(up))
end

function Document.evaluateGroundLockBlend(document: AnimationDocument, time: number, fallback: boolean?): number
	if #document.Keyframes == 0 then return if fallback ~= false then 1 else 0 end
	Document.sort(document)
	local clamped = math.clamp(time, 0, document.Duration)
	local first = document.Keyframes[1]
	if clamped <= first.Time then return if first.GroundLock ~= false then 1 else 0 end
	local previous = first; local previousIndex = 1; local following: Keyframe? = nil
	for index = 2, #document.Keyframes do
		local candidate = document.Keyframes[index]
		if candidate.Time <= clamped then previous = candidate; previousIndex = index else following = candidate; break end
	end
	local from = if previous.GroundLock ~= false then 1 else 0
	if not following or following.Time <= previous.Time or document.Interpolation ~= "Smooth" or previous.Smooth == false then return from end
	local target = if following.GroundLock ~= false then 1 else 0
	if from == target then return from end
	local alpha = (clamped - previous.Time) / (following.Time - previous.Time)
	local before = document.Keyframes[previousIndex - 1]; local after = document.Keyframes[previousIndex + 2]
	local connectedBefore = before ~= nil and before.Smooth ~= false
	local connectedAfter = after ~= nil and following.Smooth ~= false
	local eased = math.clamp(Document.smartEasedAlpha(alpha, previous, connectedBefore, connectedAfter), 0, 1)
	return from + (target - from) * eased
end

function Document.evaluate(document: AnimationDocument, time: number, neutral: Pose): Pose
	local result = Document.copyPose(neutral)
	local clamped = math.clamp(time, 0, document.Duration)
	local joints: { [string]: boolean } = {}
	for _, key in document.Keyframes do for joint in key.Values do joints[joint] = true end end

	for joint in joints do
		local jointKeys: { Keyframe } = {}
		for _, key in document.Keyframes do
			if key.Values[joint] then table.insert(jointKeys, key) end
		end
		table.sort(jointKeys, function(a, b) return a.Time < b.Time end)
		local first = jointKeys[1]
		if first then
			if clamped <= first.Time then
				result[joint] = first.Values[joint]
			else
				local previous = first; local previousIndex = 1
				local following: Keyframe? = nil
				for index = 2, #jointKeys do
					local candidate = jointKeys[index]
					if candidate.Time <= clamped then previous = candidate; previousIndex = index else following = candidate; break end
				end
				if document.Interpolation == "Smooth" and previous.Smooth ~= false and following and following.Time > previous.Time then
					local before = jointKeys[previousIndex - 1]; local after = jointKeys[previousIndex + 2]
					local connectedBefore = before ~= nil and before.Smooth ~= false
					local connectedAfter = after ~= nil and following.Smooth ~= false
					local alpha = (clamped - previous.Time) / (following.Time - previous.Time)
					local smartAlpha = Document.smartEasedAlpha(alpha, previous, connectedBefore, connectedAfter)
					result[joint] = smartCFrame(
						if before then before.Values[joint] else nil, previous.Values[joint], following.Values[joint], if after then after.Values[joint] else nil,
						if before then before.Time else nil, previous.Time, following.Time, if after then after.Time else nil,
						smartAlpha, connectedBefore, connectedAfter
					)
				else
					result[joint] = previous.Values[joint]
				end
			end
		end
	end
	return result
end

function Document.snapTime(document: AnimationDocument, time: number): number
	local frame = 1 / math.max(1, document.FPS)
	return math.clamp(math.round(time / frame) * frame, 0, document.Duration)
end

function Document.scaleDuration(document: AnimationDocument, duration: number)
	local newDuration = math.clamp(duration, 0.05, 600)
	local factor = if document.Duration > 0 then newDuration / document.Duration else 1
	for _, key in document.Keyframes do key.Time = math.clamp(key.Time * factor, 0, newDuration) end
	document.Duration = newDuration
	Document.sort(document)
end

function Document.removeEmpty(document: AnimationDocument)
	-- Empty master keys are valid timing/grounding markers. Delete them explicitly
	-- from the Master track instead of discarding them after a sparse joint edit.
end

Document.EasingStyles = table.freeze({ "Linear", "Sine", "Quad", "Cubic" })
Document.EasingDirections = table.freeze({ "In", "Out", "InOut" })

return Document
