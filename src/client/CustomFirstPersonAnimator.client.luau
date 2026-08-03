--!strict

local ContextActionService = game:GetService("ContextActionService")
local Players = game:GetService("Players")

local Locomotion = script.Parent:WaitForChild("Locomotion")
local Config = require(Locomotion:WaitForChild("Config"))
local ControllerModule = require(Locomotion:WaitForChild("Controller"))

type Controller = ControllerModule.Controller

local player = Players.LocalPlayer
local activeController: Controller? = nil
local characterGeneration = 0
local sprinting = false
local crouching = false

local FIRST_PERSON_ATTRIBUTE = "FirstPersonEnabled"
local THIRD_PERSON_MIN_ZOOM = 7
local THIRD_PERSON_MAX_ZOOM = 18

local function applyViewMode(firstPersonEnabled: boolean)
	player:SetAttribute(FIRST_PERSON_ATTRIBUTE, firstPersonEnabled)
	if firstPersonEnabled then
		player.CameraMode = Enum.CameraMode.LockFirstPerson
		player.CameraMinZoomDistance = 0.5
		player.CameraMaxZoomDistance = 0.5
	else
		-- Increase Max first because it is still 0.5 while leaving FPS lock.
		-- A seven-stud minimum forces Roblox's Classic camera out of the old
		-- first-person distance immediately instead of leaving it inside the head.
		player.CameraMaxZoomDistance = THIRD_PERSON_MAX_ZOOM
		player.CameraMinZoomDistance = THIRD_PERSON_MIN_ZOOM
		player.CameraMode = Enum.CameraMode.Classic
	end
end

local function onToggleViewAction(_actionName: string, inputState: Enum.UserInputState): Enum.ContextActionResult
	if inputState ~= Enum.UserInputState.Begin then
		return Enum.ContextActionResult.Pass
	end

	local firstPersonEnabled = player:GetAttribute(FIRST_PERSON_ATTRIBUTE) ~= false
	applyViewMode(not firstPersonEnabled)
	print(if firstPersonEnabled then "Third-person view enabled." else "First-person view enabled.")
	return Enum.ContextActionResult.Sink
end

local function onSprintAction(_actionName: string, inputState: Enum.UserInputState): Enum.ContextActionResult
	if inputState == Enum.UserInputState.Begin then
		sprinting = true
	elseif inputState == Enum.UserInputState.End or inputState == Enum.UserInputState.Cancel then
		sprinting = false
	end

	if activeController then
		activeController:SetSprinting(sprinting)
	end
	return Enum.ContextActionResult.Pass
end

local function onCrouchAction(_actionName: string, inputState: Enum.UserInputState): Enum.ContextActionResult
	if inputState ~= Enum.UserInputState.Begin then
		return Enum.ContextActionResult.Sink
	end
	if player:GetAttribute("MovementLocked") == true then
		return Enum.ContextActionResult.Sink
	end

	crouching = not crouching
	if activeController then
		activeController:SetCrouching(crouching)
	end
	return Enum.ContextActionResult.Sink
end

local function setupCharacter(character: Model)
	characterGeneration += 1
	local generation = characterGeneration
	crouching = false

	if activeController then
		activeController:Destroy()
		activeController = nil
	end

	task.spawn(function()
		local humanoid = character:WaitForChild("Humanoid", 10)
		local rootPart = character:WaitForChild("HumanoidRootPart", 10)
		if generation ~= characterGeneration or not humanoid or not rootPart then
			return
		end

		local requiredR15Parts = {
			"Head",
			"LowerTorso",
			"LeftUpperLeg",
			"LeftLowerLeg",
			"LeftFoot",
			"RightUpperLeg",
			"RightLowerLeg",
			"RightFoot",
		}
		for _, partName in requiredR15Parts do
			if not character:WaitForChild(partName, 10) then
				warn("Advanced locomotion disabled: required R15 part " .. partName .. " is missing")
				return
			end
		end
		if generation ~= characterGeneration then
			return
		end

		local controller, controllerError = ControllerModule.new(player, character, Config)
		if generation ~= characterGeneration then
			if controller then
				controller:Destroy()
			end
			return
		end

		if not controller then
			warn("Advanced locomotion disabled: " .. (controllerError or "unknown R15 rig error"))
			return
		end

		activeController = controller
		controller:SetSprinting(sprinting)
		controller:SetCrouching(crouching)
		print("Advanced R15 procedural locomotion initialized: " .. tostring(player:GetAttribute("LocomotionRevision")))
	end)
end

if player:GetAttribute(FIRST_PERSON_ATTRIBUTE) == nil then
	player:SetAttribute(FIRST_PERSON_ATTRIBUTE, true)
end
applyViewMode(player:GetAttribute(FIRST_PERSON_ATTRIBUTE) ~= false)

ContextActionService:BindAction(
	"AdvancedLocomotionSprint",
	onSprintAction,
	false,
	Enum.KeyCode.LeftShift,
	Enum.KeyCode.RightShift,
	Enum.KeyCode.ButtonL3
)

ContextActionService:BindAction(
	"AdvancedLocomotionCrouch",
	onCrouchAction,
	false,
	Enum.KeyCode.C,
	Enum.KeyCode.ButtonB
)

ContextActionService:BindAction(
	"ToggleFirstPersonView",
	onToggleViewAction,
	false,
	Enum.KeyCode.V,
	Enum.KeyCode.ButtonR3
)

player.CharacterAdded:Connect(setupCharacter)
if player.Character then
	setupCharacter(player.Character)
end
