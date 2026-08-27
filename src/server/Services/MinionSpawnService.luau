--!strict

--[[
	Preloads a player's collectible minions for the next two `GameZone` indices.
	GameZone tag: BasePart or Model (a Model must contain a BasePart).
	Required attributes: ZoneIndex: integer in the range 0..1,000,000.
	Optional attributes: MinionSpawnCount: integer in the range 1..1,000 (default: 10).
	Entering index N generates minions in N + 1 and N + 2 once per player life.

	Templates: direct children of ServerStorage/MinionTemplates; if that folder is
	absent, direct children of ServerStorage are accepted for the current scene.
	Each template must be a BasePart or Model with the `Minion` tag and an
	EnergyValue: number attribute in the range 1..1,000,000. Its Pivot must be
	placed at the point that touches the ground. Template tags are removed at
	runtime; spawned clones receive the tag instead.

	Spawned Minion optional runtime attribute:
	SpawnOwnerUserId: number. Only this player can collect that instance.
]]

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ServerStorage = game:GetService("ServerStorage")
local Workspace = game:GetService("Workspace")

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local GameplayConfig = require(Shared:WaitForChild("GameplayConfig"))
local GameplayUtil = require(script.Parent:WaitForChild("GameplayUtil"))

type RootObject = GameplayUtil.RootObject
type ZoneBounds = {
	cframe: CFrame,
	size: Vector3,
}
type PlayerSpawnState = {
	connections: { RBXScriptConnection },
	characterDiedConnection: RBXScriptConnection?,
	folders: { [number]: Folder },
	spawnedZoneIndices: { [number]: boolean },
}

local MinionSpawnService = {}

local TAG = GameplayConfig.Tags
local ATTRIBUTE = GameplayConfig.Attributes
local INSTANCE_NAME = GameplayConfig.InstanceNames
local DEFAULT = GameplayConfig.Defaults
local MAX_TEMPLATE_ENERGY = GameplayConfig.Limits.MaxEnergyValue
local SPAWN_EDGE_PADDING = 3
local SPAWN_SURFACE_OFFSET = 0.05
local MAX_POSITION_ATTEMPTS = 24

local templates: { Instance } = {}
local states: { [Player]: PlayerSpawnState } = {}
local sessionRoot: Folder? = nil
local started = false

local function getSessionRoot(): Folder
	if sessionRoot ~= nil and sessionRoot.Parent ~= nil then
		return sessionRoot
	end

	local existing = Workspace:FindFirstChild(INSTANCE_NAME.MinionSpawnSessions)
	if existing ~= nil and existing:IsA("Folder") then
		sessionRoot = existing
		return existing
	end

	local folder = Instance.new("Folder")
	folder.Name = INSTANCE_NAME.MinionSpawnSessions
	folder.Parent = Workspace
	sessionRoot = folder
	return folder
end

local function getTemplateContainer(): Instance
	local folder = ServerStorage:FindFirstChild(INSTANCE_NAME.MinionTemplates)
	if folder ~= nil and folder:IsA("Folder") then
		return folder
	end
	return ServerStorage
end

local function isValidTemplate(instance: Instance): boolean
	if GameplayUtil.getRoot(instance) == nil then
		warn("[MinionSpawnService] template must be a BasePart or Model containing a BasePart", instance)
		return false
	end
	local energyValue = instance:GetAttribute(ATTRIBUTE.EnergyValue)
	if typeof(energyValue) ~= "number" or energyValue < 1 or energyValue > MAX_TEMPLATE_ENERGY then
		warn("[MinionSpawnService] template requires EnergyValue between 1 and " .. MAX_TEMPLATE_ENERGY, instance)
		return false
	end
	return true
end

local function cacheTemplates()
	templates = {}
	for _, instance in getTemplateContainer():GetChildren() do
		if CollectionService:HasTag(instance, TAG.Minion) and isValidTemplate(instance) then
			table.insert(templates, instance)
			-- Only spawned clones are collectable. The template itself must never bind to MinionService.
			CollectionService:RemoveTag(instance, TAG.Minion)
		end
	end
	if #templates == 0 then
		warn("[MinionSpawnService] no valid Minion template found in ServerStorage")
	end
end

