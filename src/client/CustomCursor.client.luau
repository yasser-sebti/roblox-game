--!strict
-- Minimalist Custom Point / Dot Cursor Controller (Hides Default Cursor)
local Players = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")
local RunService = game:GetService("RunService")

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")

-- 1. Construct Custom Cursor ScreenGui (Topmost layer)
local cursorGui = Instance.new("ScreenGui")
cursorGui.Name = "CustomCursorGui"
cursorGui.ResetOnSpawn = false
cursorGui.IgnoreGuiInset = true
cursorGui.DisplayOrder = 2147483647 -- Renders on top of everything
cursorGui.ZIndexBehavior = Enum.ZIndexBehavior.Global
cursorGui.Parent = playerGui

-- 2. Minimalist Round Dot / Point Cursor (6px x 6px)
local cursorDot = Instance.new("Frame")
cursorDot.Name = "CursorDot"
cursorDot.Size = UDim2.new(0, 6, 0, 6)
cursorDot.AnchorPoint = Vector2.new(0.5, 0.5)
cursorDot.Position = UDim2.new(0.5, 0, 0.5, 0)
cursorDot.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
cursorDot.BorderSizePixel = 0
cursorDot.ZIndex = 2147483647
cursorDot.Parent = cursorGui

-- UICorner for clean circular dot shape
local uiCorner = Instance.new("UICorner")
uiCorner.CornerRadius = UDim.new(1, 0)
uiCorner.Parent = cursorDot

-- Subtle dark outline for high contrast
local uiStroke = Instance.new("UIStroke")
uiStroke.Color = Color3.fromRGB(0, 0, 0)
uiStroke.Transparency = 0.4
uiStroke.Thickness = 1
uiStroke.Parent = cursorDot

-- RenderStepped Enforcement: Permanently Hide Default Roblox Cursor & Position Custom Dot
RunService.RenderStepped:Connect(function()
	if UserInputService.MouseIconEnabled then
		UserInputService.MouseIconEnabled = false
	end

	local mousePos = UserInputService:GetMouseLocation()
	cursorDot.Position = UDim2.new(0, mousePos.X, 0, mousePos.Y)
end)

print("🎯 Custom Minimalist Point Cursor Active (Default Roblox Cursor Hidden).")
