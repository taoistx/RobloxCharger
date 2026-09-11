--!strict

--[[
	Owns authoritative minion pickup collection and follower counts.
	MinionPicker tag: BasePart or Model (a Model must contain a BasePart).
	Required pickup attribute: MinionType: string, matching the exact name of a
	direct child of ServerStorage/MinionTemplates (or ServerStorage in legacy places).
	Required minion-template attributes: EnergyValue: number in the range
	1..1,000,000; EnergyUpgradePerLevel: integer in the same range. The latter
	controls that minion type's energy gained per shop upgrade level.
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
local PlayerShopService = require(script.Parent:WaitForChild("PlayerShopService"))

type RootObject = GameplayUtil.RootObject
type Binding = {
	connections: { RBXScriptConnection },
	root: RootObject,
	template: Instance,
	minionType: string,
	baseValue: number,
}
type Follower = {
	instance: Instance,
	minionType: string,
	baseValue: number,
	value: number,
	order: number,
}
type PlayerConnectionState = {
	connections: { RBXScriptConnection },
	characterDiedConnection: RBXScriptConnection?,
}

local MinionService = {}

local TAG = GameplayConfig.Tags.MinionPicker
local ATTRIBUTE = GameplayConfig.Attributes
local FOLLOWER_STATE = GameplayConfig.FollowerStates

-- 拾取来源对象在击飞表现结束后延迟销毁的时间（秒）。
local SOURCE_DESTROY_DELAY = 2

-- 服务端接受拾取触碰的最大距离，用于过滤异常触碰事件（stud）。
local PICKUP_TOUCH_DISTANCE = 12

local bindings: { [Instance]: Binding } = {}
local followers: { [Player]: { Follower } } = {}
local nextFollowerOrders: { [Player]: number } = {}
local playerConnections: { [Player]: PlayerConnectionState } = {}
local storageRoot: Folder? = nil
local pickupFeedbackEvent: RemoteEvent? = nil
local started = false

local function getPickupFeedbackEvent(): RemoteEvent
	if pickupFeedbackEvent ~= nil and pickupFeedbackEvent.Parent ~= nil then
		return pickupFeedbackEvent
	end

	local eventName = GameplayConfig.InstanceNames.MinionPickupFeedback
	local existing = ReplicatedStorage:FindFirstChild(eventName)
	if existing ~= nil and existing:IsA("RemoteEvent") then
		pickupFeedbackEvent = existing
		return existing
	end
	if existing ~= nil then
		error("[MinionService] " .. eventName .. " must be a RemoteEvent: " .. existing:GetFullName())
	end

	local remote = Instance.new("RemoteEvent")
	remote.Name = eventName
	remote.Parent = ReplicatedStorage
	pickupFeedbackEvent = remote
	return remote
end

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

local function getDefaultMinionTemplate(player: Player): (Instance?, string?, number?)
	local candidates = getTemplateContainer():GetChildren()
	table.sort(candidates, function(left, right)
		return left.Name < right.Name
	end)
	for _, candidate in candidates do
		local value = candidate:GetAttribute(ATTRIBUTE.EnergyValue)
		if GameplayUtil.getRoot(candidate) ~= nil and candidate.Archivable
			and typeof(value) == "number" and value == value
			and value >= 1 and value <= GameplayConfig.Limits.MaxEnergyValue
			and PlayerShopService.isMinionUnlocked(player, candidate.Name)
		then
			return candidate, candidate.Name, value
		end
	end
	warn("[MinionService] no valid default Minion template found")
	return nil, nil, nil
end

local function getMinionDefinition(pickup: Instance): (Instance?, string?, number?)
	local minionType = pickup:GetAttribute(ATTRIBUTE.MinionType)
	if typeof(minionType) ~= "string" or minionType == "" then
		warn("[MinionService] pickup requires a non-empty MinionType string", pickup)
		return nil, nil, nil
	end
	local template, value = getMinionTemplate(minionType)
	return template, minionType, value
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

local function appendFollower(player: Player, source: Instance, minionType: string, baseValue: number, value: number)
	local order = (nextFollowerOrders[player] or 0) + 1
	nextFollowerOrders[player] = order
	source.Name = "Follower_" .. order
	source:SetAttribute(ATTRIBUTE.FollowerOwnerUserId, player.UserId)
	source:SetAttribute(ATTRIBUTE.FollowerOrder, order)
	source:SetAttribute(ATTRIBUTE.FollowerState, FOLLOWER_STATE.Following)
	source.Parent = getPlayerStorage(player)
	table.insert(getFollowers(player), {
		instance = source,
		minionType = minionType,
		baseValue = baseValue,
		value = value,
		order = order,
	})
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
	if (GameplayUtil.getPivot(binding.root).Position - rootPart.Position).Magnitude > PICKUP_TOUCH_DISTANCE then
		return
	end
	if #getFollowers(player) >= GameplayConfig.Limits.MaxFollowersPerPlayer then
		return
	end
	if not PlayerShopService.isMinionUnlocked(player, binding.minionType) then
		player:SetAttribute(ATTRIBUTE.StatusMessage, "该小兵尚未解锁！")
		return
	end
	if not PlayerEnergyService.canAddEnergy(player) then
		instance:SetAttribute(ATTRIBUTE.Collected, true)
		CollectionService:RemoveTag(instance, TAG)
		instance:Destroy()
		getPickupFeedbackEvent():FireClient(player)
		player:SetAttribute(ATTRIBUTE.StatusMessage, "能量已满，小兵不会加入！")
		return
	end
	local value = PlayerShopService.getMinionEnergyValue(player, binding.minionType, binding.baseValue)
	if value == nil then
		return
	end

	instance:SetAttribute(ATTRIBUTE.Collected, true)
	local followerSource = cloneFollowerSource(binding.template)
	if followerSource == nil then
		instance:SetAttribute(ATTRIBUTE.Collected, false)
		warn("[MinionService] cloned Minion template lost its BasePart root", binding.template)
		return
	end
	appendFollower(player, followerSource, binding.minionType, binding.baseValue, value)
	CollectionService:RemoveTag(instance, TAG)
	instance:Destroy()
	updateFollowerCount(player)
	getPickupFeedbackEvent():FireClient(player)

	local gained = PlayerEnergyService.addEnergy(player, value)
	player:SetAttribute(ATTRIBUTE.StatusMessage, "+" .. math.floor(gained) .. " 能量，小兵已加入！")
end

local function bind(instance: Instance)
	if bindings[instance] ~= nil then
		return
	end
	local root = GameplayUtil.getRoot(instance)
	local template, minionType, baseValue = getMinionDefinition(instance)
	if root == nil or template == nil or minionType == nil or baseValue == nil then
		if root == nil then
			warn("[MinionService] pickup must be a BasePart or Model containing a BasePart", instance)
		end
		return
	end

	instance:SetAttribute(ATTRIBUTE.Collected, false)
	local binding: Binding = {
		root = root,
		template = template,
		minionType = minionType,
		baseValue = baseValue,
		connections = {},
	}
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

function MinionService.refreshFollowerEnergyValues(player: Player)
	local playerFollowers = followers[player]
	if playerFollowers == nil then
		return
	end

	local powerChange = 0
	for index = #playerFollowers, 1, -1 do
		local follower = playerFollowers[index]
		if not PlayerShopService.isMinionUnlocked(player, follower.minionType) then
			powerChange -= follower.value
			table.remove(playerFollowers, index)
			follower.instance:SetAttribute(ATTRIBUTE.FollowerState, FOLLOWER_STATE.Removed)
			scheduleSourceDestroy(follower.instance, 0.15)
		else
			local value = PlayerShopService.getMinionEnergyValue(player, follower.minionType, follower.baseValue)
			if value ~= nil and value ~= follower.value then
				powerChange += value - follower.value
				follower.value = value
			end
		end
	end
	updateFollowerCount(player)
	if powerChange > 0 then
		PlayerEnergyService.addEnergy(player, powerChange)
	elseif powerChange < 0 then
		PlayerEnergyService.removeEnergy(player, -powerChange)
	end
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
		local minionTypeToAdd: string? = nil
		local baseValue: number? = nil
		local value: number? = nil
		if minionType ~= nil then
			if not PlayerShopService.isMinionUnlocked(player, minionType) then
				return false, 0
			end
			template, baseValue = getMinionTemplate(minionType)
			value = PlayerShopService.getMinionEnergyValue(player, minionType, baseValue)
			minionTypeToAdd = minionType
			if template == nil or baseValue == nil or value == nil then
				return false, 0
			end
		elseif current == 0 then
			template, minionTypeToAdd, baseValue = getDefaultMinionTemplate(player)
			if template ~= nil and minionTypeToAdd ~= nil and baseValue ~= nil then
				value = PlayerShopService.getMinionEnergyValue(player, minionTypeToAdd, baseValue)
			end
			if template == nil or minionTypeToAdd == nil or baseValue == nil or value == nil then
				return false, 0
			end
		end
		local prepared: { Follower } = {}
		for index = 1, target - current do
			local sourceTemplate = template
			local sourceMinionType = minionTypeToAdd
			local sourceBaseValue = baseValue
			local sourceValue = value
			if sourceTemplate == nil then
				local original = playerFollowers[(index - 1) % current + 1]
				sourceTemplate = original.instance
				sourceMinionType = original.minionType
				sourceBaseValue = original.baseValue
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
			table.insert(prepared, {
				instance = source,
				minionType = sourceMinionType :: string,
				baseValue = sourceBaseValue :: number,
				value = sourceValue :: number,
				order = 0,
			})
		end
		for _, follower in prepared do
			appendFollower(player, follower.instance, follower.minionType, follower.baseValue, follower.value)
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
	table.insert(connectionState.connections, player:GetAttributeChangedSignal(ATTRIBUTE.ShopRevision):Connect(function()
		MinionService.refreshFollowerEnergyValues(player)
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
	getPickupFeedbackEvent()

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
