--!strict
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")
local playerScripts = player:WaitForChild("PlayerScripts")

-- Shared contract with the procedural locomotion controller. While this is true,
-- locomotion must not restore WalkSpeed or start a gait cycle.
player:SetAttribute("MovementLocked", true)

-- Respect the player's current view choice. The locomotion script owns the V/R3 toggle.
local firstPersonEnabled = player:GetAttribute("FirstPersonEnabled") ~= false
if firstPersonEnabled then
	player.CameraMode = Enum.CameraMode.LockFirstPerson
	player.CameraMinZoomDistance = 0.5
	player.CameraMaxZoomDistance = 0.5
else
	player.CameraMaxZoomDistance = 18
	player.CameraMinZoomDistance = 7
	player.CameraMode = Enum.CameraMode.Classic
end

local FONT_ROBOTO = Enum.Font.Roboto
local GAME_LOGO_ASSET_ID: string = "rbxassetid://138133070782390"
local BAR_DURATION = 10
local SEGMENT_COUNT = 18

-- Shared LoadingIcon Module
local Shared = ReplicatedStorage:WaitForChild("Shared")
local loadingIconScript = Shared:WaitForChild("LoadingIcon", 10)
local LoadingIconModule: any = nil

if loadingIconScript and loadingIconScript:IsA("ModuleScript") then
	local success, mod = pcall(function()
		return require(loadingIconScript)
	end)
	if success then
		LoadingIconModule = mod
	end
end

-- Disable Player Controls safely
local controls: any = nil
pcall(function()
	local playerModuleScript = playerScripts:WaitForChild("PlayerModule", 10)
	if playerModuleScript and playerModuleScript:IsA("ModuleScript") then
		local PlayerModule = require(playerModuleScript) :: any
		if PlayerModule and PlayerModule.GetControls then
			controls = PlayerModule:GetControls()
		end
	end
end)

local function disableMovement(character: Model)
	local humanoidObj = character:WaitForChild("Humanoid", 10)
	if humanoidObj and humanoidObj:IsA("Humanoid") then
		humanoidObj.WalkSpeed = 0
		humanoidObj.JumpPower = 0
		humanoidObj.JumpHeight = 0
	end
	if controls and controls.Disable then
		controls:Disable()
	end
end

local function enableMovement(character: Model)
	local humanoidObj = character:FindFirstChildOfClass("Humanoid")
	if humanoidObj and humanoidObj:IsA("Humanoid") then
		humanoidObj.WalkSpeed = 7 -- Slow horror walk; sprint and crouch are owned by locomotion
		humanoidObj.JumpPower = 40
		humanoidObj.JumpHeight = 5.5
	end
	if controls and controls.Enable then
		controls:Enable()
	end
end

-- State
local isLoaded = false
local stopDots = false
local floatConnection: RBXScriptConnection? = nil

-- Lock character on spawn during loading
local currentCharacter = player.Character
if currentCharacter then
	disableMovement(currentCharacter)
end

local charConnection: RBXScriptConnection
charConnection = player.CharacterAdded:Connect(function(char)
	if not isLoaded then
		disableMovement(char)
	end
end)

-- Construct Main Loading UI
local screenGui = Instance.new("ScreenGui")
screenGui.Name = "LoadingScreenGui"
screenGui.ResetOnSpawn = false
screenGui.IgnoreGuiInset = true
screenGui.DisplayOrder = 10
screenGui.Parent = playerGui

local bgFrame = Instance.new("Frame")
bgFrame.Name = "Background"
bgFrame.Size = UDim2.new(1, 0, 1, 0)
bgFrame.Position = UDim2.new(0, 0, 0, 0)
bgFrame.BackgroundColor3 = Color3.fromRGB(0, 0, 0)
bgFrame.BorderSizePixel = 0
bgFrame.Parent = screenGui

-- Skip Button
local skipButton = Instance.new("TextButton")
skipButton.Name = "SkipButton"
skipButton.Size = UDim2.new(0, 110, 0, 36)
skipButton.AnchorPoint = Vector2.new(1, 1)
skipButton.Position = UDim2.new(1, -30, 1, -30)
skipButton.BackgroundColor3 = Color3.fromRGB(20, 20, 20)
skipButton.BackgroundTransparency = 0.4
skipButton.BorderSizePixel = 0
skipButton.Text = "SKIP >"
skipButton.TextColor3 = Color3.fromRGB(255, 255, 255)
skipButton.TextSize = 16
skipButton.Font = FONT_ROBOTO
skipButton.Modal = true
skipButton.ZIndex = 100
skipButton.Parent = bgFrame

