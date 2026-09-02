--!strict

local Debris = game:GetService("Debris")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local SoundService = game:GetService("SoundService")
local TweenService = game:GetService("TweenService")

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")
local Shared = ReplicatedStorage:WaitForChild("Shared")
local GameplayConfig = require(Shared:WaitForChild("GameplayConfig"))
local feedbackEvent = ReplicatedStorage:WaitForChild(GameplayConfig.InstanceNames.ProgressionFeedback)

if not feedbackEvent:IsA("RemoteEvent") then
	warn("[ProgressionPresentation] ProgressionFeedback must be a RemoteEvent")
	return
end

local ATTRIBUTE = GameplayConfig.Attributes
local PROGRESSION = GameplayConfig.Progression
local feedback = PROGRESSION.Feedback
local popupRandom = Random.new()

local gui = Instance.new("ScreenGui")
gui.Name = "ProgressionHud"
gui.ResetOnSpawn = false
gui.IgnoreGuiInset = true
gui.Parent = playerGui

local panel = Instance.new("Frame")
panel.Name = "ExperiencePanel"
panel.AnchorPoint = Vector2.new(0.5, 1)
panel.Size = UDim2.fromOffset(430, 58)
panel.Position = UDim2.new(0.5, 0, 1, -36)
panel.BackgroundColor3 = Color3.fromRGB(12, 18, 32)
panel.BackgroundTransparency = 0.12
panel.Parent = gui
local panelCorner = Instance.new("UICorner")
panelCorner.CornerRadius = UDim.new(0, 14)
panelCorner.Parent = panel
local panelStroke = Instance.new("UIStroke")
panelStroke.Thickness = 2
panelStroke.Color = Color3.fromRGB(255, 201, 82)
panelStroke.Transparency = 0.18
panelStroke.Parent = panel

local title = Instance.new("TextLabel")
title.Size = UDim2.new(1, -28, 0, 22)
title.Position = UDim2.fromOffset(14, 5)
title.BackgroundTransparency = 1
title.TextXAlignment = Enum.TextXAlignment.Left
title.TextColor3 = Color3.fromRGB(255, 232, 166)
title.Font = Enum.Font.GothamBold
title.TextSize = 15
title.Parent = panel

local barBackground = Instance.new("Frame")
barBackground.Size = UDim2.new(1, -28, 0, 19)
barBackground.Position = UDim2.fromOffset(14, 31)
barBackground.BackgroundColor3 = Color3.fromRGB(54, 46, 31)
barBackground.ClipsDescendants = true
barBackground.Parent = panel
local barCorner = Instance.new("UICorner")
barCorner.CornerRadius = UDim.new(1, 0)
barCorner.Parent = barBackground

local barFill = Instance.new("Frame")
barFill.Size = UDim2.fromScale(0, 1)
barFill.BackgroundColor3 = Color3.fromRGB(255, 196, 65)
barFill.Parent = barBackground
local fillCorner = Instance.new("UICorner")
fillCorner.CornerRadius = UDim.new(1, 0)
fillCorner.Parent = barFill

local progressText = Instance.new("TextLabel")
progressText.Size = UDim2.fromScale(1, 1)
progressText.BackgroundTransparency = 1
progressText.TextColor3 = Color3.fromRGB(255, 255, 255)
progressText.Font = Enum.Font.GothamBlack
progressText.TextSize = 13
progressText.ZIndex = 2
progressText.Parent = barBackground

local function getNumberAttribute(name: string, fallback: number): number
	local value = player:GetAttribute(name)
	return if typeof(value) == "number" then value else fallback
end

