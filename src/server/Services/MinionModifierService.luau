--!strict

-- Owns MinionModifier gameplay. Tag schema and ranges: Shared/MinionModifierConfig.
-- One use per player per character life. No-op operations also consume that use.
-- Bindings live until tag removal/destruction; player history is cleared on
-- CharacterRemoving/PlayerRemoving. Global connections live for the server session.

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local GameplayConfig = require(Shared:WaitForChild("GameplayConfig"))
local ModifierConfig = require(Shared:WaitForChild("MinionModifierConfig"))
local GameplayUtil = require(script.Parent:WaitForChild("GameplayUtil"))
local MinionService = require(script.Parent:WaitForChild("MinionService"))

type Binding = {
	part: BasePart,
	definition: ModifierConfig.Definition?,
	connections: { RBXScriptConnection },
	touchConnection: RBXScriptConnection?,
	used: { [Player]: boolean },
	lastAttempt: { [Player]: number },
}

local MinionModifierService = {}
local TAG = GameplayConfig.Tags.MinionModifier
local ATTRIBUTE = GameplayConfig.Attributes
local bindings: { [Instance]: Binding } = {}
local playerConnections: { [Player]: RBXScriptConnection } = {}
local started = false

local function refreshDefinition(binding: Binding)
	binding.definition = nil
	local part = binding.part
	if not part.Anchored or not part.CanTouch then
		warn("[MinionModifierService] MinionModifier requires Anchored and CanTouch", part)
		return
	end
	local definition, reason = ModifierConfig.read(part)
	if definition == nil then
		warn("[MinionModifierService] " .. (reason or "invalid configuration"), part)
		return
	end
	binding.definition = definition
end

local function onTouched(binding: Binding, touchedPart: BasePart)
	local part = binding.part
	local definition = binding.definition
	if bindings[part] ~= binding or definition == nil or not definition.enabled or not part.Anchored or not part.CanTouch
		or not part:IsDescendantOf(Workspace) or not CollectionService:HasTag(part, TAG)
	then
		return
	end
	local player, character, humanoid, rootPart = GameplayUtil.getCharacterFromTouch(touchedPart)
	if player == nil or player.Parent ~= Players or character == nil or player.Character ~= character
		or not character:IsDescendantOf(Workspace) or humanoid == nil or humanoid.Health <= 0
		or rootPart == nil or binding.used[player]
	then
		return
	end
	-- Distance to the oriented part bounds also works for wide and rotated gates.
	local position = part.CFrame:PointToObjectSpace(rootPart.Position)
	local half = part.Size / 2
	local outside = Vector3.new(
		math.max(math.abs(position.X) - half.X, 0),
		math.max(math.abs(position.Y) - half.Y, 0),
		math.max(math.abs(position.Z) - half.Z, 0)
	)
	if outside.Magnitude > ModifierConfig.TouchDistance then
		return
	end
	local now = os.clock()
	local lastAttempt = binding.lastAttempt[player]
	if lastAttempt ~= nil and now - lastAttempt < ModifierConfig.RetryCooldownSeconds then
		return
	end
	binding.lastAttempt[player] = now
	local before = MinionService.getFollowerCount(player)
	local target = ModifierConfig.getTargetCount(before, definition)
	local success, powerChange = if definition.operation == ModifierConfig.Operations.Multiply
		then MinionService.setFollowerCountFromCurrentComposition(player, target)
		else MinionService.setFollowerCount(player, target)
	if not success then
		return
	end
	binding.used[player] = true
	local powerText = if powerChange >= 0 then "+" .. math.floor(powerChange) else tostring(math.ceil(powerChange))
	player:SetAttribute(ATTRIBUTE.StatusMessage,
		"Minions " .. ModifierConfig.getLabel(definition) .. ": " .. before .. " → " .. target
			.. ", Power " .. powerText)
end

local function refresh(binding: Binding)
	-- CanTouch=false removes touch connections; reconnect when it becomes valid.
	-- Never subscribe while CanTouch is false, even for invalid authored parts.
	if binding.touchConnection ~= nil then
		binding.touchConnection:Disconnect()
		binding.touchConnection = nil
	end
	refreshDefinition(binding)
	local definition = binding.definition
	if definition ~= nil and definition.enabled and binding.part:IsDescendantOf(Workspace) then
		binding.touchConnection = binding.part.Touched:Connect(function(otherPart)
			onTouched(binding, otherPart)
		end)
	end
end

local function unbind(instance: Instance)
	local binding = bindings[instance]
	if binding == nil then
		return
	end
	bindings[instance] = nil
	for _, connection in binding.connections do
		connection:Disconnect()
	end
	if binding.touchConnection ~= nil then
		binding.touchConnection:Disconnect()
		binding.touchConnection = nil
	end
	table.clear(binding.used)
	table.clear(binding.lastAttempt)
end

local function bind(instance: Instance)
	if bindings[instance] ~= nil then
		return
	end
	if not instance:IsA("BasePart") then
		warn("[MinionModifierService] MinionModifier must be a BasePart", instance)
		return
	end
	local binding: Binding = {
		part = instance,
		definition = nil,
		connections = {},
		touchConnection = nil,
		used = {},
		lastAttempt = {},
	}
	bindings[instance] = binding
	refresh(binding)
	for _, name in { ATTRIBUTE.Operation, ATTRIBUTE.Operand, ATTRIBUTE.Enabled } do
		table.insert(binding.connections, instance:GetAttributeChangedSignal(name):Connect(function()
			refresh(binding)
		end))
	end
	for _, name in { "Anchored", "CanTouch" } do
		table.insert(binding.connections, instance:GetPropertyChangedSignal(name):Connect(function()
			refresh(binding)
		end))
	end
	table.insert(binding.connections, instance.AncestryChanged:Connect(function()
		if not instance:IsDescendantOf(game) then
			unbind(instance)
		else
			refresh(binding)
		end
	end))
	table.insert(binding.connections, instance.Destroying:Connect(function()
		unbind(instance)
	end))
end

local function clearPlayerHistory(player: Player)
	for _, binding in bindings do
		binding.used[player] = nil
		binding.lastAttempt[player] = nil
	end
end

local function bindPlayer(player: Player)
	if playerConnections[player] ~= nil then
		return
	end
	playerConnections[player] = player.CharacterRemoving:Connect(function()
		clearPlayerHistory(player)
	end)
end

function MinionModifierService.start()
	if started then
		return
	end
	started = true
	CollectionService:GetInstanceAddedSignal(TAG):Connect(bind)
	CollectionService:GetInstanceRemovedSignal(TAG):Connect(unbind)
	for _, instance in CollectionService:GetTagged(TAG) do
		bind(instance)
	end
	Players.PlayerAdded:Connect(bindPlayer)
	Players.PlayerRemoving:Connect(function(player)
		local connection = playerConnections[player]
		if connection ~= nil then
			connection:Disconnect()
			playerConnections[player] = nil
		end
		clearPlayerHistory(player)
	end)
	for _, player in Players:GetPlayers() do
		bindPlayer(player)
	end
end

return MinionModifierService
