--!strict

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local StarterPlayer = game:GetService("StarterPlayer")
local Workspace = game:GetService("Workspace")

local RigCatalog = {}

local REQUIRED_PARTS = table.freeze({
	"HumanoidRootPart", "LowerTorso", "UpperTorso", "Head",
	"LeftUpperArm", "LeftLowerArm", "LeftHand", "RightUpperArm", "RightLowerArm", "RightHand",
	"LeftUpperLeg", "LeftLowerLeg", "LeftFoot", "RightUpperLeg", "RightLowerLeg", "RightFoot",
})
local REQUIRED_JOINTS = table.freeze({
	"Root", "Waist", "Neck", "LeftShoulder", "LeftElbow", "LeftWrist",
	"RightShoulder", "RightElbow", "RightWrist", "LeftHip", "LeftKnee", "LeftAnkle",
	"RightHip", "RightKnee", "RightAnkle",
})

local function canonical(name: string): string return if name == "RootJoint" then "Root" else name end

function RigCatalog.validate(model: Instance?): (boolean, string?)
	if not model or not model:IsA("Model") then return false, "Select an R15 Model." end
	local humanoid = model:FindFirstChildOfClass("Humanoid")
	if not humanoid then return false, "The model needs a Humanoid." end
	for _, name in REQUIRED_PARTS do
		if not model:FindFirstChild(name, true) then return false, "Missing R15 body part: " .. name end
	end
	local motors: { [string]: boolean } = {}
	for _, item in model:GetDescendants() do
		if item:IsA("Motor6D") and item.Part0 and item.Part1 then motors[canonical(item.Name)] = true end
	end
	for _, name in REQUIRED_JOINTS do if not motors[name] then return false, "Missing Motor6D: " .. name end end
	return true, nil
end

