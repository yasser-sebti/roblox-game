--!strict

export type Pose = { [string]: CFrame }

local PoseMath = {}

function PoseMath.neutralPose(joints: { string }): Pose
	local pose: Pose = {}
	for _, name in joints do pose[name] = CFrame.identity end
	return pose
end

local function oppositeJoint(name: string): string
	if string.sub(name, 1, 4) == "Left" then return "Right" .. string.sub(name, 5) end
	if string.sub(name, 1, 5) == "Right" then return "Left" .. string.sub(name, 6) end
	return name
end

-- Reflect a rigid transform through the character-local sagittal plane.
-- M = diag(-1, 1, 1); applying M * T * M preserves a proper rotation.
function PoseMath.mirrorTransform(transform: CFrame): CFrame
	local x, y, z, r00, r01, r02, r10, r11, r12, r20, r21, r22 = transform:GetComponents()
	return CFrame.new(
		-x, y, z,
		r00, -r01, -r02,
		-r10, r11, r12,
		-r20, r21, r22
	)
end

function PoseMath.mirrorPose(pose: Pose): Pose
	local mirrored: Pose = {}
	for name, transform in pose do mirrored[oppositeJoint(name)] = PoseMath.mirrorTransform(transform) end
	return mirrored
end

function PoseMath.isMirrorInvolution(pose: Pose, tolerance: number?): boolean
	local restored = PoseMath.mirrorPose(PoseMath.mirrorPose(pose)); local epsilon = tolerance or 1e-6
	for name, source in pose do
		local result = restored[name]; if not result then return false end
		local sourceComponents = { source:GetComponents() }; local resultComponents = { result:GetComponents() }
		for index = 1, 12 do if math.abs(sourceComponents[index] - resultComponents[index]) > epsilon then return false end end
	end
	return true
end

function PoseMath.oppositeJoint(name: string): string return oppositeJoint(name) end

return PoseMath
