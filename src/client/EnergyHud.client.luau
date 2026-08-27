--!strict

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")

local gui = Instance.new("ScreenGui")
gui.Name = "EnergyHud"
gui.ResetOnSpawn = false
gui.IgnoreGuiInset = true
gui.Parent = playerGui

local panel = Instance.new("Frame")
panel.Name = "Panel"
panel.Size = UDim2.fromOffset(420, 104)
panel.Position = UDim2.new(0.5, -210, 0, 28)
panel.BackgroundColor3 = Color3.fromRGB(12, 18, 32)
panel.BackgroundTransparency = 0.13
panel.Parent = gui
local panelCorner = Instance.new("UICorner")
panelCorner.CornerRadius = UDim.new(0, 14)
panelCorner.Parent = panel
local panelStroke = Instance.new("UIStroke")
panelStroke.Thickness = 2
panelStroke.Color = Color3.fromRGB(79, 205, 255)
panelStroke.Transparency = 0.2
panelStroke.Parent = panel

local title = Instance.new("TextLabel")
title.Size = UDim2.new(1, -32, 0, 28)
title.Position = UDim2.fromOffset(16, 9)
title.BackgroundTransparency = 1
title.TextXAlignment = Enum.TextXAlignment.Left
title.TextColor3 = Color3.fromRGB(220, 244, 255)
title.Font = Enum.Font.GothamBold
title.TextSize = 18
title.Parent = panel

local barBackground = Instance.new("Frame")
barBackground.Size = UDim2.new(1, -32, 0, 24)
barBackground.Position = UDim2.fromOffset(16, 42)
barBackground.BackgroundColor3 = Color3.fromRGB(31, 48, 70)
barBackground.ClipsDescendants = true
barBackground.Parent = panel
local barCorner = Instance.new("UICorner")
barCorner.CornerRadius = UDim.new(1, 0)
barCorner.Parent = barBackground

local barFill = Instance.new("Frame")
barFill.Size = UDim2.fromScale(0, 1)
barFill.BackgroundColor3 = Color3.fromRGB(61, 223, 255)
barFill.Parent = barBackground
local fillCorner = Instance.new("UICorner")
fillCorner.CornerRadius = UDim.new(1, 0)
fillCorner.Parent = barFill

local energyText = Instance.new("TextLabel")
energyText.Size = UDim2.fromScale(1, 1)
energyText.BackgroundTransparency = 1
energyText.TextColor3 = Color3.fromRGB(255, 255, 255)
energyText.Font = Enum.Font.GothamBlack
energyText.TextSize = 16
energyText.ZIndex = 2
energyText.Parent = barBackground

local status = Instance.new("TextLabel")
status.Size = UDim2.new(1, -32, 0, 22)
status.Position = UDim2.fromOffset(16, 73)
status.BackgroundTransparency = 1
status.TextXAlignment = Enum.TextXAlignment.Left
status.TextColor3 = Color3.fromRGB(172, 213, 235)
status.Font = Enum.Font.Gotham
status.TextSize = 14
status.TextTruncate = Enum.TextTruncate.AtEnd
status.Parent = panel

local function getNumberAttribute(name: string, fallback: number): number
	local value = player:GetAttribute(name)
	if typeof(value) == "number" then
		return value
	end
	return fallback
end

local function updateHud()
	local level = getNumberAttribute("PlayerLevel", 1)
	local capacity = math.max(getNumberAttribute("EnergyCapacity", 100), 1)
	local energy = math.clamp(getNumberAttribute("CurrentEnergy", 0), 0, capacity)
	local inGameZone = player:GetAttribute("IsInGameZone") == true
	local message = player:GetAttribute("StatusMessage")

	title.Text = string.format("能量等级 %d  %s", math.floor(level), if inGameZone then "· 跑动充能，静止耗能" else "· 进入蓝色区域")
	energyText.Text = string.format("%d / %d", math.floor(energy), math.floor(capacity))
	status.Text = if typeof(message) == "string" and #message > 0 then message else "跑动可积累能量；静止会持续耗能；收集小兵可获得额外能量。"
	barFill.BackgroundColor3 = if inGameZone then Color3.fromRGB(61, 223, 255) else Color3.fromRGB(103, 145, 169)
	TweenService:Create(barFill, TweenInfo.new(0.12, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
		Size = UDim2.fromScale(energy / capacity, 1),
	}):Play()
