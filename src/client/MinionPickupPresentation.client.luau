--!strict

-- Client-only prediction for owned minion pickups. It never asks the server to
-- collect a pickup or grants a reward: MinionService remains authoritative.

local CollectionService = game:GetService("CollectionService")
local Debris = game:GetService("Debris")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local SoundService = game:GetService("SoundService")

local player = Players.LocalPlayer
local Shared = ReplicatedStorage:WaitForChild("Shared")
local GameplayConfig = require(Shared:WaitForChild("GameplayConfig"))
local feedbackEvent = ReplicatedStorage:WaitForChild(GameplayConfig.InstanceNames.MinionPickupFeedback)

if not feedbackEvent:IsA("RemoteEvent") then
	warn("[MinionPickupPresentation] MinionPickupFeedback must be a RemoteEvent")
	return
end

type Binding = {
	instance: Instance,
	pickupId: string,
	connections: { RBXScriptConnection },
	partTransparency: { [BasePart]: number },
	hidden: boolean,
	confirmed: boolean,
	predictionToken: number,
}

local TAG = GameplayConfig.Tags.MinionPicker
local ATTRIBUTE = GameplayConfig.Attributes
local feedback = GameplayConfig.MinionPickup.Feedback
local PREDICTION_TIMEOUT_SECONDS = 1.5

local bindings: { [Instance]: Binding } = {}
local bindingsByPickupId: { [string]: Binding } = {}
local confirmedPickupIds: { [string]: boolean } = {}
local pendingBindAttempts: { [Instance]: number } = {}

local function getParts(instance: Instance): { BasePart }
	if instance:IsA("BasePart") then
		return { instance }
	end
	local parts: { BasePart } = {}
	for _, descendant in instance:GetDescendants() do
		if descendant:IsA("BasePart") then
			table.insert(parts, descendant)
		end
	end
	return parts
end

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

local function setHidden(binding: Binding, hidden: boolean)
	if binding.hidden == hidden then
		return
	end
	binding.hidden = hidden
	for part, originalTransparency in binding.partTransparency do
		if part.Parent ~= nil then
			part.LocalTransparencyModifier = if hidden then 1 else originalTransparency
		end
	end
end

local function hidePredicted(binding: Binding)
	if binding.confirmed then
		return
	end
	setHidden(binding, true)
	binding.predictionToken += 1
	local token = binding.predictionToken
	task.delay(PREDICTION_TIMEOUT_SECONDS, function()
		if bindings[binding.instance] ~= binding or binding.confirmed or binding.predictionToken ~= token then
			return
		end
		if binding.instance.Parent ~= nil and binding.instance:GetAttribute(ATTRIBUTE.Collected) ~= true then
			setHidden(binding, false)
		end
	end)
end

local function unbind(instance: Instance)
	local binding = bindings[instance]
	pendingBindAttempts[instance] = nil
	if binding == nil then
		return
	end
	for _, connection in binding.connections do
		connection:Disconnect()
	end
	if not binding.hidden then
		setHidden(binding, false)
	end
	bindings[instance] = nil
	if bindingsByPickupId[binding.pickupId] == binding then
		bindingsByPickupId[binding.pickupId] = nil
	end
end

local function isOwnCharacterPart(part: BasePart): boolean
	local character = player.Character
	return character ~= nil and part:IsDescendantOf(character)
end

local function bind(instance: Instance)
	if bindings[instance] ~= nil then
		return
	end
	local ownerUserId = instance:GetAttribute(ATTRIBUTE.SpawnOwnerUserId)
	local pickupId = instance:GetAttribute(ATTRIBUTE.PickupId)
	-- Tags can replicate a fraction before their runtime attributes under
	-- StreamingEnabled. Retry a bounded number of times rather than leaving an
	-- otherwise valid local picker without its immediate feedback binding.
	if ownerUserId == nil or pickupId == nil then
		local attempts = pendingBindAttempts[instance] or 0
		if attempts < 10 then
			pendingBindAttempts[instance] = attempts + 1
			task.delay(0.1, function()
				if instance.Parent ~= nil and CollectionService:HasTag(instance, TAG) then
					bind(instance)
				end
			end)
		end
		return
	end
	if ownerUserId ~= player.UserId then
		return
	end
	if typeof(pickupId) ~= "string" or pickupId == "" then
		return
	end
	pendingBindAttempts[instance] = nil
	local binding: Binding = {
		instance = instance,
		pickupId = pickupId,
		connections = {},
		partTransparency = {},
		hidden = false,
		confirmed = confirmedPickupIds[pickupId] == true,
		predictionToken = 0,
	}
	for _, part in getParts(instance) do
		binding.partTransparency[part] = part.LocalTransparencyModifier
		table.insert(binding.connections, part.Touched:Connect(function(otherPart)
			if isOwnCharacterPart(otherPart) then
				hidePredicted(binding)
			end
		end))
	end
	bindings[instance] = binding
	bindingsByPickupId[pickupId] = binding
	if binding.confirmed then
		setHidden(binding, true)
	end
end

feedbackEvent.OnClientEvent:Connect(function(pickupId: unknown)
	if typeof(pickupId) == "string" and pickupId ~= "" then
		confirmedPickupIds[pickupId] = true
		local binding = bindingsByPickupId[pickupId]
		if binding ~= nil then
			binding.confirmed = true
			setHidden(binding, true)
		end
	end
	playPickupSound()
end)

for _, instance in CollectionService:GetTagged(TAG) do
	bind(instance)
end
CollectionService:GetInstanceAddedSignal(TAG):Connect(bind)
CollectionService:GetInstanceRemovedSignal(TAG):Connect(unbind)
