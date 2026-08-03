--!strict

local Document = require(script.Parent.AnimationDocument)
local PoseMath = require(script.Parent.PoseMath)

export type Pose = { [string]: CFrame }
export type AnimationDocument = Document.AnimationDocument

local Codec = {}

Codec.JointNames = table.freeze({
	"Root", "Waist", "Neck",
	"LeftShoulder", "LeftElbow", "LeftWrist",
	"RightShoulder", "RightElbow", "RightWrist",
	"LeftHip", "LeftKnee", "LeftAnkle",
	"RightHip", "RightKnee", "RightAnkle",
})

function Codec.neutralPose(): Pose
	return PoseMath.neutralPose(Codec.JointNames)
end

function Codec.copyPose(pose: Pose): Pose return Document.copyPose(pose) end

local function appendTransform(lines: { string }, indent: string, name: string, transform: CFrame)
	local values = { transform:GetComponents() }
	table.insert(lines, string.format(
		"%s[%q] = CFrame.new(%.17g, %.17g, %.17g, %.17g, %.17g, %.17g, %.17g, %.17g, %.17g, %.17g, %.17g, %.17g),",
		indent, name, table.unpack(values)
	))
end

function Codec.buildV3(document: AnimationDocument, includeGuide: boolean?): string
	local lines = { "-- R15_POSE_ANIMATION_V3" }
	if includeGuide ~= false then
		table.insert(lines, "-- Integration guide: C:\\MyRobloxGame\\docs\\POSE_ANIMATION_INTEGRATION.md")
		table.insert(lines, "-- Evaluate sparse keys, per-key Smooth, and GroundLock over time; Smooth uses the outgoing key's easing without changing stored poses.")
	end
	table.insert(lines, "-- Exact 12-component Motor6D.Transform keyframes. Easing is applied to the outgoing segment.")
	for _, line in {
		"return {", "\tRigType = \"R15\",", "\tVersion = 3,",
		string.format("\tDuration = %.17g,", document.Duration),
		string.format("\tPlaybackSpeed = %.17g,", document.PlaybackSpeed),
		string.format("\tFPS = %d,", document.FPS),
		string.format("\tLoop = %s,", tostring(document.Loop)),
		string.format("\tInterpolation = %q,", document.Interpolation),
		string.format("\tAutoKey = %s,", tostring(document.AutoKey)),
		"\tKeyframes = {",
	} do table.insert(lines, line) end
	local sortedKeys = table.clone(document.Keyframes)
	table.sort(sortedKeys, function(a, b)
		if math.abs(a.Time - b.Time) < 1e-12 then return a.Id < b.Id end
		return a.Time < b.Time
	end)
	for _, key in sortedKeys do
		table.insert(lines, string.format(
			"\t\t{ Id = %q, Time = %.17g, EasingStyle = %q, EasingDirection = %q, Values = {",
			key.Id, key.Time, key.EasingStyle, key.EasingDirection
		))
		for _, name in Codec.JointNames do
			local value = key.Values[name]
			if value then appendTransform(lines, "\t\t\t", name, value) end
		end
		table.insert(lines, string.format("\t\t}, GroundLock = %s, Smooth = %s },", tostring(key.GroundLock ~= false), tostring(key.Smooth ~= false)))
	end
	table.insert(lines, "\t},")
	table.insert(lines, "}")
	return table.concat(lines, "\n")
end

function Codec.buildSelected(pose: Pose): string
	local document = Document.new()
	document.Duration = 0.15
	document.Loop = false
	document.Keyframes = {{
		Id = "selected_pose", Time = 0, Values = Codec.copyPose(pose),
		EasingStyle = "Linear", EasingDirection = "InOut", GroundLock = true, Smooth = true,
	}}
	return Codec.buildV3(document, false)
end

