--!strict
-- Single Separated Cinematic Noise Controller (Persists Whole Game: Loading & Gameplay)
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")
local gameSettings = ReplicatedStorage:WaitForChild("GameSettings")
local shadersEnabled = gameSettings:WaitForChild("ShadersEnabled") :: BoolValue

-- 1. Construct NoiseScreen (Topmost DisplayOrder = 2147483647, ResetOnSpawn = false)
local noiseScreen = Instance.new("ScreenGui")
noiseScreen.Name = "NoiseScreen"
noiseScreen.ResetOnSpawn = false -- Keeps noise active permanently across whole game!
noiseScreen.IgnoreGuiInset = true
noiseScreen.DisplayOrder = 2147483647 -- Maximum layer in Roblox (Renders ON TOP of EVERYTHING)
noiseScreen.ZIndexBehavior = Enum.ZIndexBehavior.Global
noiseScreen.Parent = playerGui
noiseScreen.Enabled = shadersEnabled.Value

-- 2. Construct Noise ImageLabel with User's Asset ID
local Noise = Instance.new("ImageLabel")
Noise.Name = "Noise"
Noise.Size = UDim2.new(2.2, 0, 2.2, 0) -- Generous 2.2x size prevents edge clipping
Noise.AnchorPoint = Vector2.new(0.5, 0.5)
Noise.Position = UDim2.fromScale(0.5, 0.5)
Noise.BackgroundTransparency = 1
Noise.ImageTransparency = 0.94 -- Subtle, clean 6% noise opacity
Noise.Image = "rbxassetid://15344951630"
Noise.ScaleType = Enum.ScaleType.Tile
Noise.TileSize = UDim2.new(0, 256, 0, 256)
Noise.ZIndex = 2147483647
Noise.Parent = noiseScreen

-- 3. Dynamic Priority Handler: Enforce top layer whenever new ScreenGuis are added
playerGui.ChildAdded:Connect(function(child)
	if child ~= noiseScreen and child:IsA("ScreenGui") then
		noiseScreen.DisplayOrder = 2147483647
		task.defer(function()
			if noiseScreen and noiseScreen.Parent then
				noiseScreen.Parent = nil
				noiseScreen.Parent = playerGui
			end
		end)
	end
end)

shadersEnabled:GetPropertyChangedSignal("Value"):Connect(function()
	noiseScreen.Enabled = shadersEnabled.Value
end)

-- 4. Symmetric Random Offset Animation (60 FPS)
local rng = Random.new()
local framerate = 60
local framerate_enabled = true
local cache = os.clock()

RunService.RenderStepped:Connect(function()
	if not shadersEnabled.Value then return end
	if not framerate_enabled or os.clock() - cache > 1 / framerate then
		cache = os.clock()

		local xOffset = rng:NextNumber(-0.05, 0.05)
		local yOffset = rng:NextNumber(-0.05, 0.05)
		Noise.Position = UDim2.fromScale(0.5 + xOffset, 0.5 + yOffset)
	end
end)

print("🎬 Single Separated Noise Controller Active (Persists Whole Game).")
