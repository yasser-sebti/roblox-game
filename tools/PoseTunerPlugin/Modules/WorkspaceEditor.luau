--!strict

local CoreGui = game:GetService("CoreGui")
local RunService = game:GetService("RunService")
local Selection = game:GetService("Selection")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")

local FirstPersonViewConfig = require(script.Parent.Parent.FirstPersonViewConfig)

export type Pose = { [string]: CFrame }
export type EditorMode = "Move" | "Rotate" | "IK"
export type AxisSpace = "Local" | "World"

type Callbacks = {
	OnSelectionChanged: ((string) -> ())?, OnSelectionCleared: (() -> ())?, OnEditBegin: (() -> ())?,
	OnPoseChanged: ((Pose) -> ())?, OnEditEnd: (() -> ())?,
	OnStatus: ((string, boolean?) -> ())?, OnGuide: ((string) -> ())?,
	OnSceneRebuilt: (() -> ())?,
}

local Editor = {}
Editor.__index = Editor

local ARENA_CENTER = Vector3.new(0, 1500, 0)
local IK_CHAINS = {
	LeftWrist = { Root = "LeftUpperArm", EndPart = "LeftHand", Joints = { "LeftShoulder", "LeftElbow", "LeftWrist" }, Pole = Vector3.new(-1.4, 0, -2) },
	RightWrist = { Root = "RightUpperArm", EndPart = "RightHand", Joints = { "RightShoulder", "RightElbow", "RightWrist" }, Pole = Vector3.new(1.4, 0, -2) },
	LeftAnkle = { Root = "LeftUpperLeg", EndPart = "LeftFoot", Joints = { "LeftHip", "LeftKnee", "LeftAnkle" }, Pole = Vector3.new(-0.7, 0, -2) },
	RightAnkle = { Root = "RightUpperLeg", EndPart = "RightFoot", Joints = { "RightHip", "RightKnee", "RightAnkle" }, Pole = Vector3.new(0.7, 0, -2) },
}

local function canonical(name: string): string return if name == "RootJoint" then "Root" else name end
local function axisFromFace(face: Enum.NormalId): Vector3 return Vector3.FromNormalId(face) end
local function axisFromArc(axis: Enum.Axis): Vector3
	if axis == Enum.Axis.X then return Vector3.xAxis elseif axis == Enum.Axis.Y then return Vector3.yAxis else return Vector3.zAxis end
end

local function stripScripts(model: Model)
	for _, item in model:GetDescendants() do
		if item:IsA("LuaSourceContainer") or item:IsA("Tool") or item:IsA("IKControl") then item:Destroy() end
	end
end

local function configure(model: Model, ghost: boolean?)
	for _, item in model:GetDescendants() do
		if item:IsA("BasePart") then
			item.Anchored = item.Name == "HumanoidRootPart"
			item.CanCollide = false; item.CanTouch = false; item.CanQuery = not ghost; item.Massless = true; item.Locked = true
			if ghost then item.Transparency = math.max(item.Transparency, 0.78) end
		end
	end
end

function Editor.new(pluginObject: Plugin, callbacks: Callbacks)
	local self = setmetatable({}, Editor)
	self.Plugin = pluginObject; self.Callbacks = callbacks
	self.Mode = "Move" :: EditorMode; self.AxisSpace = "Local" :: AxisSpace; self.SelectedJoint = "Root"; self.SelectionActive = false
	self.Pose = {} :: Pose; self.Motors = {} :: { [string]: Motor6D }; self.RestC0 = {} :: { [string]: CFrame }; self.PartToJoint = {} :: { [BasePart]: string }
	self.Dummy = nil :: Model?; self.Arena = nil :: Folder?; self.Floor = nil :: Part?; self.Pivot = nil :: Part?
	self.Highlight = nil :: Highlight?; self.HoverHighlight = nil :: Highlight?; self.MoveHandles = nil :: Handles?; self.RotateHandles = nil :: ArcHandles?
	self.ActiveIK = nil :: IKControl?; self.IKTarget = nil :: Part?; self.IKPole = nil :: Part?; self.OnionFolder = nil :: Folder?
	self.Connections = {} :: { RBXScriptConnection }; self.Dragging = false
	self.DirectDrag = nil :: any
	self.GridParts = {} :: { Part }; self.SourceTemplate = nil :: Model?; self.SavedCamera = nil :: any
	self.JointHitboxes = {} :: { Part }; self.HitboxToJoint = {} :: { [BasePart]: string }
	self.DestroyingScene = false; self.Rebuilding = false; self.HealthAccumulator = 0
	self.SnapEnabled = true; self.MoveSnap = 0.02; self.RotateSnap = 2
	self.GroundLockEnabled = true; self.GroundLockBlend = 1; self.BaseRootCFrame = nil :: CFrame?
	self.FirstPersonEnabled = false; self.FirstPersonCameraState = nil :: any; self.FirstPersonInputState = nil :: any
	self.FirstPersonYaw = 0; self.FirstPersonPitch = 0; self.FirstPersonTargetYaw = 0; self.FirstPersonTargetPitch = 0
	self.FirstPersonRotation = CFrame.identity; self.CameraAnchorHeight = 0
	self.FirstPersonHidden = {} :: { [BasePart]: number }
	return self
end

function Editor:_status(message: string, warning: boolean?) if self.Callbacks.OnStatus then self.Callbacks.OnStatus(message, warning) end end
function Editor:_guide(message: string) if self.Callbacks.OnGuide then self.Callbacks.OnGuide(message) end end