end

local CAMERA_STEP_NAME = "EnergyHudBossImpactCamera"
local CAMERA_PULL_DISTANCE = 7.5
local CAMERA_FOV_INCREASE = 7
local CAMERA_PULL_DURATION = 0.28
local CAMERA_HOLD_DURATION = 0.42
local CAMERA_RETURN_DURATION = 0.55
local cameraEffectActive = false
local cameraEffectStartedAt = 0
local cameraBaseFieldOfView = 70

local function smoothStep(value: number): number
	local clamped = math.clamp(value, 0, 1)
	return clamped * clamped * (3 - 2 * clamped)
end

local function getCameraStrength(elapsed: number): number
	if elapsed < CAMERA_PULL_DURATION then
		return smoothStep(elapsed / CAMERA_PULL_DURATION)
	end
	if elapsed < CAMERA_PULL_DURATION + CAMERA_HOLD_DURATION then
		return 1
	end
	return 1 - smoothStep((elapsed - CAMERA_PULL_DURATION - CAMERA_HOLD_DURATION) / CAMERA_RETURN_DURATION)
end

local function stopCameraEffect()
	if not cameraEffectActive then
		return
	end
	cameraEffectActive = false
	RunService:UnbindFromRenderStep(CAMERA_STEP_NAME)
	local camera = workspace.CurrentCamera
	if camera ~= nil then
		camera.FieldOfView = cameraBaseFieldOfView
	end
end

local function playCameraEffect()
	stopCameraEffect()
	local camera = workspace.CurrentCamera
	if camera == nil then
		return
	end
	cameraEffectActive = true
	cameraEffectStartedAt = os.clock()
	cameraBaseFieldOfView = camera.FieldOfView

	RunService:BindToRenderStep(CAMERA_STEP_NAME, Enum.RenderPriority.Camera.Value + 10, function()
		local currentCamera = workspace.CurrentCamera
		if currentCamera == nil then
			stopCameraEffect()
			return
		end

		local elapsed = os.clock() - cameraEffectStartedAt
		local totalDuration = CAMERA_PULL_DURATION + CAMERA_HOLD_DURATION + CAMERA_RETURN_DURATION
		if elapsed >= totalDuration then
			stopCameraEffect()
			return
		end

		local strength = getCameraStrength(elapsed)
		local impactDecay = math.max(0, 1 - elapsed / 0.36)
		local roll = math.rad(0.7) * math.sin(elapsed * 30) * impactDecay
		currentCamera.CFrame = currentCamera.CFrame
			* CFrame.new(0, 0.18 * impactDecay, CAMERA_PULL_DISTANCE * strength)
			* CFrame.Angles(0, 0, roll)
		currentCamera.FieldOfView = cameraBaseFieldOfView + CAMERA_FOV_INCREASE * strength
	end)
end

local initialImpactSequence = player:GetAttribute("BossImpactSequence")
local lastImpactSequence = if typeof(initialImpactSequence) == "number" then initialImpactSequence else 0
player:GetAttributeChangedSignal("BossImpactSequence"):Connect(function()
	local currentSequence = player:GetAttribute("BossImpactSequence")
	if typeof(currentSequence) ~= "number" or currentSequence <= lastImpactSequence then
		return
	end
	lastImpactSequence = currentSequence
	playCameraEffect()
end)

for _, attributeName in { "PlayerLevel", "EnergyCapacity", "CurrentEnergy", "IsInGameZone", "StatusMessage" } do
	player:GetAttributeChangedSignal(attributeName):Connect(updateHud)
end

updateHud()
