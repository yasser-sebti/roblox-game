--!strict
local Players = game:GetService("Players")
local StarterPlayer = game:GetService("StarterPlayer")
local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

-- Softer gravity for a lighter, significantly slower fall speed.
Workspace.Gravity = 95

-- Automatically convert Dummy model to StarterCharacter if present
local function setupDummyCharacter()
	local dummy = Workspace:FindFirstChild("Dummy") or ReplicatedStorage:FindFirstChild("Dummy")
	if dummy and dummy:IsA("Model") then
		local existingStarterChar = StarterPlayer:FindFirstChild("StarterCharacter")
		if existingStarterChar then
			existingStarterChar:Destroy()
		end

		local dummyClone = dummy:Clone()
		dummyClone.Name = "StarterCharacter"

		-- Unanchor all parts in the dummy clone
		for _, part in dummyClone:GetDescendants() do
			if part:IsA("BasePart") then
				part.Anchored = false
			end
		end

		-- Remove default Animate script if pre-existing in dummy
		local preAnimate = dummyClone:FindFirstChild("Animate")
		if preAnimate then
			preAnimate:Destroy()
		end

		local hrp = dummyClone:FindFirstChild("HumanoidRootPart") :: BasePart?
		if hrp then
			dummyClone.PrimaryPart = hrp
		end

		dummyClone.Parent = StarterPlayer
		print("👤 Dummy model unanchored and registered as StarterPlayer.StarterCharacter!")
	end
end

setupDummyCharacter()

-- Enforce First-Person Camera Mode Globally by Default
StarterPlayer.CameraMode = Enum.CameraMode.LockFirstPerson
StarterPlayer.CameraMinZoomDistance = 0.5
StarterPlayer.CameraMaxZoomDistance = 0.5
StarterPlayer.CharacterWalkSpeed = 7 -- Slow horror walk
StarterPlayer.CharacterJumpPower = 40

local function onPlayerAdded(player: Player)
	player.CameraMode = Enum.CameraMode.LockFirstPerson
	player.CameraMinZoomDistance = 0.5
	player.CameraMaxZoomDistance = 0.5

	player.CharacterAdded:Connect(function(character)
		-- 1. Disable & destroy default Roblox Animate script
		local animateScript = character:WaitForChild("Animate", 5)
		if animateScript then
			animateScript:Destroy()
		end

		-- 2. Ensure all parts are unanchored
		for _, part in character:GetDescendants() do
			if part:IsA("BasePart") then
				part.Anchored = false
			end
		end

		-- 3. Stop any playing default animations on Humanoid Animator
		local humanoidObj = character:WaitForChild("Humanoid", 10)
		if humanoidObj and humanoidObj:IsA("Humanoid") then
			local humanoid: Humanoid = humanoidObj
			humanoid.WalkSpeed = 7
			humanoid.JumpPower = 40
			humanoid.JumpHeight = 5.5

			local animator = humanoid:FindFirstChildOfClass("Animator")
			if animator then
				for _, track in animator:GetPlayingAnimationTracks() do
					track:Stop(0)
				end
			end
		end
	end)
end

Players.PlayerAdded:Connect(onPlayerAdded)
for _, player in Players:GetPlayers() do
	onPlayerAdded(player)
end

print("⚙️ Server player handler & Native Animation Blocker initialized.")
