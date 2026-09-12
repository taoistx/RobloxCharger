--!strict

--[[
	Owns the development-only TestEnergyReward touch Part.
	TestEnergyReward tag: BasePart only.
	Required attributes: none.
	Optional attributes: none.
	The generated part awards its touching player 5,000 current energy and sets
	their session-only energy capacity to 5,000. It never creates followers.
]]

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local GameplayConfig = require(Shared:WaitForChild("GameplayConfig"))
local GameplayUtil = require(script.Parent:WaitForChild("GameplayUtil"))
local PlayerEnergyService = require(script.Parent:WaitForChild("PlayerEnergyService"))

type Binding = {
	connections: { RBXScriptConnection },
	lastAwardAt: { [Player]: number },
}

local TestEnergyRewardService = {}

local TAG = GameplayConfig.Tags.TestEnergyReward
local ATTRIBUTE = GameplayConfig.Attributes
local PART_NAME = "TestEnergyReward"
local REWARD_AMOUNT = 5000
local TOUCH_COOLDOWN_SECONDS = 1

local bindings: { [BasePart]: Binding } = {}
local started = false

local function getSpawnCFrame(): CFrame
	local spawnLocation = Workspace:FindFirstChildWhichIsA("SpawnLocation", true)
	if spawnLocation == nil then
		return CFrame.new(0, 3, -10)
	end

	local offset = spawnLocation.CFrame.LookVector * -10 + Vector3.new(0, 3, 0)
	return CFrame.new(spawnLocation.Position + offset)
end

local function createDefaultPart()
	if Workspace:FindFirstChild(PART_NAME) ~= nil then
		return
	end

	local part = Instance.new("Part")
	part.Name = PART_NAME
	part.Anchored = true
	part.CanCollide = false
	part.CanTouch = true
	part.CanQuery = false
	part.Size = Vector3.new(8, 5, 2)
	part.CFrame = getSpawnCFrame()
	part.Color = Color3.fromRGB(255, 221, 61)
	part.Material = Enum.Material.Neon
	part.TopSurface = Enum.SurfaceType.Smooth
	part.BottomSurface = Enum.SurfaceType.Smooth
	part.Parent = Workspace

	local billboard = Instance.new("BillboardGui")
	billboard.Name = "TestEnergyRewardLabel"
	billboard.Adornee = part
	billboard.AlwaysOnTop = true
	billboard.Size = UDim2.fromOffset(280, 60)
	billboard.StudsOffsetWorldSpace = Vector3.new(0, 4.5, 0)
	billboard.Parent = part

	local label = Instance.new("TextLabel")
	label.Size = UDim2.fromScale(1, 1)
	label.BackgroundTransparency = 1
	label.Font = Enum.Font.GothamBlack
	label.Text = "TEST: +5000 ENERGY / CAPACITY"
	label.TextColor3 = Color3.fromRGB(255, 245, 157)
	label.TextScaled = true
	label.TextStrokeTransparency = 0.45
	label.Parent = billboard

	CollectionService:AddTag(part, TAG)
end

local function unbind(part: BasePart)
	local binding = bindings[part]
	if binding == nil then
		return
	end
	for _, connection in binding.connections do
		connection:Disconnect()
	end
	bindings[part] = nil
end

local function awardPlayer(part: BasePart, touchedPart: BasePart)
	local binding = bindings[part]
	if binding == nil then
		return
	end

	local player, _, humanoid = GameplayUtil.getCharacterFromTouch(touchedPart)
	if player == nil or humanoid == nil or humanoid.Health <= 0 or player.Parent ~= Players then
		return
	end

	local now = os.clock()
	local lastAward = binding.lastAwardAt[player]
	if lastAward ~= nil and now - lastAward < TOUCH_COOLDOWN_SECONDS then
		return
	end
	binding.lastAwardAt[player] = now

	-- This is deliberately independent of MinionService: no follower is added or removed.
	player:SetAttribute(ATTRIBUTE.EnergyCapacity, REWARD_AMOUNT)
	PlayerEnergyService.setEnergy(player, REWARD_AMOUNT)
	player:SetAttribute(ATTRIBUTE.StatusMessage, "Test reward: Energy and capacity set to 5000 (no minions added).")
end

local function bind(instance: Instance)
	if not instance:IsA("BasePart") then
		warn("[TestEnergyRewardService] TestEnergyReward must be a BasePart", instance)
		return
	end
	if bindings[instance] ~= nil then
		return
	end
	if not instance:IsDescendantOf(Workspace) then
		return
	end

	local binding: Binding = {
		connections = {},
		lastAwardAt = {},
	}
	bindings[instance] = binding
	table.insert(binding.connections, instance.Touched:Connect(function(touchedPart: BasePart)
		awardPlayer(instance, touchedPart)
	end))
	table.insert(binding.connections, instance.Destroying:Connect(function()
		unbind(instance)
	end))
end

function TestEnergyRewardService.start()
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
	Players.PlayerRemoving:Connect(function(player)
		for _, binding in bindings do
			binding.lastAwardAt[player] = nil
		end
	end)

	createDefaultPart()
	print("[TestEnergyRewardService] created independent +5000 energy test Part")
end

return TestEnergyRewardService
