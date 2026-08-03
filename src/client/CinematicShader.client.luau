--!strict

local Lighting = game:GetService("Lighting")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local settings = ReplicatedStorage:WaitForChild("GameSettings")
local shadersEnabled = settings:WaitForChild("ShadersEnabled") :: BoolValue
local nightEnabled = settings:WaitForChild("NightEnabled") :: BoolValue

local function getOrCreateEffect(className: string, name: string): Instance
	local existing = Lighting:FindFirstChild(name)
	if existing and existing.ClassName == className then return existing end
	if existing then existing:Destroy() end
	local effect = Instance.new(className)
	effect.Name = name
	effect.Parent = Lighting
	return effect
end

local atmosphere = Lighting:FindFirstChild("RepoAtmosphere")
if atmosphere and not atmosphere:IsA("Atmosphere") then atmosphere:Destroy(); atmosphere = nil end
if not atmosphere then
	atmosphere = Instance.new("Atmosphere")
	atmosphere.Name = "RepoAtmosphere"
	atmosphere.Parent = Lighting
end
local atmosphereEffect = atmosphere :: Atmosphere

local colorCorrection = getOrCreateEffect("ColorCorrectionEffect", "RepoColorCorrection") :: ColorCorrectionEffect
colorCorrection.Contrast = 0.18
colorCorrection.Saturation = -0.22
colorCorrection.Brightness = 0
colorCorrection.TintColor = Color3.fromRGB(240, 245, 255)

local bloom = getOrCreateEffect("BloomEffect", "RepoBloom") :: BloomEffect
bloom.Intensity = 0.6
bloom.Size = 32
bloom.Threshold = 0.75

local depthOfField = getOrCreateEffect("DepthOfFieldEffect", "RepoDepthOfField") :: DepthOfFieldEffect
depthOfField.FarIntensity = 0.35
depthOfField.NearIntensity = 0.15
depthOfField.FocusDistance = 15
depthOfField.InFocusRadius = 25

local function applyShaders()
	local enabled = shadersEnabled.Value
	colorCorrection.Enabled = enabled
	bloom.Enabled = enabled
	depthOfField.Enabled = enabled
end

local function applyNight()
	if nightEnabled.Value then
		Lighting.ClockTime = 18.5
		Lighting.Brightness = 1.25
		Lighting.Ambient = Color3.fromRGB(55, 65, 80)
		Lighting.OutdoorAmbient = Color3.fromRGB(85, 95, 115)
		Lighting.EnvironmentDiffuseScale = 0.4
		Lighting.EnvironmentSpecularScale = 0.4
		atmosphereEffect.Density = 0.32
		atmosphereEffect.Offset = 0.2
		atmosphereEffect.Color = Color3.fromRGB(110, 130, 155)
		atmosphereEffect.Decay = Color3.fromRGB(60, 75, 95)
		atmosphereEffect.Glare = 0.2
		atmosphereEffect.Haze = 1.8
	else
		Lighting.ClockTime = 14
		Lighting.Brightness = 2
		Lighting.Ambient = Color3.fromRGB(128, 128, 128)
		Lighting.OutdoorAmbient = Color3.fromRGB(128, 128, 128)
		Lighting.EnvironmentDiffuseScale = 1
		Lighting.EnvironmentSpecularScale = 1
		atmosphereEffect.Density = 0.12
		atmosphereEffect.Offset = 0
		atmosphereEffect.Color = Color3.fromRGB(199, 212, 229)
		atmosphereEffect.Decay = Color3.fromRGB(106, 112, 125)
		atmosphereEffect.Glare = 0.05
		atmosphereEffect.Haze = 0.3
	end
	Lighting.GlobalShadows = true
	pcall(function() Lighting.Technology = Enum.Technology.Future end)
end

local function applyWorkspaceParameters()
	Workspace.Terrain.WaterColor = Color3.fromRGB(20, 30, 45)
	Workspace.Terrain.WaterTransparency = 0.85
	Workspace.Terrain.WaterWaveSize = 0.05
	local camera = Workspace.CurrentCamera
	if camera then camera.FieldOfView = 75 end
end

shadersEnabled:GetPropertyChangedSignal("Value"):Connect(applyShaders)
nightEnabled:GetPropertyChangedSignal("Value"):Connect(applyNight)
applyShaders()
applyNight()
applyWorkspaceParameters()

print(string.format("Cinematic visuals ready. Shaders=%s Night=%s", tostring(shadersEnabled.Value), tostring(nightEnabled.Value)))
