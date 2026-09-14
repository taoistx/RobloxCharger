--!strict

--[[
	Spawns a player's minion pickups for the active `GameZone` and preloads
	the next two `GameZone` indices.
	GameZone tag: BasePart or Model (a Model must contain a BasePart).
	Required attributes: ZoneIndex: integer in the range 0..1,000,000.
	Optional attributes: MinionSpawnCount: -1 disables pickups for this zone;
	otherwise an integer in the range 1..1,000 (default: 10).
	Entering index N generates pickups in N, N + 1, and N + 2 once per player life.
	MinionPicker-tagged descendants authored under a GameZone at server startup are
	used as fixed-position presets. They count toward MinionSpawnCount, and only
	the remaining difference is placed randomly. Presets take priority when their
	count exceeds MinionSpawnCount. A preset with no MinionType chooses a random
	unlocked type for each player. A count of -1 disables both kinds.

	Templates: direct children of ServerStorage/MinionTemplates; if that folder is
	absent, tagged direct children of ServerStorage are accepted for compatibility.
	Each template must be a BasePart or Model with an EnergyValue: number attribute
	in the range 1..1,000,000. These are follower visuals, not world pickups.

	Each generated pickup has a MinionType string attribute containing the exact
	name of the MinionTemplates child to add, plus a unique PickupId used only for
	server-to-client visual confirmation. SpawnOwnerUserId makes the pickup
	collectable only by the player for whom it was generated. Its appearance is
	cloned from the `pickBall` object in ServerStorage or Workspace. An optional
	non-empty MinionType on `pickBall` locks random spawns to that template;
	missing or empty keeps random template selection. Locked minions are not
	generated for players who have not unlocked them.
]]

local CollectionService = game:GetService("CollectionService")
local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ServerStorage = game:GetService("ServerStorage")
local Workspace = game:GetService("Workspace")

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local GameplayConfig = require(Shared:WaitForChild("GameplayConfig"))
local GameplayUtil = require(script.Parent:WaitForChild("GameplayUtil"))
local PlayerShopService = require(script.Parent:WaitForChild("PlayerShopService"))

