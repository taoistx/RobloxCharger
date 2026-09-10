--!strict

local Debris = game:GetService("Debris")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local SoundService = game:GetService("SoundService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local GameplayConfig = require(Shared:WaitForChild("GameplayConfig"))
local feedbackEvent = ReplicatedStorage:WaitForChild(GameplayConfig.InstanceNames.MinionPickupFeedback)

if not feedbackEvent:IsA("RemoteEvent") then
	warn("[MinionPickupPresentation] MinionPickupFeedback must be a RemoteEvent")
	return
end

local feedback = GameplayConfig.MinionPickup.Feedback

local function playPickupSound()
	local soundId = feedback.SoundId
	if typeof(soundId) ~= "string" or soundId == "" then
		return
	end

	local sound = Instance.new("Sound")
	sound.Name = "MinionPickupSound"
	sound.SoundId = soundId
	sound.Volume = math.max(0, feedback.SoundVolume)
	sound.Parent = SoundService
	sound:Play()
	Debris:AddItem(sound, 5)
end

feedbackEvent.OnClientEvent:Connect(playPickupSound)
