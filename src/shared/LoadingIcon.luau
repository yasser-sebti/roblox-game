--!strict
local Players = game:GetService("Players")
local TweenService = game:GetService("TweenService")
local RunService = game:GetService("RunService")

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")

-- Configuration Constants
local CONTAINER_SIZE = UDim2.new(0, 48, 0, 48)
local SQUARE_SIZE = UDim2.new(0, 12, 0, 12)
local SHRINK_SIZE = UDim2.new(0, 5, 0, 5)
local ZERO_SIZE = UDim2.new(0, 0, 0, 0)
local GAP = 5
local ZINDEX = 1000

local APPEAR_DELAY = 0.3 -- Smooth 0.3s delay before cube pop-in intro
local ANIMATION_SPEED = 0.38
local ROTATION_SPEED = 0.75
local WAVE_DELAY = 0.08
local ROTATION_DELAY = 0.08
local RESET_DELAY = 0.08
local POST_ROTATION_DELAY = 0.08
local FADE_IN_DURATION = 0.45 -- Faster, responsive pop-up entrance
local FADE_OUT_DURATION = 0.40 -- Matching pop-down exit

-- Colors (Preserved exact specs)
local SQUARE_DEFAULT_COLOR = Color3.fromRGB(255, 255, 255)
local SQUARE_TARGET_COLOR = Color3.fromRGB(175, 211, 203) -- Pastel sage-mint

local AnimationState = {
	Idle = 0,
	WaveInProgress = 1,
	WaitingForRotation = 2,
	Rotating = 3,
	ResetRotation = 4,
	WaitingForNextCycle = 5,
}

local loadingGui: ScreenGui? = nil
local container: Frame? = nil
local squares: { Frame } = {}

-- Physical Top-Left to Bottom-Right square ordering for each 90-degree orientation step
local waveOrderByStep = {
	[0] = { 1, 2, 3, 4, 5, 6, 7, 8, 9 }, -- 0 degrees orientation
	[1] = { 7, 4, 1, 8, 5, 2, 9, 6, 3 }, -- 90 degrees orientation
	[2] = { 9, 8, 7, 6, 5, 4, 3, 2, 1 }, -- 180 degrees orientation
	[3] = { 3, 6, 9, 2, 5, 8, 1, 4, 7 }, -- 270 degrees orientation
}

local currentState = AnimationState.Idle
local animationInProgress = false
local debounce = false
local activeTweens: { Tween } = {}
local connection: RBXScriptConnection? = nil
local stepCount = 0

local function cancelActiveTweens()
	for _, tween in ipairs(activeTweens) do
		if tween then
			pcall(function()
				tween:Cancel()
			end)
		end
	end
	table.clear(activeTweens)
end