type RootObject = GameplayUtil.RootObject
type ZoneBounds = {
	cframe: CFrame,
	size: Vector3,
}
type AuthoredPickup = {
	prototype: Instance,
	pivot: CFrame,
}
type ZoneDefinition = {
	bounds: ZoneBounds,
	spawnCount: number,
	authoredPickups: { AuthoredPickup },
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

-- 随机拾取物距离 GameZone 水平边界的最小边距（stud）。
local SPAWN_EDGE_PADDING = 3

-- 随机拾取物相对地面或区域底部的抬高距离（stud）。
local SPAWN_SURFACE_OFFSET = 0.05

-- 每个随机位置最多尝试多少次，超过后放弃该位置。
local MAX_POSITION_ATTEMPTS = 24

-- GameZone.MinionSpawnCount 使用该值时完全禁用预置和随机拾取物。
local DISABLED_SPAWN_COUNT = -1

local templates: { Instance } = {}
local pickupTemplate: Instance? = nil
local forcedPickupMinionTemplate: Instance? = nil
local authoredPickupsByZone: { [Instance]: { AuthoredPickup } } = {}
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

local function getTemplateContainer(): (Instance, boolean)
	local folder = ServerStorage:FindFirstChild(INSTANCE_NAME.MinionTemplates)
	if folder ~= nil and folder:IsA("Folder") then
		return folder, true
	end
	return ServerStorage, false
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
	local container, usesDedicatedFolder = getTemplateContainer()
	local templateNames: { [string]: boolean } = {}
	for _, instance in container:GetChildren() do
		local isCandidate = usesDedicatedFolder or CollectionService:HasTag(instance, TAG.Minion)
		if isCandidate and isValidTemplate(instance) then
			if templateNames[instance.Name] then
				warn("[MinionSpawnService] Minion template names must be unique", instance.Name)
				continue
			end
			templateNames[instance.Name] = true
			table.insert(templates, instance)
			-- Legacy places tag templates as Minion. Templates themselves are never collectable.
			CollectionService:RemoveTag(instance, TAG.Minion)
			CollectionService:RemoveTag(instance, TAG.MinionPicker)
		end
	end
	if #templates == 0 then
		warn("[MinionSpawnService] no valid Minion template found in ServerStorage")
	end
end

local function findMinionTemplateByName(name: string): Instance?
	for _, template in templates do
		if template.Name == name then
			return template
		end
	end
	return nil
end

local function cachePickupTemplate()
	forcedPickupMinionTemplate = nil
	local templateName = INSTANCE_NAME.MinionPickupTemplate
	local found = ServerStorage:FindFirstChild(templateName, true)
	if found == nil then
		found = Workspace:FindFirstChild(templateName, true)
	end
	if found == nil or GameplayUtil.getRoot(found) == nil then
		pickupTemplate = nil
		warn("[MinionSpawnService] pickup template must be a BasePart or Model named " .. templateName)
		return
	end

	-- Workspace-authored templates are hidden from players during Play while the
	-- server keeps using the same instance as the source for generated pickups.
	if found.Parent ~= ServerStorage then
		found.Parent = ServerStorage
	end
	found.Archivable = true
	CollectionService:RemoveTag(found, TAG.Minion)
	CollectionService:RemoveTag(found, TAG.MinionPicker)
	pickupTemplate = found

	local configuredMinionType = found:GetAttribute(ATTRIBUTE.MinionType)
	if configuredMinionType == nil or configuredMinionType == "" then
		return
	end
	if typeof(configuredMinionType) ~= "string" then
		pickupTemplate = nil
		warn("[MinionSpawnService] pickBall MinionType must be a string when configured", found)
		return
	end
	local configuredTemplate = findMinionTemplateByName(configuredMinionType)
	if configuredTemplate == nil then
		pickupTemplate = nil
		warn("[MinionSpawnService] pickBall MinionType must match a MinionTemplates child", found)
		return
	end
	forcedPickupMinionTemplate = configuredTemplate
end

local function createPickup(minionTemplate: Instance, index: number): Instance?
	local source = pickupTemplate
	if source == nil or source.Parent == nil then
		return nil
	end
	local pickup = source:Clone()
	pickup.Name = "MinionPickup_" .. index
	pickup:SetAttribute(ATTRIBUTE.MinionType, minionTemplate.Name)
	local root = GameplayUtil.getRoot(pickup)
	if root == nil then
		pickup:Destroy()
		return nil
	end
	for _, part in GameplayUtil.getParts(root) do
		part.Anchored = true
		part.CanCollide = false
		part.CanQuery = true
		part.CanTouch = true
		part.AssemblyLinearVelocity = Vector3.zero
		part.AssemblyAngularVelocity = Vector3.zero
	end

	return pickup
end

local function assignPickupId(pickup: Instance)
	pickup:SetAttribute(ATTRIBUTE.PickupId, HttpService:GenerateGUID(false))
end

local function hasMinionTemplate(minionType: string): boolean
	return findMinionTemplateByName(minionType) ~= nil
end

local function chooseRandomUnlockedTemplate(player: Player, preferredTemplate: Instance?): Instance?
	if preferredTemplate ~= nil and PlayerShopService.isMinionUnlocked(player, preferredTemplate.Name) then
		return preferredTemplate
	end

	local availableTemplates: { Instance } = {}
	for _, template in templates do
		if PlayerShopService.isMinionUnlocked(player, template.Name) then
			table.insert(availableTemplates, template)
		end
	end
	if #availableTemplates == 0 then
		return nil
	end
	return availableTemplates[math.random(1, #availableTemplates)]
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
	if count == DISABLED_SPAWN_COUNT then
		return DISABLED_SPAWN_COUNT
	end
	if count ~= math.floor(count) or count < 1 or count > GameplayConfig.Limits.MaxMinionsPerGameZone then
		warn(
			"[MinionSpawnService] GameZone MinionSpawnCount must be -1 or an integer between 1 and "
				.. GameplayConfig.Limits.MaxMinionsPerGameZone,
			instance
		)
		return DEFAULT.MinionSpawnCount
	end
	return count
end

local function getZoneDefinition(zoneIndex: number): ZoneDefinition?
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
		local bounds: ZoneBounds
		if root:IsA("BasePart") then
			bounds = { cframe = root.CFrame, size = root.Size }
		else
			local cframe, size = root:GetBoundingBox()
			bounds = { cframe = cframe, size = size }
		end
		return {
			bounds = bounds,
			spawnCount = spawnCount,
			authoredPickups = authoredPickupsByZone[instance] or {},
		}
	end
	return nil
end

local function getOwningGameZone(instance: Instance): Instance?
	local ancestor = instance.Parent
	while ancestor ~= nil and ancestor ~= Workspace do
		if CollectionService:HasTag(ancestor, TAG.GameZone) then
			return ancestor
		end
		ancestor = ancestor.Parent
	end
	return nil
end

local function cacheAuthoredPickups()
	authoredPickupsByZone = {}
	local candidates: { { pickup: Instance, zone: Instance, pivot: CFrame } } = {}

	for _, pickup in CollectionService:GetTagged(TAG.MinionPicker) do
		local zone = getOwningGameZone(pickup)
		if zone == nil then
			continue
		end
		local root = GameplayUtil.getRoot(pickup)
		if root == nil then
			warn("[MinionSpawnService] authored pickup must be a BasePart or Model containing a BasePart", pickup)
			continue
		end
		local minionType = pickup:GetAttribute(ATTRIBUTE.MinionType)
		if minionType ~= nil and typeof(minionType) ~= "string" then
			warn("[MinionSpawnService] authored pickup MinionType must be a string when configured", pickup)
			continue
		end
		if typeof(minionType) == "string" and minionType ~= "" and not hasMinionTemplate(minionType) then
			warn("[MinionSpawnService] authored pickup MinionType must match a MinionTemplates child", pickup)
			continue
		end
		table.insert(candidates, { pickup = pickup, zone = zone, pivot = root:GetPivot() })
	end

	-- Remove the authored objects before MinionService binds them as shared world
	-- pickups. The retained prototypes are cloned into each player's life session.
	for _, candidate in candidates do
		local zonePickups = authoredPickupsByZone[candidate.zone]
		if zonePickups == nil then
			zonePickups = {}
			authoredPickupsByZone[candidate.zone] = zonePickups
		end
		candidate.pickup.Archivable = true
		CollectionService:RemoveTag(candidate.pickup, TAG.MinionPicker)
		candidate.pickup.Parent = nil
		table.insert(zonePickups, {
			prototype = candidate.pickup,
			pivot = candidate.pivot,
		})
	end

	if RunService:IsStudio() then
		for zone, zonePickups in authoredPickupsByZone do
			local spawnCount = getMinionSpawnCount(zone)
			if spawnCount ~= DISABLED_SPAWN_COUNT and #zonePickups > spawnCount then
				warn(
					"[MinionSpawnService] authored pickup count exceeds MinionSpawnCount; all authored pickups will be used",
					zone,
					#zonePickups,
					spawnCount
				)
			end
		end
	end
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

local function getBottomOffset(root: RootObject): Vector3
	local boundsCFrame: CFrame
	local boundsSize: Vector3
	if root:IsA("BasePart") then
		boundsCFrame = root.CFrame
		boundsSize = root.Size
	else
		boundsCFrame, boundsSize = root:GetBoundingBox()
	end
	local bottomWorldPosition = boundsCFrame:PointToWorldSpace(Vector3.new(0, -boundsSize.Y / 2, 0))
	return root:GetPivot():PointToObjectSpace(bottomWorldPosition)
end

local function chooseSpawnCFrame(root: RootObject, zone: ZoneBounds, placedPositions: { Vector3 }): CFrame?
	local sourcePivot = root:GetPivot()
	local sourceRotation = sourcePivot - sourcePivot.Position
	local bottomOffset = getBottomOffset(root)
	local zoneRotation = zone.cframe - zone.cframe.Position
	for _ = 1, MAX_POSITION_ATTEMPTS do
		local halfWidth = math.max(zone.size.X / 2 - SPAWN_EDGE_PADDING, 0)
		local halfDepth = math.max(zone.size.Z / 2 - SPAWN_EDGE_PADDING, 0)
		local localPosition = Vector3.new(
			(math.random() * 2 - 1) * halfWidth,
			-- 自动用模板包围盒底部贴到 GameZone 顶面，不要求手工调整 Pivot。
			zone.size.Y / 2 + SPAWN_SURFACE_OFFSET,
			(math.random() * 2 - 1) * halfDepth
		)
		local targetPosition = zone.cframe:PointToWorldSpace(localPosition)
		local targetRotation = zoneRotation * sourceRotation
		local candidate = CFrame.new(targetPosition) * targetRotation * CFrame.new(-bottomOffset)
		if isFarEnough(candidate.Position, placedPositions) then
			return candidate
		end
	end
	return nil
end

local function cleanupSpawnedPickups(state: PlayerSpawnState)
	for _, folder in state.folders do
		if folder.Parent ~= nil then
			folder:Destroy()
		end
	end
	table.clear(state.folders)
	table.clear(state.spawnedZoneIndices)
end

-- Clears this player's current-life picker session. The next valid GameZone
-- entry creates a fresh set using the same path as a newly spawned character.
function MinionSpawnService.resetPlayerSession(player: Player)
	local state = states[player]
	if state == nil then
		return
	end
	cleanupSpawnedPickups(state)
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
	if not PlayerShopService.isLoaded(player) then
		return
	end

	local definition = getZoneDefinition(zoneIndex)
	if definition == nil then
		return
	end
	local spawnCount = definition.spawnCount
	if spawnCount == DISABLED_SPAWN_COUNT then
		state.spawnedZoneIndices[zoneIndex] = true
		return
	end
	if #templates == 0 then
		return
	end

	local folder = createPlayerFolder(player, zoneIndex)
	state.folders[zoneIndex] = folder
	local placedPositions: { Vector3 } = {}
	local spawnedCount = 0

	for index, authoredPickup in definition.authoredPickups do
		local authoredMinionType = authoredPickup.prototype:GetAttribute(ATTRIBUTE.MinionType)
		local authoredMinionTemplate: Instance?
		if typeof(authoredMinionType) == "string" and authoredMinionType ~= "" then
			if not PlayerShopService.isMinionUnlocked(player, authoredMinionType) then
				continue
			end
			authoredMinionTemplate = findMinionTemplateByName(authoredMinionType)
		else
			authoredMinionTemplate = chooseRandomUnlockedTemplate(player, nil)
		end
		if authoredMinionTemplate == nil then
			continue
		end
		local pickup = authoredPickup.prototype:Clone()
		local root = GameplayUtil.getRoot(pickup)
		if root == nil then
			pickup:Destroy()
			warn("[MinionSpawnService] authored pickup clone lost its BasePart root")
			continue
		end
		for _, part in GameplayUtil.getParts(root) do
			part.Anchored = true
			part.CanCollide = false
			part.CanQuery = true
			part.CanTouch = true
			part.AssemblyLinearVelocity = Vector3.zero
			part.AssemblyAngularVelocity = Vector3.zero
		end
		root:PivotTo(authoredPickup.pivot)
		pickup.Name = "AuthoredMinionPickup_" .. index
		pickup:SetAttribute(ATTRIBUTE.MinionType, authoredMinionTemplate.Name)
		pickup:SetAttribute(ATTRIBUTE.Collected, false)
		assignPickupId(pickup)
		pickup:SetAttribute(ATTRIBUTE.SpawnOwnerUserId, player.UserId)
		pickup.Parent = folder
		CollectionService:AddTag(pickup, TAG.MinionPicker)
		table.insert(placedPositions, authoredPickup.pivot.Position)
		spawnedCount += 1
	end

	local randomSpawnCount = math.max(spawnCount - spawnedCount, 0)
	for randomIndex = 1, randomSpawnCount do
		if pickupTemplate == nil then
			break
		end
		local index = #definition.authoredPickups + randomIndex
		local minionTemplate = chooseRandomUnlockedTemplate(player, forcedPickupMinionTemplate)
		if minionTemplate == nil then
			break
		end
		local pickup = createPickup(minionTemplate, index)
		if pickup == nil then
			warn("[MinionSpawnService] unable to clone pickup template")
			break
		end
		local root = GameplayUtil.getRoot(pickup)
		if root == nil then
			warn("[MinionSpawnService] generated pickup lost its BasePart root")
			pickup:Destroy()
			continue
		end

		local spawnCFrame = chooseSpawnCFrame(root, definition.bounds, placedPositions)
		if spawnCFrame == nil then
			pickup:Destroy()
			warn("[MinionSpawnService] unable to find a free pickup spawn position", player)
			break
		end

		root:PivotTo(spawnCFrame)
		pickup:SetAttribute(ATTRIBUTE.Collected, false)
		assignPickupId(pickup)
		pickup:SetAttribute(ATTRIBUTE.SpawnOwnerUserId, player.UserId)
		pickup.Parent = folder
		CollectionService:AddTag(pickup, TAG.MinionPicker)
		table.insert(placedPositions, spawnCFrame.Position)
		spawnedCount += 1
	end

	if spawnedCount > 0 then
		state.spawnedZoneIndices[zoneIndex] = true
		player:SetAttribute(ATTRIBUTE.StatusMessage, "Minion pickups for Zone " .. zoneIndex .. " are ready!")
	else
		folder:Destroy()
		state.folders[zoneIndex] = nil
	end
end

local function preloadActiveAndUpcomingZones(player: Player, currentZoneIndex: number)
	for zoneIndex = currentZoneIndex, currentZoneIndex + 2 do
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
		cleanupSpawnedPickups(state)
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
			preloadActiveAndUpcomingZones(player, zoneIndex)
		end
	end))
	table.insert(state.connections, player:GetAttributeChangedSignal(ATTRIBUTE.ShopRevision):Connect(function()
		local zoneIndex = player:GetAttribute(ATTRIBUTE.CurrentGameZoneIndex)
		if typeof(zoneIndex) == "number" and zoneIndex == math.floor(zoneIndex) and zoneIndex >= 0 then
			preloadActiveAndUpcomingZones(player, zoneIndex)
		end
	end))
	table.insert(state.connections, player.CharacterRemoving:Connect(function()
		cleanupSpawnedPickups(state)
	end))
	table.insert(state.connections, player.CharacterAdded:Connect(function(character)
		bindCharacterDeath(state, character)
	end))
	if player.Character ~= nil then
		bindCharacterDeath(state, player.Character)
	end
	local zoneIndex = player:GetAttribute(ATTRIBUTE.CurrentGameZoneIndex)
	if typeof(zoneIndex) == "number" and zoneIndex == math.floor(zoneIndex) and zoneIndex >= 0 then
		preloadActiveAndUpcomingZones(player, zoneIndex)
	end
end

local function unbindPlayer(player: Player)
	local state = states[player]
	if state == nil then
		return
	end
	cleanupSpawnedPickups(state)
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
	cachePickupTemplate()
	cacheAuthoredPickups()

	for _, player in Players:GetPlayers() do
		bindPlayer(player)
	end
	Players.PlayerAdded:Connect(bindPlayer)
	Players.PlayerRemoving:Connect(unbindPlayer)

	print("[MinionSpawnService] started")
end

return MinionSpawnService