function Editor:_snap(value: number, step: number, rotation: boolean): number
	if not self.SnapEnabled or UserInputService:IsKeyDown(Enum.KeyCode.LeftAlt) or UserInputService:IsKeyDown(Enum.KeyCode.RightAlt) then return value end
	local increment = math.max(0.0001, step)
	if UserInputService:IsKeyDown(Enum.KeyCode.LeftShift) or UserInputService:IsKeyDown(Enum.KeyCode.RightShift) then increment *= 0.25
	elseif UserInputService:IsKeyDown(Enum.KeyCode.LeftControl) or UserInputService:IsKeyDown(Enum.KeyCode.RightControl) then increment *= 5 end
	local snapped = math.round(value / increment) * increment
	if rotation then
		local degrees = math.deg(value); local cardinal = math.round(degrees / 90) * 90
		if math.abs(degrees - cardinal) <= math.max(2, self.RotateSnap) then snapped = math.rad(cardinal) end
		self:_guide(string.format("Rotation %.2f deg", math.deg(snapped)))
	else
		if math.abs(snapped) <= increment * 0.5 then snapped = 0 end
		self:_guide(string.format("Move %.3f studs", snapped))
	end
	return snapped
end

function Editor:FrameDummy(view: string?)
	if self.FirstPersonEnabled then self:SetFirstPersonPreview(false) end
	local camera, dummy = Workspace.CurrentCamera, self.Dummy
	if not camera or not dummy or not dummy.Parent then
		self:_status("Studio camera or preview dummy is unavailable.", true)
		return
	end
	local center, size = dummy:GetBoundingBox()
	local target = center.Position + Vector3.new(0, size.Y * 0.06, 0)
	local distance = math.clamp(math.max(size.X, size.Y, size.Z) * 1.65, 5.5, 24)
	local direction: Vector3
	if view == "Back" then direction = Vector3.zAxis
	elseif view == "Left" then direction = -Vector3.xAxis
	elseif view == "Right" then direction = Vector3.xAxis
	elseif view == "Top" then direction = Vector3.new(0, 1, 0.001).Unit
	elseif view == "Frame" then
		local current = camera.CFrame.Position - target
		direction = if current.Magnitude > 0.1 then current.Unit else Vector3.new(0, 0.08, -1).Unit
	else direction = Vector3.new(0, 0.08, -1).Unit end
	local up = if view == "Top" then -Vector3.zAxis else Vector3.yAxis
	camera.CFrame = CFrame.lookAt(target + direction * distance, target, up)
	camera.Focus = CFrame.new(target)
end

function Editor:_createGrid(parent: Instance)
	local floor = Instance.new("Part"); floor.Name = "EditorFloor"; floor.Size = Vector3.new(24, 0.12, 24)
	floor.Position = ARENA_CENTER - Vector3.new(0, 0.08, 0); floor.Anchored = true; floor.Locked = true
	floor.CanCollide = false; floor.CanTouch = false; floor.CanQuery = false
	floor.Color = Color3.fromRGB(25, 28, 35); floor.Material = Enum.Material.SmoothPlastic; floor:SetAttribute("PoseTunerLockedCFrame", floor.CFrame); floor.Parent = parent; self.Floor = floor
	table.clear(self.GridParts)
	for index = -12, 12 do
		for axis = 1, 2 do
			local line = Instance.new("Part"); line.Name = "GridLine"; line.Anchored = true; line.Locked = true
			line.CanCollide = false; line.CanTouch = false; line.CanQuery = false
			line.Size = if axis == 1 then Vector3.new(0.025, 0.01, 24) else Vector3.new(24, 0.01, 0.025)
			line.Position = ARENA_CENTER + Vector3.new(if axis == 1 then index else 0, 0, if axis == 2 then index else 0)
			line.Color = if index == 0 then Color3.fromRGB(100, 120, 145) else Color3.fromRGB(52, 58, 70)
			line.Material = Enum.Material.Neon; line:SetAttribute("PoseTunerLockedCFrame", line.CFrame); line.Parent = parent; table.insert(self.GridParts, line)
		end
	end
end

local function partBottomY(part: BasePart): number
	local half = part.Size * 0.5
	local frame = part.CFrame
	local verticalExtent = math.abs(frame.RightVector.Y) * half.X
		+ math.abs(frame.UpVector.Y) * half.Y
		+ math.abs(frame.LookVector.Y) * half.Z
	return frame.Position.Y - verticalExtent
end

function Editor:_groundModel(model: Model): boolean
	local root = model:FindFirstChild("HumanoidRootPart", true)
	if not root or not root:IsA("BasePart") then return false end
	local bottom = math.huge
	for _, item in model:GetDescendants() do
		if item:IsA("BasePart") and item ~= root and not item:FindFirstAncestorOfClass("Accessory")
			and not string.find(item.Name, "^PoseJointHit_") and item.Name ~= "PoseGizmoPivot"
			and item.Name ~= "IKTarget" and item.Name ~= "IKPole" then
			bottom = math.min(bottom, partBottomY(item))
		end
	end
	if bottom == math.huge then return false end
	local delta = ARENA_CENTER.Y - bottom
	if math.abs(delta) > 0.0001 then root.CFrame += Vector3.new(0, delta, 0) end
	return true
end

function Editor:ApplyGroundLock()
	if self.Floor and self.Floor.Parent then
		local locked = self.Floor:GetAttribute("PoseTunerLockedCFrame"); if typeof(locked) == "CFrame" then self.Floor.CFrame = locked end
	end
	for _, line in self.GridParts do
		if line.Parent then local locked = line:GetAttribute("PoseTunerLockedCFrame"); if typeof(locked) == "CFrame" then line.CFrame = locked end end
	end
	local dummy = self.Dummy
	if not dummy or not dummy.Parent or self.Dragging then return end
	local root = dummy:FindFirstChild("HumanoidRootPart", true)
	if root and root:IsA("BasePart") and self.BaseRootCFrame then root.CFrame = self.BaseRootCFrame end
	local blend = math.clamp(self.GroundLockBlend, 0, 1)
	if root and root:IsA("BasePart") and blend > 0 then
		local baseline = root.CFrame
		if self:_groundModel(dummy) and blend < 1 then root.CFrame = baseline:Lerp(root.CFrame, blend) end
	end
	self:_updatePivot()