local function initializeGui()
	local existingGui = playerGui:FindFirstChild("LoadingIconGui") :: ScreenGui?
	if existingGui then
		loadingGui = existingGui
		if loadingGui then
			container = loadingGui:FindFirstChild("LoadingIconContainer") :: Frame?
			if container then
				for i = 1, 9 do
					squares[i] = container:FindFirstChild("Square" .. tostring(i)) :: Frame
				end
			end
		end
	else
		local newGui = Instance.new("ScreenGui")
		newGui.Name = "LoadingIconGui"
		newGui.ResetOnSpawn = false
		newGui.DisplayOrder = 20 -- DisplayOrder 20 allows NoiseScreen (999999) to render on top
		newGui.IgnoreGuiInset = true
		newGui.Parent = playerGui
		loadingGui = newGui

		local newContainer = Instance.new("Frame")
		newContainer.Name = "LoadingIconContainer"
		newContainer.Size = CONTAINER_SIZE
		newContainer.BackgroundTransparency = 1
		newContainer.AnchorPoint = Vector2.new(0.5, 0.5)
		newContainer.Position = UDim2.new(0.5, 0, 0.5, 0)
		newContainer.Visible = false
		newContainer.ZIndex = ZINDEX
		newContainer.Parent = newGui
		container = newContainer

		local positions = {
			UDim2.new(0, 1, 0, 1),
			UDim2.new(0, 1 + 12 + GAP, 0, 1),
			UDim2.new(0, 1 + 24 + 2 * GAP, 0, 1),
			UDim2.new(0, 1, 0, 1 + 12 + GAP),
			UDim2.new(0, 1 + 12 + GAP, 0, 1 + 12 + GAP),
			UDim2.new(0, 1 + 24 + 2 * GAP, 0, 1 + 12 + GAP),
			UDim2.new(0, 1, 0, 1 + 24 + 2 * GAP),
			UDim2.new(0, 1 + 12 + GAP, 0, 1 + 24 + 2 * GAP),
			UDim2.new(0, 1 + 24 + 2 * GAP, 0, 1 + 24 + 2 * GAP),
		}

		for i = 1, 9 do
			local square = Instance.new("Frame")
			square.Name = "Square" .. tostring(i)
			square.Size = SQUARE_SIZE
			square.BackgroundColor3 = SQUARE_DEFAULT_COLOR
			square.BackgroundTransparency = 1
			square.BorderSizePixel = 0
			square.ZIndex = ZINDEX
			square.AnchorPoint = Vector2.new(0.5, 0.5)
			square.Position = UDim2.new(0, positions[i].X.Offset + 6, 0, positions[i].Y.Offset + 6)

			local aspectRatio = Instance.new("UIAspectRatioConstraint")
			aspectRatio.AspectRatio = 1
			aspectRatio.Parent = square

			square.Parent = newContainer
			squares[i] = square
		end
	end
end

-- Initialize GUI structure
initializeGui()

local function animateSquare(squareIndex: number)
	local square = squares[squareIndex]
	if not square then return end

	local shrinkTween = TweenService:Create(
		square,
		TweenInfo.new(ANIMATION_SPEED, Enum.EasingStyle.Cubic, Enum.EasingDirection.Out),
		{ Size = SHRINK_SIZE }
	)
	local colorTweenIn = TweenService:Create(
		square,
		TweenInfo.new(ANIMATION_SPEED * 0.6, Enum.EasingStyle.Cubic, Enum.EasingDirection.Out),
		{ BackgroundColor3 = SQUARE_TARGET_COLOR }
	)
	local colorTweenOut = TweenService:Create(
		square,
		TweenInfo.new(ANIMATION_SPEED * 0.8, Enum.EasingStyle.Cubic, Enum.EasingDirection.InOut),
		{ BackgroundColor3 = SQUARE_DEFAULT_COLOR }
	)
	local restoreTween = TweenService:Create(
		square,
		TweenInfo.new(ANIMATION_SPEED * 1.1, Enum.EasingStyle.Cubic, Enum.EasingDirection.InOut),
		{ Size = SQUARE_SIZE }
	)

	table.insert(activeTweens, shrinkTween)
	table.insert(activeTweens, restoreTween)
	table.insert(activeTweens, colorTweenIn)
	table.insert(activeTweens, colorTweenOut)

	shrinkTween:Play()
	colorTweenIn:Play()

	shrinkTween.Completed:Connect(function(playbackState)
		if playbackState == Enum.PlaybackState.Completed and square and square.Parent then
			colorTweenOut:Play()
			restoreTween:Play()
		end
	end)
end

