--!strict

--[[
	Renders `SwingHammer` tagged Models locally at display frame rate.
	Required direct children: Arm, HammerHead (the fixed pivot), and Post (the
	visible impact head). SwingPivot must be parented to HammerHead. The model's
	optional SwingAmplitudeDegrees, SwingSpeedRadians and SwingPhaseRadians
	attributes use the ranges/defaults documented in SwingHammerConfig. Only Arm
	and Post move; HammerHead remains fixed.
]]

local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local GameplayConfig = require(Shared:WaitForChild("GameplayConfig"))
local SwingHammerConfig = require(Shared:WaitForChild("SwingHammerConfig"))

type Binding = {
	model: Model,
	pivotPart: BasePart,
	pivot: Attachment,
	pivotCFrame: CFrame,
	parts: { BasePart },
	baseCFrames: { [BasePart]: CFrame },
	amplitudeDegrees: number,
	speedRadians: number,
	phaseRadians: number,
}

local TAG = GameplayConfig.Tags.SwingHammer
local ATTRIBUTE = GameplayConfig.Attributes
local DEFAULT = SwingHammerConfig.Defaults
local LIMIT = SwingHammerConfig.Limits
local bindings: { [Instance]: Binding } = {}
local pendingDescendantConnections: { [Instance]: RBXScriptConnection } = {}

local function readNumberAttribute(instance: Instance, name: string, default: number, minimum: number, maximum: number): number
	local value = instance:GetAttribute(name)
	if value == nil then
		return default
	end
	if typeof(value) ~= "number" or value ~= value or value < minimum or value > maximum then
		warn("[SwingHammerPresentation] invalid " .. name .. "; using default", instance)
		return default
	end
	return value
end

local function clearPending(instance: Instance)
	local connection = pendingDescendantConnections[instance]
	if connection ~= nil then
		connection:Disconnect()
		pendingDescendantConnections[instance] = nil
	end
end

local function unbind(instance: Instance)
	local binding = bindings[instance]
	if binding == nil then
		return
	end
	for part, baseCFrame in binding.baseCFrames do
		if part.Parent ~= nil then
			part.CFrame = baseCFrame
		end
	end
	bindings[instance] = nil
end

local function bind(instance: Instance)
	if bindings[instance] ~= nil then
		return
	end
	if not instance:IsA("Model") then
		warn("[SwingHammerPresentation] SwingHammer tag requires a Model", instance)
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
		-- Streaming can replicate the tagged root before its descendants. Keep one
		-- temporary listener and retry as the required objects arrive.
		if pendingDescendantConnections[instance] == nil then
			pendingDescendantConnections[instance] = instance.DescendantAdded:Connect(function()
				task.defer(bind, instance)
			end)
		end
		return
	end
	clearPending(instance)
	local parts = { arm, impactPart }
	local baseCFrames: { [BasePart]: CFrame } = {}
	for _, part in parts do
		baseCFrames[part] = part.CFrame
	end
	bindings[instance] = {
		model = instance,
		pivotPart = pivotPart,
		pivot = pivot,
		pivotCFrame = pivot.WorldCFrame,
		parts = parts,
		baseCFrames = baseCFrames,
		amplitudeDegrees = readNumberAttribute(instance, ATTRIBUTE.SwingAmplitudeDegrees, DEFAULT.AmplitudeDegrees, 0, LIMIT.MaxAmplitudeDegrees),
		speedRadians = readNumberAttribute(instance, ATTRIBUTE.SwingSpeedRadians, DEFAULT.SpeedRadians, LIMIT.MinSpeedRadians, LIMIT.MaxSpeedRadians),
		phaseRadians = readNumberAttribute(instance, ATTRIBUTE.SwingPhaseRadians, DEFAULT.PhaseRadians, -LIMIT.MaxAbsPhaseRadians, LIMIT.MaxAbsPhaseRadians),
	}
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
		local streamedOut = binding.pivot.Parent ~= binding.pivotPart
			or binding.pivotPart.Parent == nil
			or not binding.pivotPart:IsDescendantOf(binding.model)
		for _, part in binding.parts do
			streamedOut = streamedOut or part.Parent == nil or not part:IsDescendantOf(binding.model)
		end
		if instance.Parent == nil or streamedOut then
			unbind(instance)
			if instance.Parent ~= nil and CollectionService:HasTag(instance, TAG) then
				bind(instance)
			end
			continue
		end
		local angle = SwingHammerConfig.getAngleRadians(binding.amplitudeDegrees, binding.speedRadians, binding.phaseRadians, serverTime)
		for _, part in binding.parts do
			local baseCFrame = binding.baseCFrames[part]
			if part.Parent ~= nil and baseCFrame ~= nil then
				part.CFrame = SwingHammerConfig.getRotatedCFrame(baseCFrame, binding.pivotCFrame, angle)
			end
		end
	end
end)