local uiCorner = Instance.new("UICorner")
uiCorner.CornerRadius = UDim.new(0, 6)
uiCorner.Parent = skipButton

local uiStroke = Instance.new("UIStroke")
uiStroke.Color = Color3.fromRGB(255, 255, 255)
uiStroke.Transparency = 0.6
uiStroke.Thickness = 1
uiStroke.Parent = skipButton

skipButton.MouseEnter:Connect(function()
	TweenService:Create(skipButton, TweenInfo.new(0.2), { BackgroundTransparency = 0.1 }):Play()
	TweenService:Create(uiStroke, TweenInfo.new(0.2), { Transparency = 0.2 }):Play()
end)

skipButton.MouseLeave:Connect(function()
	TweenService:Create(skipButton, TweenInfo.new(0.2), { BackgroundTransparency = 0.4 }):Play()
	TweenService:Create(uiStroke, TweenInfo.new(0.2), { Transparency = 0.6 }):Play()
end)

local function finishLoadingAndCleanUp()
	if isLoaded then return end
	isLoaded = true
	stopDots = true

	if floatConnection then
		floatConnection:Disconnect()
		floatConnection = nil
	end

	if LoadingIconModule and LoadingIconModule.Hide then
		LoadingIconModule.Hide()
	end

	local skipFade = TweenService:Create(bgFrame, TweenInfo.new(0.4, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
		BackgroundTransparency = 1,
	})
	skipFade:Play()

	skipFade.Completed:Connect(function()
		player:SetAttribute("MovementLocked", false)
		if player.Character then
			enableMovement(player.Character)
		end
		charConnection:Disconnect()
		screenGui:Destroy()
		print("✅ Loading screen sequence finished. Movement restored.")
	end)
end

skipButton.Activated:Connect(finishLoadingAndCleanUp)

-- Bottom-Left UI Container
local bottomLeftContainer = Instance.new("Frame")
bottomLeftContainer.Name = "BottomLeftContainer"
bottomLeftContainer.Size = UDim2.new(0, 300, 0, 80)
bottomLeftContainer.Position = UDim2.new(0, 45, 1, -115)
bottomLeftContainer.BackgroundTransparency = 1
bottomLeftContainer.Parent = bgFrame

local loadingText = Instance.new("TextLabel")
loadingText.Name = "LoadingText"
loadingText.Size = UDim2.new(0, 240, 0, 28)
loadingText.Position = UDim2.new(0, 0, 0, 0)
loadingText.BackgroundTransparency = 1
loadingText.Text = "Loading.."
loadingText.TextColor3 = Color3.fromRGB(255, 255, 255)
loadingText.TextSize = 24
loadingText.Font = FONT_ROBOTO
loadingText.TextXAlignment = Enum.TextXAlignment.Left
loadingText.Parent = bottomLeftContainer

