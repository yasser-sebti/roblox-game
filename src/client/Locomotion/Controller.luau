--!strict

local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")

local ConfigModule = require(script.Parent.Config)
local CrouchPose = require(script.Parent.CrouchPose) :: { [string]: CFrame }
local AirPose = require(script.Parent.AirPose) :: {
	Jump: { [string]: CFrame },
	FallAdjustment: { [string]: CFrame },
}
local RigModule = require(script.Parent.Rig)
local Spring = require(script.Parent.Spring)
local PoseAnimation = require(script.Parent.PoseAnimation)
local WalkingDefault = PoseAnimation.compile(require(script.Parent.WalkingDefaultAnimation))

type LocomotionConfig = ConfigModule.LocomotionConfig
type Rig = RigModule.Rig
type ScalarSpring = Spring.ScalarSpring

type GroundSample = {
	Valid: boolean,
	HeightError: number,
	SurfaceY: number,
	Pitch: number,
	Roll: number,
}

export type Controller = {
	Player: Player,
	Rig: Rig,
	Config: LocomotionConfig,
	Connections: { RBXScriptConnection },
	VisibilityBindingName: string,
	RaycastParams: RaycastParams,
	OverlapParams: OverlapParams,
	Sprinting: boolean,
	CrouchRequested: boolean,
	Crouching: boolean,
	CrouchBlocked: boolean,
	Destroyed: boolean,
	OriginalAutoRotate: boolean,
	OriginalHipHeight: number,
	OriginalMouseSensitivity: number,
	OriginalCameraType: Enum.CameraType,
	GaitPhase: number,
	AuthoredWalkBlend: number,
	AuthoredGroundLockBlend: number,
	AuthoredWalkPose: { [string]: CFrame },
	GroundFrames: { [BasePart]: CFrame },
	TurnStepPhase: number,
	TurnDirection: number,
	TurnCommitted: boolean,
	State: string,
	MoveSpring: ScalarSpring,
	RunSpring: ScalarSpring,
	CrouchSpring: ScalarSpring,
	PelvisSpring: ScalarSpring,
	GroundLockSpring: ScalarSpring,
	CameraBobSpring: ScalarSpring,
	CameraSwaySpring: ScalarSpring,
	GaitSpeedSpring: ScalarSpring,
	StepSpeedSpring: ScalarSpring,
	AirSpring: ScalarSpring,
	FallSpring: ScalarSpring,
	TurnBlendSpring: ScalarSpring,
	DirectionXSpring: ScalarSpring,
	DirectionZSpring: ScalarSpring,
	IdleTurnSpring: ScalarSpring,
	CameraPitchSpring: ScalarSpring,
	LowerBodyYawSpring: ScalarSpring,
	SmoothedCameraRotation: CFrame,
	CameraRotationInitialized: boolean,
	CameraYaw: number,
	CameraPitch: number,
	CameraTargetYaw: number,
	CameraTargetPitch: number,
	RenderCameraSway: number,
	RenderCameraBob: number,
	RenderCameraForwardShift: number,
	RenderCameraCrouchDrop: number,
	RenderGroundLockOffset: number,
	SetSprinting: (self: Controller, enabled: boolean) -> (),
	SetCrouching: (self: Controller, enabled: boolean) -> (),
	Destroy: (self: Controller) -> (),
	_render: (self: Controller, rawDeltaTime: number) -> (),
	_renderVisibility: (self: Controller, rawDeltaTime: number) -> (),
	_canStand: (self: Controller) -> boolean,
	_probeFoot: (self: Controller, restFootLocal: Vector3, phase: number, moveDirection: Vector3, strideScale: number) -> GroundSample,
	_probeLegObstacle: (self: Controller, foot: BasePart, restFootLocal: Vector3, phase: number, recovery: number, moveDirection: Vector3, strideScale: number) -> number,
}

local ControllerModule = {}
local ControllerClass = {}
ControllerClass.__index = ControllerClass

local UP = Vector3.new(0, 1, 0)
local IDENTITY = CFrame.identity

local function radians(degrees: number): number
	return math.rad(degrees)
end

local function lerp(a: number, b: number, alpha: number): number
	return a + (b - a) * alpha
end

local function smoothstep(alpha: number): number
	local clamped = math.clamp(alpha, 0, 1)
	return clamped * clamped * (3 - 2 * clamped)
end

local function contactHeldGaitCycle(phase: number, holdFraction: number): number
	local normalized = (phase / (math.pi * 2)) % 1
	local halfHold = math.clamp(holdFraction, 0, 0.2) * 0.5
	local positiveStart = 0.25 - halfHold
	local positiveEnd = 0.25 + halfHold
	local negativeStart = 0.75 - halfHold
	local negativeEnd = 0.75 + halfHold

	if normalized >= positiveStart and normalized <= positiveEnd then
		return 1
	elseif normalized >= negativeStart and normalized <= negativeEnd then
		return -1
	elseif normalized > positiveEnd and normalized < negativeStart then
		local alpha = (normalized - positiveEnd) / math.max(0.001, negativeStart - positiveEnd)
		return 1 - smoothstep(alpha) * 2
	end

	local wrapped = if normalized < positiveStart then normalized + 1 else normalized
	local alpha = (wrapped - negativeEnd) / math.max(0.001, positiveStart + 1 - negativeEnd)
	return -1 + smoothstep(alpha) * 2
end

local function horizontal(vector: Vector3): Vector3
	return Vector3.new(vector.X, 0, vector.Z)
end

local function yawFromDirection(direction: Vector3): number
	return math.atan2(-direction.X, -direction.Z)
end

local function shortestAngle(target: number, current: number): number
	local difference = target - current
	return math.atan2(math.sin(difference), math.cos(difference))
end

local function isGrounded(humanoid: Humanoid): boolean
	local state = humanoid:GetState()
	if state == Enum.HumanoidStateType.Jumping
		or state == Enum.HumanoidStateType.Freefall
		or state == Enum.HumanoidStateType.FallingDown
		or state == Enum.HumanoidStateType.Swimming
		or state == Enum.HumanoidStateType.Climbing
		or state == Enum.HumanoidStateType.Seated
		or state == Enum.HumanoidStateType.Dead then
		return false
	end
	return humanoid.FloorMaterial ~= Enum.Material.Air
end

local function usesAirPose(humanoid: Humanoid): boolean
	local state = humanoid:GetState()
	return state == Enum.HumanoidStateType.Jumping
		or state == Enum.HumanoidStateType.Freefall
		or state == Enum.HumanoidStateType.FallingDown
end

local function writeJoint(rig: Rig, motor: Motor6D?, offset: CFrame)
	if motor and motor.Parent then
		motor.Transform = (rig.RestTransforms[motor] or IDENTITY) * offset
	end
end

local function blendJointToAir(
	rig: Rig,
	motor: Motor6D?,
	jointName: string,
	airBlend: number,
	fallBlend: number
)
	if not motor or not motor.Parent or airBlend <= 0.0001 then
		return
	end
	local restTransform = rig.RestTransforms[motor] or IDENTITY
	local currentOffset = restTransform:Inverse() * motor.Transform
	local jumpTarget = AirPose.Jump[jointName] or IDENTITY
	local fallAdjustment = AirPose.FallAdjustment[jointName] or IDENTITY
	local airTarget = jumpTarget * IDENTITY:Lerp(fallAdjustment, math.clamp(fallBlend, 0, 1))
	if jointName == "LeftWrist" then
		local fearTime = os.clock() * 2.15
		airTarget *= CFrame.Angles(
			math.sin(fearTime) * radians(2.4),
			math.sin(fearTime * 0.73 + 0.8) * radians(1.8),
			math.sin(fearTime * 1.17 + 1.9) * radians(1.4)
		)
	elseif jointName == "RightWrist" then
		local fearTime = os.clock() * 2.15
		airTarget *= CFrame.Angles(
			-math.sin(fearTime + 0.5) * radians(2.4),
			-math.sin(fearTime * 0.73 + 1.3) * radians(1.8),
			math.sin(fearTime * 1.17 + 0.2) * radians(1.4)
		)
	end
	writeJoint(rig, motor, currentOffset:Lerp(airTarget, math.clamp(airBlend, 0, 1)))
end

