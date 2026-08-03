--!strict

local HttpService = game:GetService("HttpService")

local Persistence = {}
Persistence.__index = Persistence

local SETTINGS_KEY = "R15PoseTunerStateV3"
local MAX_ANIMATIONS = 100
local MAX_KEYS = 2000

local function safeText(value: any, fallback: string, limit: number): string
	if typeof(value) ~= "string" then return fallback end
	local cleaned = string.gsub(value, "[\\\"\r\n%z]", "")
	if cleaned == "" then return fallback end
	return string.sub(cleaned, 1, limit)
end

local function safeStringList(value: any): { string }
	local result = {}
	if typeof(value) ~= "table" then return result end
	for _, item in value do
		if #result >= 100 then break end
		if typeof(item) == "string" then table.insert(result, safeText(item, "Unnamed", 128)) end
	end
	return result
end

local function encodeCFrame(value: CFrame): { number }
	return { value:GetComponents() }
end

local function decodeCFrame(value: any): CFrame?
	if typeof(value) ~= "table" or #value ~= 12 then return nil end
	local numbers = table.create(12)
	for index = 1, 12 do
		if typeof(value[index]) ~= "number" then return nil end
		numbers[index] = value[index]
	end
	return CFrame.new(table.unpack(numbers))
end

function Persistence.encodeDocument(document: any): any
	local keys = {}
	for _, key in document.Keyframes do
		local values = {}
		for name, transform in key.Values do values[name] = encodeCFrame(transform) end
		table.insert(keys, {
			Id = key.Id, Time = key.Time, Values = values,
			EasingStyle = key.EasingStyle, EasingDirection = key.EasingDirection,
			GroundLock = key.GroundLock ~= false, Smooth = key.Smooth ~= false,
		})
	end
	return {
		Duration = document.Duration, PlaybackSpeed = document.PlaybackSpeed, FPS = document.FPS,
		Loop = document.Loop, Interpolation = document.Interpolation, AutoKey = document.AutoKey,
		Keyframes = keys,
	}
end

function Persistence.decodeDocument(raw: any, Document: any): any?
	if typeof(raw) ~= "table" or typeof(raw.Keyframes) ~= "table" or #raw.Keyframes > MAX_KEYS then return nil end
	local document = Document.new()
	document.Duration = math.clamp(if typeof(raw.Duration) == "number" then raw.Duration else 2, 0.05, 600)
	document.PlaybackSpeed = math.clamp(if typeof(raw.PlaybackSpeed) == "number" then raw.PlaybackSpeed else 1, 0.05, 8)
	document.FPS = math.clamp(math.round(if typeof(raw.FPS) == "number" then raw.FPS else 30), 1, 240)
	document.Loop = raw.Loop ~= false
	document.Interpolation = if raw.Interpolation == "Smooth" then "Smooth" else "Step"
	document.AutoKey = raw.AutoKey ~= false
	for _, rawKey in raw.Keyframes do
		if typeof(rawKey) == "table" and typeof(rawKey.Id) == "string" and typeof(rawKey.Time) == "number" and typeof(rawKey.Values) == "table" then
			local values = {}
			for name, encoded in rawKey.Values do
				if typeof(name) == "string" then
					local transform = decodeCFrame(encoded)
					if transform then values[name] = transform end
				end
			end
			table.insert(document.Keyframes, {
				Id = string.sub(rawKey.Id, 1, 128), Time = math.clamp(rawKey.Time, 0, document.Duration), Values = values,
				EasingStyle = if table.find(Document.EasingStyles, rawKey.EasingStyle) then rawKey.EasingStyle else "Linear",
				EasingDirection = if table.find(Document.EasingDirections, rawKey.EasingDirection) then rawKey.EasingDirection else "InOut",
				GroundLock = rawKey.GroundLock ~= false,
				Smooth = if rawKey.Smooth ~= nil then rawKey.Smooth ~= false else document.Interpolation == "Smooth",
			})
		end
	end
	Document.sort(document)
	return document
end

function Persistence.new(pluginObject: Plugin, Document: any)
	return setmetatable({ Plugin = pluginObject, Document = Document, State = nil }, Persistence)
end

function Persistence:DefaultState(): any
	return {
		Version = 3, LastDummy = "DefaultGrayR15", RecentDummies = {}, HiddenDummies = {},
		Animations = {}, LastAnimationId = "", Draft = nil, GroundLock = true,
	}
end

function Persistence:Load(): (any, string?)
	local ok, raw = pcall(function() return self.Plugin:GetSetting(SETTINGS_KEY) end)
	local state = self:DefaultState()
	if not ok or raw == nil then self.State = state; return state, if ok then nil else tostring(raw) end
	if typeof(raw) ~= "table" or raw.Version ~= 3 then self.State = state; return state, "Stored settings were invalid and have been reset." end
	if typeof(raw.LastDummy) == "string" then state.LastDummy = safeText(raw.LastDummy, "DefaultGrayR15", 128) end
	state.RecentDummies = safeStringList(raw.RecentDummies)
	state.HiddenDummies = safeStringList(raw.HiddenDummies)
	if typeof(raw.LastAnimationId) == "string" then state.LastAnimationId = safeText(raw.LastAnimationId, "", 128) end
	state.GroundLock = raw.GroundLock ~= false
	if typeof(raw.Animations) == "table" then
		for _, entry in raw.Animations do
			if #state.Animations >= MAX_ANIMATIONS then break end
			if typeof(entry) == "table" and typeof(entry.Id) == "string" and typeof(entry.Name) == "string" then
				local decoded = Persistence.decodeDocument(entry.Document, self.Document)
				if decoded then table.insert(state.Animations, { Id = safeText(entry.Id, "animation", 128), Name = safeText(entry.Name, "Untitled Animation", 80), UpdatedAt = entry.UpdatedAt or 0, Document = decoded }) end
			end
		end
	end
	state.Draft = Persistence.decodeDocument(raw.Draft, self.Document)
	self.State = state
	return state, nil
end

function Persistence:Save(state: any): (boolean, string)
	local animations = {}
	for _, entry in state.Animations do
		table.insert(animations, { Id = entry.Id, Name = entry.Name, UpdatedAt = entry.UpdatedAt, Document = Persistence.encodeDocument(entry.Document) })
	end
	local raw = {
		Version = 3, LastDummy = state.LastDummy, RecentDummies = state.RecentDummies,
		HiddenDummies = state.HiddenDummies, LastAnimationId = state.LastAnimationId,
		Animations = animations, Draft = if state.Draft then Persistence.encodeDocument(state.Draft) else nil,
		GroundLock = state.GroundLock ~= false,
	}
	local jsonOk, json = pcall(HttpService.JSONEncode, HttpService, raw)
	if not jsonOk or #json > 8_000_000 then return false, "Catalog exceeds the 8 MB local safety limit; export entries as text." end
	local ok, err = pcall(function() self.Plugin:SetSetting(SETTINGS_KEY, raw) end)
	if not ok then return false, tostring(err) end
	local verifyOk, verify = pcall(function() return self.Plugin:GetSetting(SETTINGS_KEY) end)
	if not verifyOk or typeof(verify) ~= "table" or verify.Version ~= 3 then return false, "Studio did not confirm the settings write." end
	return true, "Saved locally."
end

return Persistence