local function parseHeader(text: string): AnimationDocument
	local document = Document.new()
	document.Duration = math.clamp(tonumber(string.match(text, "Duration%s*=%s*([%+%-%d%.eE]+)")) or 2, 0.05, 600)
	document.PlaybackSpeed = math.clamp(tonumber(string.match(text, "PlaybackSpeed%s*=%s*([%+%-%d%.eE]+)")) or 1, 0.05, 8)
	document.FPS = math.clamp(math.round(tonumber(string.match(text, "FPS%s*=%s*(%d+)")) or 30), 1, 240)
	document.Loop = string.match(text, "Loop%s*=%s*(%a+)") ~= "false"
	document.Interpolation = if string.match(text, 'Interpolation%s*=%s*"([^"]+)"') == "Smooth" then "Smooth" else "Step"
	document.AutoKey = string.match(text, "AutoKey%s*=%s*(%a+)") ~= "false"
	return document
end

local FULL_CFRAME_PATTERN = '%["([^"]+)"%]%s*=%s*CFrame%.new%s*%(([%+%-%d%.eE]+),%s*([%+%-%d%.eE]+),%s*([%+%-%d%.eE]+),%s*([%+%-%d%.eE]+),%s*([%+%-%d%.eE]+),%s*([%+%-%d%.eE]+),%s*([%+%-%d%.eE]+),%s*([%+%-%d%.eE]+),%s*([%+%-%d%.eE]+),%s*([%+%-%d%.eE]+),%s*([%+%-%d%.eE]+),%s*([%+%-%d%.eE]+)%)'
local EULER_PATTERN = '%["([^"]+)"%]%s*=%s*CFrame%.new%s*%(([%+%-%d%.eE]+),%s*([%+%-%d%.eE]+),%s*([%+%-%d%.eE]+)%)%s*%*%s*CFrame%.Angles%s*%(math%.rad%s*%(([%+%-%d%.eE]+)%),%s*math%.rad%s*%(([%+%-%d%.eE]+)%),%s*math%.rad%s*%(([%+%-%d%.eE]+)%)%)'

local function isJoint(name: string): boolean return table.find(Codec.JointNames, name) ~= nil end

local function parsePose(block: string, exact: boolean, fallback: Pose?): (Pose, number)
	local pose = if fallback then Codec.copyPose(fallback) else {} :: Pose
	local count = 0
	if exact then
		for name, x, y, z, r00, r01, r02, r10, r11, r12, r20, r21, r22 in string.gmatch(block, FULL_CFRAME_PATTERN) do
			if isJoint(name) then
				pose[name] = CFrame.new(
					tonumber(x) or 0, tonumber(y) or 0, tonumber(z) or 0,
					tonumber(r00) or 1, tonumber(r01) or 0, tonumber(r02) or 0,
					tonumber(r10) or 0, tonumber(r11) or 1, tonumber(r12) or 0,
					tonumber(r20) or 0, tonumber(r21) or 0, tonumber(r22) or 1
				)
				count += 1
			end
		end
	else
		for name, x, y, z, rx, ry, rz in string.gmatch(block, EULER_PATTERN) do
			if isJoint(name) then
				pose[name] = CFrame.new(tonumber(x) or 0, tonumber(y) or 0, tonumber(z) or 0)
					* CFrame.Angles(math.rad(tonumber(rx) or 0), math.rad(tonumber(ry) or 0), math.rad(tonumber(rz) or 0))
				count += 1
			end
		end
	end
	return pose, count
end

local function keyBlocks(text: string): { { Start: number, Id: string, Time: number, Style: string, Direction: string } }
	local blocks = {}
	local cursor = 1
	while true do
		local first, last, id, time, style, direction = string.find(text,
			'{%s*Id%s*=%s*"([^"]+)"%s*,%s*Time%s*=%s*([%+%-%d%.eE]+)%s*,%s*EasingStyle%s*=%s*"([^"]+)"%s*,%s*EasingDirection%s*=%s*"([^"]+)"%s*,%s*Values%s*=%s*{', cursor)
		if not first or not last then break end
		table.insert(blocks, { Start = first, Id = id, Time = tonumber(time) or 0, Style = style, Direction = direction })
		cursor = last + 1
	end
	return blocks
