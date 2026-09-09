--!strict

--[[
	Owns authoritative per-player `Boss` collision and lifecycle.
	Boss template tag: BasePart or Model (a Model must contain a BasePart) in Workspace.
	Required template attribute: RequiredEnergy: number in the range 1..1,000,000.
	Optional template attributes: none.
	Runtime attributes: BossOwnerUserId: the owning player's UserId;
		Defeated: boolean, defaults false.

	Tagged scene objects are templates. The service removes each template from the
	runtime DataModel and creates one independent clone for every player's current
	character. A player's clones are replaced only when that player respawns. There
	is no timed Boss respawn. Only the owning player can trigger a runtime clone.
]]

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local GameplayConfig = require(Shared:WaitForChild("GameplayConfig"))
local GameplayUtil = require(script.Parent:WaitForChild("GameplayUtil"))
local PlayerEnergyService = require(script.Parent:WaitForChild("PlayerEnergyService"))
local MinionService = require(script.Parent:WaitForChild("MinionService"))

type RootObject = GameplayUtil.RootObject
type TemplateRecord = {
	template: Instance,
	parent: Instance,
}
type Binding = {
	connections: { RBXScriptConnection },
	partConnections: { [BasePart]: RBXScriptConnection },
	parts: { [BasePart]: boolean },
	root: RootObject,
	requiredEnergy: number,
	owner: Player,
	defeated: boolean,
	lastContactTime: number,
}
type PlayerState = {
	bosses: { [Instance]: boolean },
	connections: { RBXScriptConnection },
}

local BossService = {}

local TAG = GameplayConfig.Tags.Boss
local ATTRIBUTE = GameplayConfig.Attributes
local FEEDBACK_NAME = GameplayConfig.InstanceNames.BossDefeatFeedback
local TOUCH_VALIDATION_DISTANCE = GameplayConfig.Boss.TouchValidationDistance

local templates: { TemplateRecord } = {}
local bindings: { [Instance]: Binding } = {}
local playerStates: { [Player]: PlayerState } = {}
local feedbackRemote: RemoteEvent? = nil
local started = false

local function createFeedbackRemote(): RemoteEvent
	local existing = ReplicatedStorage:FindFirstChild(FEEDBACK_NAME)
	if existing ~= nil and not existing:IsA("RemoteEvent") then
		warn("[BossService] replacing incorrectly typed BossDefeatFeedback", existing)
		existing:Destroy()
		existing = nil
	end
	if existing ~= nil then
		return existing :: RemoteEvent
	end
	local remote = Instance.new("RemoteEvent")
	remote.Name = FEEDBACK_NAME
	remote.Parent = ReplicatedStorage
	return remote
end

local function getRequiredEnergy(instance: Instance): number?
	local requiredEnergy = instance:GetAttribute(ATTRIBUTE.RequiredEnergy)
	if typeof(requiredEnergy) ~= "number"
		or requiredEnergy ~= requiredEnergy
		or requiredEnergy < 1
		or requiredEnergy > GameplayConfig.Limits.MaxBossRequiredEnergy
	then
		warn(
			"[BossService] Boss requires RequiredEnergy between 1 and "
				.. GameplayConfig.Limits.MaxBossRequiredEnergy,
			instance
		)
		return nil
	end
	return requiredEnergy
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
	for _, connection in binding.partConnections do
		connection:Disconnect()
	end
	table.clear(binding.partConnections)
	table.clear(binding.parts)
	local state = playerStates[binding.owner]
	if state ~= nil then
		state.bosses[instance] = nil
	end
end

local function defeatBoss(instance: Instance, binding: Binding, player: Player)
	binding.defeated = true
	instance:SetAttribute(ATTRIBUTE.Defeated, true)
	local releasedCount = MinionService.releaseEnergyFollowers(player, binding.requiredEnergy)
	local boundsCFrame: CFrame
	local boundsSize: Vector3
	if binding.root:IsA("BasePart") then
		boundsCFrame = binding.root.CFrame
		boundsSize = binding.root.Size
	else
		boundsCFrame, boundsSize = binding.root:GetBoundingBox()
	end
	local remote = feedbackRemote
	if remote ~= nil then
		remote:FireClient(player, boundsCFrame, boundsSize)
	end
	player:SetAttribute(
		ATTRIBUTE.StatusMessage,
		"Boss 击败！消耗 "
			.. math.floor(binding.requiredEnergy)
			.. " 能量，"
			.. releasedCount
			.. " 个小兵被撞飞。"
	)
	instance:Destroy()