local function getZoneIndex(instance: Instance): number?
	local zoneIndex = instance:GetAttribute(ATTRIBUTE.ZoneIndex)
	if typeof(zoneIndex) ~= "number"
		or zoneIndex ~= math.floor(zoneIndex)
		or zoneIndex < 0
		or zoneIndex > GameplayConfig.Limits.MaxGameZoneIndex
	then
		return nil
	end
	return zoneIndex
end

local function getMinionSpawnCount(instance: Instance): number
	local count = instance:GetAttribute(ATTRIBUTE.MinionSpawnCount)
	if typeof(count) ~= "number" then
		return DEFAULT.MinionSpawnCount
	end
	if count ~= math.floor(count) or count < 1 or count > GameplayConfig.Limits.MaxMinionsPerGameZone then
		warn("[MinionSpawnService] GameZone MinionSpawnCount must be an integer between 1 and " .. GameplayConfig.Limits.MaxMinionsPerGameZone, instance)
		return DEFAULT.MinionSpawnCount
	end
	return count
end

local function getZoneBounds(zoneIndex: number): (ZoneBounds?, number?)
	for _, instance in CollectionService:GetTagged(TAG.GameZone) do
		if getZoneIndex(instance) ~= zoneIndex then
			continue
		end
		local root = GameplayUtil.getRoot(instance)
		if root == nil then
			warn("[MinionSpawnService] GameZone must be a BasePart or Model containing a BasePart", instance)
			continue
		end
		local spawnCount = getMinionSpawnCount(instance)
		if root:IsA("BasePart") then
			return { cframe = root.CFrame, size = root.Size }, spawnCount
		end
		local cframe, size = root:GetBoundingBox()
		return { cframe = cframe, size = size }, spawnCount
	end
	return nil, nil
end


local function isFarEnough(candidate: Vector3, placedPositions: { Vector3 }): boolean
	for _, position in placedPositions do
		local difference = Vector3.new(candidate.X - position.X, 0, candidate.Z - position.Z)
		if difference.Magnitude < DEFAULT.MinionSpawnMinSpacing then
			return false
		end
	end
	return true
end

local function chooseSpawnCFrame(root: RootObject, zone: ZoneBounds, placedPositions: { Vector3 }): CFrame?
	local sourcePivot = root:GetPivot()
	local sourceRotation = sourcePivot - sourcePivot.Position
	for _ = 1, MAX_POSITION_ATTEMPTS do
		local halfWidth = math.max(zone.size.X / 2 - SPAWN_EDGE_PADDING, 0)
		local halfDepth = math.max(zone.size.Z / 2 - SPAWN_EDGE_PADDING, 0)
		local localPosition = Vector3.new(
			(math.random() * 2 - 1) * halfWidth,
			-- 模板 Pivot 即地面接触点，直接贴到 GameZone 顶面。
			zone.size.Y / 2 + SPAWN_SURFACE_OFFSET,
			(math.random() * 2 - 1) * halfDepth
		)
		local candidate = zone.cframe * CFrame.new(localPosition) * sourceRotation
		if isFarEnough(candidate.Position, placedPositions) then
			return candidate
		end
	end
	return nil
end

local function cleanupSpawnedMinions(state: PlayerSpawnState)
	for _, folder in state.folders do
		if folder.Parent ~= nil then
			folder:Destroy()
		end
	end
	table.clear(state.folders)
	table.clear(state.spawnedZoneIndices)
end

local function createPlayerFolder(player: Player, zoneIndex: number): Folder
	local folder = Instance.new("Folder")
	folder.Name = "Player_" .. player.UserId .. "_Zone_" .. zoneIndex
	folder:SetAttribute(ATTRIBUTE.SpawnOwnerUserId, player.UserId)
	folder:SetAttribute(ATTRIBUTE.ZoneIndex, zoneIndex)
	folder.Parent = getSessionRoot()
	return folder
end

