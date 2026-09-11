--!strict

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local SoundService = game:GetService("SoundService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local GameplayConfig = require(Shared:WaitForChild("GameplayConfig"))

local player = Players.LocalPlayer
local celebrationRemote = ReplicatedStorage:WaitForChild(GameplayConfig.InstanceNames.FinalCelebration)
if not celebrationRemote:IsA("RemoteEvent") then
	warn("[FinalCelebrationPresentation] FinalCelebration must be a RemoteEvent")
	return
end

local celebration = GameplayConfig.Final.Celebration
local sound = Instance.new("Sound")
sound.Name = "FinalCelebrationMusic"
sound.SoundId = celebration.SoundId
sound.Volume = celebration.SoundVolume
sound.Parent = SoundService

local activeTrack: AnimationTrack? = nil

local function playCelebrationAnimation(character: Model)
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if humanoid == nil or humanoid.Health <= 0 then
		return
	end
	local animator = humanoid:FindFirstChildOfClass("Animator")
	if animator == nil then
		animator = Instance.new("Animator")
		animator.Parent = humanoid
	end

	if activeTrack ~= nil then
		activeTrack:Stop(0.1)
		activeTrack:Destroy()
		activeTrack = nil
	end

	local animation = Instance.new("Animation")
	animation.AnimationId = if humanoid.RigType == Enum.HumanoidRigType.R6
		then celebration.R6AnimationId
		else celebration.R15AnimationId

	local success, trackOrError = pcall(function()
		return animator:LoadAnimation(animation)
	end)
	animation:Destroy()
	if not success then
		warn("[FinalCelebrationPresentation] unable to load celebration animation", trackOrError)
		return
	end

	local track = trackOrError :: AnimationTrack
	activeTrack = track
	track.Priority = Enum.AnimationPriority.Action
	track.Looped = false
	track.Stopped:Once(function()
		if activeTrack == track then
			activeTrack = nil
		end
		track:Destroy()
	end)
	track:Play(0.15)
end

celebrationRemote.OnClientEvent:Connect(function()
	sound:Stop()
	sound.TimePosition = 0
	sound:Play()

	local character = player.Character
	if character ~= nil then
		playCelebrationAnimation(character)
	end
end)
