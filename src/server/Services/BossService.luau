--!strict

--[[
	Owns `Boss` collision and defeat presentation.
	Boss tag: BasePart or Model (a Model must contain a BasePart).
	Required attributes: RequiredEnergy: number, range 1..1,000,000.
	Optional attributes: RespawnSeconds: number, range 0..3,600 (defaults to 0, no respawn);
	Defeated: boolean (runtime, defaults false).
]]

local CollectionService = game:GetService("CollectionService")
local Debris = game:GetService("Debris")

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local GameplayConfig = require(Shared:WaitForChild("GameplayConfig"))
local GameplayUtil = require(script.Parent:WaitForChild("GameplayUtil"))
local PlayerEnergyService = require(script.Parent:WaitForChild("PlayerEnergyService"))
local MinionService = require(script.Parent:WaitForChild("MinionService"))

type RootObject = GameplayUtil.RootObject
type Binding = {
	connections: { RBXScriptConnection },
	root: RootObject,
	requiredEnergy: number,
	respawnSeconds: number,
	defeated: boolean,
}

local BossService = {}

local TAG = GameplayConfig.Tags.Boss
local ATTRIBUTE = GameplayConfig.Attributes
local bindings: { [Instance]: Binding } = {}
local playerContactTimes: { [Player]: number } = {}
local started = false

local function getRequiredEnergy(instance: Instance): number?
	local requiredEnergy = instance:GetAttribute(ATTRIBUTE.RequiredEnergy)
	if typeof(requiredEnergy) ~= "number" or requiredEnergy < 1 or requiredEnergy > GameplayConfig.Limits.MaxBossRequiredEnergy then
		warn("[BossService] Boss requires RequiredEnergy between 1 and " .. GameplayConfig.Limits.MaxBossRequiredEnergy, instance)
		return nil
	end
	return requiredEnergy
end

local function getRespawnSeconds(instance: Instance): number?
	local seconds = instance:GetAttribute(ATTRIBUTE.RespawnSeconds)
	if seconds == nil then
		return 0
	end
	if typeof(seconds) ~= "number" or seconds < 0 or seconds > GameplayConfig.Limits.MaxRespawnSeconds then
		warn("[BossService] RespawnSeconds must be between 0 and " .. GameplayConfig.Limits.MaxRespawnSeconds, instance)
		return nil
	end
	return seconds
end

local function addThresholdDisplay(root: RootObject, requiredEnergy: number)
	local primaryPart = GameplayUtil.getPrimaryPart(root)
	local existing = primaryPart:FindFirstChild("EnergyThresholdDisplay")
	if existing ~= nil then
		existing:Destroy()
	end

	local billboard = Instance.new("BillboardGui")
	billboard.Name = "EnergyThresholdDisplay"
	billboard.Size = UDim2.fromOffset(150, 48)
	billboard.StudsOffsetWorldSpace = Vector3.new(0, 5, 0)
	billboard.AlwaysOnTop = true
	billboard.Adornee = primaryPart
	billboard.Parent = primaryPart

	local label = Instance.new("TextLabel")
	label.Size = UDim2.fromScale(1, 1)
	label.BackgroundColor3 = Color3.fromRGB(52, 15, 18)
	label.BackgroundTransparency = 0.2
	label.TextColor3 = Color3.fromRGB(255, 228, 80)
	label.Font = Enum.Font.GothamBlack
	label.TextScaled = true
	label.Text = "需要 " .. math.floor(requiredEnergy) .. " 能量"
	label.Parent = billboard

	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 8)
	corner.Parent = label
end

local function spawnFragments(root: RootObject)
	local origin = GameplayUtil.getPivot(root)
	local sourcePart = GameplayUtil.getPrimaryPart(root)
	local color = sourcePart.Color
	local material = sourcePart.Material
	for index = 1, 18 do
		local fragment = Instance.new("Part")
		fragment.Name = "BossFragment"
		fragment.Size = Vector3.new(0.45 + (index % 3) * 0.28, 0.45 + (index % 4) * 0.24, 0.45 + (index % 5) * 0.2)
		fragment.Color = color
		fragment.Material = material
		fragment.TopSurface = Enum.SurfaceType.Smooth
		fragment.BottomSurface = Enum.SurfaceType.Smooth
		fragment.CFrame = origin * CFrame.new(math.random(-15, 15) / 10, math.random(0, 12) / 10, math.random(-15, 15) / 10)
		fragment.Parent = workspace
		fragment:ApplyImpulse(Vector3.new(math.random(-24, 24), math.random(28, 58), math.random(-24, 24)) * fragment.AssemblyMass)
		fragment:ApplyAngularImpulse(Vector3.new(math.random(-12, 12), math.random(-12, 12), math.random(-12, 12)) * fragment.AssemblyMass)
		Debris:AddItem(fragment, 5)
	end
