--!strict

--[[
	Owns authoritative hit detection for `LinearMover` tagged Models.
	The server never moves the authored parts. It evaluates the same deterministic
	trajectory rendered by clients and sweeps every descendant Trap BasePart from
	the previous virtual position to the current one.
]]

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local GameplayConfig = require(Shared:WaitForChild("GameplayConfig"))
local LinearMoverConfig = require(Shared:WaitForChild("LinearMoverConfig"))
local TrapService = require(script.Parent:WaitForChild("TrapService"))

type Hitbox = {
	part: BasePart,
	baseCFrame: CFrame,
	radius: number,
	lastPosition: Vector3,
}

type Binding = {
	model: Model,
	primaryPart: BasePart,
	axisVector: Vector3,
	range: number,
	speed: number,
	phase: number,
	hitboxes: { Hitbox },
	connections: { RBXScriptConnection },
}

local LinearMoverService = {}

local TAG = GameplayConfig.Tags
local ATTRIBUTE = GameplayConfig.Attributes
local DEFAULT = LinearMoverConfig.Defaults
local LIMIT = LinearMoverConfig.Limits

local bindings: { [Instance]: Binding } = {}
local started = false

local function distancePointToSegment(point: Vector3, startPosition: Vector3, endPosition: Vector3): number
	local segment = endPosition - startPosition
	local lengthSquared = segment:Dot(segment)
	if lengthSquared <= 0.000001 then
		return (point - startPosition).Magnitude
	end
	local alpha = math.clamp((point - startPosition):Dot(segment) / lengthSquared, 0, 1)
	return (point - (startPosition + segment * alpha)).Magnitude
end

local function readPositiveNumber(instance: Instance, name: string, minimum: number, maximum: number): number?
	local value = instance:GetAttribute(name)
	if typeof(value) ~= "number" or value ~= value or value < minimum or value > maximum then
		warn("[LinearMoverService] " .. name .. " must be between " .. minimum .. " and " .. maximum, instance)
		return nil
	end
	return value
end

local function readPhase(instance: Instance): number
	local value = instance:GetAttribute(ATTRIBUTE.MovePhase)
	if value == nil then
		return DEFAULT.Phase
	end
	if typeof(value) ~= "number" or value ~= value or value < 0 or value > 1 then
		warn("[LinearMoverService] MovePhase must be between 0 and 1; using 0", instance)
		return DEFAULT.Phase
	end
	return value
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

local bind: (Instance) -> ()

local function refresh(instance: Instance)
	unbind(instance)
	task.defer(bind, instance)
end

bind = function(instance: Instance)
	if bindings[instance] ~= nil then
		return
	end
	if not instance:IsA("Model") then
		warn("[LinearMoverService] LinearMover tag requires a Model", instance)
		return
	end
	local primaryPart = instance.PrimaryPart
	if primaryPart == nil then
		warn("[LinearMoverService] LinearMover requires PrimaryPart", instance)
		return
	end

	local axis = instance:GetAttribute(ATTRIBUTE.MoveAxis)
	local axisVector = if typeof(axis) == "string" then LinearMoverConfig.getAxisVector(axis) else nil
	local range = readPositiveNumber(instance, ATTRIBUTE.MoveRange, LIMIT.MinRange, LIMIT.MaxRange)
	local speed = readPositiveNumber(instance, ATTRIBUTE.MoveSpeed, LIMIT.MinSpeed, LIMIT.MaxSpeed)
	if axisVector == nil or range == nil or speed == nil then
		if axisVector == nil then
			warn("[LinearMoverService] MoveAxis must be X, Y, or Z", instance)
		end
		return
	end

	local phase = readPhase(instance)
	local offset = LinearMoverConfig.getOffsetAndDirection(range, speed, phase, Workspace:GetServerTimeNow())
	local hitboxes: { Hitbox } = {}
	for _, descendant in instance:GetDescendants() do
		if descendant:IsA("BasePart") and CollectionService:HasTag(descendant, TAG.Trap) then
			if TrapService.getDamage(descendant) ~= nil then
				table.insert(hitboxes, {
					part = descendant,
					baseCFrame = descendant.CFrame,
					radius = math.max(descendant.Size.X, descendant.Size.Y, descendant.Size.Z) * 0.5,
					lastPosition = (descendant.CFrame + axisVector * offset).Position,
				})
			end
		end
	end
	if #hitboxes == 0 then
		warn("[LinearMoverService] LinearMover requires at least one descendant Trap BasePart", instance)
		return
	end

	local binding: Binding = {
		model = instance,
		primaryPart = primaryPart,
		axisVector = axisVector,
		range = range,
		speed = speed,
		phase = phase,
		hitboxes = hitboxes,
		connections = {},
	}
	bindings[instance] = binding
	table.insert(binding.connections, instance.AttributeChanged:Connect(function(name)
		if name == ATTRIBUTE.MoveAxis or name == ATTRIBUTE.MoveRange or name == ATTRIBUTE.MoveSpeed or name == ATTRIBUTE.MovePhase then
			refresh(instance)
		end
	end))
	table.insert(binding.connections, instance.DescendantAdded:Connect(function(descendant)
		if descendant:IsA("BasePart") or CollectionService:HasTag(descendant, TAG.Trap) then
			refresh(instance)
		end
	end))
	table.insert(binding.connections, instance.DescendantRemoving:Connect(function(descendant)
		if descendant:IsA("BasePart") or CollectionService:HasTag(descendant, TAG.Trap) then
			refresh(instance)
		end
	end))