local function playWaveAnimation()
	if animationInProgress then return end
	animationInProgress = true

	local currentOrder = waveOrderByStep[stepCount % 4] or waveOrderByStep[0]

	for i, squareIdx in ipairs(currentOrder) do
		task.delay((i - 1) * WAVE_DELAY, function()
			animateSquare(squareIdx)
		end)
	end

	local waveDuration = (#currentOrder - 1) * WAVE_DELAY + (ANIMATION_SPEED * 2)
	task.delay(waveDuration + ROTATION_DELAY, function()
		if currentState == AnimationState.WaveInProgress then
			currentState = AnimationState.WaitingForRotation
			animationInProgress = false
		end
	end)
end

local function rotateContainer()
	if debounce or not container then return end
	debounce = true

	local targetRotation = container.Rotation + 90

	local rotationTween = TweenService:Create(
		container,
		TweenInfo.new(ROTATION_SPEED, Enum.EasingStyle.Cubic, Enum.EasingDirection.InOut),
		{ Rotation = targetRotation }
	)

	table.insert(activeTweens, rotationTween)
	rotationTween:Play()

	rotationTween.Completed:Connect(function(playbackState)
		if playbackState == Enum.PlaybackState.Completed and container then
			currentState = AnimationState.ResetRotation
			task.delay(POST_ROTATION_DELAY, function()
				currentState = AnimationState.WaitingForNextCycle
				task.delay(RESET_DELAY, function()
					currentState = AnimationState.Idle
					debounce = false
				end)
			end)
		end
	end)
end

local function startAnimationLoop()
	if connection then connection:Disconnect() end

	connection = RunService.Heartbeat:Connect(function()
		if not container or not container.Visible then return end

		if currentState == AnimationState.Idle then
			currentState = AnimationState.WaveInProgress
			playWaveAnimation()
		elseif currentState == AnimationState.WaitingForRotation then
			currentState = AnimationState.Rotating
			stepCount += 1
			rotateContainer()
		end
	end)
end

local function ShowLoadingIcon(position: UDim2?)
	local targetPos = position or UDim2.new(0.5, 0, 0.5, 0)
	if not container then initializeGui() end
	if not container then return end

	container.Position = targetPos

	if connection then
		connection:Disconnect()
		connection = nil
	end
	cancelActiveTweens()

	stepCount = 0
	currentState = AnimationState.Idle
	animationInProgress = false
	debounce = false
	container.Rotation = 0

	for _, square in ipairs(squares) do
		square.Size = ZERO_SIZE
		square.BackgroundColor3 = SQUARE_DEFAULT_COLOR
		square.BackgroundTransparency = 1
	end

	container.Visible = true

	task.spawn(function()
		task.wait(APPEAR_DELAY)
		if not container or not container.Visible then return end

		local completedCount = 0
		local totalSquares = #squares

		for _, square in ipairs(squares) do
			local sizeTween = TweenService:Create(
				square,
				TweenInfo.new(FADE_IN_DURATION, Enum.EasingStyle.Back, Enum.EasingDirection.Out),
				{ Size = SQUARE_SIZE, BackgroundTransparency = 0 }
			)
			table.insert(activeTweens, sizeTween)
			sizeTween:Play()

			sizeTween.Completed:Connect(function(playbackState)
				if playbackState == Enum.PlaybackState.Completed then
					completedCount += 1
					if completedCount >= totalSquares then
						startAnimationLoop()
					end
				end
			end)
		end
	end)
end

local function HideLoadingIcon()
	if container and container.Visible then
		if connection then
			connection:Disconnect()
			connection = nil
		end
		cancelActiveTweens()

		local completedCount = 0
		local totalSquares = #squares

		for _, square in ipairs(squares) do
			local sizeTween = TweenService:Create(
				square,
				TweenInfo.new(FADE_OUT_DURATION, Enum.EasingStyle.Back, Enum.EasingDirection.In),
				{ Size = ZERO_SIZE, BackgroundTransparency = 1 }
			)
			table.insert(activeTweens, sizeTween)
			sizeTween:Play()

			sizeTween.Completed:Connect(function(playbackState)
				if playbackState == Enum.PlaybackState.Completed then
					completedCount += 1
					if completedCount >= totalSquares and container then
						container.Visible = false
						currentState = AnimationState.Idle
						animationInProgress = false
						debounce = false
						for _, sq in ipairs(squares) do
							sq.Size = SQUARE_SIZE
							sq.BackgroundColor3 = SQUARE_DEFAULT_COLOR
						end
					end
				end
			end)
		end
	end
end

local LoadingIconModule = {
	Show = ShowLoadingIcon,
	Hide = HideLoadingIcon,
}

return LoadingIconModule
