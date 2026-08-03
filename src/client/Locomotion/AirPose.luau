--!strict

export type AirPoseData = {
	Jump: { [string]: CFrame },
	FallAdjustment: { [string]: CFrame },
}

-- Imported from R15_STOP_MOTION_POSE_SEQUENCE_V1, frame 1.
local jumpPose: { [string]: CFrame } = {
	Root = CFrame.new(0, 0, 0) * CFrame.Angles(math.rad(0), math.rad(0), math.rad(0)),
	Waist = CFrame.new(0, 0, 0) * CFrame.Angles(math.rad(0), math.rad(0), math.rad(0)),
	Neck = CFrame.new(0, 0, 0) * CFrame.Angles(math.rad(0), math.rad(0), math.rad(0)),
	LeftShoulder = CFrame.new(0, 0, 0)
		* CFrame.Angles(math.rad(48), math.rad(-40), math.rad(12)),
	LeftElbow = CFrame.new(0.08, -0.02, -0.08)
		* CFrame.Angles(math.rad(4), math.rad(-32), math.rad(8)),
	LeftWrist = CFrame.new(0, 0, 0)
		* CFrame.Angles(math.rad(24), math.rad(8), math.rad(4)),
	RightShoulder = CFrame.new(-0.04, 0.02, -0.10)
		* CFrame.Angles(math.rad(22), math.rad(58), math.rad(12)),
	RightElbow = CFrame.new(-0.06, 0.04, -0.08)
		* CFrame.Angles(math.rad(20), math.rad(42), math.rad(12)),
	RightWrist = CFrame.new(0, 0, 0) * CFrame.Angles(math.rad(0), math.rad(0), math.rad(0)),
	LeftHip = CFrame.new(0.04, -0.02, 0.08)
		* CFrame.Angles(math.rad(48), math.rad(44), math.rad(-28)),
	LeftKnee = CFrame.new(0.10, -0.20, -0.28)
		* CFrame.Angles(math.rad(-52), math.rad(-4), math.rad(-20)),
	LeftAnkle = CFrame.new(0, 0, 0) * CFrame.Angles(math.rad(0), math.rad(0), math.rad(0)),
	RightHip = CFrame.new(-0.04, -0.20, 0.06)
		* CFrame.Angles(math.rad(54), math.rad(16), math.rad(14)),
	RightKnee = CFrame.new(0, -0.18, -0.10)
		* CFrame.Angles(math.rad(-44), math.rad(10), math.rad(0)),
	RightAnkle = CFrame.new(0, 0.02, 0.06)
		* CFrame.Angles(math.rad(-22), math.rad(-14), math.rad(2)),
}

-- Falling keeps the authored silhouette while gradually opening the tuck.
local fallAdjustment: { [string]: CFrame } = {
	Root = CFrame.Angles(math.rad(-3), 0, 0),
	Waist = CFrame.Angles(math.rad(4), 0, 0),
	LeftShoulder = CFrame.Angles(math.rad(8), 0, math.rad(-3)),
	RightShoulder = CFrame.Angles(math.rad(8), 0, math.rad(3)),
	LeftHip = CFrame.Angles(math.rad(-14), 0, 0),
	RightHip = CFrame.Angles(math.rad(-14), 0, 0),
	LeftKnee = CFrame.Angles(math.rad(18), 0, 0),
	RightKnee = CFrame.Angles(math.rad(18), 0, 0),
	LeftAnkle = CFrame.Angles(math.rad(-8), 0, 0),
	RightAnkle = CFrame.Angles(math.rad(-8), 0, 0),
}

local data: AirPoseData = {
	Jump = table.freeze(jumpPose),
	FallAdjustment = table.freeze(fallAdjustment),
}

return table.freeze(data)
