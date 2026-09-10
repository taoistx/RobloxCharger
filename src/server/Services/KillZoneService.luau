--!strict

--[[
	Owns authoritative `KillZone` touch handling.
	KillZone tag: BasePart in Workspace.
	Required attributes: none.
	Optional attributes: none.

	Touching a KillZone immediately kills the touching player's current character.
]]

local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local GameplayConfig = require(Shared:WaitForChild("GameplayConfig"))
local GameplayUtil = require(script.Parent:WaitForChild("GameplayUtil"))

type Binding = {
	connections: { RBXScriptConnection },
}

local KillZoneService = {}

local TAG = GameplayConfig.Tags.KillZone

local bindings: { [BasePart]: Binding } = {}
local started = false

local function unbind(part: BasePart)
	local binding = bindings[part]
	if binding == nil then
		return
	end

	bindings[part] = nil
	for _, connection in binding.connections do
		connection:Disconnect()
	end
end

local function onTouched(part: BasePart, touchedPart: BasePart)
	if bindings[part] == nil
		or not part:IsDescendantOf(Workspace)
		or not CollectionService:HasTag(part, TAG)
	then
		return
	end

	local player, _, humanoid = GameplayUtil.getCharacterFromTouch(touchedPart)
	if player == nil or humanoid == nil or humanoid.Health <= 0 then
		return
	end

	humanoid.Health = 0
end

local function bind(instance: Instance)
	if not instance:IsA("BasePart") then
		warn("[KillZoneService] KillZone must be a BasePart", instance)
		return
	end
	if bindings[instance] ~= nil then
		return
	end
	if not instance:IsDescendantOf(Workspace) then
		warn("[KillZoneService] KillZone must be a descendant of Workspace", instance)
		return
	end

	local binding: Binding = {
		connections = {},
	}
	bindings[instance] = binding

	table.insert(binding.connections, instance.Touched:Connect(function(otherPart)
		onTouched(instance, otherPart)
	end))
	table.insert(binding.connections, instance.AncestryChanged:Connect(function()
		if not instance:IsDescendantOf(Workspace) then
			unbind(instance)
		end
	end))
end

function KillZoneService.start()
	if started then
		return
	end
	started = true

	for _, instance in CollectionService:GetTagged(TAG) do
		bind(instance)
	end
	CollectionService:GetInstanceAddedSignal(TAG):Connect(bind)
	CollectionService:GetInstanceRemovedSignal(TAG):Connect(function(instance)
		if instance:IsA("BasePart") then
			unbind(instance)
		end
	end)

	print("[KillZoneService] started")
end

return KillZoneService