end

function Editor:SetGroundLock(enabled: boolean)
	self.GroundLockEnabled = enabled; self.GroundLockBlend = if enabled then 1 else 0; self:ApplyGroundLock()
end

function Editor:SetGroundLockBlend(blend: number)
	self.GroundLockBlend = math.clamp(blend, 0, 1); self.GroundLockEnabled = self.GroundLockBlend > 0.0001; self:ApplyGroundLock()
end

function Editor:_restoreFirstPersonVisibility()
	for part, transparency in self.FirstPersonHidden do
		if part.Parent then part.Transparency = transparency end
	end
	table.clear(self.FirstPersonHidden)
end

function Editor:_hideFirstPersonParts()
	self:_restoreFirstPersonVisibility()
	local dummy = self.Dummy; if not dummy then return end
	for _, item in dummy:GetDescendants() do
		if item:IsA("BasePart") and (item.Name == "Head" or item:FindFirstAncestorOfClass("Accessory") ~= nil) then
			self.FirstPersonHidden[item] = item.Transparency; item.Transparency = 1
		end
	end
end

function Editor:_updateFirstPerson(deltaTime: number)
	if not self.FirstPersonEnabled then return end
	local camera, dummy = Workspace.CurrentCamera, self.Dummy
	if not camera or not dummy or not dummy.Parent then return end
	local root = dummy:FindFirstChild("HumanoidRootPart", true)
	if not root or not root:IsA("BasePart") then return end
	local alpha = 1 - math.exp(-FirstPersonViewConfig.MouseSmoothingFrequency * math.clamp(deltaTime, 0, 0.05))
	self.FirstPersonYaw += (self.FirstPersonTargetYaw - self.FirstPersonYaw) * alpha
	self.FirstPersonPitch += (self.FirstPersonTargetPitch - self.FirstPersonPitch) * alpha
	self.FirstPersonRotation = CFrame.Angles(0, self.FirstPersonYaw, 0) * CFrame.Angles(self.FirstPersonPitch, 0, 0)
	local forward = Vector3.new(self.FirstPersonRotation.LookVector.X, 0, self.FirstPersonRotation.LookVector.Z)
	if forward.Magnitude < 0.001 then forward = Vector3.new(root.CFrame.LookVector.X, 0, root.CFrame.LookVector.Z) end
	if forward.Magnitude > 0.001 then forward = forward.Unit end
	local position = root.Position
		+ Vector3.yAxis * (self.CameraAnchorHeight + FirstPersonViewConfig.CameraUpOffset)
		+ forward * FirstPersonViewConfig.CameraForwardOffset
	camera.CameraType = Enum.CameraType.Scriptable
	camera.CFrame = CFrame.new(position) * self.FirstPersonRotation
	camera.Focus = CFrame.new(position + self.FirstPersonRotation.LookVector * 12)
end

function Editor:SetFirstPersonPreview(enabled: boolean)
	if self.FirstPersonEnabled == enabled then return end
	local camera = Workspace.CurrentCamera
	if enabled then
		local dummy = self.Dummy; if not camera or not dummy then self:_status("First-person preview needs a camera and preview dummy.", true); return end
		local root = dummy:FindFirstChild("HumanoidRootPart", true)
		if not root or not root:IsA("BasePart") then self:_status("First-person preview is missing HumanoidRootPart.", true); return end
		self.FirstPersonCameraState = { Type = camera.CameraType, Subject = camera.CameraSubject, CFrame = camera.CFrame, Focus = camera.Focus, FieldOfView = camera.FieldOfView }
		self.FirstPersonInputState = { MouseBehavior = UserInputService.MouseBehavior, MouseIconEnabled = UserInputService.MouseIconEnabled, MouseDeltaSensitivity = UserInputService.MouseDeltaSensitivity }
		local look = root.CFrame.LookVector
		self.FirstPersonTargetYaw = math.atan2(-look.X, -look.Z); self.FirstPersonYaw = self.FirstPersonTargetYaw
		self.FirstPersonTargetPitch = 0; self.FirstPersonPitch = 0; self.FirstPersonRotation = CFrame.Angles(0, self.FirstPersonYaw, 0)
		self.FirstPersonEnabled = true; self:_hideFirstPersonParts()
		pcall(function()
			UserInputService.MouseBehavior = Enum.MouseBehavior.LockCenter
			UserInputService.MouseIconEnabled = false
			UserInputService.MouseDeltaSensitivity = FirstPersonViewConfig.MouseSensitivity
		end)
		self:_updateFirstPerson(1 / 60); self:_status("Static first-person preview enabled. Move the mouse to look; translation is locked.")
	else
		self.FirstPersonEnabled = false; self:_restoreFirstPersonVisibility()
		local inputState = self.FirstPersonInputState
		if inputState then pcall(function()
			UserInputService.MouseBehavior = inputState.MouseBehavior
			UserInputService.MouseIconEnabled = inputState.MouseIconEnabled
			UserInputService.MouseDeltaSensitivity = inputState.MouseDeltaSensitivity
		end) end
		local saved = self.FirstPersonCameraState
		if camera and saved then
			camera.CameraType = saved.Type; camera.CameraSubject = saved.Subject; camera.CFrame = saved.CFrame
			camera.Focus = saved.Focus; camera.FieldOfView = saved.FieldOfView
		end
		self.FirstPersonCameraState = nil; self.FirstPersonInputState = nil
	end