local function createFallbackR15(): Model
	local model = Instance.new("Model")
	model.Name = "DefaultGrayR15"

	local function part(name: string, size: Vector3, position: Vector3, transparency: number?): Part
		local item = Instance.new("Part")
		item.Name = name; item.Size = size; item.Position = position; item.Color = Color3.fromRGB(145, 145, 145)
		item.Material = Enum.Material.SmoothPlastic; item.TopSurface = Enum.SurfaceType.Smooth; item.BottomSurface = Enum.SurfaceType.Smooth
		item.CanCollide = false; item.CanTouch = false; item.Anchored = false; item.Transparency = transparency or 0; item.Parent = model
		return item
	end

	local parts: { [string]: BasePart } = {
		HumanoidRootPart = part("HumanoidRootPart", Vector3.new(2, 2, 1), Vector3.new(0, 3.15, 0), 1),
		LowerTorso = part("LowerTorso", Vector3.new(2, 1.5, 1), Vector3.new(0, 3.15, 0)),
		UpperTorso = part("UpperTorso", Vector3.new(2.25, 1.65, 1.05), Vector3.new(0, 4.72, 0)),
		Head = part("Head", Vector3.new(1.55, 1.55, 1.55), Vector3.new(0, 6.35, 0)),
		LeftUpperArm = part("LeftUpperArm", Vector3.new(0.8, 1.55, 0.8), Vector3.new(-1.53, 4.55, 0)),
		LeftLowerArm = part("LeftLowerArm", Vector3.new(0.72, 1.45, 0.72), Vector3.new(-1.53, 3.05, 0)),
		LeftHand = part("LeftHand", Vector3.new(0.72, 0.72, 0.72), Vector3.new(-1.53, 1.97, 0)),
		RightUpperArm = part("RightUpperArm", Vector3.new(0.8, 1.55, 0.8), Vector3.new(1.53, 4.55, 0)),
		RightLowerArm = part("RightLowerArm", Vector3.new(0.72, 1.45, 0.72), Vector3.new(1.53, 3.05, 0)),
		RightHand = part("RightHand", Vector3.new(0.72, 0.72, 0.72), Vector3.new(1.53, 1.97, 0)),
		LeftUpperLeg = part("LeftUpperLeg", Vector3.new(0.9, 1.8, 0.9), Vector3.new(-0.53, 1.75, 0)),
		LeftLowerLeg = part("LeftLowerLeg", Vector3.new(0.82, 1.75, 0.82), Vector3.new(-0.53, 0, 0)),
		LeftFoot = part("LeftFoot", Vector3.new(0.82, 0.65, 1.25), Vector3.new(-0.53, -1.17, -0.2)),
		RightUpperLeg = part("RightUpperLeg", Vector3.new(0.9, 1.8, 0.9), Vector3.new(0.53, 1.75, 0)),
		RightLowerLeg = part("RightLowerLeg", Vector3.new(0.82, 1.75, 0.82), Vector3.new(0.53, 0, 0)),
		RightFoot = part("RightFoot", Vector3.new(0.82, 0.65, 1.25), Vector3.new(0.53, -1.17, -0.2)),
	}

	local function motor(name: string, part0Name: string, part1Name: string, jointPosition: Vector3)
		local part0, part1 = parts[part0Name], parts[part1Name]
		local world = CFrame.new(jointPosition)
		local item = Instance.new("Motor6D")
		item.Name = name; item.Part0 = part0; item.Part1 = part1
		item.C0 = part0.CFrame:ToObjectSpace(world); item.C1 = part1.CFrame:ToObjectSpace(world); item.Parent = part0
	end

	motor("Root", "HumanoidRootPart", "LowerTorso", Vector3.new(0, 3.15, 0))
	motor("Waist", "LowerTorso", "UpperTorso", Vector3.new(0, 3.91, 0))
	motor("Neck", "UpperTorso", "Head", Vector3.new(0, 5.55, 0))
	motor("LeftShoulder", "UpperTorso", "LeftUpperArm", Vector3.new(-1.13, 4.9, 0))
	motor("LeftElbow", "LeftUpperArm", "LeftLowerArm", Vector3.new(-1.53, 3.78, 0))
	motor("LeftWrist", "LeftLowerArm", "LeftHand", Vector3.new(-1.53, 2.33, 0))
	motor("RightShoulder", "UpperTorso", "RightUpperArm", Vector3.new(1.13, 4.9, 0))
	motor("RightElbow", "RightUpperArm", "RightLowerArm", Vector3.new(1.53, 3.78, 0))
	motor("RightWrist", "RightLowerArm", "RightHand", Vector3.new(1.53, 2.33, 0))
	motor("LeftHip", "LowerTorso", "LeftUpperLeg", Vector3.new(-0.53, 2.4, 0))
	motor("LeftKnee", "LeftUpperLeg", "LeftLowerLeg", Vector3.new(-0.53, 0.87, 0))
	motor("LeftAnkle", "LeftLowerLeg", "LeftFoot", Vector3.new(-0.53, -0.85, -0.05))
	motor("RightHip", "LowerTorso", "RightUpperLeg", Vector3.new(0.53, 2.4, 0))
	motor("RightKnee", "RightUpperLeg", "RightLowerLeg", Vector3.new(0.53, 0.87, 0))
	motor("RightAnkle", "RightLowerLeg", "RightFoot", Vector3.new(0.53, -0.85, -0.05))

	local humanoid = Instance.new("Humanoid")
	humanoid.Name = "Humanoid"; humanoid.DisplayDistanceType = Enum.HumanoidDisplayDistanceType.None; humanoid.Parent = model
	Instance.new("Animator", humanoid)
	model.PrimaryPart = parts.HumanoidRootPart
	return model
end

function RigCatalog.folder(): Folder
	local existing = ReplicatedStorage:FindFirstChild("PoseTunerDummies")
	if existing and existing:IsA("Folder") then return existing end
	if existing then existing:Destroy() end
	local folder = Instance.new("Folder")
	folder.Name = "PoseTunerDummies"
	folder.Parent = ReplicatedStorage
	return folder
end

