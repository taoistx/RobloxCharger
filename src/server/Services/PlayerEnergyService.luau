--!strict

--[[
	Owns player energy and `GameZone` areas.
	GameZone tag: BasePart or Model (a Model must contain a BasePart).
	Required attributes: ZoneIndex: integer in the range 0..1,000,000.
	Optional attributes owned here: none. ForcedRunService separately reads the
	ForcedRunSpeed and ForcedRunDirection attributes from the same GameZone.
	The tagged object's bounding box is the playable charging area.
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local CollectionService = game:GetService("CollectionService")

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local GameplayConfig = require(Shared:WaitForChild("GameplayConfig"))
local GameplayUtil = require(script.Parent:WaitForChild("GameplayUtil"))
local PlayerProgressionService = require(script.Parent:WaitForChild("PlayerProgressionService"))

type PlayerState = {
	character: Model?,
	humanoid: Humanoid?,
	rootPart: BasePart?,
	lastPosition: Vector3?,
	distanceUntilEnergyAward: number,
	playerConnections: { RBXScriptConnection },
	characterConnections: { RBXScriptConnection },
}

local PlayerEnergyService = {}

local TAG = GameplayConfig.Tags.GameZone
local ATTRIBUTE = GameplayConfig.Attributes
local states: { [Player]: PlayerState } = {}
local zones: { [Instance]: number } = {}
local started = false

local function getLevel(player: Player): number
	local level = player:GetAttribute(ATTRIBUTE.PlayerLevel)
	if typeof(level) ~= "number" then
		return GameplayConfig.Defaults.PlayerLevel
	end
	return math.clamp(math.floor(level), 1, GameplayConfig.Limits.MaxPlayerLevel)
end

local function setCapacity(player: Player): number
	local capacity = GameplayConfig.getCapacityForLevel(getLevel(player))
	player:SetAttribute(ATTRIBUTE.EnergyCapacity, capacity)
	return capacity
end

local function getCapacity(player: Player): number
	local capacity = player:GetAttribute(ATTRIBUTE.EnergyCapacity)
	if typeof(capacity) == "number" and capacity > 0 then
		return capacity
	end
	return setCapacity(player)
end

local function getEnergy(player: Player): number
	local energy = player:GetAttribute(ATTRIBUTE.CurrentEnergy)
	if typeof(energy) ~= "number" then
		return 0
	end
	return math.max(0, energy)
end

local function isPointInsideZone(zone: Instance, point: Vector3): boolean
	local root = GameplayUtil.getRoot(zone)
	if root == nil then
		return false
	end

	local boxCFrame: CFrame
	local boxSize: Vector3
	if root:IsA("BasePart") then
		boxCFrame = root.CFrame
		boxSize = root.Size
	else
		boxCFrame, boxSize = root:GetBoundingBox()
	end

	local localPoint = boxCFrame:PointToObjectSpace(point)
	return math.abs(localPoint.X) <= boxSize.X * 0.5
		and math.abs(localPoint.Y) <= boxSize.Y * 0.5 + 8
		and math.abs(localPoint.Z) <= boxSize.Z * 0.5
end

local function getZoneIndex(zone: Instance): number?
	local zoneIndex = zone:GetAttribute(ATTRIBUTE.ZoneIndex)
	if typeof(zoneIndex) ~= "number"
		or zoneIndex ~= math.floor(zoneIndex)
		or zoneIndex < 0
		or zoneIndex > GameplayConfig.Limits.MaxGameZoneIndex
	then
		return nil
	end
	return zoneIndex
end

local function getZoneIndexAtPoint(point: Vector3): number?
	for zone, zoneIndex in zones do
		if zone:IsDescendantOf(game) and isPointInsideZone(zone, point) then
			return zoneIndex
		end
	end
	return nil
end

local function clearCharacterState(state: PlayerState)
	for _, connection in state.characterConnections do
		connection:Disconnect()
	end
	table.clear(state.characterConnections)
	state.character = nil
	state.humanoid = nil
	state.rootPart = nil
	state.lastPosition = nil
	state.distanceUntilEnergyAward = GameplayConfig.Defaults.DistancePerEnergyAward
end

local function onCharacterAdded(player: Player, character: Model)
	local state = states[player]
	if state == nil then
		return
	end

	clearCharacterState(state)
	local humanoid = character:WaitForChild("Humanoid", 10)
	local rootPart = character:WaitForChild("HumanoidRootPart", 10)
	if not humanoid or not humanoid:IsA("Humanoid") or not rootPart or not rootPart:IsA("BasePart") then
		warn("[PlayerEnergyService] character missing Humanoid or HumanoidRootPart", player)
		return
	end

	state.character = character
	state.humanoid = humanoid
	state.rootPart = rootPart
	state.lastPosition = rootPart.Position
	state.distanceUntilEnergyAward = GameplayConfig.Defaults.DistancePerEnergyAward
	PlayerEnergyService.setEnergy(player, 0)
	player:SetAttribute(ATTRIBUTE.IsInGameZone, false)
	player:SetAttribute(ATTRIBUTE.CurrentGameZoneIndex, nil)
	player:SetAttribute(ATTRIBUTE.BossImpactSequence, 0)
	table.insert(state.characterConnections, humanoid.Died:Connect(function()
		PlayerEnergyService.setEnergy(player, 0)
		player:SetAttribute(ATTRIBUTE.IsInGameZone, false)
		player:SetAttribute(ATTRIBUTE.CurrentGameZoneIndex, nil)
	end))
end

local function bindPlayer(player: Player)
	if states[player] ~= nil then
		return
	end

	local state: PlayerState = {
		character = nil,
		humanoid = nil,
		rootPart = nil,
		lastPosition = nil,
		distanceUntilEnergyAward = GameplayConfig.Defaults.DistancePerEnergyAward,
		playerConnections = {},
		characterConnections = {},
	}
	states[player] = state
	player:SetAttribute(ATTRIBUTE.PlayerLevel, getLevel(player))
	setCapacity(player)
	PlayerEnergyService.setEnergy(player, 0)
	player:SetAttribute(ATTRIBUTE.IsInGameZone, false)
	player:SetAttribute(ATTRIBUTE.CurrentGameZoneIndex, nil)
	table.insert(state.playerConnections, player:GetAttributeChangedSignal(ATTRIBUTE.PlayerLevel):Connect(function()
		local capacity = setCapacity(player)
		PlayerEnergyService.setEnergy(player, math.min(getEnergy(player), capacity))
	end))
	table.insert(state.playerConnections, player.CharacterAdded:Connect(function(character)
		onCharacterAdded(player, character)
	end))
	if player.Character ~= nil then
		task.spawn(onCharacterAdded, player, player.Character)
	end
end

local function unbindPlayer(player: Player)
	local state = states[player]
	if state == nil then
		return
	end
	clearCharacterState(state)
	for _, connection in state.playerConnections do
		connection:Disconnect()
	end
	table.clear(state.playerConnections)
	states[player] = nil
end

local function bindZone(instance: Instance)
	if zones[instance] then
		return
	end
	if GameplayUtil.getRoot(instance) == nil then
		warn("[PlayerEnergyService] GameZone must be a BasePart or Model containing a BasePart", instance)
		return
	end
	local zoneIndex = getZoneIndex(instance)
	if zoneIndex == nil then
		warn("[PlayerEnergyService] GameZone requires ZoneIndex as an integer between 0 and " .. GameplayConfig.Limits.MaxGameZoneIndex, instance)
		return
	end
	zones[instance] = zoneIndex
end

local function unbindZone(instance: Instance)
	zones[instance] = nil
end

function PlayerEnergyService.setEnergy(player: Player, value: number)
	local capacity = getCapacity(player)
	player:SetAttribute(ATTRIBUTE.CurrentEnergy, math.clamp(value, 0, capacity))
end

function PlayerEnergyService.addEnergy(player: Player, value: number): number
	if value <= 0 then
		return 0
	end
	local before = getEnergy(player)
	PlayerEnergyService.setEnergy(player, before + value)
	return getEnergy(player) - before
end

function PlayerEnergyService.removeEnergy(player: Player, value: number): number
	if value <= 0 then
		return 0
	end
	local before = getEnergy(player)
	PlayerEnergyService.setEnergy(player, before - value)
	return before - getEnergy(player)
end

function PlayerEnergyService.spendEnergy(player: Player, value: number): boolean
	if value <= 0 then
		return true
	end
	local energy = getEnergy(player)
	if energy < value then
		return false
	end
	PlayerEnergyService.setEnergy(player, energy - value)
	return true
end

function PlayerEnergyService.isPlayerInGameZone(player: Player): boolean
	return player:GetAttribute(ATTRIBUTE.IsInGameZone) == true
end

local function awardEnergyForRunningDistance(player: Player, state: PlayerState, distance: number)
	local distancePerAward = math.max(0.001, GameplayConfig.Defaults.DistancePerEnergyAward)
	state.distanceUntilEnergyAward -= distance
	if state.distanceUntilEnergyAward > 0 then
		return
	end

	local awardCount = 1 + math.floor(-state.distanceUntilEnergyAward / distancePerAward)
	state.distanceUntilEnergyAward += awardCount * distancePerAward
	PlayerEnergyService.addEnergy(player, awardCount * distancePerAward * GameplayConfig.Defaults.EnergyPerStud)
end

function PlayerEnergyService.start()
	if started then
		return
	end
	started = true

	for _, zone in CollectionService:GetTagged(TAG) do
		bindZone(zone)
	end
	CollectionService:GetInstanceAddedSignal(TAG):Connect(bindZone)
	CollectionService:GetInstanceRemovedSignal(TAG):Connect(unbindZone)

	for _, player in Players:GetPlayers() do
		bindPlayer(player)
	end
	Players.PlayerAdded:Connect(bindPlayer)
	Players.PlayerRemoving:Connect(unbindPlayer)

	RunService.Heartbeat:Connect(function(deltaTime)
		for player, state in states do
			local rootPart = state.rootPart
			local humanoid = state.humanoid
			if rootPart == nil or humanoid == nil or humanoid.Health <= 0 then
				continue
			end

			local position = rootPart.Position
			local zoneIndex = getZoneIndexAtPoint(position)
			local inZone = zoneIndex ~= nil
			player:SetAttribute(ATTRIBUTE.IsInGameZone, inZone)
			player:SetAttribute(ATTRIBUTE.CurrentGameZoneIndex, zoneIndex)
			local previousPosition = state.lastPosition
			state.lastPosition = position
			if not inZone or previousPosition == nil then
				continue
			end

			local distance = math.min((position - previousPosition).Magnitude, 32 * deltaTime)
			local isRunning = humanoid.MoveDirection.Magnitude >= 0.05 and distance > 0.01
			if isRunning then
				awardEnergyForRunningDistance(player, state, distance)
				PlayerProgressionService.addRunningDistance(player, distance)
			else
				PlayerEnergyService.spendEnergy(player, GameplayConfig.Defaults.IdleEnergyDrainPerSecond * deltaTime)
			end
		end
	end)

	print("[PlayerEnergyService] started")
end

return PlayerEnergyService