end

local function parseV3(text: string): (AnimationDocument?, string)
	local document = parseHeader(text)
	local blocks = keyBlocks(text)
	local total = 0
	for index, info in blocks do
		local nextInfo = blocks[index + 1]
		local block = string.sub(text, info.Start, if nextInfo then nextInfo.Start - 1 else #text)
		local pose, count = parsePose(block, true)
		local smoothText = string.match(block, "Smooth%s*=%s*(%a+)")
		total += count
		table.insert(document.Keyframes, {
			Id = info.Id, Time = math.clamp(info.Time, 0, document.Duration), Values = pose,
			EasingStyle = if table.find(Document.EasingStyles, info.Style) then info.Style else "Linear",
			EasingDirection = if table.find(Document.EasingDirections, info.Direction) then info.Direction else "InOut",
			GroundLock = string.match(block, "GroundLock%s*=%s*(%a+)") ~= "false",
			Smooth = if smoothText then smoothText ~= "false" else document.Interpolation == "Smooth",
		})
	end
	if #document.Keyframes == 0 then return nil, "No valid V3 keyframes were found." end
	Document.sort(document)
	return document, string.format("Imported V3 animation: %d keys, %d joint values.", #document.Keyframes, total)
end

local function parseV2(text: string): (AnimationDocument?, string)
	local document = parseHeader(text)
	local starts = {}
	local cursor = 1
	while true do
		local first, last, id, time = string.find(text, '{%s*Id%s*=%s*"([^"]+)"%s*,%s*Time%s*=%s*([%+%-%d%.]+)%s*,%s*Values%s*=%s*{', cursor)
		if not first or not last then break end
		table.insert(starts, { Start = first, Id = id, Time = tonumber(time) or 0 })
		cursor = last + 1
	end
	local count = 0
	for index, info in starts do
		local nextInfo = starts[index + 1]
		local pose, parsed = parsePose(string.sub(text, info.Start, if nextInfo then nextInfo.Start - 1 else #text), false)
		count += parsed
		table.insert(document.Keyframes, {
			Id = info.Id, Time = math.clamp(info.Time, 0, document.Duration), Values = pose,
			EasingStyle = "Linear", EasingDirection = "InOut", GroundLock = true, Smooth = document.Interpolation == "Smooth",
		})
	end
	if #document.Keyframes == 0 or count == 0 then return nil, "No valid V2 keyframes were found." end
	Document.sort(document)
	return document, string.format("Converted V2 animation: %d keys.", #document.Keyframes)
end

local function parseV1(text: string, fallback: Pose): (AnimationDocument?, string)
	local starts = {}
	local cursor = 1
	while true do
		local first, last, duration = string.find(text, "{%s*Duration%s*=%s*([%+%-%d%.]+)", cursor)
		if not first or not last then break end
		table.insert(starts, { Start = first, Duration = math.clamp(tonumber(duration) or 0.15, 0.01, 60) })
		cursor = last + 1
	end
	local document = Document.new()
	local elapsed, count = 0, 0
	for index, info in starts do
		local nextInfo = starts[index + 1]
		local pose, parsed = parsePose(string.sub(text, info.Start, if nextInfo then nextInfo.Start - 1 else #text), false, fallback)
		count += parsed
		table.insert(document.Keyframes, {
			Id = Document.newId(), Time = elapsed, Values = pose,
			EasingStyle = "Linear", EasingDirection = "InOut", GroundLock = true, Smooth = false,
		})
		elapsed += info.Duration
	end
	if #document.Keyframes == 0 or count == 0 then return nil, "No valid V1 frames were found." end
	document.Duration = math.max(0.05, elapsed)
	document.Interpolation = "Step"
	return document, string.format("Converted V1 sequence: %d keys.", #document.Keyframes)
end

function Codec.parseAny(text: string, fallback: Pose): (AnimationDocument?, string)
	if #text > 1_000_000 then return nil, "Import exceeds the 1 MB safety limit." end
	if string.find(text, "R15_POSE_ANIMATION_V3", 1, true) then return parseV3(text) end
	if string.find(text, "R15_POSE_ANIMATION_V2", 1, true) then return parseV2(text) end
	if string.find(text, "R15_STOP_MOTION_POSE_SEQUENCE_V1", 1, true) then return parseV1(text, fallback) end
	return nil, "Expected an R15 V1, V2, or V3 animation."
end

function Codec.componentsEqual(a: CFrame, b: CFrame, epsilon: number?): boolean
	local aa, bb = { a:GetComponents() }, { b:GetComponents() }
	local limit = epsilon or 1e-7
	for index = 1, 12 do if math.abs(aa[index] - bb[index]) > limit then return false end end
	return true
end

function Codec.verifyV3(document: AnimationDocument, text: string): (boolean, string)
	if not string.find(text, 'RigType = "R15"', 1, true) then return false, "R15 rig type marker is missing." end
	if not string.find(text, "Version = 3", 1, true) then return false, "V3 format marker is missing." end
	local parsed, message = parseV3(text)
	if not parsed then return false, message end
	if math.abs(parsed.Duration - document.Duration) > 1e-10 then return false, "Duration did not round-trip." end
	if math.abs(parsed.PlaybackSpeed - document.PlaybackSpeed) > 1e-10 then return false, "Playback speed did not round-trip." end
	if parsed.FPS ~= document.FPS then return false, "FPS did not round-trip." end
	if parsed.Loop ~= document.Loop then return false, "Loop did not round-trip." end
	if parsed.Interpolation ~= document.Interpolation then return false, "Interpolation did not round-trip." end
	if parsed.AutoKey ~= document.AutoKey then return false, "Auto-Key did not round-trip." end

	local expected = Document.copy(document)
	Document.sort(expected); Document.sort(parsed)
	if #parsed.Keyframes ~= #expected.Keyframes then return false, "Keyframe count did not round-trip." end
	for index, sourceKey in expected.Keyframes do
		local parsedKey = parsed.Keyframes[index]
		if parsedKey.Id ~= sourceKey.Id then return false, string.format("Key %d ID did not round-trip.", index) end
		if math.abs(parsedKey.Time - sourceKey.Time) > 1e-10 then return false, string.format("Key %d time did not round-trip.", index) end
		if parsedKey.EasingStyle ~= sourceKey.EasingStyle or parsedKey.EasingDirection ~= sourceKey.EasingDirection then
			return false, string.format("Key %d easing did not round-trip.", index)
		end
		if parsedKey.GroundLock ~= (sourceKey.GroundLock ~= false) then return false, string.format("Key %d Ground Lock did not round-trip.", index) end
		if parsedKey.Smooth ~= (sourceKey.Smooth ~= false) then return false, string.format("Key %d Smooth did not round-trip.", index) end
		for _, joint in Codec.JointNames do
			local sourceValue, parsedValue = sourceKey.Values[joint], parsedKey.Values[joint]
			if (sourceValue == nil) ~= (parsedValue == nil) then return false, string.format("Key %d joint %s presence did not round-trip.", index, joint) end
			if sourceValue and parsedValue and not Codec.componentsEqual(sourceValue, parsedValue, 1e-9) then
				return false, string.format("Key %d joint %s transform did not round-trip.", index, joint)
			end
		end
	end
	return true, string.format(
		"Verified %d keyframes and all sparse joint transforms, timing, easing, Smooth, Ground Lock, and playback settings.",
		#expected.Keyframes
	)
end

return Codec