local function gray(model: Model)
	model.Name = "DefaultGrayR15"
	for _, item in model:GetDescendants() do
		if item:IsA("Accessory") or item:IsA("Clothing") or item:IsA("ShirtGraphic") or item:IsA("LuaSourceContainer") then
			item:Destroy()
		elseif item:IsA("BasePart") then
			item.Color = Color3.fromRGB(145, 145, 145)
			item.Material = Enum.Material.SmoothPlastic
			item.CanCollide = false
			item.Anchored = false
		end
	end
	local humanoid = model:FindFirstChildOfClass("Humanoid")
	if humanoid then humanoid.DisplayDistanceType = Enum.HumanoidDisplayDistanceType.None end
end

function RigCatalog.ensureDefault(): (Model?, string?)
	local folder = RigCatalog.folder()
	local existing = folder:FindFirstChild("DefaultGrayR15")
	if existing then
		local valid = RigCatalog.validate(existing)
		if valid then return existing :: Model, nil end
		existing:Destroy()
	end
	local ok, result = pcall(function()
		local description = Instance.new("HumanoidDescription")
		description.BodyTypeScale = 0
		description.ProportionScale = 0
		description.HeightScale = 1
		description.WidthScale = 1
		description.DepthScale = 1
		description.HeadScale = 1
		return Players:CreateHumanoidModelFromDescriptionAsync(description, Enum.HumanoidRigType.R15)
	end)
	if ok and result and result:IsA("Model") then
		gray(result); result.Parent = folder
		local valid = RigCatalog.validate(result)
		if valid then return result, nil end
		-- Some Studio/avatar-service versions return a visually R15 model with an incomplete Motor6D chain.
		local humanoid = result:FindFirstChildOfClass("Humanoid")
		if humanoid then pcall(function() humanoid:BuildRigFromAttachments() end) end
		valid = RigCatalog.validate(result)
		if valid then return result, nil end
		result:Destroy()
	end

	local fallback = createFallbackR15()
	fallback.Parent = folder
	local valid, reason = RigCatalog.validate(fallback)
	if not valid then fallback:Destroy(); return nil, "Fallback R15 failed validation: " .. tostring(reason) end
	return fallback, "Avatar service returned an incomplete rig; using the local block R15."
end

function RigCatalog.list(hidden: { string }): { Model }
	local blocked: { [string]: boolean } = {}
	for _, name in hidden do blocked[name] = true end
	local models = {}
	for _, item in RigCatalog.folder():GetChildren() do
		if item:IsA("Model") and not blocked[item.Name] then
			local valid = RigCatalog.validate(item)
			if valid then table.insert(models, item) end
		end
	end
	table.sort(models, function(a, b)
		if a.Name == "DefaultGrayR15" then return true end
		if b.Name == "DefaultGrayR15" then return false end
		return a.Name:lower() < b.Name:lower()
	end)
	return models
end

function RigCatalog.importModel(source: Model): (Model?, string?)
	local valid, reason = RigCatalog.validate(source)
	if not valid then return nil, reason end
	local folder = RigCatalog.folder()
	local base = string.gsub(source.Name, "[^%w_ %-]", "")
	if base == "" then base = "ImportedR15" end
	local name, suffix = base, 2
	while folder:FindFirstChild(name) do name = base .. " " .. suffix; suffix += 1 end
	local oldArchivable = source.Archivable
	source.Archivable = true
	local clone = source:Clone()
	source.Archivable = oldArchivable
	clone.Name = name
	clone.Parent = folder
	return clone, nil
end

function RigCatalog.findGameDummy(): Model?
	local candidates = {
		Workspace:FindFirstChild("Dummy"), Workspace:FindFirstChild("Test Guy"),
		ReplicatedStorage:FindFirstChild("Dummy"), StarterPlayer:FindFirstChild("StarterCharacter"),
	}
	for _, candidate in candidates do
		if candidate and candidate:IsA("Model") then
			local valid = RigCatalog.validate(candidate)
			if valid then return candidate end
		end
	end
	return nil
end

return RigCatalog
