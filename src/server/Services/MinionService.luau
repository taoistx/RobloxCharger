--!strict

--[[
	Owns authoritative minion pickup collection and follower counts.
	MinionPickup tag: BasePart or Model (a Model must contain a BasePart).
	Required pickup attribute: MinionType: string, matching the exact name of a
	direct child of ServerStorage/MinionTemplates (or ServerStorage in legacy places).
	Required minion-template attribute: EnergyValue: number, range 1..1,000,000.
	Optional attributes: Collected: boolean (runtime, defaults false);
	SpawnOwnerUserId: number (runtime, only this player may collect the pickup).

	On collection, the referenced minion template is cloned into
	ReplicatedStorage/MinionFollowerStorage as a replicated visual source, and the
	pickup is destroyed. The client owns formation movement and knockback.
]]

local CollectionService = game:GetService("CollectionService")
local Debris = game:GetService("Debris")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerStorage = game:GetService("ServerStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local GameplayConfig = require(Shared:WaitForChild("GameplayConfig"))
local GameplayUtil = require(script.Parent:WaitForChild("GameplayUtil"))
local PlayerEnergyService = require(script.Parent:WaitForChild("PlayerEnergyService"))

type RootObject = GameplayUtil.RootObject
type Binding = {
	connections: { RBXScriptConnection },
	root: RootObject,
	template: Instance,
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

local TAG = GameplayConfig.Tags.MinionPickup
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

local function getTemplateContainer(): Instance
	local folder = ServerStorage:FindFirstChild(GameplayConfig.InstanceNames.MinionTemplates)
	return if folder ~= nil and folder:IsA("Folder") then folder else ServerStorage
end

local function getMinionTemplate(minionType: string): (Instance?, number?)
	local container = getTemplateContainer()
	local template = container:FindFirstChild(minionType)
	if template == nil or GameplayUtil.getRoot(template) == nil or not template.Archivable then
		warn("[MinionService] missing, invalid, or non-archivable Minion template", minionType)
		return nil, nil
	end
	local value = template:GetAttribute(ATTRIBUTE.EnergyValue)
	if typeof(value) ~= "number" or value ~= value or value < 1 or value > GameplayConfig.Limits.MaxEnergyValue then
		warn("[MinionService] Minion template requires EnergyValue between 1 and " .. GameplayConfig.Limits.MaxEnergyValue, template)
		return nil, nil
	end
	return template, value
end

local function getMinionDefinition(pickup: Instance): (Instance?, number?)
	local minionType = pickup:GetAttribute(ATTRIBUTE.MinionType)
	if typeof(minionType) ~= "string" or minionType == "" then
		warn("[MinionService] pickup requires a non-empty MinionType string", pickup)
		return nil, nil
	end
	return getMinionTemplate(minionType)
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
	Debris:AddItem(instance, delaySeconds)
end

local function cloneFollowerSource(template: Instance): Instance?
	if not template.Archivable then
		return nil
	end
	local source = template:Clone()
	local root = GameplayUtil.getRoot(source)
	if root == nil then
		source:Destroy()
		return nil
	end
	prepareVisualSource(root)
	CollectionService:RemoveTag(source, GameplayConfig.Tags.Minion)
	CollectionService:RemoveTag(source, TAG)
	return source
end

local function appendFollower(player: Player, source: Instance, value: number)
	local order = (nextFollowerOrders[player] or 0) + 1
	nextFollowerOrders[player] = order
	source.Name = "Follower_" .. order
	source:SetAttribute(ATTRIBUTE.FollowerOwnerUserId, player.UserId)
	source:SetAttribute(ATTRIBUTE.FollowerOrder, order)
	source:SetAttribute(ATTRIBUTE.FollowerState, FOLLOWER_STATE.Following)
	source.Parent = getPlayerStorage(player)
	table.insert(getFollowers(player), { instance = source, value = value, order = order })
end

local function onPickupTouched(instance: Instance, touchedPart: BasePart)
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
	if #getFollowers(player) >= GameplayConfig.Limits.MaxFollowersPerPlayer then
		return
	end

	instance:SetAttribute(ATTRIBUTE.Collected, true)
	local followerSource = cloneFollowerSource(binding.template)
	if followerSource == nil then
		instance:SetAttribute(ATTRIBUTE.Collected, false)
		warn("[MinionService] cloned Minion template lost its BasePart root", binding.template)
		return
	end
	appendFollower(player, followerSource, binding.value)
	CollectionService:RemoveTag(instance, TAG)
	instance:Destroy()
	updateFollowerCount(player)

	local gained = PlayerEnergyService.addEnergy(player, binding.value)
	player:SetAttribute(ATTRIBUTE.StatusMessage, if gained > 0 then "+" .. math.floor(gained) .. " 能量，小兵已加入！" else "能量已满，小兵仍会跟随你！")
end

local function bind(instance: Instance)
	if bindings[instance] ~= nil then
		return
	end
	local root = GameplayUtil.getRoot(instance)
	local template, value = getMinionDefinition(instance)
	if root == nil or template == nil or value == nil then
		if root == nil then
			warn("[MinionService] pickup must be a BasePart or Model containing a BasePart", instance)
		end
		return
	end

	instance:SetAttribute(ATTRIBUTE.Collected, false)
	local binding: Binding = { root = root, template = template, value = value, connections = {} }
	bindings[instance] = binding
	for _, part in GameplayUtil.getParts(root) do
		table.insert(binding.connections, part.Touched:Connect(function(otherPart)
			onPickupTouched(instance, otherPart)
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

function MinionService.isValidMinionType(minionType: string): boolean
	local template = getMinionTemplate(minionType)
	return template ~= nil
end

function MinionService.getFollowerCount(player: Player): number
	local playerFollowers = followers[player]
	return if playerFollowers ~= nil then #playerFollowers else 0
end

-- Server-only count changes. Added/removed followers also add/remove the combat
-- power represented by their EnergyValue. Multiplication preserves type composition.
-- All additional sources are prepared before committing, so failure changes nothing.
function MinionService.setFollowerCount(player: Player, target: number, minionType: string?): (boolean, number)
	local playerFollowers = followers[player]
	if playerFollowers == nil or player.Parent ~= Players or target ~= target
		or target % 1 ~= 0 or target < 0 or target > GameplayConfig.Limits.MaxFollowersPerPlayer
	then
		return false, 0
	end
	local current = #playerFollowers
	local powerChange = 0
	if target > current then
		local template: Instance? = nil
		local value: number? = nil
		if minionType ~= nil then
			template, value = getMinionTemplate(minionType)
			if template == nil or value == nil then
				return false, 0
			end
		elseif current == 0 then
			return false, 0
		end
		local prepared: { Follower } = {}
		for index = 1, target - current do
			local sourceTemplate = template
			local sourceValue = value
			if sourceTemplate == nil then
				local original = playerFollowers[(index - 1) % current + 1]
				sourceTemplate = original.instance
				sourceValue = original.value
			end
			local source = cloneFollowerSource(sourceTemplate)
			if source == nil then
				for _, follower in prepared do
					follower.instance:Destroy()
				end
				warn("[MinionService] unable to clone follower source", sourceTemplate)
				return false, 0
			end
			table.insert(prepared, { instance = source, value = sourceValue :: number, order = 0 })
		end
		for _, follower in prepared do
			appendFollower(player, follower.instance, follower.value)
			powerChange += follower.value
		end
		powerChange = PlayerEnergyService.addEnergy(player, powerChange)
	else
		local removedPower = 0
		while #playerFollowers > target do
			local follower = table.remove(playerFollowers) :: Follower
			removedPower += follower.value
			follower.instance:SetAttribute(ATTRIBUTE.FollowerState, FOLLOWER_STATE.Knockback)
			scheduleSourceDestroy(follower.instance, SOURCE_DESTROY_DELAY)
		end
		powerChange = -PlayerEnergyService.removeEnergy(player, removedPower)
	end
	updateFollowerCount(player)
	return true, powerChange
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
