--!strict

--[[
	Owns authoritative `Minion` collection and follower counts.
	Minion tag: BasePart or Model (a Model must contain a BasePart).
	Required attributes: EnergyValue: number, range 1..1,000,000.
	Optional attributes: Collected: boolean (runtime, defaults false);
	SpawnOwnerUserId: number (runtime, only this player may collect the spawned Minion).

	Collected objects are moved into ReplicatedStorage/MinionFollowerStorage as
	replicated visual sources. The client owns formation movement and knockback;
	the server only owns collection, energy values, follower state, and removal.
]]

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local GameplayConfig = require(Shared:WaitForChild("GameplayConfig"))
local GameplayUtil = require(script.Parent:WaitForChild("GameplayUtil"))
local PlayerEnergyService = require(script.Parent:WaitForChild("PlayerEnergyService"))

type RootObject = GameplayUtil.RootObject
type Binding = {
	connections: { RBXScriptConnection },
	root: RootObject,
	value: number,
}
type Follower = {
	instance: Instance,
	value: number,
	order: number,
}
type PlayerConnectionState = {
	connections: { RBXScriptConnection },
	characterDiedConnection: RBXScriptConnection?,
}

local MinionService = {}

local TAG = GameplayConfig.Tags.Minion
local ATTRIBUTE = GameplayConfig.Attributes
local FOLLOWER_STATE = GameplayConfig.FollowerStates
local SOURCE_DESTROY_DELAY = 2

local bindings: { [Instance]: Binding } = {}
local followers: { [Player]: { Follower } } = {}
local nextFollowerOrders: { [Player]: number } = {}
local playerConnections: { [Player]: PlayerConnectionState } = {}
local storageRoot: Folder? = nil
local started = false

local function getStorageRoot(): Folder
	if storageRoot ~= nil and storageRoot.Parent ~= nil then
		return storageRoot
	end

	local existing = ReplicatedStorage:FindFirstChild(GameplayConfig.InstanceNames.MinionFollowerStorage)
	if existing ~= nil and existing:IsA("Folder") then
		storageRoot = existing
		return existing
	end

	local folder = Instance.new("Folder")
	folder.Name = GameplayConfig.InstanceNames.MinionFollowerStorage
	folder.Parent = ReplicatedStorage
	storageRoot = folder
	return folder
end

local function getPlayerStorage(player: Player): Folder
	local root = getStorageRoot()
	local folderName = tostring(player.UserId)
	local existing = root:FindFirstChild(folderName)
	if existing ~= nil and existing:IsA("Folder") then
		return existing
	end

	local folder = Instance.new("Folder")
	folder.Name = folderName
	folder:SetAttribute(ATTRIBUTE.FollowerOwnerUserId, player.UserId)
	folder.Parent = root
	return folder
end

local function getEnergyValue(instance: Instance): number?
	local value = instance:GetAttribute(ATTRIBUTE.EnergyValue)
	if typeof(value) ~= "number" or value < 1 or value > GameplayConfig.Limits.MaxEnergyValue then
		warn("[MinionService] Minion requires EnergyValue between 1 and " .. GameplayConfig.Limits.MaxEnergyValue, instance)
		return nil
	end
	return value
end

local function getFollowers(player: Player): { Follower }
	local playerFollowers = followers[player]
	if playerFollowers == nil then
		playerFollowers = {}
		followers[player] = playerFollowers
	end
	return playerFollowers
end

