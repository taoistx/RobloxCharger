--!strict

--[[
	Owns EnergyCapacityUpgrade touch pads.
	EnergyCapacityUpgrade tag: BasePart only, placed under Workspace.
	Required attributes: none.
	Optional attributes: none.
	Required properties: Anchored, CanCollide, and CanTouch must all be true.

	A living player purchases one capacity level immediately when stepping onto a
	pad, then keeps purchasing at the configured interval while still touching it.
	Price, Coins, level, save state, and resulting capacity are all resolved by
	server-authoritative services.
]]

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local GameplayConfig = require(Shared:WaitForChild("GameplayConfig"))
local ShopConfig = require(Shared:WaitForChild("ShopConfig"))
local GameplayUtil = require(script.Parent:WaitForChild("GameplayUtil"))
local PlayerShopService = require(script.Parent:WaitForChild("PlayerShopService"))

type Binding = {
	connections: { RBXScriptConnection },
	occupants: { [Player]: boolean },
	purchaseTasks: { [Player]: thread },
}

local EnergyCapacityUpgradeService = {}

local TAG = GameplayConfig.Tags.EnergyCapacityUpgrade
local AUTO_PURCHASE_INTERVAL_SECONDS = math.max(
	0.1,
	ShopConfig.EnergyCapacityUpgrades.AutoPurchaseIntervalSeconds
)

local bindings: { [BasePart]: Binding } = {}
local playerConnections: { [Player]: RBXScriptConnection } = {}
local feedbackRemote: RemoteEvent? = nil
local started = false

local function createFeedbackRemote(): RemoteEvent
	local remoteName = GameplayConfig.InstanceNames.EnergyCapacityUpgradeFeedback
	local existing = game:GetService("ReplicatedStorage"):FindFirstChild(remoteName)
	if existing ~= nil and not existing:IsA("RemoteEvent") then
		warn("[EnergyCapacityUpgradeService] replacing incorrectly typed feedback remote", existing)
		existing:Destroy()
		existing = nil
	end
	if existing ~= nil then
		return existing :: RemoteEvent
	end

	local remote = Instance.new("RemoteEvent")
	remote.Name = remoteName
	remote.Parent = game:GetService("ReplicatedStorage")
	return remote
end

local function isPlayerTouching(part: BasePart, player: Player): boolean
	local character = player.Character
	if character == nil then
		return false
	end
	for _, touchingPart in part:GetTouchingParts() do
		if touchingPart:IsDescendantOf(character) then
			return true
		end
	end
	return false
end

local function clearPlayer(player: Player)
	for _, binding in bindings do
		binding.occupants[player] = nil
		local purchaseTask = binding.purchaseTasks[player]
		binding.purchaseTasks[player] = nil
		if purchaseTask ~= nil and coroutine.status(purchaseTask) ~= "dead" then
			task.cancel(purchaseTask)
		end
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
	for _, purchaseTask in binding.purchaseTasks do
		if coroutine.status(purchaseTask) ~= "dead" then
			task.cancel(purchaseTask)
		end
	end
	table.clear(binding.purchaseTasks)
	table.clear(binding.occupants)
end

local function tryPurchase(player: Player)
	local success = PlayerShopService.tryUpgradeEnergyCapacity(player)
	if success then
		local remote = feedbackRemote
		if remote ~= nil then
			remote:FireClient(player)
		end
	end
end

local function startAutoPurchase(part: BasePart, binding: Binding, player: Player)
	if binding.purchaseTasks[player] ~= nil then
		return
	end
	binding.occupants[player] = true
	tryPurchase(player)

	local purchaseTask = task.spawn(function()
		local currentTask = coroutine.running()
		while true do
			task.wait(AUTO_PURCHASE_INTERVAL_SECONDS)
			if bindings[part] ~= binding
				or binding.occupants[player] ~= true
				or player.Parent ~= Players
				or not isPlayerTouching(part, player)
			then
				break
			end
			tryPurchase(player)
		end
		binding.occupants[player] = nil
		if binding.purchaseTasks[player] == currentTask then
			binding.purchaseTasks[player] = nil
		end
	end)
	binding.purchaseTasks[player] = purchaseTask
end

local function onTouched(part: BasePart, touchedPart: BasePart)
	local binding = bindings[part]
	if binding == nil then
		return
	end

	local player, _, humanoid = GameplayUtil.getCharacterFromTouch(touchedPart)
	if player == nil or humanoid == nil or humanoid.Health <= 0 or player.Parent ~= Players then
		return
	end
	startAutoPurchase(part, binding, player)
end

local function onTouchEnded(part: BasePart, touchedPart: BasePart)
	local player = GameplayUtil.getCharacterFromTouch(touchedPart)
	if player == nil then
		return
	end
	task.defer(function()
		local binding = bindings[part]
		if binding ~= nil and not isPlayerTouching(part, player) then
			binding.occupants[player] = nil
			local purchaseTask = binding.purchaseTasks[player]
			binding.purchaseTasks[player] = nil
			if purchaseTask ~= nil and coroutine.status(purchaseTask) ~= "dead" then
				task.cancel(purchaseTask)
			end
		end
	end)
end

local function bind(instance: Instance)
	if not instance:IsA("BasePart") then
		warn("[EnergyCapacityUpgradeService] EnergyCapacityUpgrade must be a BasePart", instance)
		return
	end
	if bindings[instance] ~= nil or not instance:IsDescendantOf(Workspace) then
		return
	end
	if not instance.Anchored or not instance.CanCollide or not instance.CanTouch then
		warn(
			"[EnergyCapacityUpgradeService] EnergyCapacityUpgrade requires Anchored, CanCollide, and CanTouch",
			instance
		)
		return
	end

	local binding: Binding = {
		connections = {},
		occupants = {},
		purchaseTasks = {},
	}
	bindings[instance] = binding
	table.insert(binding.connections, instance.Touched:Connect(function(touchedPart: BasePart)
		onTouched(instance, touchedPart)
	end))
	table.insert(binding.connections, instance.TouchEnded:Connect(function(touchedPart: BasePart)
		onTouchEnded(instance, touchedPart)
	end))
	table.insert(binding.connections, instance.Destroying:Connect(function()
		unbind(instance)
	end))
	table.insert(binding.connections, instance.AncestryChanged:Connect(function()
		if not instance:IsDescendantOf(Workspace) then
			unbind(instance)
		end
	end))
end

local function bindPlayer(player: Player)
	if playerConnections[player] ~= nil then
		return
	end
	playerConnections[player] = player.CharacterRemoving:Connect(function()
		clearPlayer(player)
	end)
end

local function unbindPlayer(player: Player)
	clearPlayer(player)
	local connection = playerConnections[player]
	if connection ~= nil then
		connection:Disconnect()
		playerConnections[player] = nil
	end
end

function EnergyCapacityUpgradeService.start()
	if started then
		return
	end
	started = true
	feedbackRemote = createFeedbackRemote()

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

	for _, player in Players:GetPlayers() do
		bindPlayer(player)
	end
	Players.PlayerAdded:Connect(bindPlayer)
	Players.PlayerRemoving:Connect(unbindPlayer)

	print("[EnergyCapacityUpgradeService] started")
end

return EnergyCapacityUpgradeService
