--!strict

--[[
	Shows each local player's next capacity-upgrade price on tagged pads and
	plays local feedback only after the server confirms a successful purchase.
	The displayed price is informational; the server recalculates the real cost.
]]

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local SoundService = game:GetService("SoundService")
local Workspace = game:GetService("Workspace")

local player = Players.LocalPlayer
local Shared = ReplicatedStorage:WaitForChild("Shared")
local GameplayConfig = require(Shared:WaitForChild("GameplayConfig"))
local ShopConfig = require(Shared:WaitForChild("ShopConfig"))

type Binding = {
	connections: { RBXScriptConnection },
	label: TextLabel,
}

local TAG = GameplayConfig.Tags.EnergyCapacityUpgrade
local ATTRIBUTE = GameplayConfig.Attributes
local bindings: { [BasePart]: Binding } = {}

local function getCurrentCost(): number?
	local value = player:GetAttribute(ATTRIBUTE.EnergyCapacityUpgradeLevel)
	local level = if typeof(value) == "number" then value else 0
	return ShopConfig.getCapacityUpgradeCost(level)
end

local function updateLabel(label: TextLabel)
	local cost = getCurrentCost()
	if cost == nil then
		label.Text = "Max Energy Upgrade : MAX"
	else
		label.Text = "Max Energy Upgrade : " .. math.floor(cost)
	end
end

local function updateAllLabels()
	for _, binding in bindings do
		updateLabel(binding.label)
	end
end

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

local function bind(instance: Instance)
	if not instance:IsA("BasePart") then
		warn("[EnergyCapacityUpgradePresentation] EnergyCapacityUpgrade must be a BasePart", instance)
		return
	end
	if bindings[instance] ~= nil or not instance:IsDescendantOf(Workspace) then
		return
	end

	local surfaceGui = instance:FindFirstChild("SurfaceGui")
	local label = if surfaceGui ~= nil then surfaceGui:FindFirstChild("TextLabel", true) else nil
	if surfaceGui == nil or not surfaceGui:IsA("SurfaceGui") or label == nil or not label:IsA("TextLabel") then
		warn(
			"[EnergyCapacityUpgradePresentation] tagged part requires SurfaceGui/TextLabel",
			instance
		)
		return
	end

	local binding: Binding = {
		connections = {},
		label = label,
	}
	bindings[instance] = binding
	updateLabel(label)
	table.insert(binding.connections, instance.Destroying:Connect(function()
		unbind(instance)
	end))
	table.insert(binding.connections, instance.AncestryChanged:Connect(function()
		if not instance:IsDescendantOf(Workspace) then
			unbind(instance)
		end
	end))
end

for _, instance in CollectionService:GetTagged(TAG) do
	bind(instance)
end
CollectionService:GetInstanceAddedSignal(TAG):Connect(bind)
CollectionService:GetInstanceRemovedSignal(TAG):Connect(function(instance)
	if instance:IsA("BasePart") then
		unbind(instance)
	end
end)
Workspace.DescendantAdded:Connect(function(instance)
	if CollectionService:HasTag(instance, TAG) then
		bind(instance)
	end
end)
player:GetAttributeChangedSignal(ATTRIBUTE.EnergyCapacityUpgradeLevel):Connect(updateAllLabels)

local soundConfig = ShopConfig.EnergyCapacityUpgrades.Feedback
local successSound = Instance.new("Sound")
successSound.Name = "EnergyCapacityUpgradeSuccess"
successSound.SoundId = soundConfig.SoundId
successSound.Volume = math.clamp(soundConfig.SoundVolume, 0, 10)
successSound.Parent = SoundService

local feedback = ReplicatedStorage:WaitForChild(GameplayConfig.InstanceNames.EnergyCapacityUpgradeFeedback)
if feedback:IsA("RemoteEvent") then
	feedback.OnClientEvent:Connect(function()
		successSound:Stop()
		successSound.TimePosition = 0
		successSound:Play()
	end)
else
	warn("[EnergyCapacityUpgradePresentation] feedback remote must be a RemoteEvent", feedback)
end
