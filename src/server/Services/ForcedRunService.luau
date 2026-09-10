--!strict

--[[
	Owns authoritative forced forward movement for configured `GameZone` objects.
	GameZone tag: BasePart or Model (a Model must contain a BasePart) in Workspace.
	Required attribute: ZoneIndex: integer in the range 0..1,000,000.
	Optional attribute: ForcedRunSpeed: number greater than 0 and at most 200;
		missing or 0 disables forced running for the zone.
	Conditionally required attribute: ForcedRunDirection: Vector3 with a non-zero
		horizontal component when ForcedRunSpeed is enabled. Its Y component is ignored.

	A Line-mode LinearVelocity maintains only the configured forward component, so
	jumping, falling, and lateral movement remain available. Runtime constraints are
	removed on zone exit, character death/removal, player exit, or invalid config.
]]

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local GameplayConfig = require(Shared:WaitForChild("GameplayConfig"))
local GameplayUtil = require(script.Parent:WaitForChild("GameplayUtil"))

type ZoneBinding = {
	instance: Instance,
	zoneIndex: number?,
	speed: number?,
	direction: Vector3?,
	validationError: string?,
	connections: { RBXScriptConnection },
}

type PlayerState = {
	character: Model?,
	rootPart: BasePart?,
	attachment: Attachment?,
	velocity: LinearVelocity?,
	playerConnections: { RBXScriptConnection },
	characterConnections: { RBXScriptConnection },
}

local ForcedRunService = {}

local TAG = GameplayConfig.Tags.GameZone
local ATTRIBUTE = GameplayConfig.Attributes
local MAX_ZONE_INDEX = GameplayConfig.Limits.MaxGameZoneIndex
local MAX_SPEED = GameplayConfig.Limits.MaxForcedRunSpeed
local DIRECTION_EPSILON = 0.001

local zoneBindings: { [Instance]: ZoneBinding } = {}
local playerStates: { [Player]: PlayerState } = {}
local started = false

local function clearForce(player: Player, state: PlayerState)
	if state.velocity ~= nil then
		state.velocity:Destroy()
		state.velocity = nil
	end
	if state.attachment ~= nil then
		state.attachment:Destroy()
		state.attachment = nil
	end
	player:SetAttribute(ATTRIBUTE.ForcedRunActive, false)
end

local function readZoneConfig(instance: Instance): (number?, number?, Vector3?, string?)
	if GameplayUtil.getRoot(instance) == nil then
		return nil, nil, nil, "GameZone must be a BasePart or Model containing a BasePart"
	end
	if not instance:IsDescendantOf(Workspace) then
		return nil, nil, nil, "GameZone must be inside Workspace"
	end

	local zoneIndex = instance:GetAttribute(ATTRIBUTE.ZoneIndex)
	if typeof(zoneIndex) ~= "number"
		or zoneIndex ~= math.floor(zoneIndex)
		or zoneIndex < 0
		or zoneIndex > MAX_ZONE_INDEX
	then
		return nil, nil, nil, "GameZone requires ZoneIndex as an integer between 0 and " .. MAX_ZONE_INDEX
	end

	local speed = instance:GetAttribute(ATTRIBUTE.ForcedRunSpeed)
	if speed == nil or speed == 0 then
		return zoneIndex, nil, nil, nil
	end
	if typeof(speed) ~= "number" or speed ~= speed or speed < 0 or speed > MAX_SPEED then
		return zoneIndex, nil, nil, "ForcedRunSpeed must be 0 or a number greater than 0 and at most " .. MAX_SPEED
	end

	local directionValue = instance:GetAttribute(ATTRIBUTE.ForcedRunDirection)
	if typeof(directionValue) ~= "Vector3" then
		return zoneIndex, nil, nil, "ForcedRunDirection must be a Vector3 when ForcedRunSpeed is enabled"
	end
	local horizontalDirection = Vector3.new(directionValue.X, 0, directionValue.Z)
	if horizontalDirection.Magnitude < DIRECTION_EPSILON then
		return zoneIndex, nil, nil, "ForcedRunDirection requires a non-zero horizontal component"
	end

	return zoneIndex, speed, horizontalDirection.Unit, nil
end

local function getConfigForZoneIndex(zoneIndex: number): (number?, Vector3?)
	for _, binding in zoneBindings do
		if binding.zoneIndex == zoneIndex and binding.speed ~= nil and binding.direction ~= nil then
			return binding.speed, binding.direction
		end
	end
	return nil, nil
end

local function applyForce(player: Player)
	local state = playerStates[player]
	if state == nil then
		return
	end
	clearForce(player, state)

	local character = state.character
	local rootPart = state.rootPart
	local zoneIndex = player:GetAttribute(ATTRIBUTE.CurrentGameZoneIndex)
	if character == nil or rootPart == nil or player.Character ~= character
		or not character:IsDescendantOf(Workspace)
		or typeof(zoneIndex) ~= "number" or zoneIndex ~= math.floor(zoneIndex)
	then
		return
	end

	local speed, direction = getConfigForZoneIndex(zoneIndex)
	if speed == nil or direction == nil then
		return
	end

	local attachment = Instance.new("Attachment")
	attachment.Name = "ForcedRunAttachment"
	attachment.Parent = rootPart

	local velocity = Instance.new("LinearVelocity")
	velocity.Name = "ForcedRunVelocity"
	velocity.Attachment0 = attachment
	velocity.RelativeTo = Enum.ActuatorRelativeTo.World
	velocity.VelocityConstraintMode = Enum.VelocityConstraintMode.Line
	velocity.LineDirection = direction
	velocity.LineVelocity = speed
	velocity.ForceLimitsEnabled = false
	velocity.Parent = rootPart

	state.attachment = attachment
	state.velocity = velocity
	player:SetAttribute(ATTRIBUTE.ForcedRunActive, true)
