--!strict

assert(plugin, "R15 Pose Tuner must run as a Studio plugin.")

if game:GetService("RunService"):IsRunning() then
	return
end

local toolbar = plugin:CreateToolbar("R15 Pose Tuner")
local toolbarButton = toolbar:CreateButton(
	"OpenPoseTuner",
	"Open the Edit-mode R15 animation editor",
	"rbxassetid://4458901886",
	"Pose Tuner"
)
toolbarButton.ClickableWhenViewportHidden = true

local controller = nil
local loaded, result = pcall(require, script.Parent.Modules.PluginController)
if loaded then
	controller = result.new(plugin, toolbar, toolbarButton)
	controller:Start()
else
	warn("R15 Pose Tuner controller failed to load: " .. tostring(result))
	toolbarButton.Click:Connect(function()
		warn("R15 Pose Tuner is unavailable because its controller failed to load: " .. tostring(result))
	end)
end

plugin.Unloading:Connect(function()
	if controller then controller:Destroy() end
end)
