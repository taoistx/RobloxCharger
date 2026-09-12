--!strict

-- Presentation only. MinionModifierService owns the tag's gameplay behavior.
-- Schema: Shared/MinionModifierConfig. Labels follow config changes and streaming.

local CollectionService = game:GetService("CollectionService")
local Workspace = game:GetService("Workspace")
local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local GameplayConfig = require(Shared:WaitForChild("GameplayConfig"))
local ModifierConfig = require(Shared:WaitForChild("MinionModifierConfig"))

type Binding = {
	gui: BillboardGui,
	connections: { RBXScriptConnection },
}

local TAG = GameplayConfig.Tags.MinionModifier
local ATTRIBUTE = GameplayConfig.Attributes
local OPERATION = ModifierConfig.Operations
local bindings: { [Instance]: Binding } = {}

local function unbind(instance: Instance)
	local binding = bindings[instance]
	if binding == nil then
		return
	end
	bindings[instance] = nil
	for _, connection in binding.connections do
		connection:Disconnect()
	end
	binding.gui:Destroy()
end

local function bind(instance: Instance)
	if bindings[instance] ~= nil or not instance:IsA("BasePart") then
		return
	end
	local gui = Instance.new("BillboardGui")
	gui.Name = "MinionModifierLabel"
	gui.Size = UDim2.fromOffset(180, 70)
	gui.MaxDistance = 120
	gui.AlwaysOnTop = false
	gui.Adornee = instance
	local label = Instance.new("TextLabel")
	label.Size = UDim2.fromScale(1, 1)
	label.BackgroundTransparency = 1
	label.Font = Enum.Font.GothamBlack
	label.TextScaled = true
	label.TextStrokeTransparency = 0.25
	label.Parent = gui
	gui.Parent = instance
	local binding: Binding = { gui = gui, connections = {} }
	bindings[instance] = binding

	local function refresh()
		local definition = ModifierConfig.read(instance)
		gui.Enabled = definition ~= nil and definition.enabled
			and instance.Anchored and instance.CanTouch and instance:IsDescendantOf(Workspace)
		gui.StudsOffsetWorldSpace = Vector3.new(0, instance.Size.Y / 2 + 1.5, 0)
		if definition ~= nil then
			label.Text = "MINIONS " .. ModifierConfig.getLabel(definition)
			local reduces = definition.operation == OPERATION.Subtract
				or (definition.operation == OPERATION.Multiply and definition.operand == 0)
			label.TextColor3 = if reduces then Color3.fromRGB(255, 95, 100) else Color3.fromRGB(85, 235, 145)
		end
	end
	for _, name in { ATTRIBUTE.Operation, ATTRIBUTE.Operand, ATTRIBUTE.Enabled } do
		table.insert(binding.connections, instance:GetAttributeChangedSignal(name):Connect(refresh))
	end
	for _, name in { "Size", "Anchored", "CanTouch" } do
		table.insert(binding.connections, instance:GetPropertyChangedSignal(name):Connect(refresh))
	end
	table.insert(binding.connections, instance.AncestryChanged:Connect(function()
		if not instance:IsDescendantOf(game) then
			unbind(instance)
		else
			refresh()
		end
	end))
	table.insert(binding.connections, instance.Destroying:Connect(function()
		unbind(instance)
	end))
	refresh()
end

-- These two connections have the same lifetime as this player script.
CollectionService:GetInstanceAddedSignal(TAG):Connect(bind)
CollectionService:GetInstanceRemovedSignal(TAG):Connect(unbind)
for _, instance in CollectionService:GetTagged(TAG) do
	bind(instance)
end