end

function Editor:_collect(model: Model)
	table.clear(self.Motors); table.clear(self.RestC0); table.clear(self.PartToJoint)
	for _, item in model:GetDescendants() do
		if item:IsA("Motor6D") then
			local name = canonical(item.Name); self.Motors[name] = item; self.RestC0[name] = item.C0; item.Transform = CFrame.identity
			if item.Part1 then self.PartToJoint[item.Part1] = name end
		end
	end
end

function Editor:_createJointHitboxes()
	table.clear(self.JointHitboxes); table.clear(self.HitboxToJoint)
	for name, motor in self.Motors do
		if motor.Part0 then
			local hitbox = Instance.new("Part"); hitbox.Name = "PoseJointHit_" .. name
			local large = name == "Waist" or name == "Root" or name == "Neck" or string.find(name, "Hip") ~= nil or string.find(name, "Shoulder") ~= nil
			hitbox.Size = Vector3.one * (if large then 0.58 else 0.44); hitbox.Transparency = 1
			hitbox.Anchored = true; hitbox.CanCollide = false; hitbox.CanTouch = false; hitbox.CanQuery = true; hitbox.Locked = true
			hitbox.Parent = self.Arena; self.HitboxToJoint[hitbox] = name; table.insert(self.JointHitboxes, hitbox)
		end
	end
	self:_updateJointHitboxes()
end

function Editor:_updateJointHitboxes()
	for hitbox, name in self.HitboxToJoint do
		local motor = self.Motors[name]
		if hitbox.Parent and motor and motor.Part0 then hitbox.CFrame = motor.Part0.CFrame * motor.C0 end
	end
end

function Editor:_jointFromTarget(target: BasePart?): string?
	if not target then return nil end
	local hitJoint = self.HitboxToJoint[target]; if hitJoint then return hitJoint end
	if self.Dummy and target:IsDescendantOf(self.Dummy) then return self.PartToJoint[target] end
	return nil
end

function Editor:_setHoverJoint(name: string?)
	local hover = self.HoverHighlight; if not hover then return end
	if not name or (self.SelectionActive and name == self.SelectedJoint) then hover.Adornee = nil; return end
	local motor = self.Motors[name]; hover.Adornee = if motor then motor.Part1 else nil
end

function Editor:_setSelectedPartWorld(desired: CFrame)
	local motor = self.Motors[self.SelectedJoint]
	local restC0 = self.RestC0[self.SelectedJoint]
	if not motor or not restC0 or not motor.Part0 or not motor.Part1 then return end
	local transform = restC0:Inverse() * motor.Part0.CFrame:Inverse() * desired * motor.C1
	motor.Transform = CFrame.identity; motor.C0 = restC0 * transform
	self.Pose[self.SelectedJoint] = transform
	self:ApplyGroundLock()
	if self.Callbacks.OnPoseChanged then self.Callbacks.OnPoseChanged(self:ReadPose()) end
	self:_updatePivot()
end

function Editor:_updatePivot()
	self:_updateJointHitboxes()
	if not self.SelectionActive then
		if self.Highlight then self.Highlight.Adornee = nil end
		if self.MoveHandles then self.MoveHandles.Visible = false end
		if self.RotateHandles then self.RotateHandles.Visible = false end
		return
	end
	local motor, pivot = self.Motors[self.SelectedJoint], self.Pivot
	if not motor or not motor.Part0 or not pivot then return end
	local frame = motor.Part0.CFrame * motor.C0 * motor.Transform
	pivot.CFrame = if self.AxisSpace == "World" then CFrame.new(frame.Position) else frame
	if self.Highlight and motor.Part1 then self.Highlight.Adornee = motor.Part1 end
end

function Editor:_clearIK()
	if self.ActiveIK then self.ActiveIK:Destroy() end; if self.IKTarget then self.IKTarget:Destroy() end; if self.IKPole then self.IKPole:Destroy() end
	self.ActiveIK = nil; self.IKTarget = nil; self.IKPole = nil
	if self.MoveHandles then self.MoveHandles.Adornee = self.Pivot end
end

function Editor:BakeIK()
	if not self.ActiveIK then return end
	local chain = IK_CHAINS[self.SelectedJoint]; if not chain then self:_clearIK(); return end
	local desired = {}
	for _, name in chain.Joints do local motor = self.Motors[name]; if motor and motor.Part1 then desired[name] = motor.Part1.CFrame end end
	self:_clearIK()
	for _, name in chain.Joints do
		local motor, world, restC0 = self.Motors[name], desired[name], self.RestC0[name]
		if motor and motor.Part0 and world and restC0 then
			local transform = restC0:Inverse() * motor.Part0.CFrame:Inverse() * world * motor.C1
			motor.Transform = CFrame.identity; motor.C0 = restC0 * transform
		end
	end
	self.Pose = self:ReadPose(); self:ApplyGroundLock(); if self.Callbacks.OnPoseChanged then self.Callbacks.OnPoseChanged(self.Pose) end
	self:_updatePivot()
end