-- Animated dots
task.spawn(function()
	local dots = { "Loading.", "Loading..", "Loading..." }
	local idx = 1
	while not stopDots and not isLoaded do
		task.wait(0.4)
		if stopDots or isLoaded then break end
		idx = (idx % #dots) + 1
		loadingText.Text = dots[idx]
	end
end)

-- Bar Segments
local barFrame = Instance.new("Frame")
barFrame.Name = "LoadingBarFrame"
barFrame.Size = UDim2.new(0, 250, 0, 22)
barFrame.Position = UDim2.new(0, 0, 0, 36)
barFrame.BackgroundTransparency = 1
barFrame.Parent = bottomLeftContainer

local listLayout = Instance.new("UIListLayout")
listLayout.FillDirection = Enum.FillDirection.Horizontal
listLayout.HorizontalAlignment = Enum.HorizontalAlignment.Left
listLayout.VerticalAlignment = Enum.VerticalAlignment.Center
listLayout.SortOrder = Enum.SortOrder.LayoutOrder
listLayout.Padding = UDim.new(0, 5)
listLayout.Parent = barFrame

local barSegments: { Frame } = {}
for i = 1, SEGMENT_COUNT do
	local seg = Instance.new("Frame")
	seg.Name = "Segment_" .. i
	seg.LayoutOrder = i
	seg.Size = UDim2.new(0, 5, 0, 18)
	seg.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
	seg.BackgroundTransparency = 0.90
	seg.BorderSizePixel = 0
	seg.Parent = barFrame
	table.insert(barSegments, seg)
end

-- Idle float animation
local startTime = os.clock()
floatConnection = RunService.RenderStepped:Connect(function()
	if isLoaded or not bottomLeftContainer or not bottomLeftContainer.Parent then
		if floatConnection then floatConnection:Disconnect() end
		return
	end
	local t = os.clock() - startTime
	bottomLeftContainer.Position = UDim2.new(0, 45 + math.round(math.sin(t * 2.2) * 3), 1, -115 + math.round(math.cos(t * 1.8) * 2))
	bottomLeftContainer.Rotation = math.sin(t * 1.5) * 0.8
end)

------------------------------------------------------------------------
-- Named Main Sequence Function (avoids linter false positives)
------------------------------------------------------------------------
local function runLoadingSequence()
	-- PHASE 1: Progress Bar
	local rawWeights = {}
	local totalWeight = 0
	for i = 1, SEGMENT_COUNT do
		local w = math.random(4, 16)
		table.insert(rawWeights, w)
		totalWeight += w
	end

	for i, seg in ipairs(barSegments) do
		if isLoaded then break end
		local stepDelay = (rawWeights[i] / totalWeight) * BAR_DURATION
		local tween = TweenService:Create(seg, TweenInfo.new(stepDelay * 0.7, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
			BackgroundTransparency = 0,
		})
		tween:Play()
		task.wait(stepDelay)
	end

	if isLoaded then return end

	stopDots = true
	loadingText.Text = "Loading complete"

	if floatConnection then
		floatConnection:Disconnect()
		floatConnection = nil
	end

	local fadeOutInfo = TweenInfo.new(0.8, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
	TweenService:Create(loadingText, fadeOutInfo, { TextTransparency = 1 }):Play()
	for _, seg in ipairs(barSegments) do
		TweenService:Create(seg, fadeOutInfo, { BackgroundTransparency = 1 }):Play()
	end

	task.wait(1.0)
	if isLoaded then return end
	bottomLeftContainer:Destroy()

	-- PHASE 2: Creator Text
	local creatorContainer = Instance.new("Frame")
	creatorContainer.Name = "CreatorContainer"
	creatorContainer.Size = UDim2.new(0, 400, 0, 100)
	creatorContainer.AnchorPoint = Vector2.new(0.5, 0.5)
	creatorContainer.Position = UDim2.new(0.5, 0, 0.5, 0)
	creatorContainer.BackgroundTransparency = 1
	creatorContainer.Parent = bgFrame

	local creatorSubText = Instance.new("TextLabel")
	creatorSubText.Name = "CreatorSubText"
	creatorSubText.Size = UDim2.new(1, 0, 0, 30)
	creatorSubText.Position = UDim2.new(0, 0, 0, 0)
	creatorSubText.BackgroundTransparency = 1
	creatorSubText.Text = "A story game made by :"
	creatorSubText.TextColor3 = Color3.fromRGB(255, 255, 255)
	creatorSubText.TextSize = 22
	creatorSubText.Font = FONT_ROBOTO
	creatorSubText.TextTransparency = 1
	creatorSubText.Parent = creatorContainer

	local creatorNameText = Instance.new("TextLabel")
	creatorNameText.Name = "CreatorNameText"
	creatorNameText.Size = UDim2.new(1, 0, 0, 48)
	creatorNameText.Position = UDim2.new(0, 0, 0, 36)
	creatorNameText.BackgroundTransparency = 1
	creatorNameText.Text = "SebtiBlox"
	creatorNameText.TextColor3 = Color3.fromRGB(255, 255, 255)
	creatorNameText.TextSize = 38
	creatorNameText.Font = FONT_ROBOTO
	creatorNameText.TextTransparency = 1
	creatorNameText.Parent = creatorContainer

	local textFadeIn = TweenInfo.new(1.2, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
	TweenService:Create(creatorSubText, textFadeIn, { TextTransparency = 0 }):Play()
	TweenService:Create(creatorNameText, textFadeIn, { TextTransparency = 0 }):Play()

	task.wait(2.2)
	if isLoaded then return end

	local textFadeOut = TweenInfo.new(1.0, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
	TweenService:Create(creatorSubText, textFadeOut, { TextTransparency = 1 }):Play()
	TweenService:Create(creatorNameText, textFadeOut, { TextTransparency = 1 }):Play()

	task.wait(1.2)
	if isLoaded then return end
	creatorContainer:Destroy()

	-- PHASE 3: Hint + Loading Cube
	local hintLabel = Instance.new("TextLabel")
	hintLabel.Name = "HintLabel"
	hintLabel.Size = UDim2.new(0, 600, 0, 40)
	hintLabel.AnchorPoint = Vector2.new(0.5, 0.5)
	hintLabel.Position = UDim2.new(0.5, 0, 0.44, 0)
	hintLabel.BackgroundTransparency = 1
	hintLabel.Text = "The game is being saved if u see this loading"
	hintLabel.TextColor3 = Color3.fromRGB(255, 255, 255)
	hintLabel.TextSize = 20
	hintLabel.Font = FONT_ROBOTO
	hintLabel.TextTransparency = 1
	hintLabel.Parent = bgFrame

	TweenService:Create(hintLabel, TweenInfo.new(1.0, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
		TextTransparency = 0,
	}):Play()

	task.wait(0.4)
	if isLoaded then return end

	if LoadingIconModule and LoadingIconModule.Show then
		LoadingIconModule.Show(UDim2.new(0.5, 0, 0.56, 0))
	end

	task.wait(3.5)
	if isLoaded then return end

	if LoadingIconModule and LoadingIconModule.Hide then
		LoadingIconModule.Hide()
	end

	TweenService:Create(hintLabel, TweenInfo.new(1.0, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
		TextTransparency = 1,
	}):Play()

	task.wait(1.2)
	if isLoaded then return end
	hintLabel:Destroy()

	-- PHASE 4: Game Logo
	local logoContainer = Instance.new("Frame")
	logoContainer.Name = "LogoContainer"
	logoContainer.Size = UDim2.new(0.65, 0, 0.5, 0)
	logoContainer.AnchorPoint = Vector2.new(0.5, 0.5)
	logoContainer.Position = UDim2.new(0.5, 0, 0.5, 0)
	logoContainer.BackgroundTransparency = 1
	logoContainer.Parent = bgFrame

	local aspectRatioConstraint = Instance.new("UIAspectRatioConstraint")
	aspectRatioConstraint.AspectRatio = 1.6
	aspectRatioConstraint.AspectType = Enum.AspectType.FitWithinMaxSize
	aspectRatioConstraint.DominantAxis = Enum.DominantAxis.Width
	aspectRatioConstraint.Parent = logoContainer

	local resolvedImage = GAME_LOGO_ASSET_ID
	if resolvedImage == "" then
		local assetsFolder = ReplicatedStorage:FindFirstChild("Assets")
		if assetsFolder then
			local decalObj = assetsFolder:FindFirstChild("Game Logo") or assetsFolder:FindFirstChild("GameLogo")
			if decalObj then
				if decalObj:IsA("Decal") and decalObj.Texture ~= "" then
					resolvedImage = decalObj.Texture
				elseif decalObj:IsA("Texture") and decalObj.Texture ~= "" then
					resolvedImage = decalObj.Texture
				end
			end
		end
	end

	local logoImage: ImageLabel? = nil
	local fallbackText: TextLabel? = nil

	if resolvedImage ~= "" then
		local newLogo = Instance.new("ImageLabel")
		newLogo.Name = "GameLogoImage"
		newLogo.Size = UDim2.new(1, 0, 1, 0)
		newLogo.BackgroundTransparency = 1
		newLogo.Image = resolvedImage
		newLogo.ScaleType = Enum.ScaleType.Fit
		newLogo.ResampleMode = Enum.ResamplerMode.Default
		newLogo.ImageTransparency = 0
		newLogo.Parent = logoContainer
		logoImage = newLogo
	else
		local newFallback = Instance.new("TextLabel")
		newFallback.Name = "GameLogoFallbackText"
		newFallback.Size = UDim2.new(1, 0, 1, 0)
		newFallback.BackgroundTransparency = 1
		newFallback.Text = "GAME LOGO"
		newFallback.TextColor3 = Color3.fromRGB(255, 255, 255)
		newFallback.TextSize = 54
		newFallback.Font = FONT_ROBOTO
		newFallback.TextTransparency = 0
		newFallback.Parent = logoContainer
		fallbackText = newFallback
	end

	task.wait(2.2)
	if isLoaded then return end

	local logoFadeOut = TweenInfo.new(1.5, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
	if logoImage then
		TweenService:Create(logoImage, logoFadeOut, { ImageTransparency = 1 }):Play()
	end
	if fallbackText then
		TweenService:Create(fallbackText, logoFadeOut, { TextTransparency = 1 }):Play()
	end

	task.wait(1.5)
	if isLoaded then return end

	finishLoadingAndCleanUp()
end

-- Start the loading sequence
task.spawn(runLoadingSequence)
