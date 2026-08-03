--!strict

export type Joints = {
	Root: Motor6D?,
	Waist: Motor6D?,
	Neck: Motor6D?,
	LeftShoulder: Motor6D?,
	LeftElbow: Motor6D?,
	LeftWrist: Motor6D?,
	RightShoulder: Motor6D?,
	RightElbow: Motor6D?,
	RightWrist: Motor6D?,
	LeftHip: Motor6D?,
	LeftKnee: Motor6D?,
	LeftAnkle: Motor6D?,
	RightHip: Motor6D?,
	RightKnee: Motor6D?,
	RightAnkle: Motor6D?,
}

export type Rig = {
	Character: Model,
	Humanoid: Humanoid,
	Animator: Animator,
	RootPart: BasePart,
	Head: BasePart,
	LowerTorso: BasePart,
	LeftUpperLeg: BasePart,
	LeftLowerLeg: BasePart,
	LeftFoot: BasePart,
	RightUpperLeg: BasePart,
	RightLowerLeg: BasePart,
	RightFoot: BasePart,
	Joints: Joints,
	RestTransforms: { [Motor6D]: CFrame },
	BodyParts: { BasePart },
	AnimationMotors: { Motor6D },
	GroundBodyParts: { BasePart },
	LegLength: number,
	StanceHalfWidth: number,
	CameraAnchorHeight: number,
	LeftRestFootLocal: Vector3,
	RightRestFootLocal: Vector3,
}

local RigModule = {}

local function getRequiredPart(character: Model, name: string): BasePart?
	local instance = character:FindFirstChild(name)
	if instance and instance:IsA("BasePart") then
		return instance
	end
	return nil
end

local function isFirstPersonHiddenPart(part: BasePart): boolean
	local lowerName = string.lower(part.Name)
	if lowerName == "head" or string.find(lowerName, "neck", 1, true) then
		return true
	end
	return part:FindFirstAncestorOfClass("Accessory") ~= nil
end

local function findMotor(motorsByName: { [string]: Motor6D }, ...: string): Motor6D?
	for _, name in { ... } do
		local motor = motorsByName[name]
		if motor then
			return motor
		end
	end
	return nil
end

function RigModule.applyFirstPersonVisibility(instance: Instance, firstPersonEnabled: boolean?)
	if not instance:IsA("BasePart") then
		return
	end

	local shouldHide = firstPersonEnabled ~= false and isFirstPersonHiddenPart(instance)
	instance.LocalTransparencyModifier = if shouldHide then 1 else 0
end

