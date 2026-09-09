--!strict

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")
local Shared = ReplicatedStorage:WaitForChild("Shared")
local GameplayConfig = require(Shared:WaitForChild("GameplayConfig"))

local ATTRIBUTE = GameplayConfig.Attributes
local BILLBOARD_SIZE = UDim2.fromScale(3.2, 0.48)
local BILLBOARD_HEAD_OFFSET = Vector3.new(0, 1.25, 0)

local gui = Instance.new("ScreenGui")
gui.Name = "EnergyHud"
gui.ResetOnSpawn = false
gui.IgnoreGuiInset = true
gui.Parent = playerGui

local billboard = Instance.new("BillboardGui")
billboard.Name = "EnergyBillboard"
billboard.Size = BILLBOARD_SIZE
billboard.StudsOffsetWorldSpace = BILLBOARD_HEAD_OFFSET
billboard.AlwaysOnTop = true
billboard.ResetOnSpawn = false
billboard.Enabled = false
billboard.Parent = playerGui

local panel = Instance.new("Frame")
panel.Name = "BarPanel"
panel.Size = UDim2.fromScale(1, 1)
panel.BackgroundColor3 = Color3.fromRGB(12, 18, 32)
panel.BackgroundTransparency = 0.13
panel.Parent = billboard
local panelCorner = Instance.new("UICorner")
panelCorner.CornerRadius = UDim.new(1, 0)
panelCorner.Parent = panel
local panelStroke = Instance.new("UIStroke")
panelStroke.Thickness = 1.5
panelStroke.Color = Color3.fromRGB(79, 205, 255)
panelStroke.Transparency = 0.2
panelStroke.Parent = panel

local barBackground = Instance.new("Frame")
barBackground.Size = UDim2.fromScale(0.92, 0.72)
barBackground.Position = UDim2.fromScale(0.04, 0.14)
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
energyText.TextScaled = true
energyText.ZIndex = 2
energyText.Parent = barBackground
local energyTextSize = Instance.new("UITextSizeConstraint")
energyTextSize.MinTextSize = 8
energyTextSize.MaxTextSize = 16
energyTextSize.Parent = energyText

-- Keep gameplay feedback readable without making the overhead energy bar wider.
local status = Instance.new("TextLabel")
status.Name = "StatusMessage"
status.AnchorPoint = Vector2.new(0.5, 0)
status.Size = UDim2.fromOffset(430, 28)
status.Position = UDim2.new(0.5, 0, 0, 24)
status.BackgroundColor3 = Color3.fromRGB(12, 18, 32)
status.BackgroundTransparency = 0.32
status.TextXAlignment = Enum.TextXAlignment.Center
status.TextColor3 = Color3.fromRGB(172, 213, 235)
status.Font = Enum.Font.GothamMedium
status.TextSize = 14
status.TextTruncate = Enum.TextTruncate.AtEnd
status.Visible = false
status.Parent = gui
local statusCorner = Instance.new("UICorner")
statusCorner.CornerRadius = UDim.new(1, 0)
statusCorner.Parent = status

local function attachToCharacter(character: Model)
	local head = character:FindFirstChild("Head")
	if head == nil then
		head = character:WaitForChild("Head", 5)
	end
	if player.Character ~= character then
		return
	end
	if head ~= nil and head:IsA("BasePart") then
		billboard.Adornee = head
		billboard.Enabled = true
	else
		billboard.Adornee = nil
		billboard.Enabled = false
		warn("[EnergyHud] character is missing a Head BasePart", character)
	end
end

player.CharacterAdded:Connect(function(character)
	task.defer(attachToCharacter, character)
end)
player.CharacterRemoving:Connect(function(character)
	local adornee = billboard.Adornee
	if adornee ~= nil and adornee:IsDescendantOf(character) then
		billboard.Adornee = nil
		billboard.Enabled = false
	end
end)
if player.Character ~= nil then
	task.defer(attachToCharacter, player.Character)
end

local function getNumberAttribute(name: string, fallback: number): number
	local value = player:GetAttribute(name)
	if typeof(value) == "number" then
		return value
	end
	return fallback
end

local function updateHud()
	local capacity = math.max(getNumberAttribute(ATTRIBUTE.EnergyCapacity, 100), 1)
	local energy = math.clamp(getNumberAttribute(ATTRIBUTE.CurrentEnergy, 0), 0, capacity)
	local inGameZone = player:GetAttribute(ATTRIBUTE.IsInGameZone) == true
	local message = player:GetAttribute(ATTRIBUTE.StatusMessage)

	energyText.Text = string.format("%d / %d", math.floor(energy), math.floor(capacity))
	status.Text = if typeof(message) == "string" then message else ""
	status.Visible = #status.Text > 0
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

local initialImpactSequence = player:GetAttribute(ATTRIBUTE.BossImpactSequence)
local lastImpactSequence = if typeof(initialImpactSequence) == "number" then initialImpactSequence else 0
player:GetAttributeChangedSignal(ATTRIBUTE.BossImpactSequence):Connect(function()
	local currentSequence = player:GetAttribute(ATTRIBUTE.BossImpactSequence)
	if typeof(currentSequence) ~= "number" or currentSequence <= lastImpactSequence then
		return
	end
	lastImpactSequence = currentSequence
	playCameraEffect()
end)

for _, attributeName in {
	ATTRIBUTE.EnergyCapacity,
	ATTRIBUTE.CurrentEnergy,
	ATTRIBUTE.IsInGameZone,
	ATTRIBUTE.StatusMessage,
} do
	player:GetAttributeChangedSignal(attributeName):Connect(updateHud)
end

updateHud()