local function updateCameraMotion(
	self: Controller,
	grounded: boolean,
	firstPersonEnabled: boolean,
	moveBlend: number,
	runBlend: number,
	crouchBlend: number,
	cycle: number,
	midStanceRise: number,
	footImpact: number,
	deltaTime: number
)
	local config = self.Config
	local strength = if firstPersonEnabled and grounded then moveBlend else 0
	local standingBob = lerp(config.WalkCameraBob, config.RunCameraBob, runBlend)
	local standingSway = lerp(config.WalkCameraSway, config.RunCameraSway, runBlend)
	local bobAmplitude = lerp(standingBob, config.CrouchCameraBob, crouchBlend)
	local swayAmplitude = lerp(standingSway, config.CrouchCameraSway, crouchBlend)
	-- Positional feedback only; no camera rotation is introduced here.
	local bobTarget = (midStanceRise * 0.55 - footImpact) * bobAmplitude * strength
	local swayTarget = cycle * swayAmplitude * strength
	self.RenderCameraBob = Spring.step(self.CameraBobSpring, bobTarget, config.CameraSpringFrequency, deltaTime)
	self.RenderCameraSway = Spring.step(self.CameraSwaySpring, swayTarget, config.CameraSpringFrequency, deltaTime)
	self.Rig.Humanoid.CameraOffset = Vector3.zero
end

local function crouchPoseBase(jointName: string, crouchBlend: number): CFrame
	return IDENTITY:Lerp(CrouchPose[jointName] or IDENTITY, math.clamp(crouchBlend, 0, 1))
end

local function authoredWalkBase(self: Controller, jointName: string): CFrame
	return IDENTITY:Lerp(
		self.AuthoredWalkPose[jointName] or IDENTITY,
		math.clamp(self.AuthoredWalkBlend, 0, 1)
	)
end

local function sampleAuthoredWalk(self: Controller)
	local authoredTime = self.GaitPhase / (math.pi * 2)
		* WalkingDefault.Duration
		* WalkingDefault.PlaybackSpeed
	PoseAnimation.evaluate(WalkingDefault, authoredTime, self.AuthoredWalkPose)
	self.AuthoredGroundLockBlend = PoseAnimation.evaluateGroundLock(WalkingDefault, authoredTime)
end

local function partBottomYAt(part: BasePart, frame: CFrame): number
	local halfSize = part.Size * 0.5
	local verticalRadius = math.abs(frame.RightVector.Y) * halfSize.X
		+ math.abs(frame.UpVector.Y) * halfSize.Y
		+ math.abs(frame.LookVector.Y) * halfSize.Z
	return frame.Position.Y - verticalRadius
end

local function updateRuntimeGroundLock(
	self: Controller,
	leftGround: GroundSample,
	rightGround: GroundSample,
	cycle: number,
	grounded: boolean,
	deltaTime: number
)
	local targetOffset = 0
	if grounded and self.AuthoredWalkBlend > 0.001 and self.AuthoredGroundLockBlend > 0.001 then
		local leftWeight = if leftGround.Valid then 0.5 + cycle * 0.5 else 0
		local rightWeight = if rightGround.Valid then 0.5 - cycle * 0.5 else 0
		local supportWeight = leftWeight + rightWeight
		if supportWeight > 0.001 then
			local surfaceY = (leftGround.SurfaceY * leftWeight + rightGround.SurfaceY * rightWeight)
				/ supportWeight
			local frames = self.GroundFrames
			table.clear(frames)
			frames[self.Rig.RootPart] = self.Rig.RootPart.CFrame
			for _, motor in self.Rig.AnimationMotors do
				local parentFrame = if motor.Part0 then frames[motor.Part0] else nil
				if parentFrame and motor.Part1 then
					frames[motor.Part1] = parentFrame * motor.C0 * motor.Transform * motor.C1:Inverse()
				end
			end

			local lowestBottom = math.huge
			for _, part in self.Rig.GroundBodyParts do
				local frame = frames[part]
				if frame then lowestBottom = math.min(lowestBottom, partBottomYAt(part, frame)) end
			end
			if lowestBottom < math.huge then
				targetOffset = math.clamp(
					(surfaceY - lowestBottom) * self.AuthoredGroundLockBlend * self.AuthoredWalkBlend,
					-self.Rig.LegLength * 0.25,
					self.Rig.LegLength * 0.4
				)
			end
		end
	end

	local offset = Spring.step(
		self.GroundLockSpring,
		targetOffset,
		self.Config.TerrainSpringFrequency,
		deltaTime
	)
	self.RenderGroundLockOffset = offset
	local rootMotor = self.Rig.Joints.Root
	if rootMotor and rootMotor.Parent and math.abs(offset) > 0.00001 then
		local restTransform = self.Rig.RestTransforms[rootMotor] or IDENTITY
		local currentOffset = restTransform:Inverse() * rootMotor.Transform
		writeJoint(self.Rig, rootMotor, CFrame.new(0, offset, 0) * currentOffset)
	end
end

local function mirroredCrouchTransform(transform: CFrame): CFrame
	local pitch, yaw, roll = transform:ToOrientation()
	local position = transform.Position
	return CFrame.new(-position.X, position.Y, position.Z) * CFrame.Angles(pitch, -yaw, -roll)
end

local oppositeCrouchLegPose: { [string]: CFrame } = {
	LeftHip = mirroredCrouchTransform(CrouchPose.RightHip or IDENTITY),
	LeftKnee = mirroredCrouchTransform(CrouchPose.RightKnee or IDENTITY),
	LeftAnkle = mirroredCrouchTransform(CrouchPose.RightAnkle or IDENTITY),
	-- The right trailing leg deliberately uses the exact authored left trailing
	-- transforms. Mirroring these values twists the R15 right knee's joint space.
	RightHip = CrouchPose.LeftHip or IDENTITY,
	RightKnee = CrouchPose.LeftKnee or IDENTITY,
	RightAnkle = CrouchPose.LeftAnkle or IDENTITY,
}

local function crouchLegPoseBase(jointName: string, crouchBlend: number, roleSwap: number): CFrame
	local authoredPose = CrouchPose[jointName] or IDENTITY
	local oppositePose = oppositeCrouchLegPose[jointName] or authoredPose
	local movingPose = authoredPose:Lerp(oppositePose, math.clamp(roleSwap, 0, 1))
	return IDENTITY:Lerp(movingPose, math.clamp(crouchBlend, 0, 1))
end

local function stopNativeLocomotion(character: Model, animator: Animator)
	local animate = character:FindFirstChild("Animate")
	if animate and (animate:IsA("LocalScript") or animate:IsA("Script")) then
		animate.Enabled = false
	end

	for _, track in animator:GetPlayingAnimationTracks() do
		track:Stop(0.12)
	end
end

