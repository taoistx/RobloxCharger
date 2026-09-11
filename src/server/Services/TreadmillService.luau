--!strict

--[[
	Binds tagged treadmill Models. A model named "x15 Treadmill" grants the
	base reward at x15 while a living player stands on its Conveyor part.
	x3, x15, and x50 require their configured one-time Game Pass. Occupancy,
	ownership, and coin grants are all validated by the server.

	Tag: Treadmill
	Accepted Instance: Model containing a BasePart named Conveyor
	Required Attribute: none
	Optional Attributes:
	- TreadmillEnabled: boolean, default true
	- TreadmillGamePassId: positive integer, overrides shared config
]]

local CollectionService = game:GetService("CollectionService")
local MarketplaceService = game:GetService("MarketplaceService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local GameplayConfig = require(Shared:WaitForChild("GameplayConfig"))
local TreadmillConfig = require(Shared:WaitForChild("TreadmillConfig"))
local GameplayUtil = require(script.Parent:WaitForChild("GameplayUtil"))
local PlayerShopService = require(script.Parent:WaitForChild("PlayerShopService"))

type TreadmillBinding = {
	conveyor: BasePart,
	multiplier: number,
	gamePassId: number?,
	prompt: ProximityPrompt?,
	connections: { RBXScriptConnection },
}

local TreadmillService = {}

local ATTRIBUTE = GameplayConfig.Attributes
local INSTANCE_NAME = GameplayConfig.InstanceNames
local TAG = GameplayConfig.Tags.Treadmill
local bindings: { [Instance]: TreadmillBinding } = {}
local ownedPasses: { [Player]: { [number]: boolean } } = {}
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

local function getGamePassId(instance: Instance, multiplier: number): number?
	local attributeValue = instance:GetAttribute(ATTRIBUTE.TreadmillGamePassId)
	if typeof(attributeValue) == "number" and attributeValue == attributeValue and attributeValue > 0 then
		return math.floor(attributeValue)
	end
	return TreadmillConfig.getConfiguredGamePassId(multiplier)
end

local function isEnabled(instance: Instance): boolean
	local enabled = instance:GetAttribute(ATTRIBUTE.TreadmillEnabled)
	return enabled == nil or enabled == true
end

local function isPaid(multiplier: number): boolean
	return multiplier >= TreadmillConfig.PaidMultiplierThreshold
end

local function playerOwnsPass(player: Player, gamePassId: number): boolean
	local playerPasses = ownedPasses[player]
	return playerPasses ~= nil and playerPasses[gamePassId] == true
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
	lastPromptAt[player] = nil
	player:SetAttribute(ATTRIBUTE.ActiveTreadmillMultiplier, nil)
end

local function isPlayerNearPart(player: Player, part: BasePart, maximumDistance: number): boolean
	local character = player.Character
	local rootPart = if character ~= nil then character:FindFirstChild("HumanoidRootPart") else nil
	return rootPart ~= nil
		and rootPart:IsA("BasePart")
		and (rootPart.Position - part.Position).Magnitude <= maximumDistance
end

local function requestPurchase(player: Player, binding: TreadmillBinding)
	local gamePassId = binding.gamePassId
	if gamePassId == nil or player.Parent ~= Players then
		return
	end
	if not isPlayerNearPart(
		player,
		binding.conveyor,
		TreadmillConfig.Prompt.MaxActivationDistance + TreadmillConfig.Prompt.ServerDistanceTolerance
	) then
		return
	end
	if playerOwnsPass(player, gamePassId) then
		player:SetAttribute(ATTRIBUTE.StatusMessage, "这台跑步机已经解锁。")
		return
	end

	local now = os.clock()
	if now - (lastPromptAt[player] or -math.huge) < TreadmillConfig.Prompt.CooldownSeconds then
		return
	end
	lastPromptAt[player] = now
	local remote = promptRemote
	if remote ~= nil then
		remote:FireClient(player, gamePassId)
	end
end

local function unbind(instance: Instance)
	local binding = bindings[instance]
	if binding == nil then
		return
	end
	bindings[instance] = nil
	for _, connection in binding.connections do
		connection:Disconnect()
	end
	if binding.prompt ~= nil and binding.prompt.Parent ~= nil then
		binding.prompt:Destroy()
	end
end

local function configurePrompt(prompt: ProximityPrompt, multiplier: number)
	-- The native purchase prompt shows the player's current managed/regional price.
	-- Avoid hard-coding a Robux amount into this shared world prompt.
	prompt.ActionText = "永久解锁 x" .. multiplier
	prompt.ObjectText = TreadmillConfig.Prompt.ObjectText
	prompt.KeyboardKeyCode = TreadmillConfig.Prompt.KeyboardKeyCode
	prompt.MaxActivationDistance = TreadmillConfig.Prompt.MaxActivationDistance
	prompt.HoldDuration = TreadmillConfig.Prompt.HoldDuration
	prompt.RequiresLineOfSight = false
	prompt.Enabled = true
end

local function bind(instance: Instance)
	if bindings[instance] ~= nil or not instance:IsDescendantOf(Workspace) then
		return
	end
	if not instance:IsA("Model") then
		warn("[TreadmillService] Treadmill Tag only accepts Model", instance)
		return
	end

	local multiplier = TreadmillConfig.parseMultiplier(instance.Name)
	if multiplier == nil then
		warn("[TreadmillService] model name must match x<number> Treadmill", instance)
		return
	end
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

	local gamePassId = getGamePassId(instance, multiplier)
	if isPaid(multiplier) and gamePassId == nil then
		warn("[TreadmillService] paid treadmill has no valid Game Pass ID", instance)
	end

	local prompt: ProximityPrompt? = nil
	local connections: { RBXScriptConnection } = {}
	if isPaid(multiplier) and gamePassId ~= nil then
		local existing = conveyor:FindFirstChild(TreadmillConfig.Prompt.Name)
		if existing ~= nil and not existing:IsA("ProximityPrompt") then
			existing:Destroy()
			existing = nil
		end
		prompt = if existing ~= nil then existing :: ProximityPrompt else Instance.new("ProximityPrompt")
		prompt.Name = TreadmillConfig.Prompt.Name
		configurePrompt(prompt, multiplier)
		prompt.Enabled = isEnabled(instance)
		prompt.Parent = conveyor
	end

	local binding: TreadmillBinding = {
		conveyor = conveyor,
		multiplier = multiplier,
		gamePassId = gamePassId,
		prompt = prompt,
		connections = connections,
	}
	bindings[instance] = binding
	if prompt ~= nil then
		table.insert(connections, prompt.Triggered:Connect(function(player: Player)
			requestPurchase(player, binding)
		end))
	end
	table.insert(connections, instance.Destroying:Connect(function()
		unbind(instance)
	end))
	table.insert(connections, instance:GetAttributeChangedSignal(ATTRIBUTE.TreadmillEnabled):Connect(function()
		local currentPrompt = binding.prompt
		if currentPrompt ~= nil then
			currentPrompt.Enabled = isEnabled(instance)
		end
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

local function awardTick()
	local highestMultiplierByPlayer: { [Player]: number } = {}
	local highestTouchedMultiplierByPlayer: { [Player]: number } = {}
	for instance, binding in bindings do
		if not isEnabled(instance) or not binding.conveyor:IsDescendantOf(Workspace) then
			continue
		end
		for player in getPlayersOnConveyor(binding.conveyor) do
			highestTouchedMultiplierByPlayer[player] = math.max(
				highestTouchedMultiplierByPlayer[player] or 0,
				binding.multiplier
			)
			local canUse = not isPaid(binding.multiplier)
				or (binding.gamePassId ~= nil and playerOwnsPass(player, binding.gamePassId))
			if canUse then
				highestMultiplierByPlayer[player] = math.max(
					highestMultiplierByPlayer[player] or 0,
					binding.multiplier
				)
			end
		end
	end

	for _, player in Players:GetPlayers() do
		local activeMultiplier = highestTouchedMultiplierByPlayer[player] or 0
		if player:GetAttribute(ATTRIBUTE.ActiveTreadmillMultiplier) ~= activeMultiplier then
			player:SetAttribute(ATTRIBUTE.ActiveTreadmillMultiplier, activeMultiplier)
		end
	end

	local baseCoins = math.max(0, math.floor(TreadmillConfig.Rewards.CoinsPerAward))
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
			player:SetAttribute(ATTRIBUTE.StatusMessage, "高倍率跑步机已解锁！")
		end
	end)
	task.spawn(function()
		local interval = math.max(0.1, TreadmillConfig.Rewards.AwardIntervalSeconds)
		while started do
			task.wait(interval)
			awardTick()
		end
	end)

	print("[TreadmillService] started")
end

return TreadmillService
