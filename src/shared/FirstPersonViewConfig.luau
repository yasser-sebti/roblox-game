--!strict

-- Shared by the runtime locomotion controller and the Edit-mode pose tuner.
-- Keep the static first-person preview and the shipped game camera aligned.
return table.freeze({
	CameraUpOffset = -0.10,
	CameraForwardOffset = 1.70,
	MouseSensitivity = 0.90,
	MouseSmoothingFrequency = 28,
	MouseRadiansPerPixel = 0.0025,
	MaxPitchDegrees = 85,
})
