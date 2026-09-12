--!strict

--[[
	Owns authoritative `SwingHammer` hit detection without moving server parts.
	SwingHammer tag: Model. Required direct children: Arm, HammerHead (fixed
	pivot seat), and Post (moving impact head). HammerHead must contain the fixed
	SwingPivot Attachment. Post must carry the Trap tag and EnergyDamage.
]]

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local GameplayConfig = require(Shared:WaitForChild("GameplayConfig"))
local SwingHammerConfig = require(Shared:WaitForChild("SwingHammerConfig"))
local TrapService = require(script.Parent:WaitForChild("TrapService"))

type Binding = {
	impactPart: BasePart,
	pivotPart: BasePart,
	pivot: Attachment,
	pivotCFrame: CFrame,
	baseImpactCFrame: CFrame,
	impactRadius: number,
	amplitudeDegrees: number,
	speedRadians: number,
	phaseRadians: number,
	lastImpactPosition: Vector3,
}

local SwingHammerService = {}

local TAG = GameplayConfig.Tags
local ATTRIBUTE = GameplayConfig.Attributes
local DEFAULT = SwingHammerConfig.Defaults
local LIMIT = SwingHammerConfig.Limits

local bindings: { [Instance]: Binding } = {}
local started = false

local function readNumberAttribute(instance: Instance, name: string, default: number, minimum: number, maximum: number): number
	local value = instance:GetAttribute(name)
	if value == nil then
		return default
	end
	if typeof(value) ~= "number" or value ~= value or value < minimum or value > maximum then
		warn("[SwingHammerService] invalid " .. name .. "; using default", instance)
		return default
	end
	return value
end

local function getImpactCFrame(binding: Binding, serverTime: number): CFrame
	local angle = SwingHammerConfig.getAngleRadians(binding.amplitudeDegrees, binding.speedRadians, binding.phaseRadians, serverTime)
	return SwingHammerConfig.getRotatedCFrame(binding.baseImpactCFrame, binding.pivotCFrame, angle)
end

local function distancePointToSegment(point: Vector3, startPosition: Vector3, endPosition: Vector3): number
	local segment = endPosition - startPosition
	local lengthSquared = segment:Dot(segment)
	if lengthSquared <= 0.000001 then
		return (point - startPosition).Magnitude
	end
	local alpha = math.clamp((point - startPosition):Dot(segment) / lengthSquared, 0, 1)
	return (point - (startPosition + segment * alpha)).Magnitude
end

local function bind(instance: Instance)
	if bindings[instance] ~= nil then
		return
	end
	if not instance:IsA("Model") then
		warn("[SwingHammerService] SwingHammer tag requires a Model", instance)
		return
	end

	local arm = instance:FindFirstChild(SwingHammerConfig.Names.AnimatedArm)
	local pivotPart = instance:FindFirstChild(SwingHammerConfig.Names.PivotPart)
	local impactPart = instance:FindFirstChild(SwingHammerConfig.Names.ImpactPart)
	local pivot = if pivotPart ~= nil then pivotPart:FindFirstChild(SwingHammerConfig.Names.PivotAttachment) else nil
	if arm == nil
		or not arm:IsA("BasePart")
		or pivotPart == nil
		or not pivotPart:IsA("BasePart")
		or impactPart == nil
		or not impactPart:IsA("BasePart")
		or pivot == nil
		or not pivot:IsA("Attachment")
	then
		warn("[SwingHammerService] SwingHammer requires Arm, HammerHead, Post, and SwingPivot under HammerHead", instance)
		return
	end
	if not CollectionService:HasTag(impactPart, TAG.Trap) then
		warn("[SwingHammerService] Post requires the Trap tag", instance)
		return
	end
	if TrapService.getDamage(impactPart) == nil then
		return
	end

	local binding: Binding = {
		impactPart = impactPart,
		pivotPart = pivotPart,
		pivot = pivot,
		pivotCFrame = pivot.WorldCFrame,
		baseImpactCFrame = impactPart.CFrame,
		impactRadius = math.max(impactPart.Size.X, impactPart.Size.Y, impactPart.Size.Z) * 0.5,
		amplitudeDegrees = readNumberAttribute(instance, ATTRIBUTE.SwingAmplitudeDegrees, DEFAULT.AmplitudeDegrees, 0, LIMIT.MaxAmplitudeDegrees),
		speedRadians = readNumberAttribute(instance, ATTRIBUTE.SwingSpeedRadians, DEFAULT.SpeedRadians, LIMIT.MinSpeedRadians, LIMIT.MaxSpeedRadians),
		phaseRadians = readNumberAttribute(instance, ATTRIBUTE.SwingPhaseRadians, DEFAULT.PhaseRadians, -LIMIT.MaxAbsPhaseRadians, LIMIT.MaxAbsPhaseRadians),
		lastImpactPosition = Vector3.zero,
	}
	binding.lastImpactPosition = getImpactCFrame(binding, Workspace:GetServerTimeNow()).Position
	bindings[instance] = binding