function ControllerModule.new(player: Player, character: Model, config: LocomotionConfig): (Controller?, string?)
	local rig, rigError = RigModule.create(character)
	if not rig then
		return nil, rigError
	end

	stopNativeLocomotion(character, rig.Animator)

	local raycastParams = RaycastParams.new()
	raycastParams.FilterType = Enum.RaycastFilterType.Exclude
	raycastParams.FilterDescendantsInstances = { character }
	raycastParams.IgnoreWater = true
	raycastParams.RespectCanCollide = true
	local overlapParams = OverlapParams.new()
	overlapParams.FilterType = Enum.RaycastFilterType.Exclude
	overlapParams.FilterDescendantsInstances = { character }
	overlapParams.MaxParts = 16
	local initialLook = horizontal(rig.RootPart.CFrame.LookVector)
	local initialYaw = if initialLook.Magnitude > 0.001 then yawFromDirection(initialLook.Unit) else 0
	local originalAutoRotate = rig.Humanoid.AutoRotate
	rig.Humanoid.AutoRotate = false
	local currentCamera = workspace.CurrentCamera
	local originalCameraType = if currentCamera then currentCamera.CameraType else Enum.CameraType.Custom

	local self = setmetatable({
		Player = player,
		Rig = rig,
		Config = config,
		Connections = {},
		VisibilityBindingName = "R15BodyVisibility_" .. tostring(player.UserId),
		RaycastParams = raycastParams,
		OverlapParams = overlapParams,
		Sprinting = false,
		CrouchRequested = false,
		Crouching = false,
		CrouchBlocked = false,
		Destroyed = false,
		OriginalAutoRotate = originalAutoRotate,
		OriginalHipHeight = rig.Humanoid.HipHeight,
		OriginalMouseSensitivity = UserInputService.MouseDeltaSensitivity,
		OriginalCameraType = originalCameraType,
		GaitPhase = 0,
		AuthoredWalkBlend = 0,
		AuthoredGroundLockBlend = 0,
		AuthoredWalkPose = {},
		GroundFrames = {},
		TurnStepPhase = 0,
		TurnDirection = 1,
		TurnCommitted = false,
		State = "Idle",
		MoveSpring = Spring.new(0),
		RunSpring = Spring.new(0),
		CrouchSpring = Spring.new(0),
		PelvisSpring = Spring.new(0),
		GroundLockSpring = Spring.new(0),
		CameraBobSpring = Spring.new(0),
		CameraSwaySpring = Spring.new(0),
		GaitSpeedSpring = Spring.new(0),
		StepSpeedSpring = Spring.new(1),
		AirSpring = Spring.new(0),
		FallSpring = Spring.new(0),
		TurnBlendSpring = Spring.new(0),
		DirectionXSpring = Spring.new(rig.RootPart.CFrame.LookVector.X),
		DirectionZSpring = Spring.new(rig.RootPart.CFrame.LookVector.Z),
		IdleTurnSpring = Spring.new(0),
		CameraPitchSpring = Spring.new(0),
		LowerBodyYawSpring = Spring.new(initialYaw),
		SmoothedCameraRotation = CFrame.identity,
		CameraRotationInitialized = false,
		CameraYaw = initialYaw,
		CameraPitch = 0,
		CameraTargetYaw = initialYaw,
		CameraTargetPitch = 0,
		RenderCameraSway = 0,
		RenderCameraBob = 0,
		RenderCameraForwardShift = 0,
		RenderCameraCrouchDrop = 0,
		RenderGroundLockOffset = 0,
	}, ControllerClass)
	local controller = (self :: any) :: Controller
	player:SetAttribute("LocomotionState", "Idle")
	player:SetAttribute("LocomotionRevision", "fixed-fps-neck-look-v45")
	player:SetAttribute("Crouching", false)
	player:SetAttribute("CrouchBlocked", false)

	for _, bodyPart in rig.BodyParts do
		RigModule.applyFirstPersonVisibility(bodyPart, player:GetAttribute("FirstPersonEnabled") ~= false)
	end

	table.insert(controller.Connections, character.DescendantAdded:Connect(function(descendant: Instance)
		if descendant.Name == "Animate" then
			if descendant:IsA("LocalScript") then
				descendant.Enabled = false
			elseif descendant:IsA("Script") then
				descendant.Enabled = false
			end
		end
		if descendant:IsA("BasePart") then
			table.insert(rig.BodyParts, descendant)
		end
		RigModule.applyFirstPersonVisibility(descendant, player:GetAttribute("FirstPersonEnabled") ~= false)
	end))
	table.insert(controller.Connections, player:GetAttributeChangedSignal("FirstPersonEnabled"):Connect(function()
		local firstPersonEnabled = player:GetAttribute("FirstPersonEnabled") ~= false
		controller.CameraRotationInitialized = false
		for _, bodyPart in rig.BodyParts do
			RigModule.applyFirstPersonVisibility(bodyPart, firstPersonEnabled)
		end
	end))
	table.insert(controller.Connections, UserInputService.InputChanged:Connect(function(input: InputObject)
		if player:GetAttribute("FirstPersonEnabled") == false
			or input.UserInputType ~= Enum.UserInputType.MouseMovement
			or not controller.CameraRotationInitialized then
			return
		end
		local delta = input.Delta
		controller.CameraTargetYaw -= delta.X * config.MouseRadiansPerPixel
		controller.CameraTargetPitch = math.clamp(
			controller.CameraTargetPitch - delta.Y * config.MouseRadiansPerPixel,
			-radians(config.CameraMaxPitchDegrees),
			radians(config.CameraMaxPitchDegrees)
		)
	end))
	table.insert(controller.Connections, rig.Humanoid.Died:Connect(function()
		controller:Destroy()
	end))
	table.insert(controller.Connections, rig.Animator.AnimationPlayed:Connect(function(track: AnimationTrack)
		-- This controller owns every R15 Transform. Reject late tracks from the
		-- default Animate script or any unmanaged animation-changing script.
		track:Stop(0.05)
	end))

	table.insert(controller.Connections, RunService.PreSimulation:Connect(function(deltaTime: number)
		controller:_render(deltaTime)
	end))
	RunService:BindToRenderStep(
		controller.VisibilityBindingName,
		Enum.RenderPriority.Camera.Value + 10,
		function(deltaTime: number)
			controller:_renderVisibility(deltaTime)
		end
	)

	return controller, nil
end

function ControllerClass.SetSprinting(self: Controller, enabled: boolean)
	self.Sprinting = enabled
end

function ControllerClass.SetCrouching(self: Controller, enabled: boolean)
	if self.Destroyed then
		return
	end
	self.CrouchRequested = enabled
	if enabled then
		self.Crouching = true
		self.CrouchBlocked = false
		self.Player:SetAttribute("Crouching", true)
		self.Player:SetAttribute("CrouchBlocked", false)
	end
end

function ControllerClass._canStand(self: Controller): boolean
	local rig = self.Rig
	local config = self.Config
	local hipHeightRise = math.max(0, self.OriginalHipHeight - rig.Humanoid.HipHeight)
	local poseRise = math.max(0, -(CrouchPose.Root or IDENTITY).Position.Y)
		* math.clamp(self.CrouchSpring.Position, 0, 1)
	local totalRise = hipHeightRise + poseRise
	if totalRise <= 0.025 then
		return true
	end

	-- Only query the volume that the head and shoulders will newly occupy as
	-- HipHeight raises the character. This avoids treating the floor beside the
	-- crouched body as an overhead blocker.
	local padding = config.StandClearancePadding
	local shoulderWidth = math.max(rig.RootPart.Size.X, rig.LowerTorso.Size.X, rig.Head.Size.X) + padding * 2
	local bodyDepth = math.max(rig.RootPart.Size.Z, rig.LowerTorso.Size.Z, rig.Head.Size.Z) + padding * 2
	local currentTop = rig.RootPart.Position.Y + rig.CameraAnchorHeight + rig.Head.Size.Y * 0.5 - poseRise
	local clearanceSize = Vector3.new(shoulderWidth, totalRise + padding * 2, bodyDepth)
	local clearanceCenter = Vector3.new(
		rig.RootPart.Position.X,
		currentTop + totalRise * 0.5,
		rig.RootPart.Position.Z
	)

	for _, part in workspace:GetPartBoundsInBox(CFrame.new(clearanceCenter), clearanceSize, self.OverlapParams) do
		if part.CanCollide then
			return false
		end
	end
	return true
end

function ControllerClass._renderVisibility(self: Controller, rawDeltaTime: number)
	if self.Destroyed then
		return
	end

	-- Roblox's camera TransparencyController changes LocalTransparencyModifier
	-- every frame in first person. This runs afterwards and keeps the R15 body
	-- visible while still hiding only the head and accessories inside the camera.
	local firstPersonEnabled = self.Player:GetAttribute("FirstPersonEnabled") ~= false
	for _, bodyPart in self.Rig.BodyParts do
		if bodyPart.Parent then
			RigModule.applyFirstPersonVisibility(bodyPart, firstPersonEnabled)
		end
	end

	local camera = workspace.CurrentCamera
	if firstPersonEnabled and camera then
		camera.CameraType = Enum.CameraType.Scriptable
		UserInputService.MouseBehavior = Enum.MouseBehavior.LockCenter
		UserInputService.MouseIconEnabled = false
		UserInputService.MouseDeltaSensitivity = self.Config.FirstPersonMouseSensitivity
		if not self.CameraRotationInitialized then
			local look = horizontal(self.Rig.RootPart.CFrame.LookVector)
			local yaw = if look.Magnitude > 0.001 then yawFromDirection(look.Unit) else 0
			self.CameraYaw = yaw
			self.CameraTargetYaw = yaw
			self.CameraPitch = 0
			self.CameraTargetPitch = 0
			self.SmoothedCameraRotation = CFrame.Angles(0, yaw, 0)
			self.CameraRotationInitialized = true
		else
			local deltaTime = math.clamp(rawDeltaTime, 0, self.Config.MaxDeltaTime)
			local alpha = 1 - math.exp(-self.Config.MouseLookSmoothFrequency * deltaTime)
			self.CameraYaw += (self.CameraTargetYaw - self.CameraYaw) * alpha
			self.CameraPitch += (self.CameraTargetPitch - self.CameraPitch) * alpha
			self.SmoothedCameraRotation = CFrame.Angles(0, self.CameraYaw, 0)
				* CFrame.Angles(self.CameraPitch, 0, 0)
		end
		-- This is the same fixed-anchor formula as the plugin. Pitch changes only
		-- rotation, never position, and animated Root/Ground Lock translations do
		-- not drag the FPS camera vertically. Bob remains an intentional camera
		-- effect rather than motion inherited from an attached body part.
		local yawRotation = CFrame.Angles(0, self.CameraYaw, 0)
		local horizontalForward = horizontal(yawRotation.LookVector)
		if horizontalForward.Magnitude <= 0.001 then
			horizontalForward = horizontal(self.Rig.RootPart.CFrame.LookVector)
		end
		if horizontalForward.Magnitude > 0.001 then
			horizontalForward = horizontalForward.Unit
		end
		local cameraPosition = self.Rig.RootPart.Position
			+ UP * (
				self.Rig.CameraAnchorHeight
				+ self.Config.CameraUpOffset
				+ self.RenderCameraBob
				- self.RenderCameraCrouchDrop
			)
			+ yawRotation.RightVector * self.RenderCameraSway
			+ horizontalForward * (self.Config.CameraForwardOffset + self.RenderCameraForwardShift)
		camera.CFrame = CFrame.new(cameraPosition) * self.SmoothedCameraRotation
		camera.Focus = CFrame.new(cameraPosition + self.SmoothedCameraRotation.LookVector * 12)
	else
		if camera then camera.CameraType = self.OriginalCameraType end
		UserInputService.MouseBehavior = Enum.MouseBehavior.Default
		UserInputService.MouseIconEnabled = true
		UserInputService.MouseDeltaSensitivity = self.OriginalMouseSensitivity
		self.CameraRotationInitialized = false
	end