end

local function findMoverOwner(instance: Instance): Instance?
	local current: Instance? = instance.Parent
	while current ~= nil and current ~= Workspace do
		if CollectionService:HasTag(current, TAG.LinearMover) then
			return current
		end
		current = current.Parent
	end
	return nil
end

local function refreshMoverForTrap(instance: Instance)
	local owner = findMoverOwner(instance)
	if owner ~= nil then
		refresh(owner)
	end
end

function LinearMoverService.start()
	if started then
		return
	end
	started = true

	for _, instance in CollectionService:GetTagged(TAG.LinearMover) do
		bind(instance)
	end
	CollectionService:GetInstanceAddedSignal(TAG.LinearMover):Connect(bind)
	CollectionService:GetInstanceRemovedSignal(TAG.LinearMover):Connect(unbind)
	CollectionService:GetInstanceAddedSignal(TAG.Trap):Connect(refreshMoverForTrap)
	CollectionService:GetInstanceRemovedSignal(TAG.Trap):Connect(refreshMoverForTrap)

	RunService.Heartbeat:Connect(function()
		local serverTime = Workspace:GetServerTimeNow()
		for instance, binding in bindings do
			if instance.Parent == nil or binding.primaryPart.Parent == nil then
				unbind(instance)
				continue
			end

			local offset, directionSign = LinearMoverConfig.getOffsetAndDirection(
				binding.range,
				binding.speed,
				binding.phase,
				serverTime
			)
			local movementDirection = binding.axisVector * directionSign
			for _, hitbox in binding.hitboxes do
				if hitbox.part.Parent == nil or not CollectionService:HasTag(hitbox.part, TAG.Trap) then
					refresh(instance)
					break
				end

				local currentPosition = (hitbox.baseCFrame + binding.axisVector * offset).Position
				for _, player in Players:GetPlayers() do
					local character = player.Character
					local humanoid = if character ~= nil then character:FindFirstChildOfClass("Humanoid") else nil
					local rootPart = if character ~= nil then character:FindFirstChild("HumanoidRootPart") else nil
					if humanoid == nil or humanoid.Health <= 0 or rootPart == nil or not rootPart:IsA("BasePart") then
						continue
					end
					if distancePointToSegment(rootPart.Position, hitbox.lastPosition, currentPosition)
						<= hitbox.radius + rootPart.Size.Magnitude * 0.5
					then
						TrapService.tryTrigger(hitbox.part, player, {
							position = currentPosition,
							direction = movementDirection,
							speed = DEFAULT.KnockbackSpeed,
							upwardSpeed = DEFAULT.KnockbackUpwardSpeed,
						})
					end
				end
				hitbox.lastPosition = currentPosition
			end
		end
	end)
	print("[LinearMoverService] started")
end

return LinearMoverService