function Editor:_startIK()
	self:_clearIK(); local chain, dummy = IK_CHAINS[self.SelectedJoint], self.Dummy
	if not chain or not dummy then self:_status("IK requires a wrist or ankle selection.", true); return end
	local humanoid = dummy:FindFirstChildOfClass("Humanoid"); local root = dummy:FindFirstChild(chain.Root, true); local endpoint = dummy:FindFirstChild(chain.EndPart, true)
	if not humanoid or not root or not root:IsA("BasePart") or not endpoint or not endpoint:IsA("BasePart") then self:_status("Selected IK chain is incomplete.", true); return end
	local target = Instance.new("Part"); target.Name = "IKTarget"; target.Size = Vector3.one * 0.3; target.Shape = Enum.PartType.Ball
	target.Color = Color3.fromRGB(80, 235, 160); target.Material = Enum.Material.Neon; target.Anchored = true; target.CanCollide = false; target.CFrame = endpoint.CFrame; target.Parent = self.Arena
	local targetAttachment = Instance.new("Attachment", target)
	local pole = Instance.new("Part"); pole.Name = "IKPole"; pole.Size = Vector3.one * 0.2; pole.Shape = Enum.PartType.Ball
	pole.Color = Color3.fromRGB(220, 100, 255); pole.Material = Enum.Material.Neon; pole.Anchored = true; pole.CanCollide = false; pole.Position = root.Position + root.CFrame:VectorToWorldSpace(chain.Pole); pole.Parent = self.Arena
	local poleAttachment = Instance.new("Attachment", pole)
	local ik = Instance.new("IKControl"); ik.Name = "PoseTunerIK"; ik.Type = Enum.IKControlType.Transform; ik.ChainRoot = root; ik.EndEffector = endpoint
	ik.Target = targetAttachment; ik.Pole = poleAttachment; ik.Weight = 1; ik.SmoothTime = 0; ik.Priority = 100; ik.Parent = humanoid
	self.ActiveIK = ik; self.IKTarget = target; self.IKPole = pole
	if self.MoveHandles then self.MoveHandles.Adornee = target; self.MoveHandles.Visible = true end
	if self.RotateHandles then self.RotateHandles.Visible = false end
	self:_status("Drag the green IK target, then release to bake.")
end

function Editor:_createGizmos()
	local pivot = Instance.new("Part"); pivot.Name = "PoseGizmoPivot"; pivot.Size = Vector3.one * 0.65; pivot.Transparency = 1; pivot.Anchored = true; pivot.CanCollide = false; pivot.CanQuery = false; pivot.CanTouch = false; pivot.Locked = true; pivot.Parent = self.Arena; self.Pivot = pivot
	local move = Instance.new("Handles"); move.Name = "PoseMoveHandles"; move.Style = Enum.HandlesStyle.Movement
	move.Faces = Faces.new(Enum.NormalId.Top, Enum.NormalId.Bottom, Enum.NormalId.Left, Enum.NormalId.Right, Enum.NormalId.Front, Enum.NormalId.Back); move.Color3 = Color3.fromRGB(72, 190, 255); move.Adornee = pivot; move.Visible = true; move.Parent = CoreGui; self.MoveHandles = move
	local rotate = Instance.new("ArcHandles"); rotate.Name = "PoseRotateHandles"; rotate.Axes = Axes.new(Enum.Axis.X, Enum.Axis.Y, Enum.Axis.Z); rotate.Color3 = Color3.fromRGB(255, 177, 72); rotate.Adornee = pivot; rotate.Visible = false; rotate.Parent = CoreGui; self.RotateHandles = rotate
	local startPart, startPivot = CFrame.identity, CFrame.identity
	local function beginDrag()
		local motor = self.Motors[self.SelectedJoint]; if not motor or not motor.Part1 or not self.Pivot then return end
		self.Dragging = true; startPart = motor.Part1.CFrame; startPivot = self.Pivot.CFrame
		if self.Callbacks.OnEditBegin then self.Callbacks.OnEditBegin() end
	end
	local function endDrag()
		if not self.Dragging then return end; self.Dragging = false
		if self.ActiveIK then self:BakeIK() else self:ApplyGroundLock(); if self.Callbacks.OnEditEnd then self.Callbacks.OnEditEnd() end end
	end
	table.insert(self.Connections, move.MouseButton1Down:Connect(beginDrag)); table.insert(self.Connections, move.MouseButton1Up:Connect(endDrag))
	table.insert(self.Connections, rotate.MouseButton1Down:Connect(beginDrag)); table.insert(self.Connections, rotate.MouseButton1Up:Connect(endDrag))
	table.insert(self.Connections, move.MouseDrag:Connect(function(face, distance)
		if not self.Dragging then return end; local direction = axisFromFace(face)
		if self.AxisSpace == "Local" then direction = startPivot:VectorToWorldSpace(direction) end
		local delta = direction * self:_snap(distance, self.MoveSnap, false)
		if self.ActiveIK and self.IKTarget then self.IKTarget.CFrame = startPart + delta else self:_setSelectedPartWorld(CFrame.new(delta) * startPart) end
	end))
	table.insert(self.Connections, rotate.MouseDrag:Connect(function(axis, relativeAngle, _radius)
		if not self.Dragging or self.ActiveIK then return end; local direction = axisFromArc(axis)
		if self.AxisSpace == "Local" then direction = startPivot:VectorToWorldSpace(direction) end
		local angle = self:_snap(relativeAngle, math.rad(self.RotateSnap), true); local position = startPivot.Position
		self:_setSelectedPartWorld(CFrame.new(position) * CFrame.fromAxisAngle(direction, angle) * CFrame.new(-position) * startPart)
	end))
end

