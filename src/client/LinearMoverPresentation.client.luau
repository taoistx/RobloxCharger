--!strict

--[[
	Renders `LinearMover` tagged Models locally at display frame rate. The server
	keeps the replicated parts at their authored positions and independently
	evaluates the same Workspace:GetServerTimeNow() trajectory for hit detection.
]]

local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local GameplayConfig = require(Shared:WaitForChild("GameplayConfig"))
local LinearMoverConfig = require(Shared:WaitForChild("LinearMoverConfig"))

type Binding = {
	model: Model,
	primaryPart: BasePart,
	basePivot: CFrame,
	axisVector: Vector3,
	range: number,
	speed: number,
	phase: number,
	attributeConnection: RBXScriptConnection,
}

local TAG = GameplayConfig.Tags.LinearMover
local ATTRIBUTE = GameplayConfig.Attributes
local DEFAULT = LinearMoverConfig.Defaults
local LIMIT = LinearMoverConfig.Limits

local bindings: { [Instance]: Binding } = {}
local pendingConnections: { [Instance]: RBXScriptConnection } = {}

local function readPositiveNumber(instance: Instance, name: string, minimum: number, maximum: number): number?
	local value = instance:GetAttribute(name)
	if typeof(value) ~= "number" or value ~= value or value < minimum or value > maximum then
		warn("[LinearMoverPresentation] " .. name .. " must be between " .. minimum .. " and " .. maximum, instance)
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
		warn("[LinearMoverPresentation] MovePhase must be between 0 and 1; using 0", instance)
		return DEFAULT.Phase
	end
	return value
end

local function clearPending(instance: Instance)
	local connection = pendingConnections[instance]
	if connection ~= nil then
		connection:Disconnect()
		pendingConnections[instance] = nil
	end
end

local function unbind(instance: Instance)
	local binding = bindings[instance]
	if binding == nil then
		return
	end
	binding.attributeConnection:Disconnect()
	if binding.primaryPart.Parent ~= nil and binding.model.Parent ~= nil then
		binding.model:PivotTo(binding.basePivot)
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
		warn("[LinearMoverPresentation] LinearMover tag requires a Model", instance)
		return
	end

	local primaryPart = instance.PrimaryPart
	if primaryPart == nil or primaryPart.Parent == nil or not primaryPart:IsDescendantOf(instance) then
		if pendingConnections[instance] == nil then
			pendingConnections[instance] = instance.DescendantAdded:Connect(function()
				task.defer(bind, instance)
			end)
		end
		return
	end

	local axis = instance:GetAttribute(ATTRIBUTE.MoveAxis)
	local axisVector = if typeof(axis) == "string" then LinearMoverConfig.getAxisVector(axis) else nil
	local range = readPositiveNumber(instance, ATTRIBUTE.MoveRange, LIMIT.MinRange, LIMIT.MaxRange)
	local speed = readPositiveNumber(instance, ATTRIBUTE.MoveSpeed, LIMIT.MinSpeed, LIMIT.MaxSpeed)
	if axisVector == nil or range == nil or speed == nil then
		if axisVector == nil then
			warn("[LinearMoverPresentation] MoveAxis must be X, Y, or Z", instance)
		end
		return
	end

	clearPending(instance)
	local binding = {} :: Binding
	binding.model = instance
	binding.primaryPart = primaryPart
	binding.basePivot = instance:GetPivot()
	binding.axisVector = axisVector
	binding.range = range
	binding.speed = speed
	binding.phase = readPhase(instance)
	binding.attributeConnection = instance.AttributeChanged:Connect(function(name)
		if name == ATTRIBUTE.MoveAxis or name == ATTRIBUTE.MoveRange or name == ATTRIBUTE.MoveSpeed or name == ATTRIBUTE.MovePhase then
			refresh(instance)
		end
	end)
	bindings[instance] = binding
end

for _, instance in CollectionService:GetTagged(TAG) do
	bind(instance)
end
CollectionService:GetInstanceAddedSignal(TAG):Connect(bind)
CollectionService:GetInstanceRemovedSignal(TAG):Connect(function(instance)
	clearPending(instance)
	unbind(instance)
end)

RunService.RenderStepped:Connect(function()
	local serverTime = Workspace:GetServerTimeNow()
	for instance, binding in bindings do
		if instance.Parent == nil
			or binding.primaryPart.Parent == nil
			or not binding.primaryPart:IsDescendantOf(binding.model)
		then
			unbind(instance)
			if instance.Parent ~= nil and CollectionService:HasTag(instance, TAG) then
				bind(instance)
			end
			continue
		end

		local offset = LinearMoverConfig.getOffsetAndDirection(
			binding.range,
			binding.speed,
			binding.phase,
			serverTime
		)
		binding.model:PivotTo(binding.basePivot + binding.axisVector * offset)
	end
end)
