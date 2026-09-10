--!strict

--[[
	Owns authoritative `Trap` touch handling.
	Trap tag: BasePart or Model (a Model must contain a BasePart).
	Required attribute: EnergyDamage: number in the range 1..1,000,000.

	Touching a trap removes up to EnergyDamage from the player. A short per-player,
	per-trap cooldown prevents several character body parts from charging the same
	touch more than once. Followers representing the energy actually lost are also
	released with their existing knockback presentation.
]]

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local GameplayConfig = require(Shared:WaitForChild("GameplayConfig"))
local GameplayUtil = require(script.Parent:WaitForChild("GameplayUtil"))
local MinionService = require(script.Parent:WaitForChild("MinionService"))
local PlayerEnergyService = require(script.Parent:WaitForChild("PlayerEnergyService"))

type Binding = {
	connections: { RBXScriptConnection },
	damage: number,
	lastTriggeredAt: { [Player]: number },
}

local TrapService = {}

local TAG = GameplayConfig.Tags.Trap
local ATTRIBUTE = GameplayConfig.Attributes
local MAX_DAMAGE = GameplayConfig.Limits.MaxEnergyValue
local TOUCH_COOLDOWN_SECONDS = GameplayConfig.Defaults.TrapTouchCooldownSeconds

local bindings: { [Instance]: Binding } = {}
local started = false

local function getEnergyDamage(instance: Instance): number?
	local damage = instance:GetAttribute(ATTRIBUTE.EnergyDamage)
	if typeof(damage) ~= "number" or damage < 1 or damage > MAX_DAMAGE then
		warn("[TrapService] Trap requires EnergyDamage between 1 and " .. MAX_DAMAGE, instance)
		return nil
	end
	return damage
end

local function onTrapTouched(instance: Instance, touchedPart: BasePart)
	local binding = bindings[instance]
	if binding == nil then
		return
	end

	local player, _, humanoid = GameplayUtil.getCharacterFromTouch(touchedPart)
	if player == nil or humanoid == nil or humanoid.Health <= 0 then
		return
	end

	local now = os.clock()
	local lastTriggeredAt = binding.lastTriggeredAt[player]
	if lastTriggeredAt ~= nil and now - lastTriggeredAt < TOUCH_COOLDOWN_SECONDS then
		return
	end
	binding.lastTriggeredAt[player] = now

	local removed = PlayerEnergyService.removeEnergy(player, binding.damage)
	if removed > 0 then
		local releasedCount = MinionService.releaseEnergyFollowers(player, removed)
		player:SetAttribute(
			ATTRIBUTE.StatusMessage,
			"触发陷阱，损失 " .. math.floor(removed) .. " 能量，" .. releasedCount .. " 个小兵被撞飞！"
		)
	else
		player:SetAttribute(ATTRIBUTE.StatusMessage, "触发陷阱，但当前没有能量。")
	end
end

local function bind(instance: Instance)
	if bindings[instance] ~= nil then
		return
	end
	local root = GameplayUtil.getRoot(instance)
	local damage = getEnergyDamage(instance)
	if root == nil or damage == nil then
		if root == nil then
			warn("[TrapService] Trap must be a BasePart or Model containing a BasePart", instance)
		end
		return
	end

	local binding: Binding = {
		connections = {},
		damage = damage,
		lastTriggeredAt = {},
	}
	bindings[instance] = binding
	for _, part in GameplayUtil.getParts(root) do
		table.insert(binding.connections, part.Touched:Connect(function(otherPart)
			onTrapTouched(instance, otherPart)
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

function TrapService.start()
	if started then
		return
	end
	started = true

	for _, instance in CollectionService:GetTagged(TAG) do
		bind(instance)
	end
	CollectionService:GetInstanceAddedSignal(TAG):Connect(bind)
	CollectionService:GetInstanceRemovedSignal(TAG):Connect(unbind)
	Players.PlayerRemoving:Connect(function(player)
		for _, binding in bindings do
			binding.lastTriggeredAt[player] = nil
		end
	end)

	print("[TrapService] started")
end

return TrapService
