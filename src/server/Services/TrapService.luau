--!strict

--[[
	Owns authoritative `Trap` damage and static touch binding.
	Trap tag: BasePart or Model (a Model must contain a BasePart).
	Required attribute: EnergyDamage: number in the range 1..1,000,000.

	A Trap beneath a `SwingHammer` or `LinearMover` root is motion-controlled:
	its motion service calls tryTrigger() against the virtual trajectory, and this
	module deliberately does not bind Touched at the authored position.
]]

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local GameplayConfig = require(Shared:WaitForChild("GameplayConfig"))
local GameplayUtil = require(script.Parent:WaitForChild("GameplayUtil"))
local MinionService = require(script.Parent:WaitForChild("MinionService"))
local PlayerEnergyService = require(script.Parent:WaitForChild("PlayerEnergyService"))

export type Impact = {
	position: Vector3?,
	direction: Vector3?,
	speed: number?,
	upwardSpeed: number?,
}

type StaticBinding = {
	connections: { RBXScriptConnection },
}

local TrapService = {}

local TAG = GameplayConfig.Tags
local ATTRIBUTE = GameplayConfig.Attributes
local MAX_DAMAGE = GameplayConfig.Limits.MaxEnergyValue
local TOUCH_COOLDOWN_SECONDS = GameplayConfig.Defaults.TrapTouchCooldownSeconds

local staticBindings: { [Instance]: StaticBinding } = {}
local lastTriggeredAt: { [Instance]: { [Player]: number } } = {}
local started = false

local function getDamage(instance: Instance, shouldWarn: boolean): number?
	local damage = instance:GetAttribute(ATTRIBUTE.EnergyDamage)
	if typeof(damage) ~= "number" or damage ~= damage or damage < 1 or damage > MAX_DAMAGE then
		if shouldWarn then
			warn("[TrapService] Trap requires EnergyDamage between 1 and " .. MAX_DAMAGE, instance)
		end
		return nil
	end
	return damage
end

function TrapService.getDamage(instance: Instance): number?
	return getDamage(instance, true)
end

function TrapService.isMotionControlled(instance: Instance): boolean
	local current: Instance? = instance
	while current ~= nil and current ~= Workspace do
		if CollectionService:HasTag(current, TAG.SwingHammer) or CollectionService:HasTag(current, TAG.LinearMover) then
			return true
		end
		current = current.Parent
	end
	return false
end

local function getFallbackDirection(rootPart: BasePart, impactPosition: Vector3?): Vector3
	if impactPosition ~= nil then
		local away = rootPart.Position - impactPosition
		local horizontalAway = Vector3.new(away.X, 0, away.Z)
		if horizontalAway.Magnitude >= 0.001 then
			return horizontalAway.Unit
		end
	end
	return rootPart.CFrame.RightVector
end

local function applyImpact(rootPart: BasePart, impact: Impact)
	local rawDirection = impact.direction
	local direction: Vector3
	if rawDirection ~= nil then
		local horizontal = Vector3.new(rawDirection.X, 0, rawDirection.Z)
		if horizontal.Magnitude >= 0.001 then
			direction = horizontal.Unit
		else
			direction = getFallbackDirection(rootPart, impact.position)
		end
	else
		direction = getFallbackDirection(rootPart, impact.position)
	end

	rootPart.AssemblyLinearVelocity = direction * (impact.speed or 0)
		+ Vector3.new(0, impact.upwardSpeed or 0, 0)
end