function Editor:_buildScene(source: Model, pose: Pose, frameCamera: boolean)
	local restoreFirstPerson = self.FirstPersonEnabled
	if restoreFirstPerson then self:SetFirstPersonPreview(false) end
	self:DestroyScene(true)
	local camera = Workspace.CurrentCamera
	if camera and not self.SavedCamera then self.SavedCamera = { Type = camera.CameraType, Subject = camera.CameraSubject, CFrame = camera.CFrame, Focus = camera.Focus, FieldOfView = camera.FieldOfView } end
	for _, existing in Workspace:GetChildren() do
		if existing.Name == "__TemporaryR15PoseEditor" then existing:Destroy() end
	end
	local arena = Instance.new("Folder"); arena.Name = "__TemporaryR15PoseEditor"; arena.Parent = Workspace; self.Arena = arena; self:_createGrid(arena)
	local old = source.Archivable; source.Archivable = true; local dummy = source:Clone(); source.Archivable = old
	dummy.Name = "PoseEditorR15Dummy"; stripScripts(dummy); configure(dummy); dummy.Parent = arena; dummy:PivotTo(CFrame.new(ARENA_CENTER + Vector3.new(0, 4, 0)))
	local humanoid = dummy:FindFirstChildOfClass("Humanoid"); if humanoid then humanoid.DisplayDistanceType = Enum.HumanoidDisplayDistanceType.None; humanoid.PlatformStand = true end
	self.Dummy = dummy; self:_collect(dummy); self.Pose = pose
	self:_groundModel(dummy); local baseRoot = dummy:FindFirstChild("HumanoidRootPart", true); self.BaseRootCFrame = if baseRoot and baseRoot:IsA("BasePart") then baseRoot.CFrame else nil
	local head = dummy:FindFirstChild("Head", true)
	self.CameraAnchorHeight = if baseRoot and baseRoot:IsA("BasePart") and head and head:IsA("BasePart") then baseRoot.CFrame:PointToObjectSpace(head.Position).Y else 2.5
	local highlight = Instance.new("Highlight"); highlight.Name = "PoseSelection"; highlight.FillColor = Color3.fromRGB(78, 178, 255); highlight.FillTransparency = 0.72; highlight.OutlineColor = Color3.fromRGB(220, 242, 255); highlight.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop; highlight.Parent = arena; self.Highlight = highlight
	local hoverHighlight = Instance.new("Highlight"); hoverHighlight.Name = "PoseHover"; hoverHighlight.FillTransparency = 1; hoverHighlight.OutlineColor = Color3.fromRGB(115, 215, 255); hoverHighlight.OutlineTransparency = 0.12; hoverHighlight.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop; hoverHighlight.Parent = arena; self.HoverHighlight = hoverHighlight
	self:_createJointHitboxes(); self:_createGizmos(); self:ApplyPose(pose); self:SelectJoint(self.SelectedJoint)
	local mouse = self.Plugin:GetMouse()
	table.insert(self.Connections, mouse.Button1Down:Connect(function()
		-- Handles and ArcHandles receive the same mouse-down as the viewport. Defer
		-- picking for one task so a gizmo drag can claim the click first.
		task.defer(function()
			if self.Dragging or self.Dummy ~= dummy or not dummy.Parent then return end
			local target = mouse.Target
			local joint = if target and target:IsA("BasePart") then self:_jointFromTarget(target) else nil
			if not joint and target and target.Name == "HumanoidRootPart" and target:IsDescendantOf(dummy) then joint = "Root" end
			if joint then
					Selection:Set({}); self:SelectJoint(joint)
					local motor = self.Motors[joint]
					if self.Mode ~= "IK" and motor and motor.Part1 and self.Pivot then
						self.DirectDrag = {
							Start = Vector2.new(mouse.X, mouse.Y), StartPart = motor.Part1.CFrame,
							StartPivot = self.Pivot.CFrame, Mode = self.Mode, Started = false,
						}
					end
					task.defer(function()
						if self.Dummy == dummy and dummy.Parent then Selection:Set({}) end
					end)
			else self:DeselectJoint() end
		end)
	end))
	table.insert(self.Connections, mouse.Move:Connect(function()
		local drag = self.DirectDrag
		if not drag then
			local target = mouse.Target; local hoverJoint = if target and target:IsA("BasePart") then self:_jointFromTarget(target) else nil
			if not hoverJoint and target and target.Name == "HumanoidRootPart" and target:IsDescendantOf(dummy) then hoverJoint = "Root" end
			self:_setHoverJoint(hoverJoint); return
		end
		if self.Dragging and not drag.Started then return end
		local delta = Vector2.new(mouse.X, mouse.Y) - drag.Start
		if not drag.Started then
			if delta.Magnitude < 3 then return end
			drag.Started = true; self.Dragging = true
			if self.Callbacks.OnEditBegin then self.Callbacks.OnEditBegin() end
		end
		local camera = Workspace.CurrentCamera; if not camera then return end
		if drag.Mode == "Move" then
			local distance = math.max(2, (camera.CFrame.Position - drag.StartPivot.Position).Magnitude)
			local scale = distance * 0.0018
			local horizontal = self:_snap(delta.X * scale, self.MoveSnap, false)
			local vertical = self:_snap(-delta.Y * scale, self.MoveSnap, false)
			local offset = camera.CFrame.RightVector * horizontal + camera.CFrame.UpVector * vertical
			self:_setSelectedPartWorld(drag.StartPart + offset)
		elseif drag.Mode == "Rotate" then
			local yaw = self:_snap(-delta.X * 0.0075, math.rad(self.RotateSnap), true)
			local pitch = self:_snap(-delta.Y * 0.0075, math.rad(self.RotateSnap), true)
			local position = drag.StartPivot.Position
			local rotation = CFrame.fromAxisAngle(camera.CFrame.UpVector, yaw) * CFrame.fromAxisAngle(camera.CFrame.RightVector, pitch)
			self:_setSelectedPartWorld(CFrame.new(position) * rotation * CFrame.new(-position) * drag.StartPart)
		end
	end))
	table.insert(self.Connections, UserInputService.InputChanged:Connect(function(input)
		if not self.FirstPersonEnabled or input.UserInputType ~= Enum.UserInputType.MouseMovement then return end
		local delta = input.Delta
		self.FirstPersonTargetYaw -= delta.X * FirstPersonViewConfig.MouseRadiansPerPixel
		self.FirstPersonTargetPitch = math.clamp(
			self.FirstPersonTargetPitch - delta.Y * FirstPersonViewConfig.MouseRadiansPerPixel,
			math.rad(-FirstPersonViewConfig.MaxPitchDegrees),
			math.rad(FirstPersonViewConfig.MaxPitchDegrees)
		)
	end))
	table.insert(self.Connections, mouse.Button1Up:Connect(function()
		local drag = self.DirectDrag; self.DirectDrag = nil
		if not drag or not drag.Started then return end
		self.Dragging = false; self:ApplyGroundLock()
		if self.Callbacks.OnEditEnd then self.Callbacks.OnEditEnd() end
	end))
	local clearingStudioSelection = false
	table.insert(self.Connections, Selection.SelectionChanged:Connect(function()
		if clearingStudioSelection then return end
		for _, selected in Selection:Get() do
			if selected == dummy or selected:IsDescendantOf(dummy) then
				clearingStudioSelection = true; Selection:Set({}); clearingStudioSelection = false; break
			end
		end
	end))
	table.insert(self.Connections, arena.AncestryChanged:Connect(function(_, parent)
		if parent == nil and not self.DestroyingScene then task.defer(function() self:EnsureScene() end) end
	end))
	table.insert(self.Connections, RunService.RenderStepped:Connect(function(dt)
		self.HealthAccumulator += math.min(dt, 0.1)
		if self.HealthAccumulator >= 0.25 then self.HealthAccumulator = 0; self:EnsureScene() end
		self:ApplyGroundLock()
		self:_updateFirstPerson(dt)
	end))
	self:ApplyGroundLock()
	if frameCamera then self:FrameDummy("Front") end
	if restoreFirstPerson then self:SetFirstPersonPreview(true) end
	self:_status("Editor ready. Use Studio right-click navigation and mouse-wheel zoom.")
