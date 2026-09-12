--!strict

--[[
	Owns player-specific randomized minion modifier groups.
	RandomMinionModifierGroup tag: a Model in Workspace.
	Every direct BasePart child is a selectable slot. A group requires at least two
	slots; every slot must be Anchored and CanTouch. No attributes are required.
	Assignments and one-choice history are scoped to the player's current character.
]]

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local GameplayConfig = require(Shared:WaitForChild("GameplayConfig"))
local ModifierConfig = require(Shared:WaitForChild("MinionModifierConfig"))
local GameplayUtil = require(script.Parent:WaitForChild("GameplayUtil"))
local MinionService = require(script.Parent:WaitForChild("MinionService"))
local PlayerEnergyService = require(script.Parent:WaitForChild("PlayerEnergyService"))

type Assignment = { [BasePart]: ModifierConfig.Definition }
type GroupBinding = {
	model: Model,
	slots: { BasePart },
	slotSet: { [BasePart]: boolean },
	valid: boolean,
	validationError: string?,
	connections: { RBXScriptConnection },
	slotConnections: { RBXScriptConnection },
}
type PlayerState = {
	character: Model?,
	assignments: { [Model]: Assignment },
	consumed: { [Model]: boolean },
	lastAttempts: { [Model]: number },
	lastRequests: { [Model]: number },
	connections: { RBXScriptConnection },
}

local RandomMinionModifierGroupService = {}
local TAG = GameplayConfig.Tags.RandomMinionModifierGroup
local ATTRIBUTE = GameplayConfig.Attributes
local random = Random.new()
local bindings: { [Model]: GroupBinding } = {}
local playerStates: { [Player]: PlayerState } = {}
local assignmentRemote: RemoteFunction? = nil
local updateRemote: RemoteEvent? = nil
local started = false

local function createAssignmentRemote(): RemoteFunction
	local name = GameplayConfig.InstanceNames.RandomMinionModifierAssignment
	local existing = ReplicatedStorage:FindFirstChild(name)
	if existing ~= nil and not existing:IsA("RemoteFunction") then
		warn("[RandomMinionModifierGroupService] replacing incorrectly typed remote", existing)
		existing:Destroy()
		existing = nil
	end
	if existing ~= nil then
		return existing :: RemoteFunction
	end
	local remote = Instance.new("RemoteFunction")
	remote.Name = name
	remote.Parent = ReplicatedStorage
	return remote
end

local function createUpdateRemote(): RemoteEvent
	local name = GameplayConfig.InstanceNames.RandomMinionModifierUpdate
	local existing = ReplicatedStorage:FindFirstChild(name)
	if existing ~= nil and not existing:IsA("RemoteEvent") then
		warn("[RandomMinionModifierGroupService] replacing incorrectly typed remote", existing)
		existing:Destroy()
		existing = nil
	end
	if existing ~= nil then
		return existing :: RemoteEvent
	end
	local remote = Instance.new("RemoteEvent")
	remote.Name = name
	remote.Parent = ReplicatedStorage
	return remote
end

local function sameSlots(left: { BasePart }, right: { BasePart }): boolean
	if #left ~= #right then
		return false
	end
	for index, part in left do
		if right[index] ~= part then
			return false
		end
	end
	return true
end

local function collectSlots(model: Model): ({ BasePart }, string?)
	if not model:IsDescendantOf(Workspace) then
		return {}, "RandomMinionModifierGroup must be inside Workspace"
	end
	local slots: { BasePart } = {}
	for _, child in model:GetChildren() do
		if child:IsA("BasePart") then
			table.insert(slots, child)
		end
	end
	local pivot = model:GetPivot()
	table.sort(slots, function(left, right)
		local leftX = pivot:PointToObjectSpace(left.Position).X
		local rightX = pivot:PointToObjectSpace(right.Position).X
		if leftX == rightX then
			return left.Name < right.Name
		end
		return leftX < rightX
	end)
	if #slots < 2 then
		return slots, "RandomMinionModifierGroup requires at least two direct BasePart children"
	end
	for _, slot in slots do
		if not slot.Anchored or not slot.CanTouch then
			return slots, "every direct BasePart slot must be Anchored and CanTouch"
		end
		if CollectionService:HasTag(slot, GameplayConfig.Tags.MinionModifier) then
			return slots, "random group slots must not also have the MinionModifier tag"
		end
	end
	return slots, nil
end