end

function ControllerClass._probeFoot(
	self: Controller,
	restFootLocal: Vector3,
	phase: number,
	moveDirection: Vector3,
	strideScale: number
): GroundSample
	local rig = self.Rig
	local config = self.Config
	local leadDistance = rig.LegLength * strideScale * phase
	local expectedPosition = rig.RootPart.CFrame:PointToWorldSpace(restFootLocal) + moveDirection * leadDistance
	local probeHeight = rig.LegLength * config.ProbeHeightScale
	local probeDepth = rig.LegLength * config.ProbeDepthScale
	local result = workspace:Raycast(expectedPosition + UP * probeHeight, -UP * (probeHeight + probeDepth), self.RaycastParams)

	if not result or not result.Instance.CanCollide then
		return { Valid = false, HeightError = 0, SurfaceY = 0, Pitch = 0, Roll = 0 }
	end

	local slopeAngle = math.deg(math.acos(math.clamp(result.Normal:Dot(UP), -1, 1)))
	if slopeAngle > config.MaxSlopeAngle then
		return { Valid = false, HeightError = 0, SurfaceY = 0, Pitch = 0, Roll = 0 }
	end

	local localNormal = rig.RootPart.CFrame:VectorToObjectSpace(result.Normal)
	local maxTilt = radians(config.MaxFootTiltDegrees)
	local pitch = math.clamp(math.atan2(localNormal.Z, localNormal.Y), -maxTilt, maxTilt)
	local roll = math.clamp(-math.atan2(localNormal.X, localNormal.Y), -maxTilt, maxTilt)
	local averageFootHeight = (rig.LeftFoot.Size.Y + rig.RightFoot.Size.Y) * 0.5
	local footBottom = expectedPosition.Y - averageFootHeight * 0.5
	local heightError = result.Position.Y - footBottom

	return {
		Valid = true,
		HeightError = math.clamp(heightError, -rig.LegLength * 0.25, rig.LegLength * 0.25),
		SurfaceY = result.Position.Y,
		Pitch = pitch,
		Roll = roll,
	}
end

function ControllerClass._probeLegObstacle(
	self: Controller,
	foot: BasePart,
	restFootLocal: Vector3,
	phase: number,
	recovery: number,
	moveDirection: Vector3,
	strideScale: number
): number
	if recovery <= 0.04 then
		return 0
	end

	local rig = self.Rig
	local config = self.Config
	local radius = math.clamp(
		math.min(foot.Size.X, foot.Size.Z) * config.CollisionProbeRadiusScale,
		0.08,
		0.35
	)
	local origin = foot.Position + UP * (radius * 1.15)
	local stride = moveDirection * (rig.LegLength * strideScale * phase)
	local clearance = UP * (rig.LegLength * config.CollisionClearanceScale * recovery)
	local target = rig.RootPart.CFrame:PointToWorldSpace(restFootLocal) + stride + clearance
	local direction = target - origin
	local distance = direction.Magnitude
	if distance <= 0.05 then
		return 0
	end

	local result = workspace:Spherecast(origin, radius, direction, self.RaycastParams)
	if not result or not result.Instance.CanCollide then
		return 0
	end

	-- Walkable ground is handled by the terrain probes. This volume cast reacts
	-- only to wall-like faces that the swinging foot would clip into.
	local walkableNormal = math.cos(radians(config.MaxSlopeAngle))
	if result.Normal.Y >= walkableNormal then
		return 0
	end

	local proximity = 1 - math.clamp(result.Distance / distance, 0, 1)
	local requiredLift = math.clamp(
		(result.Position.Y + radius - origin.Y) / math.max(0.1, rig.LegLength * config.CollisionClearanceScale),
		0,
		1
	)
	return math.clamp(math.max(proximity, requiredLift) * recovery, 0, 1)
end