end

function Editor:Build(source: Model, pose: Pose)
	local old = source.Archivable; source.Archivable = true; local template = source:Clone(); source.Archivable = old
	if not template then self:_status("The selected dummy could not be cloned.", true); return end
	stripScripts(template)
	for _, item in template:GetDescendants() do if item:IsA("Motor6D") then item.Transform = CFrame.identity end end
	if self.SourceTemplate then self.SourceTemplate:Destroy() end; self.SourceTemplate = template
	self:_buildScene(template, pose, true)
end

function Editor:EnsureScene()
	if self.DestroyingScene or self.Rebuilding or not self.SourceTemplate then return end
	local valid = self.Arena ~= nil and self.Arena.Parent == Workspace and self.Dummy ~= nil and self.Dummy.Parent == self.Arena
	valid = valid and self.Floor ~= nil and self.Floor.Parent == self.Arena and self.Pivot ~= nil and self.Pivot.Parent == self.Arena
	valid = valid and self.MoveHandles ~= nil and self.MoveHandles.Parent == CoreGui and self.RotateHandles ~= nil and self.RotateHandles.Parent == CoreGui
	if valid then
		for _, line in self.GridParts do
			if line.Parent ~= self.Arena then valid = false; break end
		end
	end
	if valid then for _, hitbox in self.JointHitboxes do if hitbox.Parent ~= self.Arena then valid = false; break end end end
	if valid then return end
	self.Rebuilding = true; self:_status("Preview scene was removed; rebuilding it.", true)
	local ok, failure = pcall(function() self:_buildScene(self.SourceTemplate :: Model, self.Pose, false) end)
	self.Rebuilding = false
	if not ok then self:_status("Preview recovery failed: " .. tostring(failure), true)
	elseif self.Callbacks.OnSceneRebuilt then self.Callbacks.OnSceneRebuilt() end
end

function Editor:ApplyPose(pose: Pose)
	self.Pose = pose
	for name, motor in self.Motors do
		local restC0 = self.RestC0[name]
		if restC0 then motor.Transform = CFrame.identity; motor.C0 = restC0 * (pose[name] or CFrame.identity) end
	end
	self:ApplyGroundLock(); self:_updatePivot()
end

function Editor:ReadPose(): Pose
	local pose: Pose = {}
	for name, motor in self.Motors do local restC0 = self.RestC0[name]; if restC0 then pose[name] = restC0:Inverse() * motor.C0 end end
	return pose
end

function Editor:SelectJoint(name: string)
	if not self.Motors[name] then self:_status("Missing R15 joint: " .. name, true); return end
	self.SelectedJoint = name; self.SelectionActive = true; self:_clearIK(); self:_setHoverJoint(nil); self:_updatePivot()
	if self.MoveHandles then self.MoveHandles.Visible = self.Mode ~= "Rotate" end; if self.RotateHandles then self.RotateHandles.Visible = self.Mode == "Rotate" end
	if self.Mode == "IK" then self:_startIK() end
	if self.Callbacks.OnSelectionChanged then self.Callbacks.OnSelectionChanged(name) end
end

function Editor:DeselectJoint()
	if not self.SelectionActive then return end
	self.SelectionActive = false; self.DirectDrag = nil; self:_clearIK()
	if self.Highlight then self.Highlight.Adornee = nil end; if self.HoverHighlight then self.HoverHighlight.Adornee = nil end
	if self.MoveHandles then self.MoveHandles.Visible = false end; if self.RotateHandles then self.RotateHandles.Visible = false end
	if self.Callbacks.OnSelectionCleared then self.Callbacks.OnSelectionCleared() end
end