function TrapService.tryTrigger(instance: Instance, player: Player, impact: Impact?): boolean
	if not CollectionService:HasTag(instance, TAG.Trap) then
		return false
	end

	local damage = getDamage(instance, false)
	local character = player.Character
	local humanoid = if character ~= nil then character:FindFirstChildOfClass("Humanoid") else nil
	local rootPart = if character ~= nil then character:FindFirstChild("HumanoidRootPart") else nil
	if damage == nil or humanoid == nil or humanoid.Health <= 0 or rootPart == nil or not rootPart:IsA("BasePart") then
		return false
	end

	local playerTimes = lastTriggeredAt[instance]
	if playerTimes == nil then
		playerTimes = {}
		lastTriggeredAt[instance] = playerTimes
	end
	local now = os.clock()
	local previousTime = playerTimes[player]
	if previousTime ~= nil and now - previousTime < TOUCH_COOLDOWN_SECONDS then
		return false
	end
	playerTimes[player] = now

	if impact ~= nil then
		applyImpact(rootPart, impact)
	end

	local removed = PlayerEnergyService.removeEnergy(player, damage)
	if removed > 0 then
		local releasedCount = MinionService.releaseEnergyFollowers(player, removed)
		player:SetAttribute(
			ATTRIBUTE.StatusMessage,
			"触发陷阱，损失 " .. math.floor(removed) .. " 能量，" .. releasedCount .. " 个小兵被撞飞！"
		)
	else
		player:SetAttribute(ATTRIBUTE.StatusMessage, "触发陷阱，但当前没有能量。")
	end
	return true
end

local function unbindStatic(instance: Instance)
	local binding = staticBindings[instance]
	if binding == nil then
		return
	end
	for _, connection in binding.connections do
		connection:Disconnect()
	end
	staticBindings[instance] = nil
end

local function onStaticTouched(instance: Instance, touchedPart: BasePart)
	local player, _, humanoid = GameplayUtil.getCharacterFromTouch(touchedPart)
	if player == nil or humanoid == nil or humanoid.Health <= 0 then
		return
	end
	TrapService.tryTrigger(instance, player, nil)
end

local function bindStatic(instance: Instance)
	if staticBindings[instance] ~= nil or TrapService.isMotionControlled(instance) then
		return
	end

	local root = GameplayUtil.getRoot(instance)
	if root == nil then
		warn("[TrapService] Trap must be a BasePart or Model containing a BasePart", instance)
		return
	end
	if getDamage(instance, true) == nil then
		return
	end

	local binding: StaticBinding = { connections = {} }
	staticBindings[instance] = binding
	for _, part in GameplayUtil.getParts(root) do
		table.insert(binding.connections, part.Touched:Connect(function(otherPart)
			onStaticTouched(instance, otherPart)
		end))
	end
end

local function visitTaggedTraps(root: Instance, callback: (Instance) -> ())
	if CollectionService:HasTag(root, TAG.Trap) then
		callback(root)
	end
	for _, descendant in root:GetDescendants() do
		if CollectionService:HasTag(descendant, TAG.Trap) then
			callback(descendant)
		end
	end
end

local function onMotionOwnerAdded(instance: Instance)
	visitTaggedTraps(instance, unbindStatic)
end

local function onMotionOwnerRemoved(instance: Instance)
	visitTaggedTraps(instance, bindStatic)
end

function TrapService.start()
	if started then
		return
	end
	started = true

	for _, instance in CollectionService:GetTagged(TAG.Trap) do
		bindStatic(instance)
	end
	CollectionService:GetInstanceAddedSignal(TAG.Trap):Connect(bindStatic)
	CollectionService:GetInstanceRemovedSignal(TAG.Trap):Connect(function(instance)
		unbindStatic(instance)
		lastTriggeredAt[instance] = nil
	end)
	for _, motionTag in { TAG.SwingHammer, TAG.LinearMover } do
		CollectionService:GetInstanceAddedSignal(motionTag):Connect(onMotionOwnerAdded)
		CollectionService:GetInstanceRemovedSignal(motionTag):Connect(onMotionOwnerRemoved)
	end
	Players.PlayerRemoving:Connect(function(player)
		for _, playerTimes in lastTriggeredAt do
			playerTimes[player] = nil
		end
	end)

	print("[TrapService] started")
end

return TrapService