end

local function distanceToPartBounds(part: BasePart, worldPosition: Vector3): number
	local localPosition = part.CFrame:PointToObjectSpace(worldPosition)
	local half = part.Size / 2
	local outside = Vector3.new(
		math.max(math.abs(localPosition.X) - half.X, 0),
		math.max(math.abs(localPosition.Y) - half.Y, 0),
		math.max(math.abs(localPosition.Z) - half.Z, 0)
	)
	return outside.Magnitude
end

local function onBossTouched(instance: Instance, bossPart: BasePart, touchedPart: BasePart)
	local binding = bindings[instance]
	if binding == nil
		or binding.defeated
		or not binding.parts[bossPart]
		or not bossPart.CanTouch
		or (bossPart ~= instance and not bossPart:IsDescendantOf(instance))
	then
		return
	end
	local player, character, humanoid, rootPart = GameplayUtil.getCharacterFromTouch(touchedPart)
	if player ~= binding.owner
		or player.Character ~= character
		or humanoid == nil
		or rootPart == nil
		or humanoid.Health <= 0
	then
		return
	end
	-- Validate against the actual touched part bounds rather than the Boss pivot.
	-- This remains correct for very large parts and models with distant children.
	if distanceToPartBounds(bossPart, rootPart.Position) > TOUCH_VALIDATION_DISTANCE then
		return
	end

	local now = os.clock()
	if binding.lastContactTime + 1 > now then
		return
	end
	binding.lastContactTime = now

	if not PlayerEnergyService.spendEnergy(player, binding.requiredEnergy) then
		player:SetAttribute(
			ATTRIBUTE.StatusMessage,
			"能量不足（需要 " .. math.floor(binding.requiredEnergy) .. "），被 Boss 击败！"
		)
		humanoid.Health = 0
		return
	end

	local impactSequence = player:GetAttribute(ATTRIBUTE.BossImpactSequence)
	player:SetAttribute(
		ATTRIBUTE.BossImpactSequence,
		(if typeof(impactSequence) == "number" then impactSequence else 0) + 1
	)
	defeatBoss(instance, binding, player)
	local remainingEnergy = player:GetAttribute(ATTRIBUTE.CurrentEnergy)
	if typeof(remainingEnergy) == "number" and remainingEnergy <= 0 then
		player:SetAttribute(ATTRIBUTE.StatusMessage, "能量刚好耗尽：Boss 已粉碎，但你也倒下了！")
		humanoid.Health = 0
	end
end

local function bindRuntimeBoss(instance: Instance)
	if bindings[instance] ~= nil then
		return
	end
	local ownerUserId = instance:GetAttribute(ATTRIBUTE.BossOwnerUserId)
	if typeof(ownerUserId) ~= "number" or ownerUserId ~= math.floor(ownerUserId) then
		warn("[BossService] runtime Boss requires an integer BossOwnerUserId", instance)
		return
	end
	local owner = Players:GetPlayerByUserId(ownerUserId)
	local state = if owner ~= nil then playerStates[owner] else nil
	if owner == nil or state == nil then
		instance:Destroy()
		return
	end
	local root = GameplayUtil.getRoot(instance)
	local requiredEnergy = getRequiredEnergy(instance)
	if root == nil or requiredEnergy == nil or not instance:IsDescendantOf(Workspace) then
		if root == nil then
			warn("[BossService] Boss must be a BasePart or Model containing a BasePart", instance)
		end
		instance:Destroy()
		return
	end

	instance:SetAttribute(ATTRIBUTE.Defeated, false)
	local binding: Binding = {
		root = root,
		requiredEnergy = requiredEnergy,
		owner = owner,
		defeated = false,
		lastContactTime = -math.huge,
		connections = {},
		partConnections = {},
		parts = {},
	}
	bindings[instance] = binding
	state.bosses[instance] = true

	local function bindPart(part: BasePart)
		if bindings[instance] ~= binding or binding.partConnections[part] ~= nil then
			return
		end
		part.CanCollide = false
		part.CanTouch = true
		binding.parts[part] = true
		binding.partConnections[part] = part.Touched:Connect(function(otherPart)
			onBossTouched(instance, part, otherPart)
		end)
	end
	local function unbindPart(part: BasePart)
		binding.parts[part] = nil
		local connection = binding.partConnections[part]
		if connection ~= nil then
			connection:Disconnect()
			binding.partConnections[part] = nil
		end
	end
	for _, part in GameplayUtil.getParts(root) do
		bindPart(part)
	end
	table.insert(binding.connections, instance.DescendantAdded:Connect(function(descendant)
		if descendant:IsA("BasePart") then
			bindPart(descendant)
		end
	end))
	table.insert(binding.connections, instance.DescendantRemoving:Connect(function(descendant)
		if descendant:IsA("BasePart") then
			unbindPart(descendant)
		end
	end))
	table.insert(binding.connections, instance.Destroying:Connect(function()
		unbind(instance)
	end))