end

local function refreshAllPlayers()
	for player in playerStates do
		applyForce(player)
	end
end

local function refreshZone(binding: ZoneBinding)
	local zoneIndex, speed, direction, reason = readZoneConfig(binding.instance)
	binding.zoneIndex = zoneIndex
	binding.speed = speed
	binding.direction = direction
	if reason ~= binding.validationError then
		binding.validationError = reason
		if reason ~= nil then
			warn("[ForcedRunService] " .. reason, binding.instance)
		end
	end
	refreshAllPlayers()
end

local function unbindZone(instance: Instance)
	local binding = zoneBindings[instance]
	if binding == nil then
		return
	end
	zoneBindings[instance] = nil
	for _, connection in binding.connections do
		connection:Disconnect()
	end
	refreshAllPlayers()
end

local function bindZone(instance: Instance)
	if zoneBindings[instance] ~= nil then
		return
	end
	local binding: ZoneBinding = {
		instance = instance,
		zoneIndex = nil,
		speed = nil,
		direction = nil,
		validationError = nil,
		connections = {},
	}
	zoneBindings[instance] = binding
	for _, attributeName in {
		ATTRIBUTE.ZoneIndex,
		ATTRIBUTE.ForcedRunSpeed,
		ATTRIBUTE.ForcedRunDirection,
	} do
		table.insert(binding.connections, instance:GetAttributeChangedSignal(attributeName):Connect(function()
			refreshZone(binding)
		end))
	end
	table.insert(binding.connections, instance.AncestryChanged:Connect(function()
		if not instance:IsDescendantOf(game) then
			unbindZone(instance)
		else
			refreshZone(binding)
		end
	end))
	table.insert(binding.connections, instance.Destroying:Connect(function()
		unbindZone(instance)
	end))
	refreshZone(binding)
end

local function clearCharacterState(player: Player, state: PlayerState)
	clearForce(player, state)
	for _, connection in state.characterConnections do
		connection:Disconnect()
	end
	table.clear(state.characterConnections)
	state.character = nil
	state.rootPart = nil
end

local function onCharacterAdded(player: Player, character: Model)
	local state = playerStates[player]
	if state == nil then
		return
	end
	clearCharacterState(player, state)
	state.character = character

	local humanoid = character:WaitForChild("Humanoid", 10)
	local rootPart = character:WaitForChild("HumanoidRootPart", 10)
	if playerStates[player] ~= state or state.character ~= character or player.Character ~= character then
		return
	end
	if humanoid == nil or not humanoid:IsA("Humanoid") or rootPart == nil or not rootPart:IsA("BasePart") then
		warn("[ForcedRunService] character missing Humanoid or HumanoidRootPart", player)
		return
	end

	state.rootPart = rootPart
	table.insert(state.characterConnections, humanoid.Died:Connect(function()
		clearForce(player, state)
	end))
	table.insert(state.characterConnections, character.AncestryChanged:Connect(function()
		if not character:IsDescendantOf(Workspace) then
			clearForce(player, state)
		end
	end))
	applyForce(player)
end

local function unbindPlayer(player: Player)
	local state = playerStates[player]
	if state == nil then
		return
	end
	clearCharacterState(player, state)
	for _, connection in state.playerConnections do
		connection:Disconnect()
	end
	table.clear(state.playerConnections)
	playerStates[player] = nil
end

local function bindPlayer(player: Player)
	if playerStates[player] ~= nil then
		return
	end
	local state: PlayerState = {
		character = nil,
		rootPart = nil,
		attachment = nil,
		velocity = nil,
		playerConnections = {},
		characterConnections = {},
	}
	playerStates[player] = state
	player:SetAttribute(ATTRIBUTE.ForcedRunActive, false)
	table.insert(state.playerConnections, player:GetAttributeChangedSignal(ATTRIBUTE.CurrentGameZoneIndex):Connect(function()
		applyForce(player)
	end))
	table.insert(state.playerConnections, player.CharacterAdded:Connect(function(character)
		task.spawn(onCharacterAdded, player, character)
	end))
	table.insert(state.playerConnections, player.CharacterRemoving:Connect(function(character)
		if state.character == character then
			clearCharacterState(player, state)
		end
	end))
	if player.Character ~= nil then
		task.spawn(onCharacterAdded, player, player.Character)
	end
end

function ForcedRunService.start()
	if started then
		return
	end
	started = true

	for _, instance in CollectionService:GetTagged(TAG) do
		bindZone(instance)
	end
	CollectionService:GetInstanceAddedSignal(TAG):Connect(bindZone)
	CollectionService:GetInstanceRemovedSignal(TAG):Connect(unbindZone)

	for _, player in Players:GetPlayers() do
		bindPlayer(player)
	end
	Players.PlayerAdded:Connect(bindPlayer)
	Players.PlayerRemoving:Connect(unbindPlayer)

	print("[ForcedRunService] started")
end

return ForcedRunService