local function spawnZone(player: Player, zoneIndex: number)
	local state = states[player]
	if state == nil or state.spawnedZoneIndices[zoneIndex] then
		return
	end
	if #templates == 0 then
		return
	end

	local zone, spawnCount = getZoneBounds(zoneIndex)
	if zone == nil or spawnCount == nil then
		return
	end

	local folder = createPlayerFolder(player, zoneIndex)
	state.folders[zoneIndex] = folder
	local placedPositions: { Vector3 } = {}
	local spawnedCount = 0

	for index = 1, spawnCount do
		local template = templates[math.random(1, #templates)]
		local clone = template:Clone()
		local root = GameplayUtil.getRoot(clone)
		if root == nil then
			warn("[MinionSpawnService] cloned template lost its BasePart root", template)
			clone:Destroy()
			continue
		end

		local spawnCFrame = chooseSpawnCFrame(root, zone, placedPositions)
		if spawnCFrame == nil then
			clone:Destroy()
			warn("[MinionSpawnService] unable to find a free Minion spawn position", player)
			break
		end

		root:PivotTo(spawnCFrame)
		clone.Name = "Minion_" .. index
		clone:SetAttribute(ATTRIBUTE.Collected, false)
		clone:SetAttribute(ATTRIBUTE.SpawnOwnerUserId, player.UserId)
		clone.Parent = folder
		CollectionService:AddTag(clone, TAG.Minion)
		table.insert(placedPositions, spawnCFrame.Position)
		spawnedCount += 1
	end

	if spawnedCount > 0 then
		state.spawnedZoneIndices[zoneIndex] = true
		player:SetAttribute(ATTRIBUTE.StatusMessage, "第 " .. zoneIndex .. " 区的小兵已就绪！")
	else
		folder:Destroy()
		state.folders[zoneIndex] = nil
	end
end

local function preloadUpcomingZones(player: Player, currentZoneIndex: number)
	for zoneIndex = currentZoneIndex + 1, currentZoneIndex + 2 do
		spawnZone(player, zoneIndex)
	end
end

local function bindCharacterDeath(state: PlayerSpawnState, character: Model)
	if state.characterDiedConnection ~= nil then
		state.characterDiedConnection:Disconnect()
		state.characterDiedConnection = nil
	end
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if humanoid == nil then
		return
	end
	state.characterDiedConnection = humanoid.Died:Connect(function()
		cleanupSpawnedMinions(state)
	end)
end

local function bindPlayer(player: Player)
	if states[player] ~= nil then
		return
	end
	local state: PlayerSpawnState = {
		connections = {},
		characterDiedConnection = nil,
		folders = {},
		spawnedZoneIndices = {},
	}
	states[player] = state
	table.insert(state.connections, player:GetAttributeChangedSignal(ATTRIBUTE.CurrentGameZoneIndex):Connect(function()
		local zoneIndex = player:GetAttribute(ATTRIBUTE.CurrentGameZoneIndex)
		if typeof(zoneIndex) == "number" and zoneIndex == math.floor(zoneIndex) and zoneIndex >= 0 then
			preloadUpcomingZones(player, zoneIndex)
		end
	end))
	table.insert(state.connections, player.CharacterRemoving:Connect(function()
		cleanupSpawnedMinions(state)
	end))
	table.insert(state.connections, player.CharacterAdded:Connect(function(character)
		bindCharacterDeath(state, character)
	end))
	if player.Character ~= nil then
		bindCharacterDeath(state, player.Character)
	end
	local zoneIndex = player:GetAttribute(ATTRIBUTE.CurrentGameZoneIndex)
	if typeof(zoneIndex) == "number" and zoneIndex == math.floor(zoneIndex) and zoneIndex >= 0 then
		preloadUpcomingZones(player, zoneIndex)
	end
end

local function unbindPlayer(player: Player)
	local state = states[player]
	if state == nil then
		return
	end
	cleanupSpawnedMinions(state)
	for _, connection in state.connections do
		connection:Disconnect()
	end
	if state.characterDiedConnection ~= nil then
		state.characterDiedConnection:Disconnect()
	end
	states[player] = nil
end

function MinionSpawnService.start()
	if started then
		return
	end
	started = true
	getSessionRoot()
	cacheTemplates()

	for _, player in Players:GetPlayers() do
		bindPlayer(player)
	end
	Players.PlayerAdded:Connect(bindPlayer)
	Players.PlayerRemoving:Connect(unbindPlayer)

	print("[MinionSpawnService] started")
end

return MinionSpawnService