end

local function unbind(instance: Instance)
	bindings[instance] = nil
end

local function findHammerOwner(instance: Instance): Instance?
	local current: Instance? = instance.Parent
	while current ~= nil and current ~= Workspace do
		if CollectionService:HasTag(current, TAG.SwingHammer) then
			return current
		end
		current = current.Parent
	end
	return nil
end

local function refreshHammerForTrap(instance: Instance)
	local owner = findHammerOwner(instance)
	if owner ~= nil then
		unbind(owner)
		task.defer(bind, owner)
	end
end

function SwingHammerService.start()
	if started then
		return
	end
	started = true

	for _, instance in CollectionService:GetTagged(TAG.SwingHammer) do
		bind(instance)
	end
	CollectionService:GetInstanceAddedSignal(TAG.SwingHammer):Connect(bind)
	CollectionService:GetInstanceRemovedSignal(TAG.SwingHammer):Connect(unbind)
	CollectionService:GetInstanceAddedSignal(TAG.Trap):Connect(refreshHammerForTrap)
	CollectionService:GetInstanceRemovedSignal(TAG.Trap):Connect(refreshHammerForTrap)

	RunService.Heartbeat:Connect(function()
		local serverTime = Workspace:GetServerTimeNow()
		for instance, binding in bindings do
			if instance.Parent == nil
				or binding.impactPart.Parent == nil
				or binding.pivot.Parent ~= binding.pivotPart
				or not CollectionService:HasTag(binding.impactPart, TAG.Trap)
			then
				unbind(instance)
				continue
			end

			local currentImpactPosition = getImpactCFrame(binding, serverTime).Position
			local movement = currentImpactPosition - binding.lastImpactPosition
			if movement.Magnitude < 0.001 then
				movement = getImpactCFrame(binding, serverTime + 1 / 60).Position - currentImpactPosition
			end

			for _, player in Players:GetPlayers() do
				local character = player.Character
				local humanoid = if character ~= nil then character:FindFirstChildOfClass("Humanoid") else nil
				local rootPart = if character ~= nil then character:FindFirstChild("HumanoidRootPart") else nil
				if humanoid == nil or humanoid.Health <= 0 or rootPart == nil or not rootPart:IsA("BasePart") then
					continue
				end
				if distancePointToSegment(rootPart.Position, binding.lastImpactPosition, currentImpactPosition)
					<= binding.impactRadius + rootPart.Size.Magnitude * 0.5
				then
					TrapService.tryTrigger(binding.impactPart, player, {
						position = currentImpactPosition,
						direction = movement,
						speed = DEFAULT.KnockbackSpeed,
						upwardSpeed = DEFAULT.KnockbackUpwardSpeed,
					})
				end
			end
			binding.lastImpactPosition = currentImpactPosition
		end
	end)
	print("[SwingHammerService] started")
end

return SwingHammerService
