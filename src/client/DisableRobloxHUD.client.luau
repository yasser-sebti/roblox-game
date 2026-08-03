--!strict

-- Persistent owner of Roblox's built-in HUD. Keeping this separate from loading
-- and locomotion prevents either lifecycle from accidentally restoring CoreGui.

local Players = game:GetService("Players")
local StarterGui = game:GetService("StarterGui")
local TextChatService = game:GetService("TextChatService")

local player = Players.LocalPlayer
local applying = false

local CORE_GUI_TYPES = {
	Enum.CoreGuiType.Chat,
	Enum.CoreGuiType.PlayerList,
	Enum.CoreGuiType.Backpack,
	Enum.CoreGuiType.Health,
	Enum.CoreGuiType.EmotesMenu,
}

local function disableTextChat()
	local chatWindow = TextChatService:FindFirstChildOfClass("ChatWindowConfiguration")
	if chatWindow then chatWindow.Enabled = false end

	local chatInput = TextChatService:FindFirstChildOfClass("ChatInputBarConfiguration")
	if chatInput then chatInput.Enabled = false end

	local bubbleChat = TextChatService:FindFirstChildOfClass("BubbleChatConfiguration")
	if bubbleChat then bubbleChat.Enabled = false end

end

local function disableRobloxHUD()
	if applying then return end
	applying = true

	pcall(function()
		StarterGui:SetCoreGuiEnabled(Enum.CoreGuiType.All, false)
	end)
	for _, coreGuiType in CORE_GUI_TYPES do
		pcall(function()
			StarterGui:SetCoreGuiEnabled(coreGuiType, false)
		end)
	end
	pcall(function()
		StarterGui:SetCore("TopbarEnabled", false)
	end)
	disableTextChat()

	applying = false
end

-- Core scripts may initialize or restore UI after this LocalScript starts.
-- A lightweight persistent pass is more reliable than restricted CoreGui events.
task.spawn(function()
	while script.Parent do
		disableRobloxHUD()
		task.wait(0.35)
	end
end)

TextChatService.ChildAdded:Connect(function()
	task.defer(disableTextChat)
end)

player.CharacterAdded:Connect(function()
	task.defer(disableRobloxHUD)
	task.delay(1, disableRobloxHUD)
end)

disableRobloxHUD()
print("Roblox HUD, top bar, text chat, and bubble chat disabled.")
