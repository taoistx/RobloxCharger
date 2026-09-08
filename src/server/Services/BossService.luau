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

local function addThresholdDisplay(root: RootObject, requiredEnergy: number)
	local primaryPart = GameplayUtil.getPrimaryPart(root)
	local existing = primaryPart:FindFirstChild("EnergyThresholdDisplay")
	if existing ~= nil then
		existing:Destroy()
	end

	local billboard = Instance.new("BillboardGui")
	billboard.Name = "EnergyThresholdDisplay"
	billboard.Size = UDim2.fromOffset(150, 48)
	billboard.StudsOffsetWorldSpace = Vector3.new(0, 5, 0)
	billboard.AlwaysOnTop = true
	billboard.Adornee = primaryPart
	billboard.Parent = primaryPart

	local label = Instance.new("TextLabel")
	label.Size = UDim2.fromScale(1, 1)
	label.BackgroundColor3 = Color3.fromRGB(52, 15, 18)
	label.BackgroundTransparency = 0.2
	label.TextColor3 = Color3.fromRGB(255, 228, 80)
	label.Font = Enum.Font.GothamBlack
	label.TextScaled = true
	label.Text = "需要 " .. math.floor(requiredEnergy) .. " 能量"
	label.Parent = billboard

	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 8)
	corner.Parent = label
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
	local state = playerStates[binding.owner]
	if state ~= nil then
		state.bosses[instance] = nil
	end
end

local function defeatBoss(instance: Instance, binding: Binding, player: Player)
	binding.defeated = true
	instance:SetAttribute(ATTRIBUTE.Defeated, true)
	local releasedCount = MinionService.releaseEnergyFollowers(player, binding.requiredEnergy)
	local primaryPart = GameplayUtil.getPrimaryPart(binding.root)
	local remote = feedbackRemote
	if remote ~= nil then
		remote:FireClient(player, GameplayUtil.getPivot(binding.root), primaryPart.Color)
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

local function onBossTouched(instance: Instance, touchedPart: BasePart)
	local binding = bindings[instance]
	if binding == nil or binding.defeated then
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
	if (GameplayUtil.getPivot(binding.root).Position - rootPart.Position).Magnitude > 15 then
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
	for _, part in GameplayUtil.getParts(root) do
		part.CanCollide = false
		part.CanTouch = true
	end
	addThresholdDisplay(root, requiredEnergy)
	local binding: Binding = {
		root = root,
		requiredEnergy = requiredEnergy,
		owner = owner,
		defeated = false,
		lastContactTime = 0,
		connections = {},
	}
	bindings[instance] = binding
	state.bosses[instance] = true
	for _, part in GameplayUtil.getParts(root) do
		table.insert(binding.connections, part.Touched:Connect(function(otherPart)
			onBossTouched(instance, otherPart)
		end))
	end
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