end

local function spawnTemplateForPlayer(record: TemplateRecord, player: Player)
	local state = playerStates[player]
	local character = player.Character
	if state == nil or character == nil or not character:IsDescendantOf(Workspace) then
		return
	end
	if record.parent.Parent == nil then
		return
	end
	local clone = record.template:Clone()
	clone:SetAttribute(ATTRIBUTE.BossOwnerUserId, player.UserId)
	clone:SetAttribute(ATTRIBUTE.Defeated, false)
	clone.Parent = record.parent
	CollectionService:AddTag(clone, TAG)
	bindRuntimeBoss(clone)
end

local function clearPlayerBosses(player: Player)
	local state = playerStates[player]
	if state == nil then
		return
	end
	local bosses = {}
	for boss in state.bosses do
		table.insert(bosses, boss)
	end
	for _, boss in bosses do
		if boss.Parent ~= nil then
			boss:Destroy()
		else
			unbind(boss)
		end
	end
	table.clear(state.bosses)
end

local function spawnAllBossesForCharacter(player: Player, character: Model)
	if player.Character ~= character or not character:IsDescendantOf(Workspace) then
		return
	end
	clearPlayerBosses(player)
	for _, record in templates do
		spawnTemplateForPlayer(record, player)
	end
end

local function registerTemplate(instance: Instance)
	if instance:GetAttribute(ATTRIBUTE.BossOwnerUserId) ~= nil then
		bindRuntimeBoss(instance)
		return
	end
	if not instance.Archivable then
		warn("[BossService] Boss template must be Archivable", instance)
		return
	end
	if GameplayUtil.getRoot(instance) == nil or getRequiredEnergy(instance) == nil then
		warn("[BossService] invalid Boss template", instance)
		return
	end
	local parent = instance.Parent
	if parent == nil or not instance:IsDescendantOf(Workspace) then
		warn("[BossService] Boss template must be inside Workspace", instance)
		return
	end

	CollectionService:RemoveTag(instance, TAG)
	instance.Parent = nil
	local record: TemplateRecord = {
		template = instance,
		parent = parent,
	}
	table.insert(templates, record)
	for player in playerStates do
		spawnTemplateForPlayer(record, player)
	end
end

local function bindPlayer(player: Player)
	if playerStates[player] ~= nil then
		return
	end
	local state: PlayerState = {
		bosses = {},
		connections = {},
	}
	playerStates[player] = state
	table.insert(state.connections, player.CharacterAdded:Connect(function(character)
		task.defer(spawnAllBossesForCharacter, player, character)
	end))
	table.insert(state.connections, player.CharacterRemoving:Connect(function()
		clearPlayerBosses(player)
	end))
	if player.Character ~= nil then
		task.defer(spawnAllBossesForCharacter, player, player.Character)
	end
end

local function unbindPlayer(player: Player)
	local state = playerStates[player]
	if state == nil then
		return
	end
	clearPlayerBosses(player)
	for _, connection in state.connections do
		connection:Disconnect()
	end
	playerStates[player] = nil
end

function BossService.start()
	if started then
		return
	end
	started = true
	feedbackRemote = createFeedbackRemote()

	local authoredTemplates = CollectionService:GetTagged(TAG)
	for _, instance in authoredTemplates do
		registerTemplate(instance)
	end
	CollectionService:GetInstanceAddedSignal(TAG):Connect(registerTemplate)
	CollectionService:GetInstanceRemovedSignal(TAG):Connect(unbind)

	for _, player in Players:GetPlayers() do
		bindPlayer(player)
	end
	Players.PlayerAdded:Connect(bindPlayer)
	Players.PlayerRemoving:Connect(unbindPlayer)

	print("[BossService] started")
end

return BossService
