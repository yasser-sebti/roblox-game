--!strict

-- Imported from R15_STOP_MOTION_POSE_SEQUENCE_V1, frame 1.
-- These are full Motor6D.Transform base values. Controller layers procedural
-- gait, terrain response, torso camera-follow, and transition blending on top.

local pose: { [string]: CFrame } = {
	Root = CFrame.new(0, -0.30, 0) * CFrame.Angles(math.rad(0), math.rad(0), math.rad(0)),
	Waist = CFrame.new(0, 0, 0) * CFrame.Angles(math.rad(0), math.rad(0), math.rad(0)),
	Neck = CFrame.new(0, 0, 0) * CFrame.Angles(math.rad(0), math.rad(0), math.rad(0)),
	LeftShoulder = CFrame.new(0, 0.02, 0.06)
		* CFrame.Angles(math.rad(62), math.rad(-28), math.rad(8)),
	LeftElbow = CFrame.new(0.16, -0.04, -0.14)
		* CFrame.Angles(math.rad(18), math.rad(-58), math.rad(30)),
	LeftWrist = CFrame.new(0, 0, 0)
		* CFrame.Angles(math.rad(22), math.rad(-14), math.rad(-20)),
	RightShoulder = CFrame.new(-0.04, 0.06, 0.06)
		* CFrame.Angles(math.rad(14), math.rad(-6), math.rad(8)),
	RightElbow = CFrame.new(0.02, 0.02, 0.02)
		* CFrame.Angles(math.rad(28), math.rad(12), math.rad(0)),
	RightWrist = CFrame.new(0, 0, 0.02)
		* CFrame.Angles(math.rad(38), math.rad(24), math.rad(-16)),
	LeftHip = CFrame.new(0.02, 0.16, -0.08)
		* CFrame.Angles(math.rad(14), math.rad(18), math.rad(0)),
	LeftKnee = CFrame.new(0, 0, 0.22)
		* CFrame.Angles(math.rad(-124), math.rad(-2), math.rad(-16)),
	LeftAnkle = CFrame.new(0, 0.10, -0.06)
		* CFrame.Angles(math.rad(34), math.rad(4), math.rad(0)),
	RightHip = CFrame.new(0.02, 0.02, -0.20)
		* CFrame.Angles(math.rad(88), math.rad(0), math.rad(6)),
	RightKnee = CFrame.new(-0.02, -0.40, -0.30)
		* CFrame.Angles(math.rad(-84), math.rad(0), math.rad(0)),
	RightAnkle = CFrame.new(0, 0, 0) * CFrame.Angles(math.rad(0), math.rad(0), math.rad(0)),
}

return table.freeze(pose)
