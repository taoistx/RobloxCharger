--!strict

-- Displays the authoritative Coins attribute and presents server-confirmed
-- awards. Purchases and save loads do not trigger popups.

local Debris = game:GetService("Debris")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local SoundService = game:GetService("SoundService")
local TweenService = game:GetService("TweenService")

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")
local Shared = ReplicatedStorage:WaitForChild("Shared")
local GameplayConfig = require(Shared:WaitForChild("GameplayConfig"))
local ShopConfig = require(Shared:WaitForChild("ShopConfig"))
local feedbackEvent = ReplicatedStorage:WaitForChild(GameplayConfig.InstanceNames.CoinAwardFeedback)

if not feedbackEvent:IsA("RemoteEvent") then
	warn("[CoinPresentation] CoinAwardFeedback must be a RemoteEvent")
	return
end

local ATTRIBUTE = GameplayConfig.Attributes
local PRESENTATION = ShopConfig.CoinPresentation
local FEEDBACK = PRESENTATION.Feedback
local RETURN_TO_SPAWN_FEEDBACK = PRESENTATION.ReturnToSpawnFeedback
local popupRandom = Random.new()

local gui = Instance.new("ScreenGui")
gui.Name = "CoinHud"
gui.ResetOnSpawn = false
gui.IgnoreGuiInset = true
gui.Parent = playerGui

local panel = Instance.new("Frame")
panel.Name = "CoinPanel"
panel.AnchorPoint = Vector2.new(0, 1)
panel.Size = UDim2.fromOffset(230, 72)
panel.Position = UDim2.new(0, 24, 1, -24)
panel.BackgroundTransparency = 1
panel.Parent = gui

local icon = Instance.new("ImageLabel")
icon.Name = "CoinIcon"
icon.AnchorPoint = Vector2.new(0, 0.5)
icon.Size = UDim2.fromOffset(60, 60)
icon.Position = UDim2.new(0, 0, 0.5, 0)
icon.BackgroundTransparency = 1
icon.Image = PRESENTATION.IconImage
icon.ScaleType = Enum.ScaleType.Fit
icon.Parent = panel

local coinsText = Instance.new("TextLabel")
coinsText.Name = "Coins"
coinsText.Size = UDim2.new(1, -72, 1, 0)
coinsText.Position = UDim2.fromOffset(68, 0)
coinsText.BackgroundTransparency = 1
coinsText.TextXAlignment = Enum.TextXAlignment.Left
coinsText.TextColor3 = Color3.fromRGB(255, 211, 46)
coinsText.TextStrokeColor3 = Color3.fromRGB(112, 60, 0)
coinsText.TextStrokeTransparency = 0.12
coinsText.Font = Enum.Font.GothamBlack
coinsText.TextScaled = true
coinsText.Parent = panel

local textSizeConstraint = Instance.new("UITextSizeConstraint")
textSizeConstraint.MinTextSize = 18
textSizeConstraint.MaxTextSize = 38
textSizeConstraint.Parent = coinsText

local function updateCoins()
	local value = player:GetAttribute(ATTRIBUTE.Coins)
	local coins = if typeof(value) == "number" then math.max(0, math.floor(value)) else 0
	coinsText.Text = tostring(coins)
end

local function playCoinSound()
	local soundId = FEEDBACK.SoundId
	if typeof(soundId) ~= "string" or soundId == "" then
		return
	end
	local sound = Instance.new("Sound")
	sound.Name = "CoinAwardSound"
	sound.SoundId = soundId
	sound.Volume = math.max(0, FEEDBACK.SoundVolume)
	sound.Parent = SoundService
	sound:Play()
	Debris:AddItem(sound, 5)
end

