--!strict

--[[
	Binds tagged treadmill Models. The effective reward multiplier is resolved
	from the model name through the validated experience configuration while a living
	player stands on its Conveyor part. The original model multiplier is used
	for its Game Pass lookup so existing scene permissions remain compatible.
	Paid treadmills require their configured one-time Game Pass. Stepping onto
	a locked treadmill automatically opens its native purchase prompt once per
	visit. Occupancy, ownership, and coin grants are all validated by the server.

	Tag: Treadmill
	Accepted Instance: Model containing a BasePart named Conveyor
	Required Attribute: none
	Optional Attributes:
	- TreadmillEnabled: boolean, default true
	- TreadmillGamePassId: positive integer, overrides shared config
	Runtime Attribute: EffectiveTreadmillMultiplier: integer 0..100000;
	0 means the global treadmill reward switch is paused.
]]

local CollectionService = game:GetService("CollectionService")
local MarketplaceService = game:GetService("MarketplaceService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local GameplayConfig = require(Shared:WaitForChild("GameplayConfig"))
local TreadmillConfig = require(Shared:WaitForChild("TreadmillConfig"))
local ExperienceConfigService = require(script.Parent:WaitForChild("ExperienceConfigService"))
local GameplayUtil = require(script.Parent:WaitForChild("GameplayUtil"))
local PlayerShopService = require(script.Parent:WaitForChild("PlayerShopService"))

type TreadmillBinding = {
	conveyor: BasePart,
	modelMultiplier: number,
	multiplier: number,
	gamePassId: number?,
	connections: { RBXScriptConnection },
}

local TreadmillService = {}

local ATTRIBUTE = GameplayConfig.Attributes
local INSTANCE_NAME = GameplayConfig.InstanceNames
local TAG = GameplayConfig.Tags.Treadmill
local bindings: { [Instance]: TreadmillBinding } = {}
local ownedPasses: { [Player]: { [number]: boolean } } = {}
local lockedTreadmillByPlayer: { [Player]: TreadmillBinding } = {}
local lastPromptAt: { [Player]: number } = {}
local started = false
local promptRemote: RemoteEvent? = nil

local function createRemoteEvent(name: string): RemoteEvent
	local existing = ReplicatedStorage:FindFirstChild(name)
	if existing ~= nil and not existing:IsA("RemoteEvent") then
		warn("[TreadmillService] replacing incorrectly typed remote", existing)
		existing:Destroy()
		existing = nil
	end
	if existing ~= nil then
		return existing :: RemoteEvent
	end

	local remote = Instance.new("RemoteEvent")
	remote.Name = name
	remote.Parent = ReplicatedStorage
	return remote
end

local function getGamePassId(instance: Instance, modelMultiplier: number): number?
	local attributeValue = instance:GetAttribute(ATTRIBUTE.TreadmillGamePassId)
	if typeof(attributeValue) == "number" and attributeValue == attributeValue and attributeValue > 0 then
		return math.floor(attributeValue)
	end
	return TreadmillConfig.getConfiguredGamePassId(modelMultiplier)
end

local function isEnabled(instance: Instance): boolean
	local enabled = instance:GetAttribute(ATTRIBUTE.TreadmillEnabled)
	return enabled == nil or enabled == true
end

local function isPaid(modelMultiplier: number): boolean
	return modelMultiplier >= TreadmillConfig.PaidMultiplierThreshold
end

local function syncEffectiveMultiplier(instance: Instance, binding: TreadmillBinding)
	local experienceConfig = ExperienceConfigService.getSnapshot()
	binding.multiplier = TreadmillConfig.getEffectiveMultiplier(
		binding.modelMultiplier,
		experienceConfig.treadmill.multiplierRemap
	)
	instance:SetAttribute(
		ATTRIBUTE.EffectiveTreadmillMultiplier,
		if experienceConfig.features.treadmillRewardsEnabled then binding.multiplier else 0
	)
end

local function playerOwnsPass(player: Player, gamePassId: number): boolean
	local playerPasses = ownedPasses[player]
	return playerPasses ~= nil and playerPasses[gamePassId] == true
end

local function getPassOwnership(player: Player, gamePassId: number): boolean?
	local playerPasses = ownedPasses[player]
	if playerPasses == nil then
		return nil
	end
	return playerPasses[gamePassId]
end

local function refreshPassOwnership(player: Player, gamePassId: number)
	if player.Parent ~= Players then
		return
	end

	local success, ownsOrError = pcall(function()
		return MarketplaceService:UserOwnsGamePassAsync(player.UserId, gamePassId)
	end)
	if player.Parent ~= Players then
		return
	end
	if not success then
		warn("[TreadmillService] failed to check Game Pass " .. gamePassId .. ": " .. tostring(ownsOrError))
		return
	end

	local playerPasses = ownedPasses[player]
	if playerPasses ~= nil then
		playerPasses[gamePassId] = ownsOrError == true
	end
end

local function getConfiguredPassIds(): { number }
	local passIds: { number } = {}
	local seen: { [number]: boolean } = {}
	for _, binding in bindings do
		local gamePassId = binding.gamePassId
		if gamePassId ~= nil and not seen[gamePassId] then
			seen[gamePassId] = true
			table.insert(passIds, gamePassId)
		end
	end
	return passIds
end

local function bindPlayer(player: Player)
	if ownedPasses[player] ~= nil then
		return
	end
	ownedPasses[player] = {}
	player:SetAttribute(ATTRIBUTE.ActiveTreadmillMultiplier, 0)
	for _, gamePassId in getConfiguredPassIds() do
		task.spawn(refreshPassOwnership, player, gamePassId)
	end
end

local function unbindPlayer(player: Player)
	ownedPasses[player] = nil
	lockedTreadmillByPlayer[player] = nil
	lastPromptAt[player] = nil
	player:SetAttribute(ATTRIBUTE.ActiveTreadmillMultiplier, nil)
end

local function requestPurchase(player: Player, binding: TreadmillBinding): boolean
	local gamePassId = binding.gamePassId
	if gamePassId == nil
		or player.Parent ~= Players
		or not binding.conveyor:IsDescendantOf(Workspace)
	then
		return false
	end
	if playerOwnsPass(player, gamePassId) then
		return true
	end

	local now = os.clock()
	if now - (lastPromptAt[player] or -math.huge) < TreadmillConfig.AutoPurchasePrompt.CooldownSeconds then
		return false
	end
	lastPromptAt[player] = now
	local remote = promptRemote
	if remote ~= nil then
		remote:FireClient(player, gamePassId)
		return true
	end
	return false
end

local function unbind(instance: Instance)
	local binding = bindings[instance]
	if binding == nil then
		return
	end
	bindings[instance] = nil
	instance:SetAttribute(ATTRIBUTE.EffectiveTreadmillMultiplier, nil)
	for _, connection in binding.connections do
		connection:Disconnect()
	end
	for player, lockedBinding in lockedTreadmillByPlayer do
		if lockedBinding == binding then
			lockedTreadmillByPlayer[player] = nil
		end
	end
end

local function bind(instance: Instance)
	if bindings[instance] ~= nil or not instance:IsDescendantOf(Workspace) then
		return
	end
	if not instance:IsA("Model") then
		warn("[TreadmillService] Treadmill Tag only accepts Model", instance)
		return
	end

	local modelMultiplier = TreadmillConfig.parseModelMultiplier(instance.Name)
	if modelMultiplier == nil then
		warn("[TreadmillService] model name must match x<number> Treadmill", instance)
		return
	end
	local multiplier = TreadmillConfig.getEffectiveMultiplier(
		modelMultiplier,
		ExperienceConfigService.getSnapshot().treadmill.multiplierRemap
	)
	local conveyor = instance:FindFirstChild(TreadmillConfig.ConveyorPartName, true)
	if conveyor == nil or not conveyor:IsA("BasePart") then
		warn("[TreadmillService] treadmill requires a BasePart named Conveyor", instance)
		return
	end
	local enabledValue = instance:GetAttribute(ATTRIBUTE.TreadmillEnabled)
	if enabledValue ~= nil and typeof(enabledValue) ~= "boolean" then
		warn("[TreadmillService] TreadmillEnabled must be a boolean", instance)
		return
	end

	local gamePassId = getGamePassId(instance, modelMultiplier)
	if isPaid(modelMultiplier) and gamePassId == nil then
		warn("[TreadmillService] paid treadmill has no valid Game Pass ID", instance)
	end

	local connections: { RBXScriptConnection } = {}
	local oldPrompt = conveyor:FindFirstChild(TreadmillConfig.AutoPurchasePrompt.LegacyInstanceName)
	if oldPrompt ~= nil and oldPrompt:IsA("ProximityPrompt") then
		oldPrompt:Destroy()
	end

	local binding: TreadmillBinding = {
		conveyor = conveyor,
		modelMultiplier = modelMultiplier,
		multiplier = multiplier,
		gamePassId = gamePassId,
		connections = connections,
	}
	bindings[instance] = binding
	syncEffectiveMultiplier(instance, binding)
	table.insert(connections, instance.Destroying:Connect(function()
		unbind(instance)
	end))
	table.insert(connections, instance:GetAttributeChangedSignal(ATTRIBUTE.TreadmillGamePassId):Connect(function()
		unbind(instance)
		task.defer(function()
			if CollectionService:HasTag(instance, TAG) then
				bind(instance)
			end
		end)
	end))
	table.insert(connections, instance:GetPropertyChangedSignal("Name"):Connect(function()
		unbind(instance)
		task.defer(function()
			if CollectionService:HasTag(instance, TAG) then
				bind(instance)
			end
		end)
	end))

	if gamePassId ~= nil then
		for _, player in Players:GetPlayers() do
			task.spawn(refreshPassOwnership, player, gamePassId)
		end
	end
end

local function getPlayersOnConveyor(conveyor: BasePart): { [Player]: boolean }
	local rewards = TreadmillConfig.Rewards
	local height = math.max(1, rewards.CharacterCheckHeight)
	local inset = math.max(0, rewards.HorizontalInsetStuds)
	local boxSize = Vector3.new(
		math.max(0.1, conveyor.Size.X - inset * 2),
		height,
		math.max(0.1, conveyor.Size.Z - inset * 2)
	)
	local boxCFrame = conveyor.CFrame * CFrame.new(0, conveyor.Size.Y * 0.5 + height * 0.5, 0)
	local playersOnConveyor: { [Player]: boolean } = {}
	for _, part in Workspace:GetPartBoundsInBox(boxCFrame, boxSize) do
		local player, _, humanoid = GameplayUtil.getCharacterFromTouch(part)
		if player ~= nil and humanoid ~= nil and humanoid.Health > 0 then
			playersOnConveyor[player] = true
		end
	end
	return playersOnConveyor
end

local function updateOccupancy(
	shouldAwardCoins: boolean,
	experienceConfig: ExperienceConfigService.Snapshot
)
	if not experienceConfig.features.treadmillRewardsEnabled then
		for _, player in Players:GetPlayers() do
			if player:GetAttribute(ATTRIBUTE.ActiveTreadmillMultiplier) ~= 0 then
				player:SetAttribute(ATTRIBUTE.ActiveTreadmillMultiplier, 0)
			end
			lockedTreadmillByPlayer[player] = nil
		end
		return
	end

	local highestMultiplierByPlayer: { [Player]: number } = {}
	local highestTouchedMultiplierByPlayer: { [Player]: number } = {}
	local highestLockedBindingByPlayer: { [Player]: TreadmillBinding } = {}
	for instance, binding in bindings do
		if not isEnabled(instance) or not binding.conveyor:IsDescendantOf(Workspace) then
			continue
		end
		for player in getPlayersOnConveyor(binding.conveyor) do
			highestTouchedMultiplierByPlayer[player] = math.max(
				highestTouchedMultiplierByPlayer[player] or 0,
				binding.multiplier
			)
			local gamePassId = binding.gamePassId
			local canUse = not isPaid(binding.modelMultiplier)
				or (gamePassId ~= nil and playerOwnsPass(player, gamePassId))
			if canUse then
				highestMultiplierByPlayer[player] = math.max(
					highestMultiplierByPlayer[player] or 0,
					binding.multiplier
				)
			elseif gamePassId ~= nil and getPassOwnership(player, gamePassId) == false then
				local currentLockedBinding = highestLockedBindingByPlayer[player]
				if currentLockedBinding == nil or binding.multiplier > currentLockedBinding.multiplier then
					highestLockedBindingByPlayer[player] = binding
				end
			end
		end
	end

	for _, player in Players:GetPlayers() do
		local activeMultiplier = highestTouchedMultiplierByPlayer[player] or 0
		if player:GetAttribute(ATTRIBUTE.ActiveTreadmillMultiplier) ~= activeMultiplier then
			player:SetAttribute(ATTRIBUTE.ActiveTreadmillMultiplier, activeMultiplier)
		end

		local lockedBinding = highestLockedBindingByPlayer[player]
		if lockedBinding ~= lockedTreadmillByPlayer[player] then
			if lockedBinding == nil or requestPurchase(player, lockedBinding) then
				lockedTreadmillByPlayer[player] = lockedBinding
			end
		end
	end

	if not shouldAwardCoins then
		return
	end
	local baseCoins = experienceConfig.treadmill.coinsPerAward
	for player, multiplier in highestMultiplierByPlayer do
		PlayerShopService.addCoins(player, baseCoins * multiplier)
	end
end

function TreadmillService.start()
	if started then
		return
	end
	started = true
	promptRemote = createRemoteEvent(INSTANCE_NAME.TreadmillPromptPurchase)

	for _, instance in CollectionService:GetTagged(TAG) do
		bind(instance)
	end
	CollectionService:GetInstanceAddedSignal(TAG):Connect(bind)
	CollectionService:GetInstanceRemovedSignal(TAG):Connect(unbind)

	for _, player in Players:GetPlayers() do
		bindPlayer(player)
	end
	Players.PlayerAdded:Connect(bindPlayer)
	Players.PlayerRemoving:Connect(unbindPlayer)
	ExperienceConfigService.getChangedSignal():Connect(function()
		for instance, binding in bindings do
			syncEffectiveMultiplier(instance, binding)
		end
		if not ExperienceConfigService.getSnapshot().features.treadmillRewardsEnabled then
			table.clear(lockedTreadmillByPlayer)
		end
	end)

	MarketplaceService.PromptGamePassPurchaseFinished:Connect(function(player: Player, gamePassId: number, wasPurchased: boolean)
		if not wasPurchased or player.Parent ~= Players then
			return
		end
		local knownPass = false
		for _, configuredId in getConfiguredPassIds() do
			if configuredId == gamePassId then
				knownPass = true
				break
			end
		end
		if not knownPass then
			return
		end
		local playerPasses = ownedPasses[player]
		if playerPasses ~= nil then
			playerPasses[gamePassId] = true
			player:SetAttribute(ATTRIBUTE.StatusMessage, "High-multiplier treadmill unlocked!")
		end
	end)
	task.spawn(function()
		local checkInterval = math.max(0.05, TreadmillConfig.Rewards.OccupancyCheckIntervalSeconds)
		local appliedVersion = -1
		local nextAwardAt = math.huge
		while started do
			task.wait(checkInterval)
			local now = os.clock()
			local experienceConfig = ExperienceConfigService.getSnapshot()
			local awardInterval = experienceConfig.treadmill.awardIntervalSeconds
			if experienceConfig.version ~= appliedVersion then
				appliedVersion = experienceConfig.version
				nextAwardAt = now + awardInterval
			end
			local shouldAwardCoins = now >= nextAwardAt
			if shouldAwardCoins then
				nextAwardAt = now + awardInterval
			end
			updateOccupancy(shouldAwardCoins, experienceConfig)
		end
	end)

	print("[TreadmillService] started")
end

return TreadmillService