local function updateFollowerCount(player: Player)
	local playerFollowers = followers[player]
	player:SetAttribute(ATTRIBUTE.FollowerCount, if playerFollowers ~= nil then #playerFollowers else 0)
end

local function prepareVisualSource(root: RootObject)
	for _, part in GameplayUtil.getParts(root) do
		part.Anchored = true
		part.CanCollide = false
		part.CanQuery = false
		part.CanTouch = false
		part.Massless = true
		part.AssemblyLinearVelocity = Vector3.zero
		part.AssemblyAngularVelocity = Vector3.zero
	end
end

local function scheduleSourceDestroy(instance: Instance, delaySeconds: number)
	task.delay(delaySeconds, function()
		if instance.Parent ~= nil then
			instance:Destroy()
		end
	end)
end

local function onMinionTouched(instance: Instance, touchedPart: BasePart)
	local binding = bindings[instance]
	if binding == nil or instance:GetAttribute(ATTRIBUTE.Collected) == true then
		return
	end

	local player, _, humanoid, rootPart = GameplayUtil.getCharacterFromTouch(touchedPart)
	if player == nil or humanoid == nil or rootPart == nil or humanoid.Health <= 0 then
		return
	end
	if not PlayerEnergyService.isPlayerInGameZone(player) then
		return
	end
	local spawnOwnerUserId = instance:GetAttribute(ATTRIBUTE.SpawnOwnerUserId)
	if typeof(spawnOwnerUserId) == "number" and spawnOwnerUserId ~= player.UserId then
		return
	end
	if (GameplayUtil.getPivot(binding.root).Position - rootPart.Position).Magnitude > 12 then
		return
	end

	instance:SetAttribute(ATTRIBUTE.Collected, true)
	prepareVisualSource(binding.root)

	local order = (nextFollowerOrders[player] or 0) + 1
	nextFollowerOrders[player] = order
	instance:SetAttribute(ATTRIBUTE.FollowerOwnerUserId, player.UserId)
	instance:SetAttribute(ATTRIBUTE.FollowerOrder, order)
	instance:SetAttribute(ATTRIBUTE.FollowerState, FOLLOWER_STATE.Following)
	instance.Parent = getPlayerStorage(player)
	CollectionService:RemoveTag(instance, TAG)

	local playerFollowers = getFollowers(player)
	table.insert(playerFollowers, { instance = instance, value = binding.value, order = order })
	updateFollowerCount(player)

	local gained = PlayerEnergyService.addEnergy(player, binding.value)
	player:SetAttribute(ATTRIBUTE.StatusMessage, if gained > 0 then "+" .. math.floor(gained) .. " 能量，小兵已加入！" else "能量已满，小兵仍会跟随你！")
end

local function bind(instance: Instance)
	if bindings[instance] ~= nil then
		return
	end
	local root = GameplayUtil.getRoot(instance)
	local value = getEnergyValue(instance)
	if root == nil or value == nil then
		if root == nil then
			warn("[MinionService] Minion must be a BasePart or Model containing a BasePart", instance)
		end
		return
	end

	instance:SetAttribute(ATTRIBUTE.Collected, false)
	local binding: Binding = { root = root, value = value, connections = {} }
	bindings[instance] = binding
	for _, part in GameplayUtil.getParts(root) do
		table.insert(binding.connections, part.Touched:Connect(function(otherPart)
			onMinionTouched(instance, otherPart)
		end))
	end
end

local function unbind(instance: Instance)
	local binding = bindings[instance]
	if binding == nil then
		return
	end
	for _, connection in binding.connections do
		connection:Disconnect()
	end
	bindings[instance] = nil
end

function MinionService.releaseEnergyFollowers(player: Player, energyToRepresent: number): number
	local playerFollowers = followers[player]
	if playerFollowers == nil or energyToRepresent <= 0 then
		return 0
	end

	local representedEnergy = 0
	local releasedCount = 0
	while #playerFollowers > 0 and representedEnergy < energyToRepresent do
		local follower = table.remove(playerFollowers, #playerFollowers)
		representedEnergy += follower.value
		releasedCount += 1
		follower.instance:SetAttribute(ATTRIBUTE.FollowerState, FOLLOWER_STATE.Knockback)
		scheduleSourceDestroy(follower.instance, SOURCE_DESTROY_DELAY)
	end
	updateFollowerCount(player)
	return releasedCount
end

function MinionService.releaseAllFollowers(player: Player)
	local playerFollowers = followers[player]
	if playerFollowers == nil then
		updateFollowerCount(player)
		return
	end

	while #playerFollowers > 0 do
		local follower = table.remove(playerFollowers)
		follower.instance:SetAttribute(ATTRIBUTE.FollowerState, FOLLOWER_STATE.Removed)
		scheduleSourceDestroy(follower.instance, 0.15)
	end
	updateFollowerCount(player)
end

local function bindCharacterDeath(player: Player, character: Model)
	local connectionState = playerConnections[player]
	if connectionState == nil then
		return
	end
	if connectionState.characterDiedConnection ~= nil then
		connectionState.characterDiedConnection:Disconnect()
		connectionState.characterDiedConnection = nil
	end
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if humanoid == nil then
		return
	end
	connectionState.characterDiedConnection = humanoid.Died:Connect(function()
		MinionService.releaseAllFollowers(player)
	end)
end

local function bindPlayer(player: Player)
	if playerConnections[player] ~= nil then
		return
	end
	followers[player] = {}
	nextFollowerOrders[player] = 0
	updateFollowerCount(player)

	local connectionState: PlayerConnectionState = { connections = {}, characterDiedConnection = nil }
	playerConnections[player] = connectionState
	table.insert(connectionState.connections, player.CharacterRemoving:Connect(function()
		MinionService.releaseAllFollowers(player)
	end))
	table.insert(connectionState.connections, player.CharacterAdded:Connect(function(character)
		bindCharacterDeath(player, character)
	end))
	if player.Character ~= nil then
		bindCharacterDeath(player, player.Character)
	end
end

local function unbindPlayer(player: Player)
	MinionService.releaseAllFollowers(player)
	followers[player] = nil
	nextFollowerOrders[player] = nil
	local connectionState = playerConnections[player]
	if connectionState ~= nil then
		for _, connection in connectionState.connections do
			connection:Disconnect()
		end
		if connectionState.characterDiedConnection ~= nil then
			connectionState.characterDiedConnection:Disconnect()
		end
		playerConnections[player] = nil
	end
	local playerFolder = getStorageRoot():FindFirstChild(tostring(player.UserId))
	if playerFolder ~= nil then
		scheduleSourceDestroy(playerFolder, 0.2)
	end
end

function MinionService.start()
	if started then
		return
	end
	started = true
	getStorageRoot()

	for _, instance in CollectionService:GetTagged(TAG) do
		bind(instance)
	end
	CollectionService:GetInstanceAddedSignal(TAG):Connect(bind)
	CollectionService:GetInstanceRemovedSignal(TAG):Connect(unbind)

	for _, player in Players:GetPlayers() do
		bindPlayer(player)
	end
	Players.PlayerAdded:Connect(bindPlayer)
	Players.PlayerRemoving:Connect(unbindPlayer)

	print("[MinionService] started")
end

return MinionService
