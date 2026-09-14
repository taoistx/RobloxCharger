--!strict

-- Keeps treadmill BillboardGui labels aligned with the server-authoritative
-- effective multiplier. A value of 0 communicates the emergency reward pause.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local GameplayConfig = require(Shared:WaitForChild("GameplayConfig"))
local TreadmillConfig = require(Shared:WaitForChild("TreadmillConfig"))

type Binding = {
	connections: { RBXScriptConnection },
}

local ATTRIBUTE = GameplayConfig.Attributes
local bindings: { [Model]: Binding } = {}

local function updateLabel(model: Model)
	local conveyor = model:FindFirstChild(TreadmillConfig.ConveyorPartName, true)
	if conveyor == nil or not conveyor:IsA("BasePart") then
		return
	end
	local billboard = conveyor:FindFirstChildWhichIsA("BillboardGui")
	local label = if billboard ~= nil then billboard:FindFirstChildWhichIsA("TextLabel") else nil
	if label == nil then
		return
	end

	local multiplier = model:GetAttribute(ATTRIBUTE.EffectiveTreadmillMultiplier)
	if typeof(multiplier) ~= "number" then
		label.Text = "Coins Boost: LOADING"
	elseif multiplier <= 0 then
		label.Text = "Coins Rewards Paused"
	else
		label.Text = string.format("x%d Coins Boost", math.floor(multiplier))
	end
end

local function unbind(model: Model)
	local binding = bindings[model]
	if binding == nil then
		return
	end
	bindings[model] = nil
	for _, connection in binding.connections do
		connection:Disconnect()
	end
end

local function bind(model: Model)
	if bindings[model] ~= nil
		or not model:IsDescendantOf(Workspace)
		or TreadmillConfig.parseModelMultiplier(model.Name) == nil
	then
		return
	end
	local binding: Binding = { connections = {} }
	bindings[model] = binding
	table.insert(binding.connections, model:GetAttributeChangedSignal(ATTRIBUTE.EffectiveTreadmillMultiplier):Connect(function()
		updateLabel(model)
	end))
	table.insert(binding.connections, model.DescendantAdded:Connect(function()
		updateLabel(model)
	end))
	table.insert(binding.connections, model.Destroying:Connect(function()
		unbind(model)
	end))
	table.insert(binding.connections, model.AncestryChanged:Connect(function()
		if not model:IsDescendantOf(Workspace) then
			unbind(model)
		end
	end))
	updateLabel(model)
end

local function bindFromDescendant(descendant: Instance)
	local current: Instance? = descendant
	while current ~= nil and current ~= Workspace do
		if current:IsA("Model") and TreadmillConfig.parseModelMultiplier(current.Name) ~= nil then
			bind(current)
			return
		end
		current = current.Parent
	end
end

for _, descendant in Workspace:GetDescendants() do
	bindFromDescendant(descendant)
end

Workspace.DescendantAdded:Connect(bindFromDescendant)