local function updateHud()
	local level = math.floor(getNumberAttribute(ATTRIBUTE.PlayerLevel, PROGRESSION.StartingLevel))
	local experience = math.max(0, math.floor(getNumberAttribute(ATTRIBUTE.CurrentExperience, 0)))
	local required = math.max(0, math.floor(getNumberAttribute(ATTRIBUTE.ExperienceToNextLevel, 0)))
	if level >= GameplayConfig.Limits.MaxPlayerLevel then
		title.Text = string.format("等级 %d · 已满级", level)
		progressText.Text = "MAX"
		barFill.Size = UDim2.fromScale(1, 1)
		return
	end

	title.Text = string.format("等级 %d · 跑动获得经验", level)
	progressText.Text = string.format("%d / %d XP", experience, required)
	local progress = if required > 0 then math.clamp(experience / required, 0, 1) else 0
	TweenService:Create(barFill, TweenInfo.new(0.12, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
		Size = UDim2.fromScale(progress, 1),
	}):Play()
end

local function playExperienceSound()
	local soundId = feedback.ExperienceSoundId
	if typeof(soundId) ~= "string" or soundId == "" then
		return
	end
	local sound = Instance.new("Sound")
	sound.SoundId = soundId
	sound.Volume = math.max(0, feedback.SoundVolume)
	sound.Parent = SoundService
	sound:Play()
	Debris:AddItem(sound, 5)
end

local function showExperiencePopup(amount: number)
	local character = player.Character
	local rootPart = if character ~= nil then character:FindFirstChild("HumanoidRootPart") else nil
	if rootPart == nil or not rootPart:IsA("BasePart") then
		return
	end

	local humanoid = if character ~= nil then character:FindFirstChildOfClass("Humanoid") else nil
	local hipHeight = if humanoid ~= nil and humanoid:IsA("Humanoid") then humanoid.HipHeight else 2
	local feetOffset = -(rootPart.Size.Y * 0.5 + hipHeight)
	local horizontalDirection = if popupRandom:NextNumber() < 0.5 then -1 else 1
	local horizontalDrift = horizontalDirection * popupRandom:NextNumber(0.45, 1.15)
	local riseDistance = feedback.PopupRiseStuds * popupRandom:NextNumber(0.85, 1.25)

	local popup = Instance.new("BillboardGui")
	popup.Name = "ExperiencePopup"
	popup.Adornee = rootPart
	popup.AlwaysOnTop = true
	popup.Size = UDim2.fromOffset(130, 48)
	popup.StudsOffsetWorldSpace = Vector3.new(0, feetOffset, 0)
	popup.Parent = playerGui

	local label = Instance.new("TextLabel")
	label.Size = UDim2.fromScale(1, 1)
	label.BackgroundTransparency = 1
	label.Text = "+" .. tostring(math.floor(amount)) .. " XP"
	label.TextColor3 = Color3.fromRGB(255, 222, 93)
	label.TextStrokeColor3 = Color3.fromRGB(65, 43, 9)
	label.TextStrokeTransparency = 0.15
	label.Font = Enum.Font.GothamBlack
	label.TextScaled = true
	label.Parent = popup

	local popupTween = TweenService:Create(popup, TweenInfo.new(feedback.PopupDurationSeconds, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
		StudsOffsetWorldSpace = popup.StudsOffsetWorldSpace + Vector3.new(horizontalDrift, riseDistance, 0),
	})
	local textTween = TweenService:Create(label, TweenInfo.new(feedback.PopupDurationSeconds, Enum.EasingStyle.Quad, Enum.EasingDirection.In), {
		TextTransparency = 1,
		TextStrokeTransparency = 1,
	})
	popupTween:Play()
	textTween:Play()
	Debris:AddItem(popup, feedback.PopupDurationSeconds + 0.1)
end

feedbackEvent.OnClientEvent:Connect(function(experienceAmount: unknown)
	if typeof(experienceAmount) ~= "number" or experienceAmount <= 0 then
		return
	end
	showExperiencePopup(experienceAmount)
	playExperienceSound()
end)

for _, attributeName in { ATTRIBUTE.PlayerLevel, ATTRIBUTE.CurrentExperience, ATTRIBUTE.ExperienceToNextLevel } do
	player:GetAttributeChangedSignal(attributeName):Connect(updateHud)
end

updateHud()