local function ensureAssignment(state: PlayerState, binding: GroupBinding): Assignment?
	if not binding.valid or state.character == nil then
		return nil
	end
	local existing = state.assignments[binding.model]
	if existing ~= nil then
		return existing
	end
	local definitions = ModifierConfig.generateRandomGroupDefinitions(#binding.slots, random)
	if #definitions ~= #binding.slots then
		return nil
	end
	local assignment: Assignment = {}
	for index, slot in binding.slots do
		assignment[slot] = definitions[index]
	end
	state.assignments[binding.model] = assignment
	return assignment
end

local function resetCharacterState(state: PlayerState, character: Model?)
	state.character = character
	table.clear(state.assignments)
	table.clear(state.consumed)
	table.clear(state.lastAttempts)
	table.clear(state.lastRequests)
	if character ~= nil then
		for _, binding in bindings do
			ensureAssignment(state, binding)
		end
	end
end

local function ensureCurrentCharacterState(player: Player): PlayerState?
	local state = playerStates[player]
	local character = player.Character
	if state == nil or character == nil or not character:IsDescendantOf(Workspace) then
		return nil
	end
	if state.character ~= character then
		resetCharacterState(state, character)
	end
	return state
end

local function onSlotTouched(binding: GroupBinding, slot: BasePart, touchedPart: BasePart)
	if bindings[binding.model] ~= binding or not binding.valid or not binding.slotSet[slot]
		or not binding.model:IsDescendantOf(Workspace)
		or not CollectionService:HasTag(binding.model, TAG)
		or not slot.Anchored or not slot.CanTouch
	then
		return
	end

	local player, character, humanoid, rootPart = GameplayUtil.getCharacterFromTouch(touchedPart)
	if player == nil or player.Parent ~= Players or character == nil or player.Character ~= character
		or humanoid == nil or humanoid.Health <= 0 or rootPart == nil
		or not character:IsDescendantOf(Workspace)
		or not PlayerEnergyService.isPlayerInGameZone(player)
	then
		return
	end
	local state = ensureCurrentCharacterState(player)
	if state == nil or state.character ~= character or state.consumed[binding.model] then
		return
	end

	local localPosition = slot.CFrame:PointToObjectSpace(rootPart.Position)
	local half = slot.Size / 2
	local outside = Vector3.new(
		math.max(math.abs(localPosition.X) - half.X, 0),
		math.max(math.abs(localPosition.Y) - half.Y, 0),
		math.max(math.abs(localPosition.Z) - half.Z, 0)
	)
	if outside.Magnitude > ModifierConfig.TouchDistance then
		return
	end

	local now = os.clock()
	local lastAttempt = state.lastAttempts[binding.model]
	if lastAttempt ~= nil and now - lastAttempt < ModifierConfig.RetryCooldownSeconds then
		return
	end
	state.lastAttempts[binding.model] = now

	local assignment = ensureAssignment(state, binding)
	local definition = if assignment ~= nil then assignment[slot] else nil
	if definition == nil then
		return
	end
	local before = MinionService.getFollowerCount(player)
	local target = ModifierConfig.getTargetCount(before, definition)
	local success, powerChange = if definition.operation == ModifierConfig.Operations.Multiply
		then MinionService.setFollowerCountFromCurrentComposition(player, target)
		else MinionService.setFollowerCount(player, target)
	if not success then
		return
	end

	state.consumed[binding.model] = true
	local powerText = if powerChange >= 0 then "+" .. math.floor(powerChange) else tostring(math.ceil(powerChange))
	player:SetAttribute(
		ATTRIBUTE.StatusMessage,
		"Minions " .. ModifierConfig.getLabel(definition) .. ": " .. before .. " → " .. target .. ", Power " .. powerText
	)
	local remote = updateRemote
	if remote ~= nil then
		remote:FireClient(player, binding.model, character, true)
	end
end

local function clearSlotConnections(binding: GroupBinding)
	for _, connection in binding.slotConnections do
		connection:Disconnect()
	end
	table.clear(binding.slotConnections)
end

local function refreshGroup(binding: GroupBinding, notifyPlayers: boolean)
	if bindings[binding.model] ~= binding then
		return
	end
	clearSlotConnections(binding)
	local previousSlots = binding.slots
	local previousValid = binding.valid
	local slots, reason = collectSlots(binding.model)
	local slotsChanged = not sameSlots(previousSlots, slots)
	binding.slots = slots
	binding.slotSet = {}
	binding.valid = reason == nil
	for _, slot in slots do
		binding.slotSet[slot] = true
		table.insert(binding.slotConnections, slot:GetPropertyChangedSignal("Anchored"):Connect(function()
			refreshGroup(binding, true)
		end))
		table.insert(binding.slotConnections, slot:GetPropertyChangedSignal("CanTouch"):Connect(function()
			refreshGroup(binding, true)
		end))
		if binding.valid then
			table.insert(binding.slotConnections, slot.Touched:Connect(function(otherPart)
				onSlotTouched(binding, slot, otherPart)
			end))
		end
	end

	if reason ~= binding.validationError then
		binding.validationError = reason
		if reason ~= nil then
			warn("[RandomMinionModifierGroupService] " .. reason, binding.model)
		end
	end

	if slotsChanged then
		for _, state in playerStates do
			state.assignments[binding.model] = nil
			state.lastRequests[binding.model] = nil
			ensureAssignment(state, binding)
		end
	end
	if notifyPlayers and (slotsChanged or previousValid ~= binding.valid) then
		local remote = updateRemote
		if remote ~= nil then
			for player, state in playerStates do
				local character = state.character
				if character ~= nil then
					remote:FireClient(player, binding.model, character, state.consumed[binding.model] == true)
				end
			end
		end
	end
end

local function unbindGroup(model: Model)
	local binding = bindings[model]
	if binding == nil then
		return
	end
	bindings[model] = nil
	for _, connection in binding.connections do
		connection:Disconnect()
	end
	clearSlotConnections(binding)
	for _, state in playerStates do
		state.assignments[model] = nil
		state.consumed[model] = nil
		state.lastAttempts[model] = nil
		state.lastRequests[model] = nil
	end
end

local function bindGroup(instance: Instance)
	if not instance:IsA("Model") then
		warn("[RandomMinionModifierGroupService] RandomMinionModifierGroup must be a Model", instance)
		return
	end
	if bindings[instance] ~= nil then
		return
	end
	local binding: GroupBinding = {
		model = instance,
		slots = {},
		slotSet = {},
		valid = false,
		validationError = nil,
		connections = {},
		slotConnections = {},
	}
	bindings[instance] = binding
	refreshGroup(binding, false)
	table.insert(binding.connections, instance.ChildAdded:Connect(function()
		task.defer(refreshGroup, binding, true)
	end))
	table.insert(binding.connections, instance.ChildRemoved:Connect(function()
		task.defer(refreshGroup, binding, true)
	end))
	table.insert(binding.connections, instance.AncestryChanged:Connect(function()
		task.defer(refreshGroup, binding, true)
	end))
	table.insert(binding.connections, instance.Destroying:Connect(function()
		unbindGroup(instance)
	end))
	for _, state in playerStates do
		ensureAssignment(state, binding)
	end
end

local function bindPlayer(player: Player)
	if playerStates[player] ~= nil then
		return
	end
	local state: PlayerState = {
		character = nil,
		assignments = {},
		consumed = {},
		lastAttempts = {},
		lastRequests = {},
		connections = {},
	}
	playerStates[player] = state
	table.insert(state.connections, player.CharacterAdded:Connect(function(character)
		resetCharacterState(state, character)
	end))
	table.insert(state.connections, player.CharacterRemoving:Connect(function(character)
		if state.character == character then
			resetCharacterState(state, nil)
		end
	end))
	if player.Character ~= nil then
		resetCharacterState(state, player.Character)
	end
end

local function unbindPlayer(player: Player)
	local state = playerStates[player]
	if state == nil then
		return
	end
	for _, connection in state.connections do
		connection:Disconnect()
	end
	resetCharacterState(state, nil)
	playerStates[player] = nil
end

local function getAssignmentPayload(player: Player, groupValue: unknown): any
	if typeof(groupValue) ~= "Instance" or not (groupValue :: Instance):IsA("Model") then
		return nil
	end
	local group = groupValue :: Model
	local binding = bindings[group]
	if binding == nil or not binding.valid or not group:IsDescendantOf(Workspace)
		or not CollectionService:HasTag(group, TAG)
	then
		return nil
	end
	local state = ensureCurrentCharacterState(player)
	if state == nil then
		return nil
	end
	local now = os.clock()
	local lastRequest = state.lastRequests[group]
	if lastRequest ~= nil and now - lastRequest < ModifierConfig.AssignmentRequestCooldownSeconds then
		return nil
	end
	state.lastRequests[group] = now
	local assignment = ensureAssignment(state, binding)
	if assignment == nil then
		return nil
	end
	local entries: { { part: BasePart, operation: string, operand: number } } = table.create(#binding.slots)
	for _, slot in binding.slots do
		local definition = assignment[slot]
		table.insert(entries, {
			part = slot,
			operation = definition.operation,
			operand = definition.operand,
		})
	end
	return {
		character = state.character,
		consumed = state.consumed[group] == true,
		entries = entries,
	}
end

function RandomMinionModifierGroupService.start()
	if started then
		return
	end
	started = true
	local remoteFunction = createAssignmentRemote()
	assignmentRemote = remoteFunction
	updateRemote = createUpdateRemote()
	remoteFunction.OnServerInvoke = getAssignmentPayload

	CollectionService:GetInstanceAddedSignal(TAG):Connect(bindGroup)
	CollectionService:GetInstanceRemovedSignal(TAG):Connect(function(instance)
		if instance:IsA("Model") then
			unbindGroup(instance)
		end
	end)
	for _, instance in CollectionService:GetTagged(TAG) do
		bindGroup(instance)
	end

	Players.PlayerAdded:Connect(bindPlayer)
	Players.PlayerRemoving:Connect(unbindPlayer)
	for _, player in Players:GetPlayers() do
		bindPlayer(player)
	end

	print("[RandomMinionModifierGroupService] started")
end

return RandomMinionModifierGroupService
