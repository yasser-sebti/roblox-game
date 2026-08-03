--!strict

local ChangeHistoryService = game:GetService("ChangeHistoryService")
local ContextActionService = game:GetService("ContextActionService")
local CoreGui = game:GetService("CoreGui")
local RunService = game:GetService("RunService")
local Selection = game:GetService("Selection")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")

local Document = require(script.Parent.AnimationDocument)
local History = require(script.Parent.History)
local Codec = require(script.Parent.PoseCodec)
local Persistence = require(script.Parent.Persistence)
local PoseMath = require(script.Parent.PoseMath)
local RigCatalog = require(script.Parent.RigCatalog)
local WorkspaceEditor = require(script.Parent.WorkspaceEditor)

type Pose = { [string]: CFrame }
type AnimationDocument = Document.AnimationDocument

local Controller = {}
Controller.__index = Controller

local COLORS = {
	Background = Color3.fromRGB(16, 19, 25), Panel = Color3.fromRGB(23, 27, 35),
	Input = Color3.fromRGB(31, 36, 47), Button = Color3.fromRGB(51, 59, 74),
	Active = Color3.fromRGB(43, 139, 190), Text = Color3.fromRGB(232, 237, 245),
	Muted = Color3.fromRGB(151, 161, 177), Good = Color3.fromRGB(121, 226, 170),
	Warn = Color3.fromRGB(255, 145, 120), Red = Color3.fromRGB(207, 76, 76),
}

local JOINTS = Codec.JointNames
local SHORTCUT_ACTION = "R15PoseTunerShortcutsV3"
local SHORTCUT_PRIORITY = Enum.ContextActionPriority.High.Value + 100
local EXPORT_REQUEST_SETTING = "R15PoseTunerExportRequestV1"
local MAX_EXPORT_BYTES = 7_500_000

local function copyArray(source: { any }): { any }
	local result = {}; for _, value in source do table.insert(result, value) end; return result
end

local function copyCatalog(source: any): any
	local result = {
		Version = 3, LastDummy = source.LastDummy, RecentDummies = copyArray(source.RecentDummies),
		HiddenDummies = copyArray(source.HiddenDummies), LastAnimationId = source.LastAnimationId,
		Animations = {}, Draft = if source.Draft then Document.copy(source.Draft) else nil,
		GroundLock = source.GroundLock ~= false,
	}
	for _, entry in source.Animations do
		table.insert(result.Animations, { Id = entry.Id, Name = entry.Name, UpdatedAt = entry.UpdatedAt, Document = Document.copy(entry.Document) })
	end
	return result
end

local function copyState(source: any): any
	return {
		Document = Document.copy(source.Document), WorkingPose = Document.copyPose(source.WorkingPose),
		Snapping = {
			Enabled = source.Snapping.Enabled,
			Move = source.Snapping.Move,
			Rotate = source.Snapping.Rotate,
			Timeline = source.Snapping.Timeline ~= false,
		},
		Onion = source.Onion, Catalog = copyCatalog(source.Catalog),
	}
end

local function corner(instance: GuiObject, radius: number?)
	local item = Instance.new("UICorner"); item.CornerRadius = UDim.new(0, radius or 4); item.Parent = instance
end

local function label(parent: Instance, text: string, size: UDim2, position: UDim2, bold: boolean?): TextLabel
	local item = Instance.new("TextLabel"); item.Size = size; item.Position = position; item.BackgroundTransparency = 1
	item.Font = if bold then Enum.Font.GothamBold else Enum.Font.Gotham; item.TextSize = if bold then 15 else 14
	item.TextColor3 = COLORS.Text; item.Text = text; item.TextXAlignment = Enum.TextXAlignment.Left; item.Parent = parent
	return item
end

local function button(parent: Instance, text: string, size: UDim2, position: UDim2): TextButton
	local item = Instance.new("TextButton"); item.Size = size; item.Position = position; item.BackgroundColor3 = COLORS.Button; item.BorderSizePixel = 0
	item.Font = Enum.Font.GothamMedium; item.TextSize = 13; item.TextColor3 = COLORS.Text; item.Text = text; item.AutoButtonColor = true; item.Parent = parent; corner(item)
	return item
end

local function box(parent: Instance, text: string, size: UDim2, position: UDim2): TextBox
	local item = Instance.new("TextBox"); item.Size = size; item.Position = position; item.BackgroundColor3 = COLORS.Input; item.BorderSizePixel = 0
	item.Font = Enum.Font.Code; item.TextSize = 14; item.TextColor3 = COLORS.Text; item.Text = text; item.ClearTextOnFocus = false; item.Parent = parent; corner(item)
	return item
end

local function panel(parent: Instance, size: UDim2, position: UDim2): Frame
	local item = Instance.new("Frame"); item.Size = size; item.Position = position; item.BackgroundColor3 = COLORS.Panel; item.BorderSizePixel = 0; item.Parent = parent; corner(item, 6); return item
end

function Controller.new(pluginObject: Plugin, toolbar: PluginToolbar?, toolbarButton: PluginToolbarButton?)
	local self = setmetatable({}, Controller)
	self.Plugin = pluginObject; self.UI = {}; self.Editor = nil; self.History = nil; self.Persistence = Persistence.new(pluginObject, Document)
	self.Toolbar = toolbar; self.ToolbarButton = toolbarButton
	self.SelectedJoint = "Root"; self.SelectionActive = true; self.SelectedKeyId = nil; self.Playhead = 0; self.Playing = false; self.Open = false
	self.PlaybackDirection = 1; self.PlaybackMultiplier = 1
	self.SelectedTimelineTrack = "Master"
	self.SelectedKeys = {}; self.CopiedKeys = {}; self.CopiedTrack = "Master"; self.TimelineDrag = nil
	self.MasterTrackExpanded = true; self.TimelineScrub = false
	self.DragBefore = nil; self.SaveSerial = 0; self.OpenSerial = 0; self.Connections = {}; self.Initialized = false; self.LoadFailed = false
	self.ShortcutsBound = false; self.LayoutMode = "Wide"; self.ActiveToolTab = "Pose"
	self.ToolsVisible = true; self.InspectorVisible = true
	self.PendingDestructiveAction = nil; self.PendingDestructiveUntil = 0
	return self
end

function Controller:status(text: string, warning: boolean?)
	local item = self.UI.Status
	if item then item.Text = text; item.TextColor3 = if warning then COLORS.Warn else COLORS.Good end
end

function Controller:current(): any
	assert(self.History, "Pose tuner document is not initialized yet.")
	return self.History:Get()
end

function Controller:groundLockAt(time: number): boolean
	local state = self:current()
	return Document.evaluateGroundLock(state.Document, time, state.Catalog.GroundLock ~= false)
end

function Controller:groundLockBlendAt(time: number): number
	local state = self:current()
	return Document.evaluateGroundLockBlend(state.Document, time, state.Catalog.GroundLock ~= false)
end

function Controller:smoothAt(time: number): boolean
	return Document.evaluateSmooth(self:current().Document, time, true)
end

function Controller:applyEditorPose(pose: Pose?)
	if not self.Editor then return end
	local enabled = self:groundLockAt(self.Playhead)
	self.Editor:SetGroundLockBlend(self:groundLockBlendAt(self.Playhead))
	self.Editor:ApplyPose(pose or self:current().WorkingPose)
	if self.UI.GroundLock then self.UI.GroundLock.Text = "Ground (Key): " .. (if enabled then "On" else "Off") end
	if self.UI.Interpolation then self.UI.Interpolation.Text = "Smooth Key: " .. (if self:smoothAt(self.Playhead) then "On" else "Off") end
end

function Controller:scheduleSave()
	self.SaveSerial += 1; local serial = self.SaveSerial
	task.delay(0.8, function()
		if serial ~= self.SaveSerial or not self.History then return end
		local state = self:current(); state.Catalog.Draft = Document.copy(state.Document)
		local ok, message = self.Persistence:Save(state.Catalog)
		if not ok then self:status("Local save failed: " .. message, true) end
	end)
end

function Controller:transact(name: string, mutator: (any) -> (), applyPose: boolean?)
	if not self.History then self:status("The editor is still loading.", true); return end
	self.History:Transact(mutator); self:scheduleSave(); self:refreshAll()
	if applyPose then self:applyEditorPose(self:current().WorkingPose) end
	self:status(name .. " — undo available.")
end

function Controller:evaluate(time: number): Pose return Document.evaluate(self:current().Document, time, Codec.neutralPose()) end

function Controller:setPlayhead(time: number, apply: boolean?)
	local document = self:current().Document; self.Playhead = math.clamp(time, 0, document.Duration)
	self:current().WorkingPose = self:evaluate(self.Playhead)
	if apply ~= false then self:applyEditorPose(self:current().WorkingPose) end
	self:refreshTimeline(); self:refreshFields(); self:updateOnion()
end

function Controller:updateTransportUI()
	if self.UI.Play then self.UI.Play.Text = if self.Playing then "Pause" else "Play" end
	if self.UI.TransportState and self.History then
		local direction = if self.PlaybackDirection < 0 then "Reverse" else if self.PlaybackMultiplier > 1 then "Fast" else "Forward"
		self.UI.TransportState.Text = if self.Playing then string.format("%s  %.2fx", direction, self:current().Document.PlaybackSpeed * self.PlaybackMultiplier) else "Paused"
	end
end

function Controller:pausePlayback()
	self.Playing = false; self:updateTransportUI()
end

function Controller:startPlayback(direction: number, multiplier: number)
	if not self.History or #self:current().Document.Keyframes == 0 then self:status("Create a key before playback.", true); return end
	local document = self:current().Document
	if document.Interpolation == "Step" then
		self:transact("Enable smooth playback", function(state) state.Document.Interpolation = "Smooth" end)
		document = self:current().Document
	end
	local earliest = Document.earliestTime(document)
	self.PlaybackDirection = if direction < 0 then -1 else 1; self.PlaybackMultiplier = math.clamp(multiplier, 0.1, 8)
	if self.PlaybackDirection > 0 and self.Playhead >= document.Duration - 1e-5 then self.Playhead = earliest
	elseif self.PlaybackDirection < 0 and self.Playhead <= earliest + 1e-5 then self.Playhead = document.Duration end
	self.Playing = true; self:setPlayhead(self.Playhead); self:updateTransportUI()
end

function Controller:keyPose()
	if not self.Editor then return end
	self:pausePlayback()
	self.Editor:BakeIK()
	local captured = self.Editor:ReadPose()
	local before = self.Editor:ReadPose()
	local groundLock = self:groundLockAt(self.Playhead); local smooth = self:smoothAt(self.Playhead)
	self.History:Transact(function(state)
		state.WorkingPose = Document.copyPose(captured)
		local existing = Document.findAtTime(state.Document, self.Playhead)
		local key = Document.keyPose(state.Document, self.Playhead, captured)
		if not existing then key.GroundLock = groundLock; key.Smooth = smooth end
		self.SelectedKeyId = key.Id; self.SelectedTimelineTrack = "Master"; table.clear(self.SelectedKeys); self.SelectedKeys[key.Id] = true
	end)
	local after = self.Editor:ReadPose()
	for _, name in JOINTS do
		if before[name] and after[name] and not Codec.componentsEqual(before[name], after[name]) then
			self:status("Capture safety check failed for " .. name .. "; live pose was restored.", true)
			self:applyEditorPose(captured); break
		end
	end
	self:scheduleSave(); self:refreshAll(); self:status("Exact live pose keyed at " .. string.format("%.3fs", self.Playhead))
end

function Controller:keyNeutralPose()
	if not self.History then return end
	self:pausePlayback(); local neutral = Codec.neutralPose(); local groundLock = self:groundLockAt(self.Playhead); local smooth = self:smoothAt(self.Playhead)
	self.History:Transact(function(state)
		state.WorkingPose = Document.copyPose(neutral)
		local existing = Document.findAtTime(state.Document, self.Playhead)
		local key = Document.keyPose(state.Document, self.Playhead, neutral)
		if not existing then key.GroundLock = groundLock; key.Smooth = smooth end
		self.SelectedKeyId = key.Id; self.SelectedTimelineTrack = "Master"; table.clear(self.SelectedKeys); self.SelectedKeys[key.Id] = true
	end)
	self:applyEditorPose(neutral)
	self:scheduleSave(); self:refreshAll(); self:updateOnion(); self:status(string.format("Neutral pose keyed at %.3fs.", self.Playhead))
end

function Controller:applyCurrentPoseKey()
	if not self.History then return end
	self:pausePlayback()
	if self.Editor then self.Editor:BakeIK() end
	local captured = if self.Editor then self.Editor:ReadPose() else Document.copyPose(self:current().WorkingPose)
	local sparse: Pose = {}
	for _, name in JOINTS do
		local value = captured[name] or CFrame.identity
		if not Codec.componentsEqual(value, CFrame.identity, 1e-6) then sparse[name] = value end
	end
	local groundLock = self:groundLockAt(self.Playhead); local smooth = self:smoothAt(self.Playhead)
	self.History:Transact(function(state)
		state.WorkingPose = Document.copyPose(captured)
		local existing = Document.findAtTime(state.Document, self.Playhead)
		local key = Document.ensureAtTime(state.Document, self.Playhead)
		key.Values = Document.copyPose(sparse)
		if not existing then key.GroundLock = groundLock; key.Smooth = smooth end
		self.SelectedKeyId = key.Id; self.SelectedTimelineTrack = "Master"; table.clear(self.SelectedKeys); self.SelectedKeys[key.Id] = true
	end)
	self:applyEditorPose(captured); self:scheduleSave(); self:refreshAll(); self:updateOnion()
	local changedCount = 0; for _ in sparse do changedCount += 1 end
	self:status(string.format("Applied sparse pose at %.3fs (%d changed joints).", self.Playhead, changedCount))
end

function Controller:parseTimelineTime(textValue: string): number?
	if not self.History then return nil end
	local cleaned = string.lower(string.gsub(textValue, "%s+", "")); local document = self:current().Document
	local numberText, suffix = string.match(cleaned, "^([%+%-]?[%d%.]+)([fs]?)$")
	local value = if numberText then tonumber(numberText) else nil; if not value then return nil end
	local seconds = if suffix == "f" then value / document.FPS else value
	return self:snapTimelineTime(math.clamp(seconds, 0, document.Duration), false)
end

function Controller:setMirrorTime(time: number)
	if not self.History or not self.UI.MirrorTime then return end
	local clamped = math.clamp(time, 0, self:current().Document.Duration)
	self.UI.MirrorTime.Text = string.format("%.3fs", clamped)
end

function Controller:mirrorCurrentPose()
	if not self.History then return end
	local target = self:parseTimelineTime(self.UI.MirrorTime.Text)
	if not target then self:status("Mirror time must use seconds (1.25s) or frames (38f).", true); return end
	self:pausePlayback()
	local source = if self.Editor then self.Editor:ReadPose() else self:evaluate(self.Playhead)
	local mirrored = PoseMath.mirrorPose(source)
	if not PoseMath.isMirrorInvolution(source) then self:status("Mirror validation failed; the source pose was not changed.", true); return end
	local groundLock = self:groundLockAt(self.Playhead); local smooth = self:smoothAt(self.Playhead)
	self.History:Transact(function(state)
		state.WorkingPose = Document.copyPose(mirrored)
		local existing = Document.findAtTime(state.Document, target)
		local key = Document.keyPose(state.Document, target, mirrored)
		if not existing then key.GroundLock = groundLock; key.Smooth = smooth end
		self.SelectedKeyId = key.Id; self.SelectedTimelineTrack = "Master"; table.clear(self.SelectedKeys); self.SelectedKeys[key.Id] = true
	end)
	self.Playhead = target; self:applyEditorPose(mirrored)
	self:scheduleSave(); self:refreshAll(); self:updateOnion(); self:status(string.format("Mirrored pose keyed at %.3fs.", target))
end

