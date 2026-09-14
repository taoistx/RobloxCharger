--!strict

--[[
	Owns authoritative `ReturnToSpawn` touch handling.
	ReturnToSpawn tag: anchored BasePart in Workspace with CanTouch enabled.
	Required attribute: CoinReward: positive integer in the range 1..1,000,000.
	Optional presentation: a descendant SurfaceGui containing a TextLabel. Its text
	is server-maintained as `win Reward: <CoinReward>` when present.
	Default values: the per-player touch cooldown is configured by
	GameplayConfig.Defaults.ReturnToSpawnTouchCooldownSeconds (currently 1 second).

	A living player who touches the zone is returned to their RespawnLocation (or
	the first Workspace SpawnLocation), loses all current Energy and followers,
	and receives the configured Coins reward. Their per-life picker, modifier-gate,
	random-gate, and Boss state is also reset. Each follower is converted to the
	configured Coins bonus before it is removed. All state changes are server-owned.
]]

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local GameplayConfig = require(Shared:WaitForChild("GameplayConfig"))
local ExperienceConfigService = require(script.Parent:WaitForChild("ExperienceConfigService"))
local GameplayUtil = require(script.Parent:WaitForChild("GameplayUtil"))
local BossService = require(script.Parent:WaitForChild("BossService"))
local MinionService = require(script.Parent:WaitForChild("MinionService"))
local MinionModifierService = require(script.Parent:WaitForChild("MinionModifierService"))
local MinionSpawnService = require(script.Parent:WaitForChild("MinionSpawnService"))
local PlayerEnergyService = require(script.Parent:WaitForChild("PlayerEnergyService"))
local PlayerShopService = require(script.Parent:WaitForChild("PlayerShopService"))
local RandomMinionModifierGroupService = require(script.Parent:WaitForChild("RandomMinionModifierGroupService"))

type Binding = {
	connections: { RBXScriptConnection },
	lastTriggeredAt: { [Player]: number },
}

local ReturnToSpawnService = {}

local TAG = GameplayConfig.Tags.ReturnToSpawn
local ATTRIBUTE = GameplayConfig.Attributes
local MAX_COIN_REWARD = GameplayConfig.Limits.MaxCoinReward
local TOUCH_COOLDOWN_SECONDS = GameplayConfig.Defaults.ReturnToSpawnTouchCooldownSeconds
local TELEPORT_HEIGHT_PADDING = 3

local bindings: { [BasePart]: Binding } = {}
local started = false

local function getCoinReward(part: BasePart, shouldWarn: boolean): number?
	local coinReward = part:GetAttribute(ATTRIBUTE.CoinReward)
	if typeof(coinReward) ~= "number"
		or coinReward ~= math.floor(coinReward)
		or coinReward < 1
		or coinReward > MAX_COIN_REWARD
	then
		if shouldWarn then
			warn("[ReturnToSpawnService] ReturnToSpawn requires CoinReward as an integer between 1 and " .. MAX_COIN_REWARD, part)
		end
		return nil
	end
	return coinReward
end

local function updateRewardLabel(part: BasePart, coinReward: number, shouldWarn: boolean)
	local surfaceGui = part:FindFirstChildWhichIsA("SurfaceGui", true)
	local label = if surfaceGui ~= nil then surfaceGui:FindFirstChildWhichIsA("TextLabel", true) else nil
	if label == nil then
		if shouldWarn then
			warn("[ReturnToSpawnService] ReturnToSpawn should contain a SurfaceGui with a TextLabel", part)
		end
		return
	end
	local experienceConfig = ExperienceConfigService.getSnapshot()
	if not experienceConfig.features.returnRewardsEnabled then
		label.Text = "Win Reward: PAUSED"
		return
	end
	local effectiveReward = math.clamp(
		math.floor(coinReward * experienceConfig.returnBaseRewardMultiplier),
		0,
		MAX_COIN_REWARD
	)
	label.Text = "Win Reward: " .. effectiveReward
end

local function refreshRewardPresentation(part: BasePart, shouldWarn: boolean)
	local coinReward = getCoinReward(part, shouldWarn)
	if coinReward == nil then
		return
	end
	updateRewardLabel(part, coinReward, shouldWarn)
end

local function getRespawnCFrame(player: Player): CFrame?
	local spawnLocation = player.RespawnLocation
	if spawnLocation == nil or not spawnLocation:IsDescendantOf(Workspace) then
		spawnLocation = Workspace:FindFirstChildWhichIsA("SpawnLocation", true)
	end
	if spawnLocation == nil then
		return nil
	end

	return spawnLocation.CFrame + Vector3.new(0, spawnLocation.Size.Y * 0.5 + TELEPORT_HEIGHT_PADDING, 0)
end

local function resetBackgroundMusic(player: Player)
	local sequence = player:GetAttribute(ATTRIBUTE.MusicResetSequence)
	local nextSequence = if typeof(sequence) == "number" and sequence == math.floor(sequence) and sequence >= 0
		then sequence + 1
		else 1
	player:SetAttribute(ATTRIBUTE.MusicResetSequence, nextSequence)
end