function ControllerClass._render(self: Controller, rawDeltaTime: number)
	if self.Destroyed then
		return
	end

	local rig = self.Rig
	local humanoid = rig.Humanoid
	if not rig.Character.Parent or not humanoid.Parent or humanoid.Health <= 0 then
		self:Destroy()
		return
	end

	local config = self.Config
	local deltaTime = math.clamp(rawDeltaTime, 0, config.MaxDeltaTime)
	local locked = self.Player:GetAttribute("MovementLocked") == true
	local grounded = isGrounded(humanoid)
	local airPoseActive = usesAirPose(humanoid)
	local airBlend = Spring.step(
		self.AirSpring,
		if airPoseActive then 1 else 0,
		config.AirTransitionFrequency,
		deltaTime
	)
	local fallingTarget = airPoseActive
		and rig.RootPart.AssemblyLinearVelocity.Y <= config.FallVelocityThreshold
	local fallBlend = Spring.step(
		self.FallSpring,
		if fallingTarget then 1 else 0,
		config.FallTransitionFrequency,
		deltaTime
	)
	local firstPersonEnabled = self.Player:GetAttribute("FirstPersonEnabled") ~= false
	local requestedMove = horizontal(humanoid.MoveDirection)
	local requestMagnitude = math.clamp(requestedMove.Magnitude, 0, 1)
	local moving = not locked and grounded and requestMagnitude > config.IdleSpeedThreshold

	if self.CrouchRequested then
		self.Crouching = true
		self.CrouchBlocked = false
	elseif self.Crouching or self.CrouchSpring.Position > 0.02 then
		if self:_canStand() then
			self.Crouching = false
			self.CrouchBlocked = false
		else
			self.Crouching = true
			self.CrouchBlocked = true
		end
	else
		self.Crouching = false
		self.CrouchBlocked = false
	end
	self.Player:SetAttribute("Crouching", self.Crouching)
	self.Player:SetAttribute("CrouchBlocked", self.CrouchBlocked)

	local crouchBlend = Spring.step(
		self.CrouchSpring,
		if self.Crouching then 1 else 0,
		config.CrouchTransitionFrequency,
		deltaTime
	)
	local crouchHipHeight = math.max(0.5, self.OriginalHipHeight - rig.LegLength * config.CrouchHipHeightReductionScale)
	humanoid.HipHeight = lerp(self.OriginalHipHeight, crouchHipHeight, crouchBlend)

	local runTarget = if moving and self.Sprinting and crouchBlend < 0.08 then 1 else 0
	local stoppedBlendFrequency = lerp(
		config.IdleTransitionSpringFrequency,
		config.CrouchStopSpringFrequency,
		crouchBlend
	)
	local movementBlendFrequency = if moving then config.BodySpringFrequency else stoppedBlendFrequency
	local moveBlend = Spring.step(self.MoveSpring, if moving then 1 else 0, movementBlendFrequency, deltaTime)
	local runBlend = Spring.step(self.RunSpring, runTarget, config.BodySpringFrequency, deltaTime)

	local standingMovementSpeed = lerp(config.WalkSpeed, config.RunSpeed, runBlend)
	local baseMovementSpeed = lerp(standingMovementSpeed, config.CrouchSpeed, crouchBlend)
	humanoid.AutoRotate = false

	local currentLowerYaw = self.LowerBodyYawSpring.Position
	local fallbackDirection = CFrame.Angles(0, currentLowerYaw, 0).LookVector
	local targetDirection = if requestMagnitude > 0.001 then requestedMove.Unit else fallbackDirection
	local smoothDirection = Vector3.new(
		Spring.step(self.DirectionXSpring, targetDirection.X, config.DirectionSpringFrequency, deltaTime),
		0,
		Spring.step(self.DirectionZSpring, targetDirection.Z, config.DirectionSpringFrequency, deltaTime)
	)
	local smoothDirectionMagnitude = math.clamp(smoothDirection.Magnitude, 0, 1)
	local moveDirection = if smoothDirection.Magnitude > 0.001 then smoothDirection.Unit else fallbackDirection

	local cameraYaw: number? = nil
	local cameraPitchTarget = 0
	local camera = workspace.CurrentCamera
	if camera then
		local cameraDirection = horizontal(camera.CFrame.LookVector)
		if cameraDirection.Magnitude > 0.001 then
			cameraYaw = yawFromDirection(cameraDirection.Unit)
		end
		if firstPersonEnabled then
			cameraPitchTarget = math.clamp(
				math.asin(math.clamp(camera.CFrame.LookVector.Y, -1, 1)),
				-radians(config.UpperTorsoMaxPitchDegrees),
				radians(config.UpperTorsoMaxPitchDegrees)
			)
		end
	end
	local upperBodyPitch = Spring.step(
		self.CameraPitchSpring,
		cameraPitchTarget,
		config.UpperTorsoFollowFrequency,
		deltaTime
	)

	local upperBodyYawTarget = 0
	local lowerBodyTargetYaw = currentLowerYaw
	local cameraError = 0
	if firstPersonEnabled and cameraYaw then
		cameraError = shortestAngle(cameraYaw, currentLowerYaw)
		upperBodyYawTarget = math.clamp(
			cameraError,
			-radians(config.IdleTorsoMaxDegrees),
			radians(config.IdleTorsoMaxDegrees)
		)
		if moving then
			lowerBodyTargetYaw = currentLowerYaw + cameraError
		end
	elseif moving then
		lowerBodyTargetYaw = currentLowerYaw + shortestAngle(yawFromDirection(moveDirection), currentLowerYaw)
	end

	local upperBodyYaw = Spring.step(
		self.IdleTurnSpring,
		upperBodyYawTarget,
		if airPoseActive then config.AirTorsoTurnFrequency else config.UpperTorsoFollowFrequency,
		deltaTime
	)
	local followThreshold = radians(config.IdleLegFollowThresholdDegrees)
	if airPoseActive then
		self.TurnCommitted = false
		-- The torso consumes the first part of the camera turn. Only after that
		-- threshold does the airborne lower body begin following, at a slow rate.
		if cameraYaw and math.abs(upperBodyYaw) >= radians(config.AirBodyFollowThresholdDegrees) then
			lowerBodyTargetYaw = currentLowerYaw + cameraError
		end
	elseif moving or not grounded or not firstPersonEnabled or not cameraYaw then
		self.TurnCommitted = false
	elseif not self.TurnCommitted and math.abs(upperBodyYaw) >= followThreshold then
		self.TurnCommitted = true
		self.TurnDirection = if cameraError >= 0 then 1 else -1
	end

	if self.TurnCommitted then
		if math.abs(cameraError) <= radians(2.5) then
			self.TurnCommitted = false
		else
			self.TurnDirection = if cameraError >= 0 then 1 else -1
			-- Once triggered, complete the turn all the way to camera-forward.
			lowerBodyTargetYaw = currentLowerYaw + cameraError
		end
	end

	local unwrappedTargetYaw = currentLowerYaw + shortestAngle(lowerBodyTargetYaw, currentLowerYaw)
	local facingFrequency = if airPoseActive
		then config.AirBodyTurnFrequency
		elseif moving then config.MovingFacingSpringFrequency
		else config.IdleLegFollowSpeed
	local lowerBodyYaw = Spring.step(self.LowerBodyYawSpring, unwrappedTargetYaw, facingFrequency, deltaTime)
	local followedYaw = lowerBodyYaw - currentLowerYaw
	if firstPersonEnabled and math.abs(followedYaw) > 0.00001 then
		upperBodyYaw -= followedYaw
		self.IdleTurnSpring.Position = upperBodyYaw
	end
	rig.RootPart.CFrame = CFrame.new(rig.RootPart.Position) * CFrame.Angles(0, lowerBodyYaw, 0)

	local turnBlend = Spring.step(
		self.TurnBlendSpring,
		if self.TurnCommitted then 1 else 0,
		config.TurnStepBlendFrequency,
		deltaTime
	)
	if self.TurnCommitted then
		self.TurnStepPhase = (self.TurnStepPhase + config.TurnStepPhaseRate * deltaTime) % (math.pi * 2)
	end
	local turnCycle = math.sin(self.TurnStepPhase) * self.TurnDirection
	local leftTurnLift = math.max(0, turnCycle) ^ 2 * turnBlend
	local rightTurnLift = math.max(0, -turnCycle) ^ 2 * turnBlend

	-- Preserve the spring's magnitude for pose blending. During a 180-degree
	-- reversal this naturally passes through neutral instead of snapping axes.
	local localMove = rig.RootPart.CFrame:VectorToObjectSpace(smoothDirection)
	local actualSpeed = horizontal(rig.RootPart.AssemblyLinearVelocity).Magnitude
	local standingTargetSpeed = lerp(config.WalkSpeed, config.RunSpeed, runBlend)
	local targetSpeed = lerp(standingTargetSpeed, config.CrouchSpeed, crouchBlend) * requestMagnitude
	local gaitSpeedTarget = if moving then math.max(actualSpeed, targetSpeed * 0.72) else 0
	local stoppedGaitFrequency = lerp(
		config.GaitDecelerationSpringFrequency,
		config.CrouchStopSpringFrequency,
		crouchBlend
	)
	local gaitSpeedFrequency = if moving then config.BodySpringFrequency else stoppedGaitFrequency
	local gaitSpeed = Spring.step(self.GaitSpeedSpring, gaitSpeedTarget, gaitSpeedFrequency, deltaTime)
	local standingPhasePerStud = lerp(config.WalkPhasePerStud, config.RunPhasePerStud, runBlend)
	local phasePerStud = lerp(standingPhasePerStud, config.CrouchPhasePerStud, crouchBlend)
	if gaitSpeed > 0.05 then
		self.GaitPhase = (self.GaitPhase + gaitSpeed * phasePerStud * deltaTime) % (math.pi * 2)
	end
	self.AuthoredWalkBlend = math.clamp(
		moveBlend * (1 - crouchBlend) * (1 - airBlend),
		0,
		1
	)
	sampleAuthoredWalk(self)

	local forwardAmount = math.clamp(-localMove.Z, -1, 1)
	local strafeAmount = math.clamp(localMove.X, -1, 1)
	local reversePhase = if forwardAmount < -0.15 then -1 else 1
	-- Running reuses the exact walking cycle shape. Only phase cadence changes;
	-- sprint no longer swaps in a separate exaggerated set of joint targets.
	local standingContactHold = config.WalkContactHoldFraction
	local contactHoldFraction = lerp(standingContactHold, config.CrouchContactHoldFraction, crouchBlend)
	local rawCycle = contactHeldGaitCycle(self.GaitPhase, contactHoldFraction) * reversePhase
	-- Preserve the contact plateau while slightly strengthening extension
	-- through the rest of the stride.
	local cycle = math.sign(rawCycle) * math.abs(rawCycle) ^ 0.82
	local leftRecovery = math.max(0, -cycle) ^ 1.25
	local rightRecovery = math.max(0, cycle) ^ 1.25
	local leftContact = math.max(0, cycle) ^ 4
	local rightContact = math.max(0, -cycle) ^ 4
	local footImpact = math.clamp(leftContact + rightContact, 0, 1)
	local midStanceRise = 1 - footImpact
	local standingStepSpeedDip = lerp(config.WalkStepSpeedDip, config.RunStepSpeedDip, runBlend)
	local stepSpeedDip = lerp(standingStepSpeedDip, config.CrouchStepSpeedDip, crouchBlend)
	-- Use a broader speed pulse than the visual heel impact. This makes weight
	-- transfer noticeable without holding/freezing the animation at contact.
	local movementStepWeight = math.abs(cycle) ^ 2
	local stepSpeedTarget = 1 - movementStepWeight * stepSpeedDip * moveBlend
	local stepSpeedScale = Spring.step(
		self.StepSpeedSpring,
		stepSpeedTarget,
		config.StepSpeedSpringFrequency,
		deltaTime
	)
	if not locked then
		humanoid.WalkSpeed = baseMovementSpeed * stepSpeedScale
	end
	local standingStrideScale = 0.145
	local strideScale = lerp(standingStrideScale, config.CrouchStrideScale, crouchBlend)
		* smoothDirectionMagnitude
		* moveBlend

	local leftGround = self:_probeFoot(rig.LeftRestFootLocal, cycle, moveDirection, strideScale)
	local rightGround = self:_probeFoot(rig.RightRestFootLocal, -cycle, moveDirection, strideScale)
	local leftObstacle = if moving
		then self:_probeLegObstacle(rig.LeftFoot, rig.LeftRestFootLocal, cycle, leftRecovery, moveDirection, strideScale)
		else 0
	local rightObstacle = if moving
		then self:_probeLegObstacle(rig.RightFoot, rig.RightRestFootLocal, -cycle, rightRecovery, moveDirection, strideScale)
		else 0
	local terrainBlend = if grounded then lerp(0.45, 1, moveBlend) else 0
	local leftHeight = if leftGround.Valid then leftGround.HeightError else 0
	local rightHeight = if rightGround.Valid then rightGround.HeightError else 0
	local leftSupport = if leftGround.Valid then 0.5 + cycle * 0.5 else 0
	local rightSupport = if rightGround.Valid then 0.5 - cycle * 0.5 else 0
	local supportWeight = leftSupport + rightSupport
	local supportHeight = if supportWeight > 0.001
		then (leftHeight * leftSupport + rightHeight * rightSupport) / supportWeight
		else 0
	local pelvisTarget = math.clamp(
		supportHeight,
		-rig.LegLength * config.MaxPelvisDropScale,
		rig.LegLength * config.MaxPelvisRiseScale
	) * terrainBlend
	local pelvisDrop = Spring.step(self.PelvisSpring, pelvisTarget, config.TerrainSpringFrequency, deltaTime)

	local standingHipSwing = config.WalkHipSwingDegrees
	local hipSwing = radians(standingHipSwing) * moveBlend * (1 - self.AuthoredWalkBlend * 0.86)
	local hipYaw = radians(config.WalkHipYawDegrees) * moveBlend
	local standingKneeBend = config.WalkKneeBendDegrees
	local kneeBend = radians(standingKneeBend) * moveBlend * (1 - self.AuthoredWalkBlend * 0.86)
	local ankleFlex = radians(config.WalkAnkleFlexDegrees) * moveBlend * (1 - self.AuthoredWalkBlend * 0.82)
	local standingArmSwing = config.WalkArmSwingDegrees
	local armSwing = radians(lerp(standingArmSwing, 8, crouchBlend)) * moveBlend * (1 - self.AuthoredWalkBlend * 0.88)
	local shoulderRoll = radians(config.WalkShoulderRollDegrees) * moveBlend * (1 - self.AuthoredWalkBlend * 0.82)
	local elbowBend = radians(config.WalkElbowBendDegrees) * moveBlend * (1 - self.AuthoredWalkBlend * 0.82)
	local standingTorsoTwist = config.WalkTorsoTwistDegrees
	local torsoTwist = radians(lerp(standingTorsoTwist, 3, crouchBlend)) * moveBlend
	local crouchTurnMultiplier = lerp(1, config.CrouchTurnScale, crouchBlend)
	local turnHipSwing = radians(config.TurnStepHipSwingDegrees) * crouchTurnMultiplier
	local turnHipYaw = radians(config.TurnStepHipYawDegrees) * crouchTurnMultiplier
	local turnKneeBend = radians(config.TurnStepKneeBendDegrees) * crouchTurnMultiplier
	local turnAnkleFlex = radians(config.TurnStepAnkleFlexDegrees) * crouchTurnMultiplier
	local crouchStrafeDirectionalScale = lerp(0.72, 1, crouchBlend)
	local directionalStrength = math.max(
		math.abs(forwardAmount),
		math.abs(strafeAmount) * crouchStrafeDirectionalScale
	)
	local leftHipPitch = cycle * hipSwing * directionalStrength
	local rightHipPitch = -cycle * hipSwing * directionalStrength
	local hipStrafeScale = lerp(0.38, config.CrouchStrafeHipScale, crouchBlend)
	local hipStrafe = cycle * hipSwing * hipStrafeScale * strafeAmount
	local hipTurn = cycle * hipYaw * (0.35 + math.abs(strafeAmount) * 0.65)

	local leftTerrainKnee = radians(math.clamp(
		math.max(0, leftHeight) * config.TerrainKneeDegreesPerStud,
		0,
		config.MaxTerrainKneeDegrees
	)) * terrainBlend
	local rightTerrainKnee = radians(math.clamp(
		math.max(0, rightHeight) * config.TerrainKneeDegreesPerStud,
		0,
		config.MaxTerrainKneeDegrees
	)) * terrainBlend

	local clock = os.clock()
	local idleStrength = if grounded then math.clamp(1 - moveBlend, 0, 1) else 0
	local idleWaveA = math.sin(clock * 0.73) * 0.62 + math.sin(clock * 1.37 + 0.8) * 0.28
	local idleWaveB = math.sin(clock * 0.47 + 1.9) * 0.58 + math.sin(clock * 1.11 + 2.6) * 0.24
	local idleShiftX = idleWaveA * rig.LegLength * config.IdleWeightShiftScale * idleStrength
	local idleShiftZ = idleWaveB * rig.LegLength * config.IdleWeightShiftScale * 0.42 * idleStrength
	local idleRoll = idleWaveA * radians(config.IdleSwayDegrees) * idleStrength
	local idlePitch = idleWaveB * radians(config.IdleSwayDegrees) * 0.42 * idleStrength
	local idleHipPitch = idleWaveB * radians(config.IdleSwayDegrees) * 0.65 * idleStrength
	local idleKnee = radians(config.IdleKneeBendDegrees) * idleStrength
	local leftIdleKnee = idleKnee * (0.45 + math.max(0, idleWaveA) * 0.55)
	local rightIdleKnee = idleKnee * (0.45 + math.max(0, -idleWaveA) * 0.55)

	local contactCompression = radians(config.ContactKneeCompressionDegrees) * moveBlend
	local collisionKneeBend = radians(config.CollisionKneeBendDegrees) * moveBlend
	local maxKneeBend = radians(125)
	local leftKneeAngle = math.clamp(
		leftRecovery * kneeBend
			+ leftContact * contactCompression
			+ leftTerrainKnee
			+ leftObstacle * collisionKneeBend
			+ leftIdleKnee
			+ leftTurnLift * turnKneeBend,
		0,
		maxKneeBend
	)
	local rightKneeAngle = math.clamp(
		rightRecovery * kneeBend
			+ rightContact * contactCompression
			+ rightTerrainKnee
			+ rightObstacle * collisionKneeBend
			+ rightIdleKnee
			+ rightTurnLift * turnKneeBend,
		0,
		maxKneeBend
	)
	local maxAnkleAngle = radians(config.MaxFootTiltDegrees)
	local collisionAnkleFlex = radians(config.CollisionAnkleFlexDegrees) * moveBlend
	local leftAnklePitch = math.clamp(
		leftGround.Pitch * terrainBlend
			+ leftRecovery * ankleFlex
			- leftContact * ankleFlex * 0.45
			+ leftObstacle * collisionAnkleFlex
			- idleHipPitch * 0.65
			+ leftTurnLift * turnAnkleFlex,
		-maxAnkleAngle,
		maxAnkleAngle
	)
	local rightAnklePitch = math.clamp(
		rightGround.Pitch * terrainBlend
			+ rightRecovery * ankleFlex
			- rightContact * ankleFlex * 0.45
			+ rightObstacle * collisionAnkleFlex
			+ idleHipPitch * 0.55
			+ rightTurnLift * turnAnkleFlex,
		-maxAnkleAngle,
		maxAnkleAngle
	)

	-- The authored crouch is a right-leg-leading lunge. While moving, smoothly
	-- exchange the lead and trailing roles instead of merely bending both knees
	-- around that permanently asymmetric pose. The contact-held cycle supplies
	-- the planted pauses visible in the reference sequence.
	local crouchSwap = smoothstep(cycle * 0.5 + 0.5) * moveBlend
	local crouchTransition = (1 - math.abs(cycle)) * moveBlend
	local phaseVelocity = math.cos(self.GaitPhase) * reversePhase
	local leftCrouchSwing = math.max(0, phaseVelocity) * crouchTransition
	local rightCrouchSwing = math.max(0, -phaseVelocity) * crouchTransition
	local leftCrouchLead = math.max(0, cycle) ^ 1.35 * moveBlend
	local rightCrouchLead = math.max(0, -cycle) ^ 1.35 * moveBlend
	local strafeKneeMultiplier = 1 + math.abs(strafeAmount) * config.CrouchStrafeKneeBoost
	local transitionHipLift = radians(config.CrouchTransitionHipLiftDegrees)
	local transitionKneeLift = radians(config.CrouchTransitionKneeLiftDegrees) * strafeKneeMultiplier
	local leadLowerLegForward = radians(config.CrouchLeadLowerLegForwardDegrees)

	local leftCrouchHipPitch = leftCrouchSwing * transitionHipLift
	local rightCrouchHipPitch = rightCrouchSwing * transitionHipLift
	local leftCrouchKneePitch = -leftCrouchSwing * transitionKneeLift
		+ leftCrouchLead * leadLowerLegForward
		- leftTerrainKnee
		- leftObstacle * collisionKneeBend
		- leftTurnLift * turnKneeBend
	local rightCrouchKneePitch = -rightCrouchSwing * transitionKneeLift
		+ rightCrouchLead * leadLowerLegForward
		- rightTerrainKnee
		- rightObstacle * collisionKneeBend
		- rightTurnLift * turnKneeBend
	local leftCrouchAnklePitch = leftGround.Pitch * terrainBlend
		+ leftObstacle * collisionAnkleFlex
		+ leftTurnLift * turnAnkleFlex
	local rightCrouchAnklePitch = rightGround.Pitch * terrainBlend
		+ rightObstacle * collisionAnkleFlex
		+ rightTurnLift * turnAnkleFlex

	local finalLeftHipPitch = lerp(leftHipPitch, leftCrouchHipPitch, crouchBlend)
	local finalRightHipPitch = lerp(rightHipPitch, rightCrouchHipPitch, crouchBlend)
	local finalLeftKneePitch = lerp(-leftKneeAngle, leftCrouchKneePitch, crouchBlend)
	local finalRightKneePitch = lerp(-rightKneeAngle, rightCrouchKneePitch, crouchBlend)
	local finalLeftAnklePitch = lerp(leftAnklePitch, leftCrouchAnklePitch, crouchBlend)
	local finalRightAnklePitch = lerp(rightAnklePitch, rightCrouchAnklePitch, crouchBlend)

	local turnPelvisBob = -math.abs(math.sin(self.TurnStepPhase))
		* rig.LegLength
		* config.TurnStepPelvisScale
		* turnBlend
	local gaitVertical = (
		midStanceRise * config.PelvisBobScale
			- footImpact * config.PelvisImpactDropScale
	) * rig.LegLength * moveBlend * lerp(1, 0.58, crouchBlend)
	-- Raise the capsule a few hundredths of a stud at the deepest lunge. The
	-- generic contact impact already supplies the downward half of the motion;
	-- this clearance term prevents the trailing knee/foot from crossing ground.
	local crouchGroundClearance = (0.25 + math.abs(cycle) * 0.75)
		* config.CrouchGroundClearanceScale
		* rig.LegLength
		* moveBlend
		* crouchBlend
	local bob = gaitVertical + crouchGroundClearance + turnPelvisBob
	local pelvisSwayScale = lerp(config.PelvisSwayScale, config.CrouchPelvisSwayScale, crouchBlend)
	local pelvisSway = -cycle * rig.LegLength * pelvisSwayScale * moveBlend + idleShiftX
	-- Root yaw makes the entire crouched silhouette rotate on every step. Keep
	-- that counter-twist for standing locomotion only.
	local pelvisTwist = cycle * radians(config.PelvisTwistDegrees) * moveBlend * (1 - crouchBlend)
	local standingLean = config.ForwardLeanDegrees
	local lean = radians(lerp(standingLean, config.CrouchLeanDegrees, crouchBlend)) * moveBlend
	local strafeLean = radians(config.StrafeLeanDegrees) * strafeAmount * moveBlend
	local breath = (math.sin(clock * 1.8) * 0.72 + math.sin(clock * 0.89 + 0.4) * 0.28)
		* radians(0.9)
		* idleStrength
	-- First-person look rotation belongs entirely to the neck/head. The Waist
	-- retains locomotion, breathing, and balance motion but never follows the
	-- FPS camera horizontally or vertically.
	local neckCameraPitch = upperBodyPitch
	local horizontalTorsoBlend = 1 - crouchBlend * (1 - airBlend)
	local neckCameraYaw = upperBodyYaw * horizontalTorsoBlend
	local waistPitch = breath + lean * 0.38 - idlePitch * 0.45
	local waistYaw = (cycle * torsoTwist + pelvisTwist * 0.4) * horizontalTorsoBlend
	local waistRoll = -strafeLean * 0.65 - idleRoll * 0.72
	local waistRotation = CFrame.Angles(waistPitch, waistYaw, waistRoll)
	-- The crouch arms have a fixed downward pose. Counter the waist rotation so
	-- camera-follow and procedural torso lean do not drag that pose around.
	local crouchArmTorsoCounter = IDENTITY:Lerp(waistRotation:Inverse(), crouchBlend)
	local downLookRatio = math.clamp(
		-upperBodyPitch / math.max(0.001, radians(config.UpperTorsoMaxPitchDegrees)),
		0,
		1
	)
	local upLookRatio = math.clamp(
		upperBodyPitch / math.max(0.001, radians(config.UpperTorsoMaxPitchDegrees)),
		0,
		1
	)
	local upperTorsoForwardOffset = downLookRatio * rig.LegLength * config.LookDownTorsoForwardScale
	local upLookCameraClearance = upLookRatio
		* rig.LegLength
		* config.CrouchLookUpCameraForwardScale
		* crouchBlend
	self.RenderCameraForwardShift = upperTorsoForwardOffset + upLookCameraClearance
	self.RenderCameraCrouchDrop = (
		rig.LegLength * config.CrouchCameraDropScale
			+ math.max(0, -(CrouchPose.Root or IDENTITY).Position.Y)
	) * crouchBlend

	writeJoint(
		rig,
		rig.Joints.Root,
		authoredWalkBase(self, "Root")
			* crouchPoseBase("Root", crouchBlend)
			* CFrame.new(pelvisSway, pelvisDrop + bob, idleShiftZ)
			* CFrame.Angles(
				-lean + idlePitch,
				-pelvisTwist,
				-strafeLean * 0.35 + idleRoll * 0.35
			)
	)
	writeJoint(
		rig,
		rig.Joints.Waist,
		authoredWalkBase(self, "Waist")
			* crouchPoseBase("Waist", crouchBlend)
			* CFrame.new(0, 0, -upperTorsoForwardOffset)
			* waistRotation
	)
	writeJoint(
		rig,
		rig.Joints.Neck,
		authoredWalkBase(self, "Neck") * crouchPoseBase("Neck", crouchBlend) * CFrame.Angles(
			-breath * 0.55 - lean * 0.2 + neckCameraPitch,
			-cycle * torsoTwist * 0.35 * horizontalTorsoBlend + neckCameraYaw,
			strafeLean * 0.22 + idleRoll * 0.25
		)
	)

	writeJoint(
		rig,
		rig.Joints.LeftHip,
		authoredWalkBase(self, "LeftHip") * crouchLegPoseBase("LeftHip", crouchBlend, crouchSwap) * CFrame.Angles(
			finalLeftHipPitch + idleHipPitch * 0.55 - leftTurnLift * turnHipSwing,
			-hipTurn + self.TurnDirection * leftTurnLift * turnHipYaw,
			hipStrafe - idleRoll * 0.24
		)
	)
	writeJoint(
		rig,
		rig.Joints.RightHip,
		authoredWalkBase(self, "RightHip") * crouchLegPoseBase("RightHip", crouchBlend, crouchSwap) * CFrame.Angles(
			finalRightHipPitch - idleHipPitch * 0.45 - rightTurnLift * turnHipSwing,
			hipTurn + self.TurnDirection * rightTurnLift * turnHipYaw,
			hipStrafe - idleRoll * 0.12
		)
	)
	writeJoint(
		rig,
		rig.Joints.LeftKnee,
		authoredWalkBase(self, "LeftKnee")
			* crouchLegPoseBase("LeftKnee", crouchBlend, crouchSwap)
			* CFrame.Angles(finalLeftKneePitch, 0, 0)
	)
	writeJoint(
		rig,
		rig.Joints.RightKnee,
		authoredWalkBase(self, "RightKnee")
			* crouchLegPoseBase("RightKnee", crouchBlend, crouchSwap)
			* CFrame.Angles(finalRightKneePitch, 0, 0)
	)
	writeJoint(
		rig,
		rig.Joints.LeftAnkle,
		authoredWalkBase(self, "LeftAnkle")
			* crouchLegPoseBase("LeftAnkle", crouchBlend, crouchSwap)
			* CFrame.Angles(finalLeftAnklePitch, 0, leftGround.Roll * terrainBlend + idleRoll * 0.10)
	)
	writeJoint(
		rig,
		rig.Joints.RightAnkle,
		authoredWalkBase(self, "RightAnkle")
			* crouchLegPoseBase("RightAnkle", crouchBlend, crouchSwap)
			* CFrame.Angles(finalRightAnklePitch, 0, rightGround.Roll * terrainBlend + idleRoll * 0.08)
	)

	-- Arms counter-swing the legs. Elbows flex more on the rearward recovery stroke.
	local idleLeftArm = (math.sin(clock * 0.61 + 0.3) * 0.7 + idleWaveB * 0.3) * radians(1.6) * idleStrength
	local idleRightArm = (math.sin(clock * 0.53 + 2.1) * 0.65 - idleWaveB * 0.35) * radians(1.4) * idleStrength
	local idleLeftElbow = radians(2.8) * idleStrength * (0.8 + idleWaveA * 0.2)
	local idleRightElbow = radians(4.2) * idleStrength * (0.8 - idleWaveA * 0.2)
	local standingArmDynamicBlend = 1 - crouchBlend
	writeJoint(
		rig,
		rig.Joints.LeftShoulder,
		crouchArmTorsoCounter * authoredWalkBase(self, "LeftShoulder") * crouchPoseBase("LeftShoulder", crouchBlend) * CFrame.Angles(
			(-cycle * armSwing + idleLeftArm)
				* standingArmDynamicBlend,
			(-cycle * torsoTwist * 0.22)
				* standingArmDynamicBlend,
			(-shoulderRoll * (0.55 + rightRecovery * 0.45) - idleRoll * 0.3) * standingArmDynamicBlend
		)
	)
	writeJoint(
		rig,
		rig.Joints.RightShoulder,
		crouchArmTorsoCounter * authoredWalkBase(self, "RightShoulder") * crouchPoseBase("RightShoulder", crouchBlend) * CFrame.Angles(
			(cycle * armSwing + idleRightArm)
				* standingArmDynamicBlend,
			(-cycle * torsoTwist * 0.22)
				* standingArmDynamicBlend,
			shoulderRoll * (0.55 + leftRecovery * 0.45)
				* standingArmDynamicBlend
				- idleRoll * 0.3 * standingArmDynamicBlend
		)
	)
	writeJoint(
		rig,
		rig.Joints.LeftElbow,
		authoredWalkBase(self, "LeftElbow") * crouchPoseBase("LeftElbow", crouchBlend) * CFrame.Angles(
			-(radians(7) * moveBlend
				+ rightRecovery * elbowBend
				+ idleLeftElbow) * standingArmDynamicBlend,
			0,
			0
		)
	)
	writeJoint(
		rig,
		rig.Joints.RightElbow,
		authoredWalkBase(self, "RightElbow") * crouchPoseBase("RightElbow", crouchBlend) * CFrame.Angles(
			-(radians(7) * moveBlend
				+ leftRecovery * elbowBend
				+ idleRightElbow) * standingArmDynamicBlend,
			0,
			0
		)
	)
	writeJoint(rig, rig.Joints.LeftWrist, authoredWalkBase(self, "LeftWrist") * crouchPoseBase("LeftWrist", crouchBlend))
	writeJoint(rig, rig.Joints.RightWrist, authoredWalkBase(self, "RightWrist") * crouchPoseBase("RightWrist", crouchBlend))

	-- Blend the cached ground locomotion result into the authored airborne pose.
	-- This runs after every procedural joint has been prepared, so takeoff and
	-- landing transition cleanly from standing or crouched locomotion.
	blendJointToAir(rig, rig.Joints.Root, "Root", airBlend, fallBlend)
	-- Waist and neck retain the camera-follow result above, allowing the torso
	-- to lead a mid-air turn before the root catches up.
	blendJointToAir(rig, rig.Joints.LeftShoulder, "LeftShoulder", airBlend, fallBlend)
	blendJointToAir(rig, rig.Joints.LeftElbow, "LeftElbow", airBlend, fallBlend)
	blendJointToAir(rig, rig.Joints.LeftWrist, "LeftWrist", airBlend, fallBlend)
	blendJointToAir(rig, rig.Joints.RightShoulder, "RightShoulder", airBlend, fallBlend)
	blendJointToAir(rig, rig.Joints.RightElbow, "RightElbow", airBlend, fallBlend)
	blendJointToAir(rig, rig.Joints.RightWrist, "RightWrist", airBlend, fallBlend)
	blendJointToAir(rig, rig.Joints.LeftHip, "LeftHip", airBlend, fallBlend)
	blendJointToAir(rig, rig.Joints.LeftKnee, "LeftKnee", airBlend, fallBlend)
	blendJointToAir(rig, rig.Joints.LeftAnkle, "LeftAnkle", airBlend, fallBlend)
	blendJointToAir(rig, rig.Joints.RightHip, "RightHip", airBlend, fallBlend)
	blendJointToAir(rig, rig.Joints.RightKnee, "RightKnee", airBlend, fallBlend)
	blendJointToAir(rig, rig.Joints.RightAnkle, "RightAnkle", airBlend, fallBlend)

	-- Apply the exported per-key Ground Lock after every animation layer has
	-- settled. It offsets only the visual Root Motor, so Humanoid collision and
	-- terrain physics remain authoritative while the lowest posed body part
	-- stays on the supporting surface exactly as it does in the pose tuner.
	updateRuntimeGroundLock(self, leftGround, rightGround, cycle, grounded, deltaTime)

	updateCameraMotion(
		self,
		grounded,
		firstPersonEnabled,
		moveBlend,
		runBlend,
		crouchBlend,
		cycle,
		midStanceRise,
		footImpact,
		deltaTime
	)

	local nextState = if airPoseActive
		then (if fallBlend > 0.5 then "Fall" else "Jump")
		elseif not grounded
		then "Air"
		elseif crouchBlend > 0.5
		then (if moveBlend > 0.12 then "CrouchWalk" else "CrouchIdle")
		elseif runBlend > 0.5
		then "Run"
		elseif moveBlend > 0.12 then "Walk"
		else "Idle"
	if nextState ~= self.State then
		self.State = nextState
		self.Player:SetAttribute("LocomotionState", nextState)
	end
end

function ControllerClass.Destroy(self: Controller)
	if self.Destroyed then
		return
	end
	self.Destroyed = true

	RunService:UnbindFromRenderStep(self.VisibilityBindingName)
	for _, connection in self.Connections do
		connection:Disconnect()
	end
	table.clear(self.Connections)
	if self.Rig.Humanoid.Parent then
		self.Rig.Humanoid.AutoRotate = self.OriginalAutoRotate
		self.Rig.Humanoid.HipHeight = self.OriginalHipHeight
	end
	self.Player:SetAttribute("Crouching", false)
	self.Player:SetAttribute("CrouchBlocked", false)
	local camera = workspace.CurrentCamera
	if camera then camera.CameraType = self.OriginalCameraType end
	UserInputService.MouseBehavior = Enum.MouseBehavior.Default
	UserInputService.MouseIconEnabled = true
	UserInputService.MouseDeltaSensitivity = self.OriginalMouseSensitivity
	RigModule.restore(self.Rig)
end

return ControllerModule