function Controller:undo()
	if not self.History then self:status("The editor is still loading.", true); return end
	if self.History:UndoOnce() then self:pausePlayback(); self:applyState(); self:status("Undo") else self:status("Nothing to undo.", true) end
end

function Controller:redo()
	if not self.History then self:status("The editor is still loading.", true); return end
	if self.History:RedoOnce() then self:pausePlayback(); self:applyState(); self:status("Redo") else self:status("Nothing to redo.", true) end
end

function Controller:applyState()
	local state = self:current(); self.Playhead = math.clamp(self.Playhead, 0, state.Document.Duration)
	if self.Editor then
		self.Editor:SetSnapSettings(state.Snapping.Enabled, state.Snapping.Move, state.Snapping.Rotate)
		self:applyEditorPose(state.WorkingPose)
	end
	self:scheduleSave(); self:refreshAll(); self:updateOnion()
end

function Controller:setGroundLock(enabled: boolean?)
	if not self.History then return end
	self:pausePlayback()
	local nextEnabled = if enabled == nil then not self:groundLockAt(self.Playhead) else enabled
	self:transact("Keyframe ground lock", function(state)
		local existing = Document.findAtTime(state.Document, self.Playhead)
		local inheritedSmooth = Document.evaluateSmooth(state.Document, self.Playhead, true)
		local key = Document.ensureAtTime(state.Document, self.Playhead)
		key.GroundLock = nextEnabled
		if not existing then key.Smooth = inheritedSmooth end
		state.Catalog.GroundLock = nextEnabled
		self.SelectedKeyId = key.Id; self.SelectedTimelineTrack = "Master"; table.clear(self.SelectedKeys); self.SelectedKeys[key.Id] = true
	end)
	self:applyEditorPose(); self:updateOnion(); self:status(string.format("Ground Lock %s for the key at %.3fs.", if nextEnabled then "enabled" else "disabled", self.Playhead))
end


function Controller:setKeySmooth(enabled: boolean?)
	if not self.History then return end
	self:pausePlayback()
	local nextEnabled = if enabled == nil then not self:smoothAt(self.Playhead) else enabled
	self:transact("Keyframe smoothing", function(state)
		local existing = Document.findAtTime(state.Document, self.Playhead)
		local inheritedGround = Document.evaluateGroundLock(state.Document, self.Playhead, state.Catalog.GroundLock ~= false)
		local key = Document.ensureAtTime(state.Document, self.Playhead)
		if not existing then key.GroundLock = inheritedGround end
		key.Smooth = nextEnabled
		state.Document.Interpolation = "Smooth"
		self.SelectedKeyId = key.Id; self.SelectedTimelineTrack = "Master"; table.clear(self.SelectedKeys); self.SelectedKeys[key.Id] = true
	end)
	self:applyEditorPose(); self:updateOnion()
	self:status(string.format("Smooth animation %s for the outgoing segment at %.3fs; joint values were not modified.", if nextEnabled then "enabled" else "disabled", self.Playhead))
end

function Controller:setFirstPersonPreview(enabled: boolean)
	if not self.Editor then return end
	self.Editor:SetFirstPersonPreview(enabled)
	if self.UI.FirstPerson then self.UI.FirstPerson.Text = "First Person: " .. (if self.Editor.FirstPersonEnabled then "On" else "Off") end
end

function Controller:refreshFields()
	if not self.UI.Fields or not self.History then return end
	if not self.SelectionActive then
		for _, field in self.UI.Fields do field.Text = "-"; field.TextEditable = false end
		self.UI.Selected.Text = "Selected: None"; return
	end
	local transform = self:current().WorkingPose[self.SelectedJoint] or CFrame.identity
	local rx, ry, rz = transform:ToOrientation(); local values = { transform.X, transform.Y, transform.Z, math.deg(rx), math.deg(ry), math.deg(rz) }
	for index, field in self.UI.Fields do field.TextEditable = true; if not field:IsFocused() then field.Text = string.format(if index <= 3 then "%.4f" else "%.2f", values[index]) end end
	self.UI.Selected.Text = "Selected: " .. self.SelectedJoint
end

function Controller:applyNumeric()
	if not self.SelectionActive then self:status("Select a body part before editing its transform.", true); return end
	local numbers = {}; for index, field in self.UI.Fields do numbers[index] = tonumber(field.Text); if not numbers[index] then self:refreshFields(); return end end
	local transform = CFrame.new(numbers[1], numbers[2], numbers[3]) * CFrame.Angles(math.rad(numbers[4]), math.rad(numbers[5]), math.rad(numbers[6]))
	local joint = self.SelectedJoint
	local groundLock = self:groundLockAt(self.Playhead); local smooth = self:smoothAt(self.Playhead)
	if self:current().Document.AutoKey then self.SelectedTimelineTrack = joint end
	self:transact("Edit " .. joint, function(state)
		state.WorkingPose[joint] = transform
		if state.Document.AutoKey then Document.keyJoint(state.Document, self.Playhead, joint, transform, groundLock, smooth) end
	end, true)
	if self:current().Document.AutoKey then
		local key = Document.findAtTime(self:current().Document, self.Playhead)
		if key then self.SelectedKeyId = key.Id; table.clear(self.SelectedKeys); self.SelectedKeys[key.Id] = true; self:refreshTimeline() end
	end
end

function Controller:selectedKey(): any?
	if not self.SelectedKeyId then return nil end
	return Document.findById(self:current().Document, self.SelectedKeyId)
end

function Controller:selectedIds(): { string }
	local ids = {}; for id in self.SelectedKeys do table.insert(ids, id) end
	if #ids == 0 and self.SelectedKeyId then table.insert(ids, self.SelectedKeyId) end
	return ids
end