local function returnPlayer(player: Player, character: Model, rootPart: BasePart, coinReward: number)
	local respawnCFrame = getRespawnCFrame(player)
	if respawnCFrame == nil then
		warn("[ReturnToSpawnService] no SpawnLocation is available for", player)
		return
	end

	local experienceConfig = ExperienceConfigService.getSnapshot()
	local followerCount = MinionService.getFollowerCount(player)
	local baseCoinReward = 0
	local followerCoinReward = 0
	if experienceConfig.features.returnRewardsEnabled then
		baseCoinReward = math.clamp(
			math.floor(coinReward * experienceConfig.returnBaseRewardMultiplier),
			0,
			MAX_COIN_REWARD
		)
		followerCoinReward = followerCount * experienceConfig.returnFollowerCoinRate
	end
	local totalCoinReward = baseCoinReward + followerCoinReward
	MinionService.releaseAllFollowers(player)
	MinionSpawnService.resetPlayerSession(player)
	MinionModifierService.resetPlayerSession(player)
	RandomMinionModifierGroupService.resetPlayerSession(player)
	BossService.resetPlayerSession(player)

	rootPart.AssemblyLinearVelocity = Vector3.zero
	rootPart.AssemblyAngularVelocity = Vector3.zero
	character:PivotTo(respawnCFrame)
	rootPart.AssemblyLinearVelocity = Vector3.zero
	rootPart.AssemblyAngularVelocity = Vector3.zero
	PlayerEnergyService.resetPlayerSession(player)
	resetBackgroundMusic(player)

	if totalCoinReward <= 0 then
		local message = if experienceConfig.features.returnRewardsEnabled
			then "Returned to spawn: followers and Energy reset."
			else "Returned to spawn: rewards are temporarily paused."
		player:SetAttribute(ATTRIBUTE.StatusMessage, message)
	elseif PlayerShopService.addCoins(player, totalCoinReward, true) then
		local rewardMessage = "Returned to spawn: followers and Energy reset, +" .. baseCoinReward .. " Coins"
		if followerCoinReward > 0 then
			rewardMessage = rewardMessage .. " + " .. followerCount .. " followers × "
				.. experienceConfig.returnFollowerCoinRate
				.. " = +" .. totalCoinReward .. " Coins!"
		else
			rewardMessage = rewardMessage .. "!"
		end
		player:SetAttribute(ATTRIBUTE.StatusMessage, rewardMessage)
	else
		warn("[ReturnToSpawnService] unable to award Coins because the player shop state is unavailable", player)
		player:SetAttribute(ATTRIBUTE.StatusMessage, "Returned to spawn: followers and Energy reset.")
	end
end

local function onTouched(part: BasePart, touchedPart: BasePart)
	local binding = bindings[part]
	if binding == nil
		or not part:IsDescendantOf(Workspace)
		or not CollectionService:HasTag(part, TAG)
	then
		return
	end

	local player, character, humanoid, rootPart = GameplayUtil.getCharacterFromTouch(touchedPart)
	if player == nil or character == nil or humanoid == nil or humanoid.Health <= 0 or rootPart == nil then
		return
	end
	local coinReward = getCoinReward(part, false)
	if coinReward == nil then
		return
	end

	local now = os.clock()
	local previousTime = binding.lastTriggeredAt[player]
	if previousTime ~= nil and now - previousTime < TOUCH_COOLDOWN_SECONDS then
		return
	end
	binding.lastTriggeredAt[player] = now
	returnPlayer(player, character, rootPart, coinReward)
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
		warn("[ReturnToSpawnService] ReturnToSpawn must be a BasePart", instance)
		return
	end
	if bindings[instance] ~= nil then
		return
	end
	if not instance:IsDescendantOf(Workspace) then
		warn("[ReturnToSpawnService] ReturnToSpawn must be a descendant of Workspace", instance)
		return
	end
	if not instance.Anchored or not instance.CanTouch then
		warn("[ReturnToSpawnService] ReturnToSpawn requires Anchored and CanTouch", instance)
		return
	end
	if getCoinReward(instance, true) == nil then
		return
	end
	refreshRewardPresentation(instance, true)

	local binding: Binding = {
		connections = {},
		lastTriggeredAt = {},
	}
	bindings[instance] = binding
	table.insert(binding.connections, instance.Touched:Connect(function(otherPart)
		onTouched(instance, otherPart)
	end))
	table.insert(binding.connections, instance:GetAttributeChangedSignal(ATTRIBUTE.CoinReward):Connect(function()
		refreshRewardPresentation(instance, true)
	end))
	table.insert(binding.connections, instance.DescendantAdded:Connect(function(descendant)
		if descendant:IsA("SurfaceGui") or descendant:IsA("TextLabel") then
			refreshRewardPresentation(instance, false)
		end
	end))
	table.insert(binding.connections, instance.AncestryChanged:Connect(function()
		if not instance:IsDescendantOf(Workspace) then
			unbind(instance)
		end
	end))
end

function ReturnToSpawnService.start()
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
			binding.lastTriggeredAt[player] = nil
		end
	end)
	ExperienceConfigService.getChangedSignal():Connect(function()
		for part in bindings do
			refreshRewardPresentation(part, false)
		end
	end)

	print("[ReturnToSpawnService] started")
end

return ReturnToSpawnService