function RigModule.create(character: Model): (Rig?, string?)
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if not humanoid then
		return nil, "Humanoid is missing"
	end
	if humanoid.RigType ~= Enum.HumanoidRigType.R15 then
		return nil, "the character is not a standard R15 rig"
	end

	local rootPart = getRequiredPart(character, "HumanoidRootPart")
	local head = getRequiredPart(character, "Head")
	local lowerTorso = getRequiredPart(character, "LowerTorso")
	local leftUpperLeg = getRequiredPart(character, "LeftUpperLeg")
	local leftLowerLeg = getRequiredPart(character, "LeftLowerLeg")
	local leftFoot = getRequiredPart(character, "LeftFoot")
	local rightUpperLeg = getRequiredPart(character, "RightUpperLeg")
	local rightLowerLeg = getRequiredPart(character, "RightLowerLeg")
	local rightFoot = getRequiredPart(character, "RightFoot")

	if not rootPart or not head or not lowerTorso or not leftUpperLeg or not leftLowerLeg or not leftFoot
		or not rightUpperLeg or not rightLowerLeg or not rightFoot then
		return nil, "one or more required R15 body parts are missing"
	end

	local animator = humanoid:FindFirstChildOfClass("Animator")
	if not animator then
		animator = Instance.new("Animator")
		animator.Parent = humanoid
	end

	local motorsByName: { [string]: Motor6D } = {}
	local restTransforms: { [Motor6D]: CFrame } = {}
	local bodyParts: { BasePart } = {}

	-- This is the only full descendant scan performed for a character lifecycle.
	for _, descendant in character:GetDescendants() do
		if descendant:IsA("Motor6D") then
			motorsByName[descendant.Name] = descendant
			-- R15's authored rest pose lives in C0/C1. Transform is only the
			-- additive animation layer, so its neutral value must be identity.
			restTransforms[descendant] = CFrame.identity
		elseif descendant:IsA("BasePart") then
			table.insert(bodyParts, descendant)
			RigModule.applyFirstPersonVisibility(descendant)
		end
	end

	local leftLength = leftUpperLeg.Size.Y + leftLowerLeg.Size.Y + leftFoot.Size.Y * 0.5
	local rightLength = rightUpperLeg.Size.Y + rightLowerLeg.Size.Y + rightFoot.Size.Y * 0.5
	local legLength = math.max(1, (leftLength + rightLength) * 0.5)
	local leftRestFootLocal = rootPart.CFrame:PointToObjectSpace(leftFoot.Position)
	local rightRestFootLocal = rootPart.CFrame:PointToObjectSpace(rightFoot.Position)
	local stanceHalfWidth = math.max(0.25, math.abs(rightRestFootLocal.X - leftRestFootLocal.X) * 0.5)
	local joints: Joints = {
		Root = findMotor(motorsByName, "Root", "RootJoint"),
		Waist = findMotor(motorsByName, "Waist"),
		Neck = findMotor(motorsByName, "Neck"),
		LeftShoulder = findMotor(motorsByName, "LeftShoulder", "Left Shoulder"),
		LeftElbow = findMotor(motorsByName, "LeftElbow", "Left Elbow"),
		LeftWrist = findMotor(motorsByName, "LeftWrist", "Left Wrist"),
		RightShoulder = findMotor(motorsByName, "RightShoulder", "Right Shoulder"),
		RightElbow = findMotor(motorsByName, "RightElbow", "Right Elbow"),
		RightWrist = findMotor(motorsByName, "RightWrist", "Right Wrist"),
		LeftHip = findMotor(motorsByName, "LeftHip", "Left Hip"),
		LeftKnee = findMotor(motorsByName, "LeftKnee", "Left Knee"),
		LeftAnkle = findMotor(motorsByName, "LeftAnkle", "Left Ankle"),
		RightHip = findMotor(motorsByName, "RightHip", "Right Hip"),
		RightKnee = findMotor(motorsByName, "RightKnee", "Right Knee"),
		RightAnkle = findMotor(motorsByName, "RightAnkle", "Right Ankle"),
	}

	if not joints.Root or not joints.Waist
		or not joints.LeftHip or not joints.LeftKnee or not joints.LeftAnkle
		or not joints.RightHip or not joints.RightKnee or not joints.RightAnkle
		or not joints.LeftShoulder or not joints.RightShoulder then
		return nil, "one or more required R15 Motor6D joints are missing"
	end

	-- Match the pose tuner's FPS anchor exactly: derive the neutral head from
	-- R15 C0/C1 values, never from the live pose left behind by Animate.
	local cameraAnchorHeight = rootPart.CFrame:PointToObjectSpace(head.Position).Y
	local rootMotor, waistMotor, neckMotor = joints.Root, joints.Waist, joints.Neck
	if rootMotor and waistMotor and neckMotor
		and rootMotor.Part0 == rootPart
		and waistMotor.Part0 == rootMotor.Part1
		and neckMotor.Part0 == waistMotor.Part1
		and neckMotor.Part1 == head then
		local lowerTorsoFrame = rootPart.CFrame * rootMotor.C0 * rootMotor.C1:Inverse()
		local upperTorsoFrame = lowerTorsoFrame * waistMotor.C0 * waistMotor.C1:Inverse()
		local neutralHeadFrame = upperTorsoFrame * neckMotor.C0 * neckMotor.C1:Inverse()
		cameraAnchorHeight = rootPart.CFrame:PointToObjectSpace(neutralHeadFrame.Position).Y
	end

	-- Anatomical order guarantees every parent frame exists before its child
	-- when the runtime ground-lock solver evaluates the visual pose.
	local animationMotors: { Motor6D } = {}
	for _, motor in {
		joints.Root, joints.Waist, joints.Neck,
		joints.LeftShoulder, joints.LeftElbow, joints.LeftWrist,
		joints.RightShoulder, joints.RightElbow, joints.RightWrist,
		joints.LeftHip, joints.LeftKnee, joints.LeftAnkle,
		joints.RightHip, joints.RightKnee, joints.RightAnkle,
	} do
		if motor then table.insert(animationMotors, motor) end
	end

	local groundBodyParts: { BasePart } = {}
	for _, part in bodyParts do
		if part ~= rootPart and not part:FindFirstAncestorOfClass("Accessory") then
			table.insert(groundBodyParts, part)
		end
	end

	local rig: Rig = {
		Character = character,
		Humanoid = humanoid,
		Animator = animator,
		RootPart = rootPart,
		Head = head,
		LowerTorso = lowerTorso,
		LeftUpperLeg = leftUpperLeg,
		LeftLowerLeg = leftLowerLeg,
		LeftFoot = leftFoot,
		RightUpperLeg = rightUpperLeg,
		RightLowerLeg = rightLowerLeg,
		RightFoot = rightFoot,
		Joints = joints,
		RestTransforms = restTransforms,
		BodyParts = bodyParts,
		AnimationMotors = animationMotors,
		GroundBodyParts = groundBodyParts,
		LegLength = legLength,
		StanceHalfWidth = stanceHalfWidth,
		CameraAnchorHeight = cameraAnchorHeight,
		LeftRestFootLocal = leftRestFootLocal,
		RightRestFootLocal = rightRestFootLocal,
	}

	return rig, nil
end

function RigModule.restore(rig: Rig)
	for motor, restTransform in rig.RestTransforms do
		if motor.Parent then
			motor.Transform = restTransform
		end
	end
	if rig.Humanoid.Parent then
		rig.Humanoid.CameraOffset = Vector3.zero
	end
end

return RigModule
