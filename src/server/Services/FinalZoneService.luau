--!strict

--[[
	Owns authoritative `FinalZone` touch handling.
	FinalZone tag: BasePart in Workspace.
	Required attributes: none.
	Optional attributes: none.

	A living player can trigger each FinalZone once per ceremony. The client is
	asked to play celebration presentation; after the configured duration, the
	server removes every follower, resets current energy, and returns the same
	character to its respawn location.
]]

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local GameplayConfig = require(Shared:WaitForChild("GameplayConfig"))
local GameplayUtil = require(script.Parent:WaitForChild("GameplayUtil"))
local MinionService = require(script.Parent:WaitForChild("MinionService"))

type Binding = {
	connections: { RBXScriptConnection },
}

local FinalZoneService = {}

local TAG = GameplayConfig.Tags.FinalZone
local REMOTE_NAME = GameplayConfig.InstanceNames.FinalCelebration
local TELEPORT_HEIGHT_PADDING = 3

local bindings: { [BasePart]: Binding } = {}
local pendingCharacters: { [Player]: Model } = {}
local started = false

local function getCelebrationRemote(): RemoteEvent
	local existing = ReplicatedStorage:FindFirstChild(REMOTE_NAME)
	if existing ~= nil then
		if existing:IsA("RemoteEvent") then
			return existing
		end
		existing:Destroy()
	end

	local remote = Instance.new("RemoteEvent")
	remote.Name = REMOTE_NAME
	remote.Parent = ReplicatedStorage
	return remote
end

local function getRespawnCFrame(player: Player): CFrame?
	local spawnLocation = player.RespawnLocation
	if spawnLocation == nil or not spawnLocation:IsDescendantOf(Workspace) then
		spawnLocation = Workspace:FindFirstChildWhichIsA("SpawnLocation", true)
	end
	if spawnLocation == nil then
		return nil
	end

	return spawnLocation.CFrame + Vector3.new(0, spawnLocation.Size.Y * 0.5 + TELEPORT_HEIGHT_PADDING, 0)
end

local function finishCelebration(player: Player, character: Model)
	if pendingCharacters[player] ~= character then
		return
	end
	pendingCharacters[player] = nil

	if player.Parent ~= Players or player.Character ~= character or not character:IsDescendantOf(Workspace) then
		return
	end
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	local rootPart = character:FindFirstChild("HumanoidRootPart")
	if humanoid == nil or humanoid.Health <= 0 or not rootPart or not rootPart:IsA("BasePart") then
		return
	end

	MinionService.releaseAllFollowers(player)

	local respawnCFrame = getRespawnCFrame(player)
	if respawnCFrame == nil then
		warn("[FinalZoneService] no SpawnLocation is available for", player)
		return
	end

	rootPart.AssemblyLinearVelocity = Vector3.zero
	rootPart.AssemblyAngularVelocity = Vector3.zero
	character:PivotTo(respawnCFrame)
	rootPart.AssemblyLinearVelocity = Vector3.zero
	rootPart.AssemblyAngularVelocity = Vector3.zero
end

local function beginCelebration(player: Player, character: Model)
	if pendingCharacters[player] ~= nil then
		return
	end
	pendingCharacters[player] = character
	getCelebrationRemote():FireClient(player)

	task.delay(GameplayConfig.Final.CelebrationDurationSeconds, function()
		finishCelebration(player, character)
	end)
end

local function onTouched(part: BasePart, touchedPart: BasePart)
	if bindings[part] == nil
		or not part:IsDescendantOf(Workspace)
		or not CollectionService:HasTag(part, TAG)
	then
		return
	end

	local player, character, humanoid = GameplayUtil.getCharacterFromTouch(touchedPart)
	if player == nil or character == nil or humanoid == nil or humanoid.Health <= 0 then
		return
	end
	beginCelebration(player, character)
end

local function unbind(part: BasePart)
	local binding = bindings[part]
	if binding == nil then
		return
	end

	bindings[part] = nil
	for _, connection in binding.connections do
		connection:Disconnect()
	end
end

local function bind(instance: Instance)
	if not instance:IsA("BasePart") then
		warn("[FinalZoneService] FinalZone must be a BasePart", instance)
		return
	end
	if bindings[instance] ~= nil then
		return
	end
	if not instance:IsDescendantOf(Workspace) then
		warn("[FinalZoneService] FinalZone must be a descendant of Workspace", instance)
		return
	end
	if not instance.Anchored or not instance.CanTouch then
		warn("[FinalZoneService] FinalZone requires Anchored and CanTouch", instance)
		return
	end

	local binding: Binding = { connections = {} }
	bindings[instance] = binding
	table.insert(binding.connections, instance.Touched:Connect(function(otherPart)
		onTouched(instance, otherPart)
	end))
	table.insert(binding.connections, instance.AncestryChanged:Connect(function()
		if not instance:IsDescendantOf(Workspace) then
			unbind(instance)
		end
	end))
end

function FinalZoneService.start()
	if started then
		return
	end
	started = true
	getCelebrationRemote()

	for _, instance in CollectionService:GetTagged(TAG) do
		bind(instance)
	end
	CollectionService:GetInstanceAddedSignal(TAG):Connect(bind)
	CollectionService:GetInstanceRemovedSignal(TAG):Connect(function(instance)
		if instance:IsA("BasePart") then
			unbind(instance)
		end
	end)

	Players.PlayerRemoving:Connect(function(player)
		pendingCharacters[player] = nil
	end)
	for _, player in Players:GetPlayers() do
		player.CharacterRemoving:Connect(function(character)
			if pendingCharacters[player] == character then
				pendingCharacters[player] = nil
			end
		end)
	end
	Players.PlayerAdded:Connect(function(player)
		player.CharacterRemoving:Connect(function(character)
			if pendingCharacters[player] == character then
				pendingCharacters[player] = nil
			end
		end)
	end)

	print("[FinalZoneService] started")
end

return FinalZoneService