local function showCoinPopup(amount: number, showAtCharacterHead: boolean)
	local popupDurationSeconds = if showAtCharacterHead
		then RETURN_TO_SPAWN_FEEDBACK.PopupDurationSeconds
		else FEEDBACK.PopupDurationSeconds
	local popupRiseStuds = if showAtCharacterHead
		then RETURN_TO_SPAWN_FEEDBACK.PopupRiseStuds
		else FEEDBACK.PopupRiseStuds
	local character = player.Character
	local rootPart = if character ~= nil then character:FindFirstChild("HumanoidRootPart") else nil
	if rootPart == nil or not rootPart:IsA("BasePart") then
		return
	end

	local humanoid = if character ~= nil then character:FindFirstChildOfClass("Humanoid") else nil
	local hipHeight = if humanoid ~= nil and humanoid:IsA("Humanoid") then humanoid.HipHeight else 2
	local feetOffset = -(rootPart.Size.Y * 0.5 + hipHeight)
	local head = if character ~= nil then character:FindFirstChild("Head") else nil
	local headPart = if head ~= nil and head:IsA("BasePart") then head else nil
	local adornee = if showAtCharacterHead and headPart ~= nil then headPart else rootPart
	local verticalOffset = feetOffset
	if showAtCharacterHead then
		verticalOffset = if headPart ~= nil then headPart.Size.Y * 0.5 + 0.75 else rootPart.Size.Y + hipHeight
	end
	local horizontalDirection = if popupRandom:NextNumber() < 0.5 then -1 else 1
	local minimumDrift = if showAtCharacterHead then RETURN_TO_SPAWN_FEEDBACK.HorizontalDriftMin else 0.45
	local maximumDrift = if showAtCharacterHead then RETURN_TO_SPAWN_FEEDBACK.HorizontalDriftMax else 1.15
	local horizontalDrift = horizontalDirection * popupRandom:NextNumber(minimumDrift, maximumDrift)
	local riseDistance = popupRiseStuds * popupRandom:NextNumber(0.85, 1.25)

	local popup = Instance.new("BillboardGui")
	popup.Name = "CoinPopup"
	popup.Adornee = adornee
	popup.AlwaysOnTop = true
	popup.Size = UDim2.fromOffset(150, 48)
	popup.StudsOffsetWorldSpace = Vector3.new(0, verticalOffset, 0)
	popup.Parent = playerGui

	local popupIcon = Instance.new("ImageLabel")
	popupIcon.Name = "CoinIcon"
	popupIcon.AnchorPoint = Vector2.new(0, 0.5)
	popupIcon.Size = UDim2.fromOffset(42, 42)
	popupIcon.Position = UDim2.new(0, 4, 0.5, 0)
	popupIcon.BackgroundTransparency = 1
	popupIcon.Image = PRESENTATION.IconImage
	popupIcon.ScaleType = Enum.ScaleType.Fit
	popupIcon.Parent = popup

	local label = Instance.new("TextLabel")
	label.Name = "Amount"
	label.Size = UDim2.new(1, -48, 1, 0)
	label.Position = UDim2.fromOffset(48, 0)
	label.BackgroundTransparency = 1
	label.Text = "+" .. tostring(math.floor(amount))
	label.TextXAlignment = Enum.TextXAlignment.Left
	label.TextColor3 = Color3.fromRGB(255, 222, 93)
	label.TextStrokeColor3 = Color3.fromRGB(65, 43, 9)
	label.TextStrokeTransparency = 0.15
	label.Font = Enum.Font.GothamBlack
	label.TextScaled = true
	label.Parent = popup

	local popupTween = TweenService:Create(popup, TweenInfo.new(popupDurationSeconds, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
		StudsOffsetWorldSpace = popup.StudsOffsetWorldSpace + Vector3.new(horizontalDrift, riseDistance, 0),
	})
	local labelTween = TweenService:Create(label, TweenInfo.new(popupDurationSeconds, Enum.EasingStyle.Quad, Enum.EasingDirection.In), {
		TextTransparency = 1,
		TextStrokeTransparency = 1,
	})
	local iconTween = TweenService:Create(popupIcon, TweenInfo.new(popupDurationSeconds, Enum.EasingStyle.Quad, Enum.EasingDirection.In), {
		ImageTransparency = 1,
	})
	popupTween:Play()
	labelTween:Play()
	iconTween:Play()
	Debris:AddItem(popup, popupDurationSeconds + 0.1)
end

feedbackEvent.OnClientEvent:Connect(function(coinAmount: unknown, showAtCharacterHead: unknown)
	if typeof(coinAmount) ~= "number" or coinAmount <= 0 then
		return
	end
	showCoinPopup(coinAmount, showAtCharacterHead == true)
	playCoinSound()
end)

player:GetAttributeChangedSignal(ATTRIBUTE.Coins):Connect(updateCoins)
updateCoins()