end

local function respawnBoss(template: Instance, parent: Instance, seconds: number)
	if seconds <= 0 then
		return
	end
	task.delay(seconds, function()
		if parent.Parent == nil then
			return
		end
		local clone = template:Clone()
		clone:SetAttribute(ATTRIBUTE.Defeated, false)
		clone.Parent = parent
		CollectionService:AddTag(clone, TAG)
	end)
end

local function defeatBoss(instance: Instance, binding: Binding, player: Player)
	binding.defeated = true
	instance:SetAttribute(ATTRIBUTE.Defeated, true)
	local template = instance:Clone()
	local parent = instance.Parent
	-- Start follower physics first so its replication reaches clients in the
	-- same simulation step as the boss fragments.
	local releasedCount = MinionService.releaseEnergyFollowers(player, binding.requiredEnergy)
	spawnFragments(binding.root)
	player:SetAttribute(ATTRIBUTE.StatusMessage, "Boss 击败！消耗 " .. math.floor(binding.requiredEnergy) .. " 能量，" .. releasedCount .. " 个小兵被撞飞。")
	instance:Destroy()
	if parent ~= nil then
		respawnBoss(template, parent, binding.respawnSeconds)
	end
end

local function onBossTouched(instance: Instance, touchedPart: BasePart)
	local binding = bindings[instance]
	if binding == nil or binding.defeated then
		return
	end
	local player, _, humanoid, rootPart = GameplayUtil.getCharacterFromTouch(touchedPart)
	if player == nil or humanoid == nil or rootPart == nil or humanoid.Health <= 0 then
		return
	end
	if (GameplayUtil.getPivot(binding.root).Position - rootPart.Position).Magnitude > 15 then
		return
	end

	local now = os.clock()
	if (playerContactTimes[player] or 0) + 1 > now then
		return
	end
	playerContactTimes[player] = now

	if not PlayerEnergyService.spendEnergy(player, binding.requiredEnergy) then
		player:SetAttribute(ATTRIBUTE.StatusMessage, "能量不足（需要 " .. math.floor(binding.requiredEnergy) .. "），被 Boss 击败！")
		humanoid.Health = 0
		return
	end

	local impactSequence = player:GetAttribute(ATTRIBUTE.BossImpactSequence)
	player:SetAttribute(ATTRIBUTE.BossImpactSequence, (if typeof(impactSequence) == "number" then impactSequence else 0) + 1)
	defeatBoss(instance, binding, player)
	local remainingEnergy = player:GetAttribute(ATTRIBUTE.CurrentEnergy)
	if typeof(remainingEnergy) == "number" and remainingEnergy <= 0 then
		player:SetAttribute(ATTRIBUTE.StatusMessage, "能量刚好耗尽：Boss 已粉碎，但你也倒下了！")
		humanoid.Health = 0
	end
end

local function bind(instance: Instance)
	if bindings[instance] ~= nil then
		return
	end
	local root = GameplayUtil.getRoot(instance)
	local requiredEnergy = getRequiredEnergy(instance)
	local respawnSeconds = getRespawnSeconds(instance)
	if root == nil or requiredEnergy == nil or respawnSeconds == nil then
		if root == nil then
			warn("[BossService] Boss must be a BasePart or Model containing a BasePart", instance)
		end
		return
	end

	instance:SetAttribute(ATTRIBUTE.Defeated, false)
	addThresholdDisplay(root, requiredEnergy)
	local binding: Binding = { root = root, requiredEnergy = requiredEnergy, respawnSeconds = respawnSeconds, defeated = false, connections = {} }
	bindings[instance] = binding
	for _, part in GameplayUtil.getParts(root) do
		table.insert(binding.connections, part.Touched:Connect(function(otherPart)
			onBossTouched(instance, otherPart)
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

function BossService.start()
	if started then
		return
	end
	started = true
	for _, instance in CollectionService:GetTagged(TAG) do
		bind(instance)
	end
	CollectionService:GetInstanceAddedSignal(TAG):Connect(bind)
	CollectionService:GetInstanceRemovedSignal(TAG):Connect(unbind)

	print("[BossService] started")
end

return BossService