function Editor:SetMode(mode: EditorMode)
	self.Mode = mode; self:_clearIK(); if self.MoveHandles then self.MoveHandles.Visible = self.SelectionActive and mode ~= "Rotate" end; if self.RotateHandles then self.RotateHandles.Visible = self.SelectionActive and mode == "Rotate" end; if mode == "IK" and self.SelectionActive then self:_startIK() end
	self:_status(if mode == "Move" then "Move mode: drag a limb directly, or drag an axis arrow." elseif mode == "Rotate" then "Rotate mode: drag a limb directly, or drag a colored ring." else "IK mode: select a wrist or ankle, then drag its target.")
end
function Editor:SetAxisSpace(space: AxisSpace) self.AxisSpace = space; self:_updatePivot() end
function Editor:SetSnapSettings(enabled: boolean, move: number, rotate: number) self.SnapEnabled = enabled; self.MoveSnap = math.clamp(move, 0.001, 10); self.RotateSnap = math.clamp(rotate, 0.1, 90) end

function Editor:SetOnion(previous: Pose?, following: Pose?, enabled: boolean, previousGroundLock: boolean?, followingGroundLock: boolean?)
	if self.OnionFolder then self.OnionFolder:Destroy(); self.OnionFolder = nil end
	if self.Arena then for _, child in self.Arena:GetChildren() do if child.Name == "OnionSkins" then child:Destroy() end end end
	if not enabled or not self.Dummy or not self.Arena then return end
	local folder = Instance.new("Folder"); folder.Name = "OnionSkins"; folder.Parent = self.Arena; self.OnionFolder = folder
	local function ghost(name: string, pose: Pose, color: Color3, groundLock: boolean)
		local source = self.SourceTemplate or self.Dummy
		local clone = source:Clone(); clone.Name = name; stripScripts(clone)
		local descendants = clone:GetDescendants()
		for index = #descendants, 1, -1 do
			local item = descendants[index]
			if item:IsA("Accessory") or item:IsA("Decal") or item:IsA("Texture") or item:IsA("SurfaceAppearance") then item:Destroy() end
		end
		configure(clone, true)
		local ghostHumanoid = clone:FindFirstChildOfClass("Humanoid"); if ghostHumanoid then ghostHumanoid.DisplayDistanceType = Enum.HumanoidDisplayDistanceType.None end
		for _, item in clone:GetDescendants() do
			if item:IsA("BasePart") then
				item.Color = color; item.Material = Enum.Material.ForceField; item.Transparency = if item.Name == "HumanoidRootPart" then 1 else 0.78
				if item:IsA("MeshPart") then item.TextureID = "" end
			end
		end
		clone.Parent = folder
		local cloneRoot = clone:FindFirstChild("HumanoidRootPart", true); local liveRoot = self.Dummy:FindFirstChild("HumanoidRootPart", true)
		if cloneRoot and cloneRoot:IsA("BasePart") and liveRoot and liveRoot:IsA("BasePart") then cloneRoot.CFrame = liveRoot.CFrame else clone:PivotTo(self.Dummy:GetPivot()) end
		for joint, motor in self:_motorsOf(clone) do motor.Transform = CFrame.identity; motor.C0 = motor.C0 * (pose[joint] or CFrame.identity) end
		if groundLock then self:_groundModel(clone) end
		for _, item in clone:GetDescendants() do
			if item:IsA("BasePart") then
				local live = self.Dummy:FindFirstChild(item.Name, true)
				if live and live:IsA("BasePart") then
					local relative = live.CFrame:ToObjectSpace(item.CFrame); local _, angle = relative:ToAxisAngle()
					if relative.Position.Magnitude <= 0.001 and math.abs(angle) <= 0.001 then item.Transparency = 1 end
				end
				if self.FirstPersonEnabled and item.Name == "Head" then item.Transparency = 1 end
			end
		end
	end
	if previous then ghost("Previous_Blue", previous, Color3.fromRGB(70, 145, 255), previousGroundLock ~= false) end
	if following then ghost("Next_Orange", following, Color3.fromRGB(255, 145, 55), followingGroundLock ~= false) end
end

function Editor:_motorsOf(model: Model): { [string]: Motor6D }
	local result = {}; for _, item in model:GetDescendants() do if item:IsA("Motor6D") then result[canonical(item.Name)] = item end end; return result
end

function Editor:DestroyScene(preserveSource: boolean?)
	self.DestroyingScene = true
	if self.FirstPersonEnabled then self:SetFirstPersonPreview(false) end
	for _, connection in self.Connections do connection:Disconnect() end; table.clear(self.Connections); self:_clearIK()
	if self.MoveHandles then self.MoveHandles:Destroy() end; if self.RotateHandles then self.RotateHandles:Destroy() end
	self.MoveHandles = nil; self.RotateHandles = nil; if self.Arena then self.Arena:Destroy() end
	self.Arena = nil; self.Dummy = nil; self.Floor = nil; self.Pivot = nil; self.Highlight = nil; self.HoverHighlight = nil; self.BaseRootCFrame = nil
	self.DirectDrag = nil; self.Dragging = false
	self.SelectionActive = false; table.clear(self.GridParts); table.clear(self.JointHitboxes); table.clear(self.HitboxToJoint); table.clear(self.Motors); table.clear(self.RestC0); table.clear(self.PartToJoint)
	if not preserveSource and self.SourceTemplate then self.SourceTemplate:Destroy(); self.SourceTemplate = nil end
	self.DestroyingScene = false
end

function Editor:Destroy()
	if self.FirstPersonEnabled then self:SetFirstPersonPreview(false) end
	self:DestroyScene(); local camera, saved = Workspace.CurrentCamera, self.SavedCamera
	if camera and saved then camera.CameraType = saved.Type; camera.CameraSubject = saved.Subject; camera.CFrame = saved.CFrame; camera.Focus = saved.Focus; camera.FieldOfView = saved.FieldOfView end
	self.SavedCamera = nil
end

return Editor