function Controller:cycleEasing(field: string, values: { string })
	local selected = self:selectedKey(); if not selected then self:status("Select a timeline key first.", true); return end
	local current = selected[field]; local index = table.find(values, current) or 0; local nextValue = values[index % #values + 1]; local id = selected.Id
	local ids = self:selectedIds()
	self:transact("Change segment easing", function(state)
		for _, selectedId in ids do local key = Document.findById(state.Document, selectedId); if key then key[field] = nextValue end end
	end)
end

function Controller:setEasing(field: string, value: string)
	local ids = self:selectedIds(); if #ids == 0 then self:status("Select one or more timeline keys first.", true); return end
	self:transact("Change segment easing", function(state)
		for _, selectedId in ids do
			local key = Document.findById(state.Document, selectedId)
			if key then key[field] = value end
		end
	end)
	if self.UI.StyleMenu then self.UI.StyleMenu.Visible = false end
	if self.UI.DirectionMenu then self.UI.DirectionMenu.Visible = false end
	self.UI.ActiveDropdown = nil
end

function Controller:toggleDropdown(name: string)
	local target = self.UI[name]
	if not target then return end
	local show = not target.Visible
	if self.UI.StyleMenu then self.UI.StyleMenu.Visible = false end
	if self.UI.DirectionMenu then self.UI.DirectionMenu.Visible = false end
	target.Visible = show; self.UI.ActiveDropdown = if show then target else nil
end

function Controller:copySelected()
	local ids = self:selectedIds(); if #ids == 0 then return end
	local selected = {}; local earliest = math.huge; local track = self.SelectedTimelineTrack
	for _, id in ids do
		local key = Document.findById(self:current().Document, id)
		if key and (track == "Master" or key.Values[track]) then table.insert(selected, key); earliest = math.min(earliest, key.Time) end
	end
	table.clear(self.CopiedKeys)
	self.CopiedTrack = track
	for _, key in selected do
		local copied = Document.copyKeyframe(key)
		if track ~= "Master" then copied.Values = { [track] = key.Values[track] } end
		table.insert(self.CopiedKeys, { Offset = key.Time - earliest, Key = copied })
	end
	self:status(string.format("Copied %d key(s).", #self.CopiedKeys))
end

function Controller:pasteCopied(offsetFrames: number?)
	if #self.CopiedKeys == 0 then self:status("No copied keys.", true); return end
	local document = self:current().Document; local base = self.Playhead + (offsetFrames or 0) / document.FPS
	self:transact("Paste keys", function(state)
		table.clear(self.SelectedKeys)
		for _, copied in self.CopiedKeys do
			local sourceKey = copied.Key; local targetTime = math.clamp(base + copied.Offset, 0, state.Document.Duration)
			local key = Document.findAtTime(state.Document, targetTime)
			if key then
				if self.CopiedTrack == "Master" then
					key.Values = Document.copyPose(sourceKey.Values); key.EasingStyle = sourceKey.EasingStyle; key.EasingDirection = sourceKey.EasingDirection; key.GroundLock = sourceKey.GroundLock ~= false; key.Smooth = sourceKey.Smooth ~= false
				else
					for joint, transform in sourceKey.Values do key.Values[joint] = transform end
				end
			else
				key = Document.copyKeyframe(sourceKey); key.Id = Document.newId(); key.Time = targetTime; table.insert(state.Document.Keyframes, key)
			end
			self.SelectedKeys[key.Id] = true; self.SelectedKeyId = key.Id
		end
		Document.sort(state.Document)
	end)
end

function Controller:nudgeSelected(frames: number)
	local ids = self:selectedIds(); if #ids == 0 then return end
	if self.SelectedTimelineTrack ~= "Master" then
		for _, id in ids do
			local key = Document.findById(self:current().Document, id); local count = 0
			if key then for _ in key.Values do count += 1 end end
			if count > 1 then self:status("Use the Master track to move a key shared by multiple joints.", true); return end
		end
	end
	self:transact("Nudge keys", function(state)
		local delta = frames / state.Document.FPS
		for _, id in ids do local key = Document.findById(state.Document, id); if key then key.Time = math.clamp(key.Time + delta, 0, state.Document.Duration) end end
		Document.sort(state.Document)
	end)
end

function Controller:updateCurve()
	local holder = self.UI.Curve
	if not holder then return end
	for _, child in holder:GetChildren() do if string.find(child.Name, "^Curve") then child:Destroy() end end
	local key = self:selectedKey(); local styleName = if key then key.EasingStyle else "Linear"; local directionName = if key then key.EasingDirection else "InOut"
	self.UI.Style.Text = "Style: " .. styleName; self.UI.Direction.Text = "Direction: " .. directionName
	local style = Enum.EasingStyle[styleName]; local direction = Enum.EasingDirection[directionName]
	local connectedBefore, connectedAfter = false, false
	if key and self.History then
		local document = self:current().Document; Document.sort(document)
		local keys = {}
		for _, candidate in document.Keyframes do
			if self.SelectedTimelineTrack == "Master" or candidate.Values[self.SelectedTimelineTrack] then table.insert(keys, candidate) end
		end
		local keyIndex = table.find(keys, key)
		if keyIndex then
			local before = keys[keyIndex - 1]; local following = keys[keyIndex + 1]; local after = keys[keyIndex + 2]
			connectedBefore = before ~= nil and before.Smooth ~= false
			connectedAfter = following ~= nil and after ~= nil and following.Smooth ~= false
		end
	end
	local samples = {}; local minimum, maximum = 0, 1
	for index = 0, 120 do
		local alpha = index / 120
		local value = if key and key.Smooth == false then (if index == 120 then 1 else 0)
			elseif key then Document.smartEasedAlpha(alpha, key, connectedBefore, connectedAfter)
			else TweenService:GetValue(alpha, style, direction)
		table.insert(samples, Vector2.new(alpha, value)); minimum = math.min(minimum, value); maximum = math.max(maximum, value)
	end
	local span = math.max(0.001, maximum - minimum); local padding = math.max(span * 0.08, 0.035); minimum -= padding; maximum += padding; span = maximum - minimum
	local absolute = holder.AbsoluteSize; local width = math.max(240, absolute.X); local height = math.max(150, absolute.Y); local margin = 12
	local function pointOf(sample: Vector2): Vector2
		return Vector2.new(margin + sample.X * (width - margin * 2), margin + (1 - (sample.Y - minimum) / span) * (height - margin * 2))
	end
	local function axisAt(value: number, color: Color3)
		local normalized = (value - minimum) / span; local y = margin + (1 - normalized) * (height - margin * 2)
		local axis = Instance.new("Frame"); axis.Name = "CurveAxis"; axis.Position = UDim2.fromOffset(margin, math.floor(y)); axis.Size = UDim2.fromOffset(width - margin * 2, 1); axis.BackgroundColor3 = color; axis.BackgroundTransparency = 0.45; axis.BorderSizePixel = 0; axis.Parent = holder
	end
	axisAt(0, Color3.fromRGB(110, 125, 150)); axisAt(1, Color3.fromRGB(110, 170, 150))
	for index = 2, #samples do
		local from = pointOf(samples[index - 1]); local to = pointOf(samples[index]); local delta = to - from; local length = delta.Magnitude
		local segment = Instance.new("Frame"); segment.Name = "CurveSegment"; segment.AnchorPoint = Vector2.new(0.5, 0.5)
		segment.Position = UDim2.fromOffset((from.X + to.X) * 0.5, (from.Y + to.Y) * 0.5); segment.Size = UDim2.fromOffset(math.max(1, length + 0.5), 2)
		segment.Rotation = math.deg(math.atan2(delta.Y, delta.X)); segment.BackgroundColor3 = Color3.fromRGB(255, 145, 60); segment.BorderSizePixel = 0; segment.Parent = holder
	end
end

function Controller:updateOnion()
	if not self.Editor then return end; local document = self:current().Document; local previous, following
	for _, key in document.Keyframes do
		if key.Time < self.Playhead then previous = key elseif key.Time > self.Playhead then following = key; break end
	end
	local fallback = self:current().Catalog.GroundLock ~= false
	self.Editor:SetOnion(
		if previous then Document.evaluate(document, previous.Time, Codec.neutralPose()) else nil,
		if following then Document.evaluate(document, following.Time, Codec.neutralPose()) else nil,
		self:current().Onion,
		if previous then Document.evaluateGroundLock(document, previous.Time, fallback) else nil,
		if following then Document.evaluateGroundLock(document, following.Time, fallback) else nil
	)
end

function Controller:timelineTimeFromScreen(screenX: number): number
	local holder = self.UI.TimelineKeys
	if not holder or not self.History then return 0 end
	local document = self:current().Document; local width = self.TimelineWidth or math.max(480, document.Duration * 180)
	local contentX = screenX - holder.AbsolutePosition.X + holder.CanvasPosition.X
	return math.clamp((contentX - 11) / math.max(1, width - 24) * document.Duration, 0, document.Duration)
end

function Controller:snapTimelineTime(rawTime: number, includePlayhead: boolean?, ignored: { [string]: boolean }?): number
	local state = self:current(); local document = state.Document; local raw = math.clamp(rawTime, 0, document.Duration)
	if state.Snapping.Timeline == false then return raw end
	local width = self.TimelineWidth or math.max(480, document.Duration * 180)
	local tolerance = math.max(7 / math.max(1, width - 24) * document.Duration, 0.2 / document.FPS)
	local best = math.clamp(math.round(raw * document.FPS) / document.FPS, 0, document.Duration)
	local bestDistance = math.abs(best - raw)
	local function consider(candidate: number)
		local distance = math.abs(candidate - raw)
		if distance <= tolerance and distance < bestDistance then best = candidate; bestDistance = distance end
	end
	consider(0); consider(document.Duration)
	if includePlayhead then consider(self.Playhead) end
	for _, key in document.Keyframes do if not ignored or not ignored[key.Id] then consider(key.Time) end end
	return best
end

function Controller:applyTimelineScrub(screenX: number)
	if not self.History then return end
	local time = self:snapTimelineTime(self:timelineTimeFromScreen(screenX), false)
	self.Playhead = time; self:current().WorkingPose = self:evaluate(time)
	self:applyEditorPose(self:current().WorkingPose)
	self:updateTimelinePlayhead(); self:refreshFields()
end

function Controller:updateTimelineGhost(screenX: number)
	local ghost = self.UI.GhostPlayhead; local holder = self.UI.TimelineKeys
	if not ghost or not ghost.Parent or not holder or not self.History then return end
	local time = self:snapTimelineTime(self:timelineTimeFromScreen(screenX), false)
	local document = self:current().Document; local width = self.TimelineWidth or math.max(480, document.Duration * 180)
	ghost.Position = UDim2.fromOffset(math.floor(time / document.Duration * (width - 24)) + 11, 0); ghost.Visible = true
end

function Controller:refreshTimeline()
	local holder, trackList = self.UI.TimelineKeys, self.UI.TimelineTrackList; if not holder or not trackList or not self.History then return end
	for _, child in holder:GetChildren() do child:Destroy() end; for _, child in trackList:GetChildren() do child:Destroy() end
	local document = self:current().Document; local width = math.max(480, document.Duration * 180); local rowHeight, headerHeight = 28, 24
	local tracks = { "Master" }; if self.MasterTrackExpanded then for _, name in JOINTS do table.insert(tracks, name) end end
	local height = headerHeight + #tracks * rowHeight
	holder.CanvasSize = UDim2.fromOffset(width, height); trackList.CanvasSize = UDim2.fromOffset(0, height)
	local trackHeader = label(trackList, "TRACK / JOINT", UDim2.new(1, -8, 0, headerHeight), UDim2.fromOffset(6, 0), true); trackHeader.TextSize = 12; trackHeader.TextColor3 = COLORS.Muted
	for row, track in tracks do
		local y = headerHeight + (row - 1) * rowHeight
		local stripe = Instance.new("Frame"); stripe.Name = "TrackRow"; stripe.Size = UDim2.fromOffset(width, rowHeight); stripe.Position = UDim2.fromOffset(0, y); stripe.BackgroundColor3 = if row % 2 == 0 then Color3.fromRGB(35, 41, 52) else COLORS.Input; stripe.BackgroundTransparency = 0.28; stripe.BorderSizePixel = 0; stripe.Parent = holder
		local leftOffset = if track == "Master" then 28 else 15
		if track == "Master" then
			local expand = button(trackList, if self.MasterTrackExpanded then "v" else ">", UDim2.fromOffset(24, rowHeight - 2), UDim2.fromOffset(3, y + 1)); expand.TextSize = 14
			expand.Activated:Connect(function() self.MasterTrackExpanded = not self.MasterTrackExpanded; self:refreshTimeline() end)
		end
		local trackButton = button(trackList, if track == "Master" then "MASTER POSE" else track, UDim2.new(1, -leftOffset - 3, 0, rowHeight - 2), UDim2.fromOffset(leftOffset, y + 1)); trackButton.TextXAlignment = Enum.TextXAlignment.Left; trackButton.TextSize = 12; trackButton.BackgroundColor3 = if self.SelectedTimelineTrack == track then COLORS.Active else if row % 2 == 0 then Color3.fromRGB(39, 46, 59) else COLORS.Button
		trackButton.Activated:Connect(function()
			if self.SelectedTimelineTrack ~= track then table.clear(self.SelectedKeys); self.SelectedKeyId = nil end
			self.SelectedTimelineTrack = track
			if track ~= "Master" then self.SelectedJoint = track; if self.Editor then self.Editor:SelectJoint(track) end end
			self:refreshTimeline(); self:refreshFields()
		end)
	end
	local tickStep = math.max(if document.Duration <= 5 then 0.25 elseif document.Duration <= 15 then 0.5 else 1, document.Duration / 120)
	local tick = 0
	while tick <= document.Duration + 0.0001 do
		local x = math.floor(tick / document.Duration * (width - 24)) + 11
		local line = Instance.new("Frame"); line.Name = "TimeGrid"; line.Size = UDim2.fromOffset(1, height); line.Position = UDim2.fromOffset(x, 0); line.BackgroundColor3 = Color3.fromRGB(54, 61, 75); line.BackgroundTransparency = if math.abs(tick - math.round(tick)) < 0.001 then 0.15 else 0.55; line.BorderSizePixel = 0; line.Parent = holder
		if math.abs(tick - math.round(tick)) < 0.001 then local tickLabel = label(holder, string.format("%.0fs", tick), UDim2.fromOffset(42, 18), UDim2.fromOffset(x + 3, 2)); tickLabel.TextSize = 12; tickLabel.TextColor3 = COLORS.Muted end
		tick += tickStep
	end
	local scrubSurface = button(holder, "", UDim2.fromOffset(width, headerHeight), UDim2.fromOffset(0, 0)); scrubSurface.Name = "TimelineRulerDragSurface"; scrubSurface.BackgroundTransparency = 1; scrubSurface.AutoButtonColor = false; scrubSurface.ZIndex = 2
	scrubSurface.MouseMoved:Connect(function(x) if not self.TimelineDrag then self:updateTimelineGhost(x) end end)
	scrubSurface.MouseLeave:Connect(function() if not self.TimelineScrub and self.UI.GhostPlayhead then self.UI.GhostPlayhead.Visible = false end end)
	scrubSurface.InputBegan:Connect(function(input)
		if input.UserInputType ~= Enum.UserInputType.MouseButton1 then return end
		self:pausePlayback()
		self.TimelineScrub = true; self:applyTimelineScrub(input.Position.X); self:updateTimelineGhost(input.Position.X)
	end)
	local ghost = Instance.new("Frame"); ghost.Name = "GhostPlayhead"; ghost.Size = UDim2.fromOffset(1, height); ghost.BackgroundColor3 = Color3.fromRGB(220, 230, 245); ghost.BackgroundTransparency = 0.38; ghost.BorderSizePixel = 0; ghost.Visible = false; ghost.ZIndex = 3; ghost.Parent = holder; self.UI.GhostPlayhead = ghost
	local function markerFor(key: any, track: string, row: number, draggable: boolean)
		local x = math.floor(key.Time / document.Duration * (width - 24)); local y = headerHeight + (row - 1) * rowHeight + 2
		local marker = button(holder, "", UDim2.fromOffset(24, 24), UDim2.fromOffset(x, y)); marker.Name = key.Id; marker:SetAttribute("TimelineTrack", track); marker.BackgroundTransparency = 1; marker.AutoButtonColor = false; marker.ZIndex = 6
		local diamond = Instance.new("Frame"); diamond.Name = "KeyDiamond"; diamond.AnchorPoint = Vector2.new(0.5, 0.5); diamond.Position = UDim2.fromScale(0.5, 0.5); diamond.Size = UDim2.fromOffset(12, 12); diamond.Rotation = 45; diamond.BorderSizePixel = 0; diamond.ZIndex = 7; diamond.BackgroundColor3 = if self.SelectedKeys[key.Id] and self.SelectedTimelineTrack == track then Color3.fromRGB(255, 190, 70) else if track == "Master" then COLORS.Text else Color3.fromRGB(100, 205, 255); diamond.Parent = marker; corner(diamond, 1)
		marker.InputBegan:Connect(function(input)
			if input.UserInputType ~= Enum.UserInputType.MouseButton1 then return end
			local ctrl = UserInputService:IsKeyDown(Enum.KeyCode.LeftControl) or UserInputService:IsKeyDown(Enum.KeyCode.RightControl)
			local shift = UserInputService:IsKeyDown(Enum.KeyCode.LeftShift) or UserInputService:IsKeyDown(Enum.KeyCode.RightShift)
			local additive = (shift or ctrl) and self.SelectedTimelineTrack == track
			if additive then
				self.SelectedKeys[key.Id] = not self.SelectedKeys[key.Id]
				if self.SelectedKeys[key.Id] then self.SelectedKeyId = key.Id elseif self.SelectedKeyId == key.Id then self.SelectedKeyId = next(self.SelectedKeys) end
			else table.clear(self.SelectedKeys); self.SelectedKeys[key.Id] = true; self.SelectedKeyId = key.Id end
			self.SelectedTimelineTrack = track; self.Playhead = key.Time
			if track ~= "Master" then self.SelectedJoint = track; if self.Editor then self.Editor:SelectJoint(track) end end
			self:current().WorkingPose = self:evaluate(key.Time); self:applyEditorPose(self:current().WorkingPose)
			if draggable then
				local initialTimes = {}; for _, id in self:selectedIds() do local selectedKey = Document.findById(document, id); if selectedKey then initialTimes[id] = selectedKey.Time end end
				self.TimelineDrag = { Before = copyState(self:current()), StartX = input.Position.X, InitialTimes = initialTimes, Width = width, Moved = false }
			else self.TimelineDrag = nil end
			for _, child in holder:GetChildren() do
				if child:IsA("TextButton") and child:GetAttribute("TimelineTrack") then
					local childTrack = child:GetAttribute("TimelineTrack"); local childDiamond = child:FindFirstChild("KeyDiamond")
					if childDiamond and childDiamond:IsA("Frame") then childDiamond.BackgroundColor3 = if self.SelectedKeys[child.Name] and childTrack == self.SelectedTimelineTrack then Color3.fromRGB(255, 190, 70) else if childTrack == "Master" then COLORS.Text else Color3.fromRGB(100, 205, 255) end
				end
			end
			self:refreshFields(); self:updateCurve()
		end)
	end
	for _, key in document.Keyframes do
		markerFor(key, "Master", 1, true)
		if self.MasterTrackExpanded then for index, joint in JOINTS do if key.Values[joint] then markerFor(key, joint, index + 1, false) end end end
	end
	local playhead = Instance.new("Frame"); playhead.Name = "Playhead"; playhead.Size = UDim2.fromOffset(2, height); playhead.Position = UDim2.fromOffset(math.floor(self.Playhead / document.Duration * (width - 24)) + 11, 0); playhead.BackgroundColor3 = COLORS.Red; playhead.BorderSizePixel = 0; playhead.ZIndex = 4; playhead.Parent = holder; self.UI.Playhead = playhead; self.TimelineWidth = width
	local head = Instance.new("Frame"); head.Name = "PlayheadHandle"; head.AnchorPoint = Vector2.new(0.5, 0); head.Position = UDim2.fromOffset(1, 0); head.Size = UDim2.fromOffset(10, 10); head.Rotation = 45; head.BackgroundColor3 = COLORS.Red; head.BorderSizePixel = 0; head.ZIndex = 5; head.Parent = playhead; corner(head, 2)
	self.UI.Time.Text = string.format("%.3f / %.3f", self.Playhead, document.Duration)
	self:updateCurve()
end

function Controller:updateTimelinePlayhead()
	if not self.History or not self.UI.Playhead or not self.UI.Playhead.Parent then return end
	local document = self:current().Document; local width = self.TimelineWidth or math.max(480, document.Duration * 180)
	self.UI.Playhead.Position = UDim2.fromOffset(math.floor(self.Playhead / document.Duration * (width - 24)) + 11, 0)
	self.UI.Time.Text = string.format("%.3f / %.3f", self.Playhead, document.Duration)
end

function Controller:refreshCatalog()
	local dummyList, animationList = self.UI.DummyList, self.UI.AnimationList; if not dummyList or not self.History then return end
	for _, child in dummyList:GetChildren() do child:Destroy() end; for _, child in animationList:GetChildren() do child:Destroy() end
	local state = self:current(); local y = 0
	for _, model in RigCatalog.list(state.Catalog.HiddenDummies) do
		local item = button(dummyList, model.Name, UDim2.new(1, -6, 0, 24), UDim2.fromOffset(3, y)); y += 27
		item.BackgroundColor3 = if model.Name == state.Catalog.LastDummy then COLORS.Active else COLORS.Button
		item.Activated:Connect(function() self:selectDummy(model.Name) end)
	end
	dummyList.CanvasSize = UDim2.fromOffset(0, y)
	y = 0
	for _, entry in state.Catalog.Animations do
		local item = button(animationList, entry.Name, UDim2.new(1, -6, 0, 24), UDim2.fromOffset(3, y)); y += 27
		item.BackgroundColor3 = if entry.Id == state.Catalog.LastAnimationId then COLORS.Active else COLORS.Button
		item.Activated:Connect(function() state.Catalog.LastAnimationId = entry.Id; self.UI.AnimationName.Text = entry.Name; self:refreshCatalog() end)
	end
	animationList.CanvasSize = UDim2.fromOffset(0, y)
end

function Controller:refreshParameters()
	if not self.History then return end
	local document, state = self:current().Document, self:current()
	if not self.UI.Duration:IsFocused() then self.UI.Duration.Text = string.format("%.3f", document.Duration) end
	if not self.UI.Speed:IsFocused() then self.UI.Speed.Text = string.format("%.2f", document.PlaybackSpeed) end
	if not self.UI.FPS:IsFocused() then self.UI.FPS.Text = tostring(document.FPS) end
	self.UI.Interpolation.Text = "Smooth Key: " .. (if self:smoothAt(self.Playhead) then "On" else "Off"); self.UI.Loop.Text = "Loop: " .. (if document.Loop then "On" else "Off")
	self.UI.AutoKey.Text = "Auto-Key: " .. (if document.AutoKey then "On" else "Off"); self.UI.Onion.Text = "Onion: " .. (if state.Onion then "On" else "Off")
	if self.UI.Guides then self.UI.Guides.Text = "Guides: " .. (if state.Snapping.Enabled then "On" else "Off") end
	if self.UI.TimelineSnap then self.UI.TimelineSnap.Text = "Time Snap: " .. (if state.Snapping.Timeline ~= false then "On" else "Off") end
	if self.UI.MoveSnap and not self.UI.MoveSnap:IsFocused() then self.UI.MoveSnap.Text = string.format("%.3f", state.Snapping.Move) end
	if self.UI.RotateSnap and not self.UI.RotateSnap:IsFocused() then self.UI.RotateSnap.Text = string.format("%.2f", state.Snapping.Rotate) end
	if self.UI.GroundLock then self.UI.GroundLock.Text = "Ground (Key): " .. (if self:groundLockAt(self.Playhead) then "On" else "Off") end
	if self.UI.FirstPerson and self.Editor then self.UI.FirstPerson.Text = "First Person: " .. (if self.Editor.FirstPersonEnabled then "On" else "Off") end
end

function Controller:refreshAll()
	if not self.UI.Root then return end; self:refreshFields(); self:refreshParameters(); self:refreshTimeline(); self:refreshCatalog()
end

function Controller:findDummy(name: string): Model?
	for _, model in RigCatalog.list(self:current().Catalog.HiddenDummies) do if model.Name == name then return model end end
	return nil
end

function Controller:selectDummy(name: string)
	local source = self:findDummy(name); if not source then self:status("Dummy is missing or invalid.", true); return end
	self:transact("Select dummy", function(state)
		state.Catalog.LastDummy = name
		for index = #state.Catalog.RecentDummies, 1, -1 do if state.Catalog.RecentDummies[index] == name then table.remove(state.Catalog.RecentDummies, index) end end
		table.insert(state.Catalog.RecentDummies, 1, name)
	end)
	if self.Editor then self.Editor:Build(source, self:current().WorkingPose); self:applyEditorPose(self:current().WorkingPose); self:updateOnion() end
end

function Controller:saveAnimation(update: boolean?)
	local state = self:current(); local name = string.sub(self.UI.AnimationName.Text, 1, 80)
	name = string.gsub(name, "[\\\"\r\n%z]", "")
	if name == "" then name = "Untitled Animation"; self.UI.AnimationName.Text = name end
	self:transact(if update then "Update catalog animation" else "Save catalog animation", function(nextState)
		local catalog = nextState.Catalog; local existing
		if update and catalog.LastAnimationId ~= "" then for _, entry in catalog.Animations do if entry.Id == catalog.LastAnimationId then existing = entry; break end end end
		if existing then existing.Name = name; existing.Document = Document.copy(nextState.Document); existing.UpdatedAt = os.time()
		else
			local id = "anim_" .. string.gsub(game:GetService("HttpService"):GenerateGUID(false), "-", "")
			table.insert(catalog.Animations, { Id = id, Name = name, UpdatedAt = os.time(), Document = Document.copy(nextState.Document) }); catalog.LastAnimationId = id
		end
	end)
end

function Controller:selectedAnimation(): any?
	local catalog = self:current().Catalog; for _, entry in catalog.Animations do if entry.Id == catalog.LastAnimationId then return entry end end; return nil
end

function Controller:loadAnimation()
	local selected = self:selectedAnimation(); if not selected then self:status("Select a catalog animation.", true); return end
	self:transact("Load catalog animation", function(state) state.Document = Document.copy(selected.Document); state.WorkingPose = Document.evaluate(state.Document, Document.earliestTime(state.Document), Codec.neutralPose()) end, true)
	self.Playhead = Document.earliestTime(self:current().Document)
end

function Controller:deleteAnimation()
	local selected = self:selectedAnimation(); if not selected then return end; local id = selected.Id
	self:transact("Delete catalog animation", function(state)
		for index = #state.Catalog.Animations, 1, -1 do if state.Catalog.Animations[index].Id == id then table.remove(state.Catalog.Animations, index) end end
		state.Catalog.LastAnimationId = ""
	end)
end

function Controller:deleteSelectedKeys()
	local ids = self:selectedIds(); if #ids == 0 then return end
	local selected = {}; for _, id in ids do selected[id] = true end; local track = self.SelectedTimelineTrack
	self:transact(if track == "Master" then "Delete keys" else "Delete " .. track .. " keys", function(state)
		if track == "Master" then
			for index = #state.Document.Keyframes, 1, -1 do if selected[state.Document.Keyframes[index].Id] then table.remove(state.Document.Keyframes, index) end end
		else
			for _, key in state.Document.Keyframes do if selected[key.Id] then key.Values[track] = nil end end
			Document.removeEmpty(state.Document)
		end
	end)
	table.clear(self.SelectedKeys); self.SelectedKeyId = nil
end

function Controller:updateTimelineDrag(input: InputObject)
	if input.UserInputType ~= Enum.UserInputType.MouseMovement then return end
	if self.TimelineScrub and not self.TimelineDrag then self:applyTimelineScrub(input.Position.X); self:updateTimelineGhost(input.Position.X); return end
	local drag = self.TimelineDrag; if not drag then return end
	local document = self:current().Document; local deltaPixels = input.Position.X - drag.StartX
	if math.abs(deltaPixels) < 1 then return end; drag.Moved = true
	local deltaTime = deltaPixels / math.max(1, drag.Width - 24) * document.Duration
	local ignored = {}; local anchorId = self.SelectedKeyId
	for id in drag.InitialTimes do ignored[id] = true; if not anchorId then anchorId = id end end
	local anchorInitial = if anchorId then drag.InitialTimes[anchorId] else nil
	local snapOffset = 0
	if anchorInitial then local rawAnchor = anchorInitial + deltaTime; snapOffset = self:snapTimelineTime(rawAnchor, true, ignored) - rawAnchor end
	for id, initialTime in drag.InitialTimes do
		local key = Document.findById(document, id); if key then key.Time = math.clamp(initialTime + deltaTime + snapOffset, 0, document.Duration) end
	end
	Document.sort(document)
	local anchor = if self.SelectedKeyId then Document.findById(document, self.SelectedKeyId) else nil
	if anchor then self.Playhead = anchor.Time; self:current().WorkingPose = self:evaluate(anchor.Time); self:applyEditorPose(self:current().WorkingPose) end
	-- Update only key positions so the active drag objects remain alive.
	for _, child in self.UI.TimelineKeys:GetChildren() do
		if child:IsA("TextButton") then local key = Document.findById(document, child.Name); if key then child.Position = UDim2.fromOffset(math.floor(key.Time / document.Duration * (drag.Width - 24)), child.Position.Y.Offset) end end
	end
	self:updateTimelinePlayhead()
end

function Controller:endTimelineDrag(input: InputObject)
	if input.UserInputType ~= Enum.UserInputType.MouseButton1 then return end
	if self.TimelineScrub then
		self.TimelineScrub = false; if self.UI.GhostPlayhead then self.UI.GhostPlayhead.Visible = false end; self:updateOnion()
		if not self.TimelineDrag then return end
	end
	if not self.TimelineDrag then return end
	local drag = self.TimelineDrag; self.TimelineDrag = nil
	if drag.Moved then
		local after = copyState(self:current()); self.History.Present = drag.Before; self.History:Replace(after, true); self:scheduleSave(); self:status("Move keys — undo available.")
	end
	self:refreshTimeline(); self:refreshFields(); self:updateOnion()
end

function Controller:verifiedAnimationText(document: AnimationDocument): (string?, string)
	if #document.Keyframes == 0 then return nil, "Create at least one keyframe before exporting the animation." end
	local text = Codec.buildV3(document)
	if #text > MAX_EXPORT_BYTES then return nil, "Animation export exceeds the 7.5 MB local safety limit." end
	local verified, message = Codec.verifyV3(document, text)
	if not verified then return nil, "Export verification failed: " .. message end
	return text, message
end

function Controller:showAnimationText(document: AnimationDocument?)
	local text, message = self:verifiedAnimationText(document or self:current().Document)
	if not text then self:status(message, true); return end
	self.UI.Text.Text = text; self:setTextVisible(true)
	if self.UI.TextHelp then self.UI.TextHelp.Text = "WHOLE ANIMATION V3 â€” verified complete. Press Ctrl+C now; all text is selected. You can also edit/paste V1, V2, or V3 here for importing." end
	self.UI.Text:CaptureFocus(); self.UI.Text.CursorPosition = 1; self.UI.Text.SelectionStart = #text + 1
	self:status(message .. " Press Ctrl+C to copy it.")
end

function Controller:prepareText(selectedOnly: boolean?)
	if not selectedOnly then self:showAnimationText(); return end
	local text = Codec.buildSelected(self:evaluate(self.Playhead))
	self.UI.Text.Text = text; self:setTextVisible(true)
	if self.UI.TextHelp then self.UI.TextHelp.Text = "SELECTED POSE V3 â€” evaluated at the current playhead. Press Ctrl+C now; all text is selected." end
	self.UI.Text:CaptureFocus(); self.UI.Text.CursorPosition = 1; self.UI.Text.SelectionStart = #text + 1
	self:status("Selected pose text prepared. Press Ctrl+C to copy it.")
end

local function safeExportName(raw: string): string
	local cleaned = string.gsub(raw, "[%c<>:\"/\\|%?%*]", "_")
	cleaned = string.gsub(cleaned, "^%s+", ""); cleaned = string.gsub(cleaned, "%s+$", "")
	cleaned = string.gsub(cleaned, "[%.%s]+$", "")
	if cleaned == "" then cleaned = "Untitled Animation" end
	return string.sub(cleaned, 1, 96)
end

function Controller:exportAnimationFile(extension: "txt" | "luau")
	local text, verification = self:verifiedAnimationText(self:current().Document)
	if not text then self:status(verification, true); return end
	local rawName = if self.UI.AnimationName and self.UI.AnimationName.Text ~= "" then self.UI.AnimationName.Text else "Untitled Animation"
	local fileName = safeExportName(rawName) .. "." .. extension
	local request = {
		Version = 1,
		Token = game:GetService("HttpService"):GenerateGUID(false),
		FileName = fileName,
		Extension = extension,
		Content = text,
		CreatedAt = os.time(),
	}
	local ok, reason = pcall(function() self.Plugin:SetSetting(EXPORT_REQUEST_SETTING, request) end)
	if not ok then
		self:status("Could not queue the file export: " .. tostring(reason) .. ". Opening the verified text instead.", true)
		self:showAnimationText(); return
	end
	self:status(verification .. " Queued pose-exports/" .. fileName .. " (a numbered copy is used if it exists). Run the pose-tuner BAT if the file does not appear.")
end

function Controller:importText()
	local document, message = Codec.parseAny(self.UI.Text.Text, Codec.neutralPose())
	if not document then self:status(message, true); return end
	self:transact("Import animation", function(state) state.Document = document; state.WorkingPose = Document.evaluate(document, Document.earliestTime(document), Codec.neutralPose()) end, true)
	self.Playhead = Document.earliestTime(document); self:status(message)
end

function Controller:setTextVisible(visible: boolean)
	if self.UI.Text then self.UI.Text.Visible = visible end
	if self.UI.TextHelp then self.UI.TextHelp.Visible = visible end
	if self.UI.TextSelectAll then self.UI.TextSelectAll.Visible = visible end
	if self.UI.TextToggle then self.UI.TextToggle.Text = if visible then "HIDE TEXT" else "TEXT" end
	if not visible and self.UI.TextHelp then self.UI.TextHelp.Text = "Paste V1/V2/V3 animation text below, or view the verified selected pose/whole animation. The full V3 view contains every animation setting and key detail." end
end

function Controller:showToolTab(name: string)
	self.ActiveToolTab = name
	if self.UI.StyleMenu then self.UI.StyleMenu.Visible = false end
	if self.UI.DirectionMenu then self.UI.DirectionMenu.Visible = false end
	self.UI.ActiveDropdown = nil
	if not self.UI.ToolPages then return end
	for pageName, page in self.UI.ToolPages do page.Visible = pageName == name end
	for tabName, tab in self.UI.ToolTabs do tab.BackgroundColor3 = if tabName == name then COLORS.Active else COLORS.Button end
	if name == "Easing" then task.defer(function() if self.Open then self:updateCurve() end end) end
end

function Controller:setEditorMode(mode: "Move" | "Rotate" | "IK")
	if not self.Editor then return end
	self.Editor:SetMode(mode)
	if self.UI.ModeButtons then for name, item in self.UI.ModeButtons do item.BackgroundColor3 = if name == mode then COLORS.Active else COLORS.Button end end
end

function Controller:confirmDestructive(action: string, item: TextButton, normalText: string, callback: () -> ())
	local now = os.clock()
	if self.PendingDestructiveAction == action and now <= (self.PendingDestructiveUntil or 0) then
		self.PendingDestructiveAction = nil; self.PendingDestructiveUntil = 0; item.Text = normalText; callback(); return
	end
	self.PendingDestructiveAction = action; self.PendingDestructiveUntil = now + 4; item.Text = "CLICK AGAIN"
	self:status("Click again within 4 seconds to confirm " .. normalText .. ".", true)
	task.delay(4, function()
		if self.PendingDestructiveAction == action and os.clock() > (self.PendingDestructiveUntil or 0) then
			self.PendingDestructiveAction = nil; self.PendingDestructiveUntil = 0
			if item.Parent then item.Text = normalText end
		end
	end)
end

function Controller:clearHistory()
	if not self.History then return end
	self.History:Clear(); self:status("Undo and redo history cleared.")
end

function Controller:deleteSavedAnimations()
	if not self.History then return end
	self:transact("Delete saved animations", function(state)
		table.clear(state.Catalog.Animations); state.Catalog.LastAnimationId = ""
	end)
	self:status("All locally saved animation catalog entries were deleted.")
end

function Controller:resetAllTunerData()
	if not self.History then return end
	local catalog = self.Persistence:DefaultState()
	local document = Document.new()
	local initial = {
		Document = document, WorkingPose = Codec.neutralPose(),
		Snapping = { Enabled = true, Move = 0.02, Rotate = 2, Timeline = true },
		Onion = true, Catalog = catalog,
	}
	self.History = History.new(copyState, initial); self.Playhead = 0; self.Playing = false
	self.SelectedJoint = "Root"; self.SelectionActive = true; self.SelectedTimelineTrack = "Master"; self.SelectedKeyId = nil
	table.clear(self.SelectedKeys); table.clear(self.CopiedKeys); self.TimelineDrag = nil; self.TimelineScrub = false
	local ok, message = self.Persistence:Save(catalog)
	if self.Editor then self:applyEditorPose(initial.WorkingPose); self.Editor:SelectJoint("Root"); self:setEditorMode("Move") end
	self.SelectedTimelineTrack = "Master"
	self:refreshAll(); self:updateOnion()
	self:status(if ok then "All tuner history, drafts, settings, and saved animations were reset." else "Reset completed, but local settings could not be saved: " .. message, not ok)
end

function Controller:applyResponsiveLayout()
	local root = self.UI.Root; if not root then return end
	local size = root.AbsoluteSize; if size.X < 1 or size.Y < 1 then return end
	local nextMode = if size.X >= 1500 then "Wide" elseif size.X >= 1100 then "Compact" else "Minimal"
	if nextMode ~= self.LayoutMode then
		self.LayoutMode = nextMode
		if nextMode == "Wide" then self.InspectorVisible = true; self.ToolsVisible = true
		elseif nextMode == "Compact" then self.InspectorVisible = true; self.ToolsVisible = false
		else self.InspectorVisible = false; self.ToolsVisible = false end
	end
	local inspectorWidth = math.min(400, size.X - 24)
	local timelineHeight = if size.Y >= 760 then 205 else 180
	local timelineX = if nextMode == "Minimal" then 12 else inspectorWidth + 24
	local timelineRight = if nextMode == "Wide" then 424 else 12
	local timelineWidth = math.max(320, size.X - timelineX - timelineRight)
	self.UI.Inspector.Size = UDim2.fromOffset(inspectorWidth, math.max(360, size.Y - 24)); self.UI.Inspector.Position = UDim2.fromOffset(12, 12)
	self.UI.Inspector.Visible = self.InspectorVisible
	self.UI.Timeline.Size = UDim2.fromOffset(timelineWidth, timelineHeight); self.UI.Timeline.Position = UDim2.fromOffset(timelineX, size.Y - timelineHeight - 12)
	local toolsWidth = math.min(400, size.X - 24); local toolsHeight = math.max(300, size.Y - timelineHeight - 160)
	self.UI.ToolsPanel.Size = UDim2.fromOffset(toolsWidth, toolsHeight); self.UI.ToolsPanel.Position = UDim2.fromOffset(size.X - toolsWidth - 12, 136)
	self.UI.ToolsPanel.Visible = self.ToolsVisible
	local viewWidth = math.min(650, math.max(500, size.X - 180))
	self.UI.ViewPanel.Size = UDim2.fromOffset(viewWidth, 112); self.UI.ViewPanel.Position = UDim2.fromOffset(math.floor((size.X - viewWidth) * 0.5), 12)
	self.UI.InspectorToggle.Visible = nextMode == "Minimal"; self.UI.ToolsToggle.Visible = nextMode ~= "Wide"
	self.UI.InspectorToggle.Position = UDim2.fromOffset(12, 130); self.UI.ToolsToggle.Position = UDim2.new(1, -112, 0, 130)
	local textWidth = math.min(540, size.X - 24); self.UI.Text.Size = UDim2.fromOffset(textWidth, math.max(260, size.Y - 142)); self.UI.Text.Position = UDim2.fromOffset(size.X - textWidth - 12, 126)
	self.UI.TextHelp.Size = UDim2.fromOffset(textWidth, 44); self.UI.TextHelp.Position = UDim2.fromOffset(size.X - textWidth - 12, 82)
	self.UI.TextToggle.Position = UDim2.new(1, -112, 0, 12)
	if self.UI.TextSelectAll then self.UI.TextSelectAll.Position = UDim2.new(1, -222, 0, 12) end
	self:refreshTimeline()
end

function Controller:buildResponsiveUI(guiParent: Instance)
	local root = Instance.new("Frame"); root.Name = "PoseTunerRoot"; root.Size = UDim2.fromScale(1, 1); root.BackgroundTransparency = 1; root.BorderSizePixel = 0; root.Parent = guiParent; self.UI.Root = root
	local scroll = Instance.new("ScrollingFrame"); scroll.Name = "Inspector"; scroll.BackgroundColor3 = COLORS.Panel; scroll.BackgroundTransparency = 0.03; scroll.BorderSizePixel = 0; scroll.ScrollBarThickness = 7; scroll.CanvasSize = UDim2.fromOffset(0, 730); scroll.Parent = root; corner(scroll, 7); self.UI.Inspector = scroll
	local title = label(scroll, "R15 POSE TUNER V3", UDim2.new(1, -24, 0, 28), UDim2.fromOffset(12, 8), true); title.TextSize = 17
	local key = button(scroll, "Key Pose", UDim2.fromOffset(82, 30), UDim2.fromOffset(12, 42)); key.Activated:Connect(function() self:keyPose() end)
	self.UI.Play = button(scroll, "Play", UDim2.fromOffset(62, 30), UDim2.fromOffset(100, 42)); self.UI.Play.Activated:Connect(function()
		if self.Playing then self:pausePlayback() else self:startPlayback(1, 1) end
	end)
	local undo = button(scroll, "Undo", UDim2.fromOffset(62, 30), UDim2.fromOffset(168, 42)); undo.Activated:Connect(function() self:undo() end)
	local redo = button(scroll, "Redo", UDim2.fromOffset(62, 30), UDim2.fromOffset(236, 42)); redo.Activated:Connect(function() self:redo() end)
	local reset = button(scroll, "Reset", UDim2.fromOffset(68, 30), UDim2.fromOffset(304, 42)); reset.Activated:Connect(function()
		self:transact("Reset document", function(state) state.Document = Document.new(); state.WorkingPose = Codec.neutralPose() end, true); self.Playhead = 0; self.SelectedKeyId = nil; table.clear(self.SelectedKeys)
	end)
	self.UI.Selected = label(scroll, "Selected: Root", UDim2.new(1, -24, 0, 24), UDim2.fromOffset(12, 80), true)
	local modes = { { "MOVE  [E]", "Move" }, { "ROTATE  [R]", "Rotate" }, { "IK", "IK" } }
	self.UI.ModeButtons = {}
	for index, info in modes do local item = button(scroll, info[1], UDim2.fromOffset(88, 30), UDim2.fromOffset(12 + (index - 1) * 94, 108)); item.TextSize = 14; self.UI.ModeButtons[info[2]] = item; item.BackgroundColor3 = if info[2] == "Move" then COLORS.Active else COLORS.Button; item.Activated:Connect(function() self:setEditorMode(info[2] :: any) end) end
	local axis = button(scroll, "Axes: Local", UDim2.fromOffset(94, 28), UDim2.fromOffset(294, 108)); axis.Activated:Connect(function() if not self.Editor then return end; local nextSpace = if self.Editor.AxisSpace == "Local" then "World" else "Local"; self.Editor:SetAxisSpace(nextSpace); axis.Text = "Axes: " .. nextSpace end)

	local jointsPanel = panel(scroll, UDim2.new(1, -24, 0, 170), UDim2.fromOffset(12, 144)); label(jointsPanel, "R15 JOINTS", UDim2.new(1, -12, 0, 22), UDim2.fromOffset(8, 5), true)
	for index, name in JOINTS do
		local column = (index - 1) % 3; local row = math.floor((index - 1) / 3)
		local item = button(jointsPanel, name, UDim2.new(1 / 3, -8, 0, 25), UDim2.new(column / 3, 4, 0, 31 + row * 27)); item.TextSize = 12
		item.Activated:Connect(function() if not self.History then return end; self.SelectedJoint = name; self.SelectedTimelineTrack = name; if self.Editor then self.Editor:SelectJoint(name) end; self:refreshFields(); self:refreshTimeline() end)
	end

	local transformPanel = panel(scroll, UDim2.new(1, -24, 0, 190), UDim2.fromOffset(12, 322)); label(transformPanel, "EXACT JOINT TRANSFORM", UDim2.new(1, -12, 0, 22), UDim2.fromOffset(8, 5), true)
	self.UI.Fields = {}; local names = { "Position X", "Position Y", "Position Z", "Rotation X", "Rotation Y", "Rotation Z" }
	for index, name in names do
		local col = (index - 1) % 2; local row = math.floor((index - 1) / 2); label(transformPanel, name, UDim2.fromOffset(82, 22), UDim2.fromOffset(8 + col * 190, 34 + row * 48))
		local field = box(transformPanel, "0", UDim2.fromOffset(94, 29), UDim2.fromOffset(88 + col * 190, 31 + row * 48)); table.insert(self.UI.Fields, field); field.FocusLost:Connect(function(enter) if enter then self:applyNumeric() else self:refreshFields() end end)
	end
	local viewText = button(scroll, "View Anim TXT", UDim2.fromOffset(112, 30), UDim2.fromOffset(12, 524)); viewText.Activated:Connect(function() self:showAnimationText() end)
	local saveText = button(scroll, "Save .TXT", UDim2.fromOffset(104, 30), UDim2.fromOffset(130, 524)); saveText.Activated:Connect(function() self:exportAnimationFile("txt") end)
	local saveLuau = button(scroll, "Save .LUAU", UDim2.fromOffset(112, 30), UDim2.fromOffset(240, 524)); saveLuau.Activated:Connect(function() self:exportAnimationFile("luau") end)
	local selected = button(scroll, "View Pose TXT", UDim2.fromOffset(112, 30), UDim2.fromOffset(12, 562)); selected.Activated:Connect(function() self:prepareText(true) end)
	local importText = button(scroll, "Import Text", UDim2.fromOffset(104, 30), UDim2.fromOffset(130, 562)); importText.Activated:Connect(function() self:importText() end)
	self.UI.Status = label(scroll, "Ready.", UDim2.new(1, -24, 0, 94), UDim2.fromOffset(12, 608)); self.UI.Status.TextWrapped = true; self.UI.Status.TextYAlignment = Enum.TextYAlignment.Top; self.UI.Status.TextColor3 = COLORS.Good; self.UI.Status.TextSize = 13

	local tools = panel(root, UDim2.fromOffset(400, 500), UDim2.new(1, -412, 0, 100)); self.UI.ToolsPanel = tools
	self.UI.ToolPages = {}; self.UI.ToolTabs = {}
	for index, name in { "Pose", "Parameters", "Easing", "Animations", "Dummies" } do
		local tab = button(tools, name, UDim2.new(0.2, -6, 0, 31), UDim2.new((index - 1) * 0.2, 4, 0, 5)); self.UI.ToolTabs[name] = tab; tab.Activated:Connect(function() self:showToolTab(name) end)
		local page = Instance.new("Frame"); page.Name = name; page.Size = UDim2.new(1, -16, 1, -46); page.Position = UDim2.fromOffset(8, 40); page.BackgroundTransparency = 1; page.Parent = tools; self.UI.ToolPages[name] = page
	end

	local posePage = self.UI.ToolPages.Pose; label(posePage, "POSE CREATION", UDim2.new(1, -8, 0, 24), UDim2.fromOffset(4, 4), true)
	local neutralKey = button(posePage, "Key Neutral", UDim2.fromOffset(112, 34), UDim2.fromOffset(4, 38)); neutralKey.Activated:Connect(function() self:keyNeutralPose() end)
	local applyPose = button(posePage, "Apply Pose", UDim2.fromOffset(112, 34), UDim2.fromOffset(122, 38)); applyPose.Activated:Connect(function() self:applyCurrentPoseKey() end)
	local mirrorPose = button(posePage, "Mirror Pose", UDim2.fromOffset(112, 34), UDim2.fromOffset(240, 38)); mirrorPose.Activated:Connect(function() self:mirrorCurrentPose() end)
	label(posePage, "Mirror destination", UDim2.fromOffset(130, 24), UDim2.fromOffset(4, 88)); self.UI.MirrorTime = box(posePage, "0.000s", UDim2.fromOffset(112, 30), UDim2.fromOffset(140, 84))
	local mirrorAtPlayhead = button(posePage, "Use Playhead", UDim2.fromOffset(112, 31), UDim2.fromOffset(4, 126)); mirrorAtPlayhead.Activated:Connect(function() self:setMirrorTime(self.Playhead) end)
	local mirrorNextFrame = button(posePage, "+1 Frame", UDim2.fromOffset(112, 31), UDim2.fromOffset(122, 126)); mirrorNextFrame.Activated:Connect(function() self:setMirrorTime(self.Playhead + 1 / self:current().Document.FPS) end)
	local mirrorHint = label(posePage, "Use seconds (1.25s) or frames (38f). Existing destination poses are replaced while their easing is preserved.", UDim2.new(1, -8, 0, 66), UDim2.fromOffset(4, 174)); mirrorHint.TextWrapped = true; mirrorHint.TextYAlignment = Enum.TextYAlignment.Top; mirrorHint.TextColor3 = COLORS.Muted
	local applyHint = label(posePage, "Apply Pose creates a master key containing only joints changed from the neutral pose. An unchanged pose still creates an empty timing key.", UDim2.new(1, -8, 0, 66), UDim2.fromOffset(4, 242)); applyHint.TextWrapped = true; applyHint.TextYAlignment = Enum.TextYAlignment.Top; applyHint.TextColor3 = COLORS.Muted

	local params = self.UI.ToolPages.Parameters; label(params, "ANIMATION PARAMETERS", UDim2.new(1, -12, 0, 24), UDim2.fromOffset(4, 4), true)
	label(params, "Duration", UDim2.fromOffset(74, 24), UDim2.fromOffset(4, 38)); self.UI.Duration = box(params, "2", UDim2.fromOffset(92, 29), UDim2.fromOffset(88, 34))
	label(params, "Speed", UDim2.fromOffset(64, 24), UDim2.fromOffset(198, 38)); self.UI.Speed = box(params, "1", UDim2.fromOffset(82, 29), UDim2.fromOffset(268, 34))
	label(params, "FPS", UDim2.fromOffset(74, 24), UDim2.fromOffset(4, 78)); self.UI.FPS = box(params, "30", UDim2.fromOffset(92, 29), UDim2.fromOffset(88, 74))
	label(params, "Move snap", UDim2.fromOffset(82, 24), UDim2.fromOffset(4, 122)); self.UI.MoveSnap = box(params, "0.020", UDim2.fromOffset(92, 29), UDim2.fromOffset(88, 118))
	label(params, "Rotate snap", UDim2.fromOffset(90, 24), UDim2.fromOffset(198, 122)); self.UI.RotateSnap = box(params, "2", UDim2.fromOffset(82, 29), UDim2.fromOffset(292, 118))
	self.UI.Duration.FocusLost:Connect(function(enter) if enter then local value = tonumber(self.UI.Duration.Text); if value then self:transact("Scale duration", function(state) Document.scaleDuration(state.Document, value) end) end end; self:refreshParameters() end)
	self.UI.Speed.FocusLost:Connect(function(enter) if enter then local value = tonumber(self.UI.Speed.Text); if value then self:transact("Playback speed", function(state) state.Document.PlaybackSpeed = math.clamp(value, 0.05, 8) end) end end; self:refreshParameters() end)
	self.UI.FPS.FocusLost:Connect(function(enter) if enter then local value = tonumber(self.UI.FPS.Text); if value then self:transact("Timeline FPS", function(state) state.Document.FPS = math.clamp(math.round(value), 1, 240) end) end end; self:refreshParameters() end)
	self.UI.MoveSnap.FocusLost:Connect(function(enter) if enter then local value = tonumber(self.UI.MoveSnap.Text); if value then self:transact("Move snapping", function(state) state.Snapping.Move = math.clamp(value, 0.001, 10) end); if self.Editor then local s = self:current().Snapping; self.Editor:SetSnapSettings(s.Enabled, s.Move, s.Rotate) end end end; self:refreshParameters() end)
	self.UI.RotateSnap.FocusLost:Connect(function(enter) if enter then local value = tonumber(self.UI.RotateSnap.Text); if value then self:transact("Rotation snapping", function(state) state.Snapping.Rotate = math.clamp(value, 0.1, 90) end); if self.Editor then local s = self:current().Snapping; self.Editor:SetSnapSettings(s.Enabled, s.Move, s.Rotate) end end end; self:refreshParameters() end)
	self.UI.Interpolation = button(params, "Smooth Key: On", UDim2.fromOffset(116, 30), UDim2.fromOffset(4, 164)); self.UI.Interpolation.Activated:Connect(function() self:setKeySmooth(nil) end)
	self.UI.Loop = button(params, "Loop: On", UDim2.fromOffset(88, 30), UDim2.fromOffset(126, 164)); self.UI.Loop.Activated:Connect(function() self:transact("Loop", function(state) state.Document.Loop = not state.Document.Loop end) end)
	self.UI.AutoKey = button(params, "Auto-Key: On", UDim2.fromOffset(108, 30), UDim2.fromOffset(222, 164)); self.UI.AutoKey.Activated:Connect(function() self:transact("Auto-Key", function(state) state.Document.AutoKey = not state.Document.AutoKey end) end)
	self.UI.Onion = button(params, "Onion: On", UDim2.fromOffset(88, 30), UDim2.fromOffset(4, 202)); self.UI.Onion.Activated:Connect(function() self:transact("Onion skins", function(state) state.Onion = not state.Onion end); self:updateOnion() end)
	self.UI.Guides = button(params, "Guides: On", UDim2.fromOffset(100, 30), UDim2.fromOffset(100, 202)); self.UI.Guides.Activated:Connect(function() self:transact("Smart guides", function(state) state.Snapping.Enabled = not state.Snapping.Enabled end); if self.Editor then local s = self:current().Snapping; self.Editor:SetSnapSettings(s.Enabled, s.Move, s.Rotate) end end)
	label(params, "DATA MANAGEMENT", UDim2.new(1, -8, 0, 24), UDim2.fromOffset(4, 250), true)
	local clearHistory = button(params, "Clear History", UDim2.fromOffset(112, 32), UDim2.fromOffset(4, 282)); clearHistory.Activated:Connect(function() self:clearHistory() end)
	local deleteAnimations = button(params, "Delete Animations", UDim2.fromOffset(132, 32), UDim2.fromOffset(122, 282)); deleteAnimations.BackgroundColor3 = COLORS.Red; deleteAnimations.Activated:Connect(function() self:confirmDestructive("deleteAnimations", deleteAnimations, "Delete Animations", function() self:deleteSavedAnimations() end) end)
	local resetData = button(params, "Reset All Data", UDim2.fromOffset(126, 32), UDim2.fromOffset(260, 282)); resetData.BackgroundColor3 = COLORS.Red; resetData.Activated:Connect(function() self:confirmDestructive("resetAllData", resetData, "Reset All Data", function() self:resetAllTunerData() end) end)

	local easing = self.UI.ToolPages.Easing; label(easing, "SELECTED SEGMENT EASING", UDim2.new(1, -8, 0, 24), UDim2.fromOffset(4, 4), true)
	self.UI.Style = button(easing, "Style: Linear", UDim2.new(0.5, -8, 0, 32), UDim2.fromOffset(4, 38)); self.UI.Style.Activated:Connect(function() self:toggleDropdown("StyleMenu") end)
	self.UI.Direction = button(easing, "Direction: InOut", UDim2.new(0.5, -8, 0, 32), UDim2.new(0.5, 4, 0, 38)); self.UI.Direction.Activated:Connect(function() self:toggleDropdown("DirectionMenu") end)
	self.UI.Curve = Instance.new("Frame"); self.UI.Curve.Size = UDim2.new(1, -8, 0, 190); self.UI.Curve.Position = UDim2.fromOffset(4, 82); self.UI.Curve.BackgroundColor3 = COLORS.Input; self.UI.Curve.BorderSizePixel = 0; self.UI.Curve.ClipsDescendants = true; self.UI.Curve.Parent = easing; corner(self.UI.Curve)
	local function easingMenu(name: string, values: { string }, field: string, position: UDim2, width: UDim2, visibleRows: number): ScrollingFrame
		local menu = Instance.new("ScrollingFrame"); menu.Name = name; menu.Position = position; menu.Size = UDim2.new(width.X.Scale, width.X.Offset, 0, visibleRows * 27 + 6)
		menu.BackgroundColor3 = COLORS.Background; menu.BorderSizePixel = 0; menu.ScrollBarThickness = 6; menu.ZIndex = 40; menu.Visible = false; menu.ClipsDescendants = true; menu.Parent = easing; corner(menu, 5)
		for index, value in values do
			local choice = button(menu, value, UDim2.new(1, -8, 0, 25), UDim2.fromOffset(3, 3 + (index - 1) * 27)); choice.ZIndex = 41
			choice.Activated:Connect(function() self:setEasing(field, value) end)
		end
		menu.CanvasSize = UDim2.fromOffset(0, #values * 27 + 6)
		return menu
	end
	self.UI.StyleMenu = easingMenu("StyleMenu", Document.EasingStyles, "EasingStyle", UDim2.fromOffset(4, 74), UDim2.new(0.5, -8, 0, 0), 7)
	self.UI.DirectionMenu = easingMenu("DirectionMenu", Document.EasingDirections, "EasingDirection", UDim2.new(0.5, 4, 0, 74), UDim2.new(0.5, -8, 0, 0), 3)
	table.insert(self.Connections, self.UI.Curve:GetPropertyChangedSignal("AbsoluteSize"):Connect(function() self:updateCurve() end))

	local catalog = self.UI.ToolPages.Animations; label(catalog, "LOCAL ANIMATION CATALOG", UDim2.new(1, -8, 0, 24), UDim2.fromOffset(4, 4), true)
	self.UI.AnimationName = box(catalog, "Untitled Animation", UDim2.new(1, -176, 0, 30), UDim2.fromOffset(4, 38)); local save = button(catalog, "Save New", UDim2.fromOffset(78, 30), UDim2.new(1, -166, 0, 38)); save.Activated:Connect(function() self:saveAnimation(false) end); local update = button(catalog, "Update", UDim2.fromOffset(76, 30), UDim2.new(1, -82, 0, 38)); update.Activated:Connect(function() self:saveAnimation(true) end)
	self.UI.AnimationList = Instance.new("ScrollingFrame"); self.UI.AnimationList.Size = UDim2.new(1, -8, 1, -126); self.UI.AnimationList.Position = UDim2.fromOffset(4, 78); self.UI.AnimationList.BackgroundColor3 = COLORS.Input; self.UI.AnimationList.BorderSizePixel = 0; self.UI.AnimationList.ScrollBarThickness = 7; self.UI.AnimationList.Parent = catalog; corner(self.UI.AnimationList)
	local animationActions = { { "Load", function() self:loadAnimation() end }, { "Duplicate", function() local chosen = self:selectedAnimation(); if chosen then self.UI.AnimationName.Text = chosen.Name .. " Copy"; self:transact("Duplicate catalog animation", function(state) local id = "anim_" .. game:GetService("HttpService"):GenerateGUID(false); table.insert(state.Catalog.Animations, { Id = id, Name = self.UI.AnimationName.Text, UpdatedAt = os.time(), Document = Document.copy(chosen.Document) }); state.Catalog.LastAnimationId = id end) end end }, { "View TXT", function() local chosen = self:selectedAnimation(); if chosen then self:showAnimationText(chosen.Document) end end }, { "Delete", function() self:deleteAnimation() end } }
	for index, info in animationActions do local item = button(catalog, info[1], UDim2.new(0.25, -7, 0, 31), UDim2.new((index - 1) * 0.25, 4, 1, -37)); item.Activated:Connect(info[2]) end

	local dummies = self.UI.ToolPages.Dummies; label(dummies, "R15 DUMMY CATALOG", UDim2.new(1, -8, 0, 24), UDim2.fromOffset(4, 4), true)
	self.UI.DummyList = Instance.new("ScrollingFrame"); self.UI.DummyList.Size = UDim2.new(1, -8, 1, -118); self.UI.DummyList.Position = UDim2.fromOffset(4, 38); self.UI.DummyList.BackgroundColor3 = COLORS.Input; self.UI.DummyList.BorderSizePixel = 0; self.UI.DummyList.ScrollBarThickness = 7; self.UI.DummyList.Parent = dummies; corner(self.UI.DummyList)
	local import = button(dummies, "Import Selection", UDim2.new(1 / 3, -7, 0, 34), UDim2.new(0, 4, 1, -40)); import.Activated:Connect(function()
		local chosen = Selection:Get()[1]; if not chosen or not chosen:IsA("Model") then self:status("Select an R15 Model in Explorer first.", true); return end
		local recording = ChangeHistoryService:TryBeginRecording("Import Pose Tuner Dummy")
		local model, reason = RigCatalog.importModel(chosen); if recording then ChangeHistoryService:FinishRecording(recording, if model then Enum.FinishRecordingOperation.Commit else Enum.FinishRecordingOperation.Cancel) end
		if not model then self:status(reason or "Invalid dummy.", true) else self:selectDummy(model.Name) end
	end)
	local hide = button(dummies, "Hide Selected", UDim2.new(1 / 3, -7, 0, 34), UDim2.new(1 / 3, 3, 1, -40)); hide.Activated:Connect(function() local name = self:current().Catalog.LastDummy; if name == "DefaultGrayR15" then self:status("The default dummy cannot be hidden.", true); return end; self:transact("Hide dummy", function(state) table.insert(state.Catalog.HiddenDummies, name); state.Catalog.LastDummy = "DefaultGrayR15" end); self:selectDummy("DefaultGrayR15") end)
	local restore = button(dummies, "Restore Hidden", UDim2.new(1 / 3, -7, 0, 34), UDim2.new(2 / 3, 2, 1, -40)); restore.Activated:Connect(function() self:transact("Restore dummy catalog", function(state) table.clear(state.Catalog.HiddenDummies) end) end)

	local timeline = panel(root, UDim2.fromOffset(800, 205), UDim2.fromOffset(424, 500)); self.UI.Timeline = timeline
	label(timeline, "TIMELINE", UDim2.fromOffset(90, 24), UDim2.fromOffset(8, 5), true); self.UI.Time = label(timeline, "0 / 2", UDim2.fromOffset(120, 24), UDim2.fromOffset(98, 5)); self.UI.Time.TextSize = 12
	self.UI.TimelineSnap = button(timeline, "Time Snap: On", UDim2.fromOffset(102, 27), UDim2.fromOffset(220, 4)); self.UI.TimelineSnap.Activated:Connect(function()
		self:transact("Timeline snapping", function(state) state.Snapping.Timeline = state.Snapping.Timeline == false end)
	end)
	local reversePlay = button(timeline, utf8.char(9664), UDim2.fromOffset(30, 27), UDim2.fromOffset(330, 4)); reversePlay.TextSize = 16; reversePlay.Activated:Connect(function() self:startPlayback(-1, 1) end)
	local forwardPlay = button(timeline, utf8.char(9654), UDim2.fromOffset(30, 27), UDim2.fromOffset(364, 4)); forwardPlay.TextSize = 16; forwardPlay.Activated:Connect(function() self:startPlayback(1, 1) end)
	local pausePlay = button(timeline, "II", UDim2.fromOffset(30, 27), UDim2.fromOffset(398, 4)); pausePlay.TextSize = 14; pausePlay.Activated:Connect(function() self:pausePlayback() end)
	local fastPlay = button(timeline, ">>", UDim2.fromOffset(36, 27), UDim2.fromOffset(432, 4)); fastPlay.TextSize = 14; fastPlay.Activated:Connect(function() self:startPlayback(1, 2) end)
	self.UI.TransportState = label(timeline, "Paused", UDim2.fromOffset(94, 24), UDim2.fromOffset(474, 5)); self.UI.TransportState.TextSize = 12; self.UI.TransportState.TextColor3 = COLORS.Muted
	local deleteKey = button(timeline, "Delete Key", UDim2.fromOffset(86, 27), UDim2.new(1, -94, 0, 4)); deleteKey.Activated:Connect(function() self:deleteSelectedKeys() end)
	local copyKey = button(timeline, "Copy", UDim2.fromOffset(58, 27), UDim2.new(1, -226, 0, 4)); copyKey.Activated:Connect(function() self:copySelected() end)
	local duplicateKey = button(timeline, "Duplicate", UDim2.fromOffset(70, 27), UDim2.new(1, -164, 0, 4)); duplicateKey.Activated:Connect(function() self:copySelected(); self:pasteCopied(1) end)
	local pasteKey = button(timeline, "Paste", UDim2.fromOffset(58, 27), UDim2.new(1, -292, 0, 4)); pasteKey.Activated:Connect(function() self:pasteCopied() end)
	self.UI.TimelineTrackList = Instance.new("ScrollingFrame"); self.UI.TimelineTrackList.Size = UDim2.new(0, 142, 1, -44); self.UI.TimelineTrackList.Position = UDim2.fromOffset(8, 36); self.UI.TimelineTrackList.BackgroundColor3 = COLORS.Input; self.UI.TimelineTrackList.BorderSizePixel = 0; self.UI.TimelineTrackList.ScrollBarThickness = 0; self.UI.TimelineTrackList.ScrollingEnabled = false; self.UI.TimelineTrackList.ClipsDescendants = true; self.UI.TimelineTrackList.Parent = timeline; corner(self.UI.TimelineTrackList)
	self.UI.TimelineKeys = Instance.new("ScrollingFrame"); self.UI.TimelineKeys.Size = UDim2.new(1, -166, 1, -44); self.UI.TimelineKeys.Position = UDim2.fromOffset(158, 36); self.UI.TimelineKeys.BackgroundColor3 = COLORS.Input; self.UI.TimelineKeys.BorderSizePixel = 0; self.UI.TimelineKeys.ScrollBarThickness = 7; self.UI.TimelineKeys.ScrollingDirection = Enum.ScrollingDirection.XY; self.UI.TimelineKeys.ClipsDescendants = true; self.UI.TimelineKeys.Parent = timeline; corner(self.UI.TimelineKeys)
	self.UI.TimelineKeys:GetPropertyChangedSignal("CanvasPosition"):Connect(function() local position = self.UI.TimelineKeys.CanvasPosition; self.UI.TimelineTrackList.CanvasPosition = Vector2.new(0, position.Y) end)

	local view = panel(root, UDim2.fromOffset(650, 112), UDim2.fromOffset(450, 12)); self.UI.ViewPanel = view; label(view, "VIEW", UDim2.fromOffset(48, 26), UDim2.fromOffset(10, 8), true)
	for index, info in { { "Front", "Front" }, { "Back", "Back" }, { "Left", "Left" }, { "Right", "Right" }, { "Top", "Top" }, { "Frame", "Frame" } } do
		local item = button(view, info[1], UDim2.fromOffset(68, 28), UDim2.fromOffset(58 + (index - 1) * 72, 7)); item.Activated:Connect(function() if self.Editor then self:setFirstPersonPreview(false); self.Editor:FrameDummy(info[2]) end end)
	end
	self.UI.GroundLock = button(view, "Ground (Key): On", UDim2.fromOffset(136, 29), UDim2.fromOffset(10, 43)); self.UI.GroundLock.Activated:Connect(function() self:setGroundLock(nil) end)
	self.UI.FirstPerson = button(view, "First Person: Off", UDim2.fromOffset(130, 29), UDim2.fromOffset(152, 43)); self.UI.FirstPerson.Activated:Connect(function() if self.Editor then self:setFirstPersonPreview(not self.Editor.FirstPersonEnabled) end end)
	local close = button(view, "CLOSE", UDim2.fromOffset(76, 29), UDim2.new(1, -84, 0, 43)); close.BackgroundColor3 = COLORS.Red; close.Activated:Connect(function() self:Close() end)
	local navigation = label(view, "Native Studio camera: RMB navigation + wheel. First Person locks translation and uses mouse-look only.", UDim2.new(1, -20, 0, 24), UDim2.fromOffset(10, 78)); navigation.TextSize = 12; navigation.TextColor3 = COLORS.Muted

	self.UI.InspectorToggle = button(root, "INSPECTOR", UDim2.fromOffset(106, 30), UDim2.fromOffset(12, 130)); self.UI.InspectorToggle.Activated:Connect(function() self.InspectorVisible = not self.InspectorVisible; self.UI.Inspector.Visible = self.InspectorVisible end)
	self.UI.ToolsToggle = button(root, "TOOLS", UDim2.fromOffset(100, 30), UDim2.new(1, -112, 0, 130)); self.UI.ToolsToggle.Activated:Connect(function() self.ToolsVisible = not self.ToolsVisible; self.UI.ToolsPanel.Visible = self.ToolsVisible end)
	self.UI.TextToggle = button(root, "TEXT", UDim2.fromOffset(100, 30), UDim2.new(1, -112, 0, 12)); self.UI.TextToggle.Activated:Connect(function() self:setTextVisible(not self.UI.Text.Visible) end)
	self.UI.TextSelectAll = button(root, "SELECT ALL", UDim2.fromOffset(104, 30), UDim2.new(1, -222, 0, 12)); self.UI.TextSelectAll.Visible = false; self.UI.TextSelectAll.ZIndex = 32; self.UI.TextSelectAll.Activated:Connect(function()
		local text = self.UI.Text.Text; self.UI.Text:CaptureFocus(); self.UI.Text.CursorPosition = 1; self.UI.Text.SelectionStart = #text + 1
		self:status("Animation text selected. Press Ctrl+C to copy it.")
	end)
	self.UI.TextHelp = label(root, "Paste V1/V2/V3 animation text below, or view the verified selected pose/whole animation. The full V3 view contains every animation setting and key detail.", UDim2.fromOffset(520, 44), UDim2.new(1, -532, 0, 82)); self.UI.TextHelp.TextWrapped = true; self.UI.TextHelp.TextColor3 = COLORS.Muted; self.UI.TextHelp.Visible = false; self.UI.TextHelp.ZIndex = 31
	self.UI.Text = box(root, "Paste or export animation text here.", UDim2.fromOffset(520, 620), UDim2.new(1, -532, 0, 126)); self.UI.Text.MultiLine = true; self.UI.Text.TextXAlignment = Enum.TextXAlignment.Left; self.UI.Text.TextYAlignment = Enum.TextYAlignment.Top; self.UI.Text.TextWrapped = false; self.UI.Text.ClipsDescendants = true; self.UI.Text.Visible = false; self.UI.Text.ZIndex = 30

	local loading = Instance.new("Frame"); loading.Name = "Loading"; loading.Size = UDim2.fromOffset(440, 170); loading.AnchorPoint = Vector2.new(0.5, 0.5); loading.Position = UDim2.fromScale(0.5, 0.5); loading.BackgroundColor3 = COLORS.Background; loading.ZIndex = 100; loading.Active = true; loading.Parent = root; corner(loading, 8); self.UI.Loading = loading
	self.UI.LoadingTitle = label(loading, "Opening R15 Pose Tuner", UDim2.new(1, -40, 0, 34), UDim2.new(0, 20, 0.5, -68), true); self.UI.LoadingTitle.TextSize = 17; self.UI.LoadingTitle.ZIndex = 101; self.UI.LoadingTitle.TextXAlignment = Enum.TextXAlignment.Center
	self.UI.LoadingStatus = label(loading, "Loading modules...", UDim2.new(1, -40, 0, 48), UDim2.new(0, 20, 0.5, -28)); self.UI.LoadingStatus.ZIndex = 101; self.UI.LoadingStatus.TextXAlignment = Enum.TextXAlignment.Center; self.UI.LoadingStatus.TextWrapped = true
	self.UI.Retry = button(loading, "Retry", UDim2.fromOffset(100, 32), UDim2.new(0.5, -50, 0.5, 36)); self.UI.Retry.ZIndex = 101; self.UI.Retry.Visible = false; self.UI.Retry.Activated:Connect(function() task.spawn(function() self:initializeEditor() end) end)
	self:showToolTab("Pose")
	table.insert(self.Connections, root:GetPropertyChangedSignal("AbsoluteSize"):Connect(function() self:applyResponsiveLayout() end))
	task.defer(function() self:applyResponsiveLayout() end)
end

function Controller:buildUI(guiParent: Instance)
	local root = Instance.new("Frame"); root.Name = "PoseTunerRoot"; root.Size = UDim2.fromScale(1, 1); root.BackgroundTransparency = 1; root.BorderSizePixel = 0; root.Parent = guiParent; self.UI.Root = root
	local scroll = Instance.new("ScrollingFrame"); scroll.Name = "Inspector"; scroll.Size = UDim2.fromOffset(400, 720); scroll.Position = UDim2.fromOffset(12, 12); scroll.BackgroundColor3 = COLORS.Panel; scroll.BackgroundTransparency = 0.04; scroll.BorderSizePixel = 0; scroll.ScrollBarThickness = 5; scroll.CanvasSize = UDim2.fromOffset(0, 690); scroll.Parent = root; corner(scroll, 6)
	label(scroll, "R15 POSE TUNER V3", UDim2.new(1, -24, 0, 24), UDim2.fromOffset(12, 8), true)
	local key = button(scroll, "Key Pose", UDim2.fromOffset(76, 28), UDim2.fromOffset(12, 38)); key.Activated:Connect(function() self:keyPose() end)
	self.UI.Play = button(scroll, "Play", UDim2.fromOffset(58, 28), UDim2.fromOffset(94, 38)); self.UI.Play.Activated:Connect(function()
		if not self.Playing then
			if #self:current().Document.Keyframes == 0 then self:status("Create a key before playback.", true); return end
			self.Playhead = Document.earliestTime(self:current().Document); self.Playing = true; self.UI.Play.Text = "Stop"; self:setPlayhead(self.Playhead)
		else self.Playing = false; self.UI.Play.Text = "Play" end
	end)
	local undo = button(scroll, "Undo", UDim2.fromOffset(58, 28), UDim2.fromOffset(158, 38)); undo.Activated:Connect(function() self:undo() end)
	local redo = button(scroll, "Redo", UDim2.fromOffset(58, 28), UDim2.fromOffset(222, 38)); redo.Activated:Connect(function() self:redo() end)
	local reset = button(scroll, "Reset", UDim2.fromOffset(58, 28), UDim2.fromOffset(286, 38)); reset.Activated:Connect(function()
		self:transact("Reset document", function(state) state.Document = Document.new(); state.WorkingPose = Codec.neutralPose() end, true); self.Playhead = 0; self.SelectedKeyId = nil
	end)
	self.UI.Selected = label(scroll, "Selected: Root", UDim2.new(1, -24, 0, 22), UDim2.fromOffset(12, 72), true)
	local modes = { { "Move (E)", "Move" }, { "Rotate (R)", "Rotate" }, { "IK", "IK" } }
	for index, info in modes do local item = button(scroll, info[1], UDim2.fromOffset(86, 25), UDim2.fromOffset(12 + (index - 1) * 92, 98)); item.Activated:Connect(function() if self.Editor then self.Editor:SetMode(info[2]) end end) end
	local axis = button(scroll, "Axes: Local", UDim2.fromOffset(96, 25), UDim2.fromOffset(288, 98)); axis.Activated:Connect(function() if not self.Editor then return end; local nextSpace = if self.Editor.AxisSpace == "Local" then "World" else "Local"; self.Editor:SetAxisSpace(nextSpace); axis.Text = "Axes: " .. nextSpace end)

	local jointsPanel = panel(scroll, UDim2.new(1, -24, 0, 132), UDim2.fromOffset(12, 132)); label(jointsPanel, "R15 JOINTS", UDim2.new(1, -12, 0, 20), UDim2.fromOffset(8, 4), true)
	for index, name in JOINTS do
		local column = (index - 1) % 3; local row = math.floor((index - 1) / 3)
		local item = button(jointsPanel, name, UDim2.new(1 / 3, -8, 0, 19), UDim2.new(column / 3, 4, 0, 27 + row * 20)); item.TextSize = 9
		item.Activated:Connect(function() if not self.History then return end; self.SelectedJoint = name; if self.Editor then self.Editor:SelectJoint(name) end; self:refreshFields() end)
	end

	local transformPanel = panel(scroll, UDim2.new(1, -24, 0, 154), UDim2.fromOffset(12, 272)); label(transformPanel, "EXACT JOINT TRANSFORM", UDim2.new(1, -12, 0, 20), UDim2.fromOffset(8, 4), true)
	self.UI.Fields = {}; local names = { "Position X", "Position Y", "Position Z", "Rotation X", "Rotation Y", "Rotation Z" }
	for index, name in names do
		local col = (index - 1) % 2; local row = math.floor((index - 1) / 2); label(transformPanel, name, UDim2.fromOffset(76, 20), UDim2.fromOffset(8 + col * 190, 28 + row * 36))
		local field = box(transformPanel, "0", UDim2.fromOffset(92, 24), UDim2.fromOffset(86 + col * 190, 26 + row * 36)); table.insert(self.UI.Fields, field); field.FocusLost:Connect(function(enter) if enter then self:applyNumeric() else self:refreshFields() end end)
	end

	local params = panel(root, UDim2.fromOffset(370, 122), UDim2.new(1, -382, 0, 48)); label(params, "ANIMATION PARAMETERS", UDim2.new(1, -12, 0, 20), UDim2.fromOffset(8, 4), true)
	label(params, "Duration", UDim2.fromOffset(55, 20), UDim2.fromOffset(8, 28)); self.UI.Duration = box(params, "2", UDim2.fromOffset(62, 22), UDim2.fromOffset(66, 26))
	label(params, "Speed", UDim2.fromOffset(42, 20), UDim2.fromOffset(140, 28)); self.UI.Speed = box(params, "1", UDim2.fromOffset(55, 22), UDim2.fromOffset(184, 26))
	label(params, "FPS", UDim2.fromOffset(30, 20), UDim2.fromOffset(250, 28)); self.UI.FPS = box(params, "30", UDim2.fromOffset(48, 22), UDim2.fromOffset(280, 26))
	self.UI.Duration.FocusLost:Connect(function(enter) if enter then local value = tonumber(self.UI.Duration.Text); if value then self:transact("Scale duration", function(state) Document.scaleDuration(state.Document, value) end) end end; self:refreshParameters() end)
	self.UI.Speed.FocusLost:Connect(function(enter) if enter then local value = tonumber(self.UI.Speed.Text); if value then self:transact("Playback speed", function(state) state.Document.PlaybackSpeed = math.clamp(value, 0.05, 8) end) end end; self:refreshParameters() end)
	self.UI.FPS.FocusLost:Connect(function(enter) if enter then local value = tonumber(self.UI.FPS.Text); if value then self:transact("Timeline FPS", function(state) state.Document.FPS = math.clamp(math.round(value), 1, 240) end) end end; self:refreshParameters() end)
	self.UI.Interpolation = button(params, "Step", UDim2.fromOffset(72, 24), UDim2.fromOffset(8, 60)); self.UI.Interpolation.Activated:Connect(function() self:transact("Interpolation", function(state) state.Document.Interpolation = if state.Document.Interpolation == "Step" then "Smooth" else "Step" end) end)
	self.UI.Loop = button(params, "Loop: On", UDim2.fromOffset(72, 24), UDim2.fromOffset(86, 60)); self.UI.Loop.Activated:Connect(function() self:transact("Loop", function(state) state.Document.Loop = not state.Document.Loop end) end)
	self.UI.AutoKey = button(params, "Auto-Key: On", UDim2.fromOffset(92, 24), UDim2.fromOffset(164, 60)); self.UI.AutoKey.Activated:Connect(function() self:transact("Auto-Key", function(state) state.Document.AutoKey = not state.Document.AutoKey end) end)
	self.UI.Onion = button(params, "Onion: On", UDim2.fromOffset(82, 24), UDim2.fromOffset(262, 60)); self.UI.Onion.Activated:Connect(function() self:transact("Onion skins", function(state) state.Onion = not state.Onion end); self:updateOnion() end)
	local snap = button(params, "Guides: On", UDim2.fromOffset(82, 24), UDim2.fromOffset(8, 90)); snap.Activated:Connect(function() self:transact("Smart guides", function(state) state.Snapping.Enabled = not state.Snapping.Enabled end); if self.Editor then local s = self:current().Snapping; self.Editor:SetSnapSettings(s.Enabled, s.Move, s.Rotate) end; snap.Text = "Guides: " .. (if self:current().Snapping.Enabled then "On" else "Off") end)

	local easing = panel(root, UDim2.fromOffset(370, 116), UDim2.new(1, -382, 0, 178)); label(easing, "SELECTED SEGMENT EASING", UDim2.new(1, -12, 0, 20), UDim2.fromOffset(8, 4), true)
	self.UI.Style = button(easing, "Style: Linear", UDim2.fromOffset(132, 25), UDim2.fromOffset(8, 28)); self.UI.Style.Activated:Connect(function() self:cycleEasing("EasingStyle", Document.EasingStyles) end)
	self.UI.Direction = button(easing, "Direction: InOut", UDim2.fromOffset(132, 25), UDim2.fromOffset(146, 28)); self.UI.Direction.Activated:Connect(function() self:cycleEasing("EasingDirection", Document.EasingDirections) end)
	self.UI.Curve = Instance.new("Frame"); self.UI.Curve.Size = UDim2.new(1, -294, 0, 74); self.UI.Curve.Position = UDim2.fromOffset(286, 28); self.UI.Curve.BackgroundColor3 = COLORS.Input; self.UI.Curve.BorderSizePixel = 0; self.UI.Curve.Parent = easing; corner(self.UI.Curve)

	local timeline = panel(root, UDim2.new(1, -806, 0, 205), UDim2.new(0, 424, 1, -217)); label(timeline, "TIMELINE", UDim2.fromOffset(70, 20), UDim2.fromOffset(8, 4), true); self.UI.Time = label(timeline, "0 / 2", UDim2.fromOffset(120, 20), UDim2.fromOffset(76, 4))
	local deleteKey = button(timeline, "Delete Key", UDim2.fromOffset(76, 22), UDim2.new(1, -84, 0, 3)); deleteKey.Activated:Connect(function() self:deleteSelectedKeys() end)
	local copyKey = button(timeline, "Copy", UDim2.fromOffset(52, 22), UDim2.new(1, -200, 0, 3)); copyKey.Activated:Connect(function() self:copySelected() end)
	local duplicateKey = button(timeline, "Duplicate", UDim2.fromOffset(60, 22), UDim2.new(1, -144, 0, 3)); duplicateKey.Activated:Connect(function() self:copySelected(); self:pasteCopied(1) end)
	self.UI.TimelineKeys = Instance.new("ScrollingFrame"); self.UI.TimelineKeys.Size = UDim2.new(1, -16, 1, -40); self.UI.TimelineKeys.Position = UDim2.fromOffset(8, 32); self.UI.TimelineKeys.BackgroundColor3 = COLORS.Input; self.UI.TimelineKeys.BorderSizePixel = 0; self.UI.TimelineKeys.ScrollBarThickness = 5; self.UI.TimelineKeys.ScrollingDirection = Enum.ScrollingDirection.X; self.UI.TimelineKeys.Parent = timeline; corner(self.UI.TimelineKeys)

	local catalog = panel(root, UDim2.fromOffset(370, 190), UDim2.new(1, -382, 0, 302)); label(catalog, "LOCAL ANIMATION CATALOG", UDim2.new(1, -12, 0, 20), UDim2.fromOffset(8, 4), true)
	self.UI.AnimationName = box(catalog, "Untitled Animation", UDim2.new(1, -176, 0, 24), UDim2.fromOffset(8, 28)); local save = button(catalog, "Save New", UDim2.fromOffset(74, 24), UDim2.new(1, -160, 0, 28)); save.Activated:Connect(function() self:saveAnimation(false) end); local update = button(catalog, "Update", UDim2.fromOffset(70, 24), UDim2.new(1, -80, 0, 28)); update.Activated:Connect(function() self:saveAnimation(true) end)
	self.UI.AnimationList = Instance.new("ScrollingFrame"); self.UI.AnimationList.Size = UDim2.new(0.5, -12, 0, 94); self.UI.AnimationList.Position = UDim2.fromOffset(8, 60); self.UI.AnimationList.BackgroundColor3 = COLORS.Input; self.UI.AnimationList.BorderSizePixel = 0; self.UI.AnimationList.ScrollBarThickness = 5; self.UI.AnimationList.Parent = catalog; corner(self.UI.AnimationList)
	local actions = { { "Load", function() self:loadAnimation() end }, { "Duplicate", function() local selected = self:selectedAnimation(); if selected then self.UI.AnimationName.Text = selected.Name .. " Copy"; self:transact("Duplicate catalog animation", function(state) local id = "anim_" .. game:GetService("HttpService"):GenerateGUID(false); table.insert(state.Catalog.Animations, { Id = id, Name = self.UI.AnimationName.Text, UpdatedAt = os.time(), Document = Document.copy(selected.Document) }); state.Catalog.LastAnimationId = id end) end end }, { "Export", function() local selected = self:selectedAnimation(); if selected then self.UI.Text.Text = Codec.buildV3(selected.Document); self.UI.Text.Visible = true end end }, { "Delete", function() self:deleteAnimation() end } }
	for index, info in actions do local item = button(catalog, info[1], UDim2.new(0.5, -12, 0, 24), UDim2.new(0.5, 4, 0, 60 + (index - 1) * 27)); item.Activated:Connect(info[2]) end

	local dummies = panel(root, UDim2.fromOffset(370, 132), UDim2.new(1, -382, 0, 500)); label(dummies, "R15 DUMMY CATALOG", UDim2.new(1, -12, 0, 20), UDim2.fromOffset(8, 4), true)
	self.UI.DummyList = Instance.new("ScrollingFrame"); self.UI.DummyList.Size = UDim2.new(0.55, -10, 0, 92); self.UI.DummyList.Position = UDim2.fromOffset(8, 28); self.UI.DummyList.BackgroundColor3 = COLORS.Input; self.UI.DummyList.BorderSizePixel = 0; self.UI.DummyList.ScrollBarThickness = 5; self.UI.DummyList.Parent = dummies; corner(self.UI.DummyList)
	local import = button(dummies, "Import Selection", UDim2.new(0.45, -10, 0, 26), UDim2.new(0.55, 2, 0, 28)); import.Activated:Connect(function()
		local chosen = Selection:Get()[1]; if not chosen or not chosen:IsA("Model") then self:status("Select an R15 Model in Explorer first.", true); return end
		local recording = ChangeHistoryService:TryBeginRecording("Import Pose Tuner Dummy")
		local model, reason = RigCatalog.importModel(chosen); if recording then ChangeHistoryService:FinishRecording(recording, if model then Enum.FinishRecordingOperation.Commit else Enum.FinishRecordingOperation.Cancel) end
		if not model then self:status(reason or "Invalid dummy.", true) else self:selectDummy(model.Name) end
	end)
	local hide = button(dummies, "Hide Selected", UDim2.new(0.45, -10, 0, 26), UDim2.new(0.55, 2, 0, 60)); hide.Activated:Connect(function() local name = self:current().Catalog.LastDummy; if name == "DefaultGrayR15" then self:status("The default dummy cannot be hidden.", true); return end; self:transact("Hide dummy", function(state) table.insert(state.Catalog.HiddenDummies, name); state.Catalog.LastDummy = "DefaultGrayR15" end); self:selectDummy("DefaultGrayR15") end)
	local restore = button(dummies, "Restore Hidden", UDim2.new(0.45, -10, 0, 26), UDim2.new(0.55, 2, 0, 92)); restore.Activated:Connect(function() self:transact("Restore dummy catalog", function(state) table.clear(state.Catalog.HiddenDummies) end) end)

	self.UI.TextToggle = button(root, "TEXT", UDim2.fromOffset(64, 28), UDim2.new(1, -76, 0, 12)); self.UI.TextToggle.Activated:Connect(function() self.UI.Text.Visible = not self.UI.Text.Visible; self.UI.TextToggle.Text = if self.UI.Text.Visible then "HIDE" else "TEXT" end)
	local whole = button(scroll, "Export All", UDim2.fromOffset(80, 25), UDim2.fromOffset(12, 610)); whole.Activated:Connect(function() self:prepareText(false) end); local selected = button(scroll, "Export Pose", UDim2.fromOffset(82, 25), UDim2.fromOffset(98, 610)); selected.Activated:Connect(function() self:prepareText(true) end); local importText = button(scroll, "Import Text", UDim2.fromOffset(82, 25), UDim2.fromOffset(186, 610)); importText.Activated:Connect(function() self:importText() end)
	self.UI.Text = box(root, "Paste or export animation text here.", UDim2.fromOffset(500, 620), UDim2.new(1, -512, 0, 48)); self.UI.Text.MultiLine = true; self.UI.Text.TextXAlignment = Enum.TextXAlignment.Left; self.UI.Text.TextYAlignment = Enum.TextYAlignment.Top; self.UI.Text.TextWrapped = false; self.UI.Text.ClipsDescendants = true; self.UI.Text.Visible = false; self.UI.Text.ZIndex = 30
	self.UI.Status = label(scroll, "Ready.", UDim2.new(1, -24, 0, 42), UDim2.fromOffset(12, 646)); self.UI.Status.TextWrapped = true; self.UI.Status.TextYAlignment = Enum.TextYAlignment.Top; self.UI.Status.TextColor3 = COLORS.Good

	local view = panel(root, UDim2.fromOffset(510, 76), UDim2.new(0.5, -255, 0, 12)); label(view, "VIEW", UDim2.fromOffset(42, 24), UDim2.fromOffset(10, 7), true)
	local viewControls = {
		{ "Left", 52, 8, function() if self.Editor then self.Editor:FrameDummy("Left") end end },
		{ "Right", 112, 8, function() if self.Editor then self.Editor:FrameDummy("Right") end end },
		{ "Top", 172, 8, function() if self.Editor then self.Editor:FrameDummy("Top") end end },
		{ "Back", 232, 8, function() if self.Editor then self.Editor:FrameDummy("Back") end end },
		{ "Front", 52, 40, function() if self.Editor then self.Editor:FrameDummy("Front") end end },
		{ "Frame", 122, 40, function() if self.Editor then self.Editor:FrameDummy("Frame") end end },
	}
	for _, control in viewControls do local item = button(view, control[1], UDim2.fromOffset(58, 26), UDim2.fromOffset(control[2], control[3])); item.Activated:Connect(control[4]) end
	local front = button(view, "Front View", UDim2.fromOffset(88, 58), UDim2.fromOffset(342, 8)); front.Activated:Connect(function() if self.Editor then self.Editor:FrameDummy("Front") end end)
	local close = button(view, "X", UDim2.fromOffset(54, 58), UDim2.fromOffset(442, 8)); close.BackgroundColor3 = COLORS.Red; close.Activated:Connect(function() self:Close() end)
	label(view, "Studio RMB navigation + wheel zoom", UDim2.fromOffset(190, 18), UDim2.fromOffset(188, 45)).TextSize = 12

	local loading = Instance.new("Frame"); loading.Name = "Loading"; loading.Size = UDim2.fromOffset(420, 150); loading.AnchorPoint = Vector2.new(0.5, 0.5); loading.Position = UDim2.fromScale(0.5, 0.5); loading.BackgroundColor3 = COLORS.Background; loading.ZIndex = 100; loading.Active = true; loading.Parent = root; corner(loading, 8); self.UI.Loading = loading
	self.UI.LoadingTitle = label(loading, "Opening R15 Pose Tuner", UDim2.new(1, -40, 0, 30), UDim2.new(0, 20, 0.5, -60), true); self.UI.LoadingTitle.ZIndex = 101; self.UI.LoadingTitle.TextXAlignment = Enum.TextXAlignment.Center
	self.UI.LoadingStatus = label(loading, "Loading modules...", UDim2.new(1, -40, 0, 42), UDim2.new(0, 20, 0.5, -24)); self.UI.LoadingStatus.ZIndex = 101; self.UI.LoadingStatus.TextXAlignment = Enum.TextXAlignment.Center; self.UI.LoadingStatus.TextWrapped = true
	self.UI.Retry = button(loading, "Retry", UDim2.fromOffset(90, 28), UDim2.new(0.5, -45, 0.5, 28)); self.UI.Retry.ZIndex = 101; self.UI.Retry.Visible = false; self.UI.Retry.Activated:Connect(function() task.spawn(function() self:initializeEditor() end) end)
end

function Controller:loading(phase: string)
	self.UI.Loading.Visible = true; self.UI.Retry.Visible = false; self.UI.LoadingStatus.Text = phase; task.wait()
end

function Controller:initializeEditor(openSerial: number?)
	if openSerial and (openSerial ~= self.OpenSerial or not self.Open) then return end
	if RunService:IsRunning() then self.UI.LoadingStatus.Text = "Stop the playtest to use the Edit-mode pose tuner."; self.UI.Retry.Visible = true; return end
	local ok, failure = xpcall(function()
		self:loading("Loading persistent settings...")
		if openSerial and (openSerial ~= self.OpenSerial or not self.Open) then return end
		local catalog, warning = self.Persistence:Load()
		self:loading("Validating dummy catalog...")
		local default, reason = RigCatalog.ensureDefault(); if not default then error(reason or "Default R15 could not be created.") end
		if not self.History then
			local document = if catalog.Draft then Document.copy(catalog.Draft) else Document.new()
			-- Older tuner drafts defaulted to Step, which made limbs jump only at key times.
			-- Migrate the active recovery draft to smooth playback; users can still select Step explicitly afterward.
			if document.Interpolation == "Step" then document.Interpolation = "Smooth" end
			local initial = { Document = document, WorkingPose = Document.evaluate(document, Document.earliestTime(document), Codec.neutralPose()), Snapping = { Enabled = true, Move = 0.02, Rotate = 2, Timeline = true }, Onion = true, Catalog = catalog }
			self.History = History.new(copyState, initial)
		else self:current().Catalog = catalog end
		self:loading("Creating temporary R15 preview...")
		if openSerial and (openSerial ~= self.OpenSerial or not self.Open) then return end
		if self.Editor then self.Editor:Destroy() end
		self.Editor = WorkspaceEditor.new(self.Plugin, {
			OnSelectionChanged = function(name)
				local trackChanged = self.SelectedTimelineTrack ~= name
				self.SelectionActive = true; self.SelectedJoint = name; self.SelectedTimelineTrack = name; self:refreshFields()
				if trackChanged then self:refreshTimeline() end
			end,
			OnSelectionCleared = function()
				self.SelectionActive = false; self.SelectedTimelineTrack = "Master"; self:refreshFields(); self:refreshTimeline()
			end,
			OnEditBegin = function() self.DragBefore = copyState(self:current()) end,
			OnPoseChanged = function(pose) self:current().WorkingPose = Document.copyPose(pose); self:refreshFields() end,
			OnEditEnd = function()
				if not self.DragBefore then return end; local before, after = self.DragBefore, copyState(self:current()); self.DragBefore = nil
				if after.Document.AutoKey then
					local groundLock = Document.evaluateGroundLock(before.Document, self.Playhead, before.Catalog.GroundLock ~= false)
					local smooth = Document.evaluateSmooth(before.Document, self.Playhead, true)
					local keyedId: string? = nil
					for _, name in JOINTS do
						if before.WorkingPose[name] and after.WorkingPose[name] and not Codec.componentsEqual(before.WorkingPose[name], after.WorkingPose[name]) then
							keyedId = Document.keyJoint(after.Document, self.Playhead, name, after.WorkingPose[name], groundLock, smooth).Id
						end
					end
					self.SelectedTimelineTrack = self.SelectedJoint
					if keyedId then self.SelectedKeyId = keyedId; table.clear(self.SelectedKeys); self.SelectedKeys[keyedId] = true end
				end
				self.History.Present = before; self.History:Replace(after, true); self:scheduleSave(); self:refreshAll()
			end,
			OnStatus = function(message, warningFlag) self:status(message, warningFlag) end,
			OnGuide = function(message) self:status(message) end,
			OnSceneRebuilt = function() task.defer(function() if self.Open and self.Editor then self:updateOnion() end end) end,
		})
		local selectedName = self:current().Catalog.LastDummy
		local source = self:findDummy(selectedName)
		if selectedName == "DefaultGrayR15" then source = RigCatalog.findGameDummy() or source end
		source = source or default
		self.Editor:Build(source, self:current().WorkingPose)
		self:applyEditorPose(self:current().WorkingPose)
		self:setMirrorTime(self.Playhead)
		self:setEditorMode("Move")
		self:loading("Preparing timeline and catalogs...")
		self:refreshAll(); self:updateOnion(); self.UI.Loading.Visible = false; self.Initialized = true
		self:status(if warning then warning else "Ready. No player character or Play session is used.", warning ~= nil)
	end, debug.traceback)
	if not ok then
		warn("R15 Pose Tuner initialization failed: " .. tostring(failure))
		self.LoadFailed = true; self.UI.Loading.Visible = true; self.UI.LoadingStatus.Text = "POSE TUNER FAILED\n" .. tostring(failure); self.UI.LoadingStatus.TextColor3 = COLORS.Warn; self.UI.Retry.Visible = true
	end
end

function Controller:onShortcut(input: InputObject, processed: boolean): boolean
	if processed or not self.Open or UserInputService:GetFocusedTextBox() then return false end
	if not self.History then return false end
	local ctrl = UserInputService:IsKeyDown(Enum.KeyCode.LeftControl) or UserInputService:IsKeyDown(Enum.KeyCode.RightControl)
	local shift = UserInputService:IsKeyDown(Enum.KeyCode.LeftShift) or UserInputService:IsKeyDown(Enum.KeyCode.RightShift)
	if ctrl and input.KeyCode == Enum.KeyCode.Z then if shift then self:redo() else self:undo() end; return true
	elseif ctrl and input.KeyCode == Enum.KeyCode.Y then self:redo(); return true
	elseif input.KeyCode == Enum.KeyCode.E and self.Editor then self:setEditorMode("Move"); return true
	elseif input.KeyCode == Enum.KeyCode.R and self.Editor then self:setEditorMode("Rotate"); return true
	elseif ctrl and input.KeyCode == Enum.KeyCode.C then self:copySelected(); return true
	elseif ctrl and input.KeyCode == Enum.KeyCode.V then self:pasteCopied(); return true
	elseif ctrl and input.KeyCode == Enum.KeyCode.D then self:copySelected(); self:pasteCopied(1); return true
	elseif shift and input.KeyCode == Enum.KeyCode.Left then self:nudgeSelected(-1); return true
	elseif shift and input.KeyCode == Enum.KeyCode.Right then self:nudgeSelected(1); return true
	elseif input.KeyCode == Enum.KeyCode.Space then
		if self.Playing then self:pausePlayback() else self:startPlayback(1, 1) end
		return true
	elseif input.KeyCode == Enum.KeyCode.Delete or input.KeyCode == Enum.KeyCode.Backspace then self:deleteSelectedKeys(); return true
	end
	return false
end

function Controller:bindShortcuts()
	if self.ShortcutsBound then return end
	ContextActionService:BindActionAtPriority(SHORTCUT_ACTION, function(_, inputState, input)
		if inputState ~= Enum.UserInputState.Begin then return Enum.ContextActionResult.Pass end
		return if self:onShortcut(input, false) then Enum.ContextActionResult.Sink else Enum.ContextActionResult.Pass
	end, false, SHORTCUT_PRIORITY,
		Enum.KeyCode.Z, Enum.KeyCode.Y, Enum.KeyCode.E, Enum.KeyCode.R,
		Enum.KeyCode.C, Enum.KeyCode.V, Enum.KeyCode.D, Enum.KeyCode.Left,
		Enum.KeyCode.Right, Enum.KeyCode.Space, Enum.KeyCode.Delete, Enum.KeyCode.Backspace)
	self.ShortcutsBound = true
end

function Controller:unbindShortcuts()
	if not self.ShortcutsBound then return end
	ContextActionService:UnbindAction(SHORTCUT_ACTION); self.ShortcutsBound = false
end

function Controller:Start()
	local toolbar = self.Toolbar or self.Plugin:CreateToolbar("R15 Pose Tuner")
	local toggle = self.ToolbarButton or toolbar:CreateButton("OpenPoseTuner", "Open the Edit-mode R15 animation editor", "rbxassetid://4458901886", "Pose Tuner")
	toggle.ClickableWhenViewportHidden = true; self.ToolbarButton = toggle
	local oldOverlay = CoreGui:FindFirstChild("R15PoseTunerEditOverlay")
	if oldOverlay then oldOverlay:Destroy() end
	local overlay = Instance.new("ScreenGui")
	overlay.Name = "R15PoseTunerEditOverlay"; overlay.DisplayOrder = 10_000; overlay.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	overlay.IgnoreGuiInset = false; overlay.Enabled = false; overlay.Parent = CoreGui; self.Overlay = overlay; self:buildResponsiveUI(overlay)
	table.insert(self.Connections, toggle.Click:Connect(function() if self.Open then self:Close() else self:OpenEditor() end end))
	table.insert(self.Connections, self.Plugin.Deactivation:Connect(function()
		if self.Open then self:Close() end
	end))
	table.insert(self.Connections, UserInputService.InputChanged:Connect(function(input) self:updateTimelineDrag(input) end))
	table.insert(self.Connections, UserInputService.InputEnded:Connect(function(input) self:endTimelineDrag(input) end))
	table.insert(self.Connections, RunService.RenderStepped:Connect(function(dt)
		if self.Open and RunService:IsRunning() then self:Close(); return end
		if not self.Open or not self.Playing or not self.History then return end
		local document = self:current().Document; local earliest = Document.earliestTime(document)
		local nextTime = self.Playhead + math.min(dt, 0.05) * document.PlaybackSpeed * self.PlaybackMultiplier * self.PlaybackDirection
		if nextTime > document.Duration then
			if document.Loop then nextTime = earliest else nextTime = document.Duration; self.Playing = false end
		elseif nextTime < earliest then
			if document.Loop then nextTime = document.Duration else nextTime = earliest; self.Playing = false end
		end
		self.Playhead = nextTime; self:current().WorkingPose = self:evaluate(nextTime); self:applyEditorPose(self:current().WorkingPose); self:updateTimelinePlayhead(); self:refreshFields()
		self:updateTransportUI()
	end))
end

function Controller:OpenEditor()
	self.OpenSerial += 1; local serial = self.OpenSerial
	self.Plugin:Activate(false)
	self.Open = true; self.Overlay.Enabled = true; self.ToolbarButton:SetActive(true); self:bindShortcuts(); self:applyResponsiveLayout()
	self.UI.Loading.Visible = true; self.UI.LoadingStatus.TextColor3 = COLORS.Text; self.UI.LoadingStatus.Text = "Starting Edit-mode editor..."; self.UI.Retry.Visible = false
	task.spawn(function() self:initializeEditor(serial) end)
end

function Controller:Close()
	self.OpenSerial += 1; self.Open = false; self:pausePlayback(); self:unbindShortcuts()
	if self.Editor then self.Editor:Destroy(); self.Editor = nil end
	if self.Overlay then self.Overlay.Enabled = false end; if self.ToolbarButton then self.ToolbarButton:SetActive(false) end
	if self.Plugin:IsActivated() then self.Plugin:Deactivate() end
	if self.History then local state = self:current(); state.Catalog.Draft = Document.copy(state.Document); self.Persistence:Save(state.Catalog) end
end

function Controller:Destroy()
	self:Close(); for _, connection in self.Connections do connection:Disconnect() end; table.clear(self.Connections); if self.Overlay then self.Overlay:Destroy(); self.Overlay = nil end
end

return Controller
