--!strict

-- Owns treadmill-only client presentation: the native Game Pass purchase
-- prompt and a forced run animation while the server reports that the local
-- character is on a treadmill. Coins and access remain server-authoritative.

local MarketplaceService = game:GetService("MarketplaceService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local player = Players.LocalPlayer
local Shared = ReplicatedStorage:WaitForChild("Shared")
local GameplayConfig = require(Shared:WaitForChild("GameplayConfig"))

local ATTRIBUTE = GameplayConfig.Attributes
local character: Model? = player.Character
local runTrack: AnimationTrack? = nil
local runAnimation: Animation? = nil
local humanoidDiedConnection: RBXScriptConnection? = nil

local function stopRunAnimation()
	local track = runTrack
	runTrack = nil
	if track ~= nil then
		track:Stop(0.15)
		track:Destroy()
	end
	local animation = runAnimation
	runAnimation = nil
	if animation ~= nil then
		animation:Destroy()
	end
end

local function getRunAnimationId(currentCharacter: Model, humanoid: Humanoid): string
	local animateScript = currentCharacter:FindFirstChild("Animate")
	local runContainer = if animateScript ~= nil then animateScript:FindFirstChild("run") else nil
	local configuredAnimation = if runContainer ~= nil
		then runContainer:FindFirstChildWhichIsA("Animation")
		else nil
	if configuredAnimation ~= nil and configuredAnimation.AnimationId ~= "" then
		return configuredAnimation.AnimationId
	end
	return if humanoid.RigType == Enum.HumanoidRigType.R6
		then "rbxassetid://180426354"
		else "rbxassetid://507767714"
end

local function startRunAnimation()
	if runTrack ~= nil then
		if not runTrack.IsPlaying then
			runTrack:Play(0.15, 1, 1)
		end
		return
	end

	local currentCharacter = character
	if currentCharacter == nil then
		return
	end
	local humanoid = currentCharacter:FindFirstChildOfClass("Humanoid")
	if humanoid == nil or humanoid.Health <= 0 then
		return
	end
	local animator = humanoid:FindFirstChildOfClass("Animator")
	if animator == nil then
		return
	end

	local animation = Instance.new("Animation")
	animation.Name = "TreadmillRunAnimation"
	animation.AnimationId = getRunAnimationId(currentCharacter, humanoid)
	local success, trackOrError = pcall(function()
		return animator:LoadAnimation(animation)
	end)
	if not success then
		animation:Destroy()
		warn("[TreadmillController] failed to load run animation: " .. tostring(trackOrError))
		return
	end

	local track = trackOrError :: AnimationTrack
	track.Name = "TreadmillRunAnimationTrack"
	track.Priority = Enum.AnimationPriority.Movement
	track.Looped = true
	runAnimation = animation
	runTrack = track
	track:Play(0.15, 1, 1)
end

local function refreshRunAnimation()
	local multiplierValue = player:GetAttribute(ATTRIBUTE.ActiveTreadmillMultiplier)
	local isOnTreadmill = typeof(multiplierValue) == "number" and multiplierValue > 0
	if isOnTreadmill then
		startRunAnimation()
	else
		stopRunAnimation()
	end
end

local function bindCharacter(newCharacter: Model)
	character = newCharacter
	stopRunAnimation()
	if humanoidDiedConnection ~= nil then
		humanoidDiedConnection:Disconnect()
		humanoidDiedConnection = nil
	end

	local humanoid = newCharacter:FindFirstChildOfClass("Humanoid")
	if humanoid ~= nil then
		humanoidDiedConnection = humanoid.Died:Connect(stopRunAnimation)
	end
	task.defer(refreshRunAnimation)
end

player:GetAttributeChangedSignal(ATTRIBUTE.ActiveTreadmillMultiplier):Connect(refreshRunAnimation)
player.CharacterAdded:Connect(bindCharacter)
player.CharacterRemoving:Connect(function(removingCharacter: Model)
	if character == removingCharacter then
		character = nil
		stopRunAnimation()
		if humanoidDiedConnection ~= nil then
			humanoidDiedConnection:Disconnect()
			humanoidDiedConnection = nil
		end
	end
end)
if character ~= nil then
	bindCharacter(character)
end

local promptRemote = ReplicatedStorage:WaitForChild(GameplayConfig.InstanceNames.TreadmillPromptPurchase)
if not promptRemote:IsA("RemoteEvent") then
	warn("[TreadmillController] TreadmillPromptPurchase is not a RemoteEvent")
	return
end

promptRemote.OnClientEvent:Connect(function(gamePassIdValue: unknown)
	if typeof(gamePassIdValue) ~= "number"
		or gamePassIdValue ~= gamePassIdValue
		or gamePassIdValue <= 0
	then
		warn("[TreadmillController] server sent an invalid Game Pass ID")
		return
	end

	local gamePassId = math.floor(gamePassIdValue)
	local success, err = pcall(function()
		MarketplaceService:PromptGamePassPurchase(player, gamePassId)
	end)
	if not success then
		warn("[TreadmillController] failed to open Game Pass prompt: " .. tostring(err))
	end
end)
