--!strict

--[[
	Owns authoritative player shop state, coins, minion unlocks, and upgrades.
	Client requests only name an action and optional minion type; all prices,
	unlocks, and upgrade effects are recalculated on the server.
]]

local DataStoreService = game:GetService("DataStoreService")
local CollectionService = game:GetService("CollectionService")
local MarketplaceService = game:GetService("MarketplaceService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerStorage = game:GetService("ServerStorage")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local GameplayConfig = require(Shared:WaitForChild("GameplayConfig"))
local ShopConfig = require(Shared:WaitForChild("ShopConfig"))
local ExperienceConfigService = require(script.Parent:WaitForChild("ExperienceConfigService"))
local GameplayUtil = require(script.Parent:WaitForChild("GameplayUtil"))

type PlayerState = {
	coins: number,
	coinDistanceRemainder: number,
	capacityUpgradeLevel: number,
	unlockedMinionTypes: { [string]: boolean },
	minionEnergyUpgradeLevels: { [string]: number },
	dirty: boolean,
	loaded: boolean,
	revision: number,
	saving: boolean,
	lastPurchaseAt: number,
}

type SavedShop = {
	version: number,
	coins: number,
	coinDistanceRemainder: number,
	capacityUpgradeLevel: number,
	unlockedMinionTypes: { [string]: boolean },
	minionEnergyUpgradeLevels: { [string]: number },
}

type MinionSnapshot = {
	minionType: string,
	displayName: string,
	iconImage: string?,
	unlocked: boolean,
	baseEnergy: number,
	currentEnergy: number,
	energyUpgradePerLevel: number,
	upgradeLevel: number,
	upgradeCost: number?,
	unlockCoinCost: number,
	gamePassId: number?,
}

type ShopSnapshot = {
	coins: number,
	capacityUpgradeLevel: number,
	capacityUpgradeCost: number?,
	capacityBonus: number,
	minions: { MinionSnapshot },
}

type ShopBinding = {
	prompt: ProximityPrompt,
	triggeredConnection: RBXScriptConnection,
	destroyingConnection: RBXScriptConnection?,
}

local PlayerShopService = {}

local ATTRIBUTE = GameplayConfig.Attributes
local INSTANCE_NAME = GameplayConfig.InstanceNames
local TAG = GameplayConfig.Tags.Shop
local ACTION = ShopConfig.PurchaseActions
local PURCHASE_COOLDOWN_SECONDS = 0.15
local SHOP_MODEL_NAME = "Shop"
local MAX_SAFE_INTEGER = 9007199254740991

local states: { [Player]: PlayerState } = {}
local shopBindings: { [Instance]: ShopBinding } = {}
local started = false
local shopStore: GlobalDataStore? = nil
local nextStoreRetryAt = 0
local snapshotRemote: RemoteFunction? = nil
local purchaseRemote: RemoteFunction? = nil
local updatedRemote: RemoteEvent? = nil
local openRemote: RemoteEvent? = nil
local coinAwardFeedbackRemote: RemoteEvent? = nil
local invalidMinionUpgradeAttributeWarnings: { [Instance]: boolean } = {}
local invalidMinionIconAttributeWarnings: { [Instance]: boolean } = {}

local function getShopStore(): GlobalDataStore?
	if shopStore ~= nil then
		return shopStore
	end
	if os.clock() < nextStoreRetryAt then
		return nil
	end

	local success, storeOrError = pcall(function()
		return DataStoreService:GetDataStore(ShopConfig.DataStoreName)
	end)
	if not success then
		nextStoreRetryAt = os.clock() + 30
		warn("[PlayerShopService] shop storage is unavailable: " .. tostring(storeOrError))
		return nil
	end

	shopStore = storeOrError :: GlobalDataStore
	return shopStore
end

local function createRemoteFunction(name: string): RemoteFunction
	local existing = ReplicatedStorage:FindFirstChild(name)
	if existing ~= nil and not existing:IsA("RemoteFunction") then
		warn("[PlayerShopService] replacing incorrectly typed remote", existing)
		existing:Destroy()
		existing = nil
	end
	if existing ~= nil then
		return existing :: RemoteFunction
	end

	local remote = Instance.new("RemoteFunction")
	remote.Name = name
	remote.Parent = ReplicatedStorage
	return remote
end

local function createRemoteEvent(name: string): RemoteEvent
	local existing = ReplicatedStorage:FindFirstChild(name)
	if existing ~= nil and not existing:IsA("RemoteEvent") then
		warn("[PlayerShopService] replacing incorrectly typed remote", existing)
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

local function getPromptParent(instance: Instance): BasePart?
	local root = GameplayUtil.getRoot(instance)
	if root == nil then
		return nil
	end
	return GameplayUtil.getPrimaryPart(root)
end

local function configurePrompt(prompt: ProximityPrompt)
	local promptConfig = ShopConfig.Prompt
	prompt.ActionText = promptConfig.ActionText
	prompt.ObjectText = promptConfig.ObjectText
	prompt.KeyboardKeyCode = promptConfig.KeyboardKeyCode
	prompt.MaxActivationDistance = promptConfig.MaxActivationDistance
	prompt.HoldDuration = promptConfig.HoldDuration
	prompt.RequiresLineOfSight = false
	prompt.Enabled = true
end

local function unbindShop(instance: Instance)
	local binding = shopBindings[instance]
	if binding == nil then
		return
	end
	shopBindings[instance] = nil
	binding.triggeredConnection:Disconnect()
	if binding.destroyingConnection ~= nil then
		binding.destroyingConnection:Disconnect()
	end
	if binding.prompt.Parent ~= nil then
		binding.prompt:Destroy()
	end
end

local function bindShop(instance: Instance)
	if shopBindings[instance] ~= nil then
		return
	end
	if not instance:IsDescendantOf(Workspace) then
		return
	end
	if instance.Name ~= SHOP_MODEL_NAME and not CollectionService:HasTag(instance, TAG) then
		return
	end
	local promptParent = getPromptParent(instance)
	if promptParent == nil then
		warn("[PlayerShopService] Shop must be a BasePart or Model containing a BasePart", instance)
		return
	end

	local promptName = ShopConfig.Prompt.Name
	local existing = promptParent:FindFirstChild(promptName)
	if existing ~= nil and not existing:IsA("ProximityPrompt") then
		warn("[PlayerShopService] replacing incorrectly typed ShopPrompt", existing)
		existing:Destroy()
		existing = nil
	end
	local prompt = if existing ~= nil then existing :: ProximityPrompt else Instance.new("ProximityPrompt")
	prompt.Name = promptName
	configurePrompt(prompt)
	prompt.Parent = promptParent

	local binding: ShopBinding = {
		prompt = prompt,
		triggeredConnection = prompt.Triggered:Connect(function(player: Player)
			if player.Parent ~= Players then
				return
			end
			local remote = openRemote
			if remote ~= nil then
				remote:FireClient(player)
			end
		end),
		destroyingConnection = nil,
	}
	binding.destroyingConnection = instance.Destroying:Connect(function()
		unbindShop(instance)
	end)
	shopBindings[instance] = binding
end

local function bindAuthoredShops()
	for _, instance in CollectionService:GetTagged(TAG) do
		bindShop(instance)
	end
	for _, instance in Workspace:GetDescendants() do
		if instance.Name == SHOP_MODEL_NAME then
			bindShop(instance)
		end
	end
end

local function getTemplateContainer(): Instance
	local folder = ServerStorage:FindFirstChild(INSTANCE_NAME.MinionTemplates)
	return if folder ~= nil and folder:IsA("Folder") then folder else ServerStorage
end

local function getTemplateBaseEnergy(minionType: string): number?
	local template = getTemplateContainer():FindFirstChild(minionType)
	if template == nil or GameplayUtil.getRoot(template) == nil then
		return nil
	end

	local energyValue = template:GetAttribute(ATTRIBUTE.EnergyValue)
	if typeof(energyValue) ~= "number"
		or energyValue ~= energyValue
		or energyValue < 1
		or energyValue > GameplayConfig.Limits.MaxEnergyValue
	then
		return nil
	end

	return energyValue
end

local function getTemplateEnergyUpgradePerLevel(minionType: string): number?
	local template = getTemplateContainer():FindFirstChild(minionType)
	if template == nil or GameplayUtil.getRoot(template) == nil then
		return nil
	end

	local energyUpgradePerLevel = template:GetAttribute(ATTRIBUTE.EnergyUpgradePerLevel)
	if typeof(energyUpgradePerLevel) ~= "number"
		or energyUpgradePerLevel ~= energyUpgradePerLevel
		or energyUpgradePerLevel % 1 ~= 0
		or energyUpgradePerLevel < 1
		or energyUpgradePerLevel > GameplayConfig.Limits.MaxEnergyValue
	then
		if not invalidMinionUpgradeAttributeWarnings[template] then
			invalidMinionUpgradeAttributeWarnings[template] = true
			warn(
				"[PlayerShopService] Minion template requires EnergyUpgradePerLevel as an integer between 1 and "
					.. GameplayConfig.Limits.MaxEnergyValue,
				template
			)
		end
		return nil
	end

	return energyUpgradePerLevel
end

local function getTemplateIconImage(minionType: string): string?
	local template = getTemplateContainer():FindFirstChild(minionType)
	if template == nil or GameplayUtil.getRoot(template) == nil then
		return nil
	end

	local iconId = template:GetAttribute(ATTRIBUTE.MinionIconId)
	if typeof(iconId) == "number"
		and iconId == iconId
		and iconId % 1 == 0
		and iconId > 0
		and iconId <= MAX_SAFE_INTEGER
	then
		return "rbxassetid://" .. string.format("%.0f", iconId)
	end
	if typeof(iconId) == "string" then
		local digits = string.match(iconId, "^%s*(%d+)%s*$")
		if digits ~= nil and #digits <= 20 and string.find(digits, "[1-9]") ~= nil then
			return "rbxassetid://" .. digits
		end
	end

	if not invalidMinionIconAttributeWarnings[template] then
		invalidMinionIconAttributeWarnings[template] = true
		warn(
			"[PlayerShopService] Minion template requires MinionIconId as a positive integer or digit-only string asset ID",
			template
		)
	end
	return nil
end

local function getKnownMinionTypes(): { string }
	local minionTypes: { string } = {}
	local seen: { [string]: boolean } = {}
	local container = getTemplateContainer()
	for _, instance in container:GetChildren() do
		if getTemplateBaseEnergy(instance.Name) ~= nil
			and getTemplateEnergyUpgradePerLevel(instance.Name) ~= nil
			and not seen[instance.Name]
		then
			seen[instance.Name] = true
			table.insert(minionTypes, instance.Name)
		end
	end
	for minionType in ShopConfig.Minions do
		if not seen[minionType]
			and getTemplateBaseEnergy(minionType) ~= nil
			and getTemplateEnergyUpgradePerLevel(minionType) ~= nil
		then
			seen[minionType] = true
			table.insert(minionTypes, minionType)
		end
	end
	table.sort(minionTypes)
	return minionTypes
end

local function getGamePassId(minionType: string): number?
	local config = ShopConfig.getMinionConfig(minionType)
	if typeof(config.gamePassId) == "number" and config.gamePassId > 0 then
		return math.floor(config.gamePassId)
	end
	return nil
end

local function hasPermanentMinionUnlock(state: PlayerState, minionType: string): boolean
	return minionType == ShopConfig.DefaultUnlockedMinionType or state.unlockedMinionTypes[minionType] == true
end

local function getSafeNonNegativeInteger(value: unknown): number
	if typeof(value) ~= "number" or value ~= value or value < 0 then
		return 0
	end
	return math.floor(value)
end

local function getSafeNonNegativeNumber(value: unknown): number
	if typeof(value) ~= "number" or value ~= value or value < 0 then
		return 0
	end
	return value
end

local function getDefaultState(): PlayerState
	local unlockedMinionTypes: { [string]: boolean } = {}
	unlockedMinionTypes[ShopConfig.DefaultUnlockedMinionType] = true
	return {
		coins = 0,
		coinDistanceRemainder = 0,
		capacityUpgradeLevel = 0,
		unlockedMinionTypes = unlockedMinionTypes,
		minionEnergyUpgradeLevels = {},
		dirty = false,
		loaded = false,
		revision = 0,
		saving = false,
		lastPurchaseAt = -math.huge,
	}
end

local function sanitizeCapacityUpgradeLevel(level: unknown): number
	return math.clamp(
		getSafeNonNegativeInteger(level),
		0,
		ShopConfig.EnergyCapacityUpgrades.MaxLevel
	)
end

local function sanitizeMinionUpgradeLevel(level: unknown): number
	return math.clamp(
		getSafeNonNegativeInteger(level),
		0,
		ShopConfig.MinionEnergyUpgrades.MaxLevel
	)
end

local function syncAttributes(player: Player, state: PlayerState)
	player:SetAttribute(ATTRIBUTE.Coins, state.coins)
	player:SetAttribute(ATTRIBUTE.EnergyCapacityUpgradeLevel, state.capacityUpgradeLevel)
	player:SetAttribute(ATTRIBUTE.ShopRevision, state.revision)
end

local function markDirty(state: PlayerState)
	state.dirty = true
	state.revision += 1
end

local function applySavedState(state: PlayerState, saved: unknown)
	if typeof(saved) ~= "table" then
		return
	end

	state.coins = getSafeNonNegativeInteger(saved.coins)
	state.coinDistanceRemainder = getSafeNonNegativeNumber(saved.coinDistanceRemainder)
	state.capacityUpgradeLevel = sanitizeCapacityUpgradeLevel(saved.capacityUpgradeLevel)
	state.unlockedMinionTypes[ShopConfig.DefaultUnlockedMinionType] = true

	if typeof(saved.unlockedMinionTypes) == "table" then
		for minionType, unlocked in saved.unlockedMinionTypes do
			if typeof(minionType) == "string" and unlocked == true then
				state.unlockedMinionTypes[minionType] = true
			end
		end
	end
	if typeof(saved.minionEnergyUpgradeLevels) == "table" then
		for minionType, upgradeLevel in saved.minionEnergyUpgradeLevels do
			if typeof(minionType) == "string" then
				local safeLevel = sanitizeMinionUpgradeLevel(upgradeLevel)
				if safeLevel > 0 then
					state.minionEnergyUpgradeLevels[minionType] = safeLevel
				end
			end
		end
	end

	local distancePerAward = ExperienceConfigService.getSnapshot().runCoinDistance
	state.coinDistanceRemainder %= distancePerAward
end

local function getSavePayload(state: PlayerState): SavedShop
	local unlockedMinionTypes: { [string]: boolean } = {}
	for minionType, unlocked in state.unlockedMinionTypes do
		if unlocked then
			unlockedMinionTypes[minionType] = true
		end
	end
	unlockedMinionTypes[ShopConfig.DefaultUnlockedMinionType] = true

	local minionEnergyUpgradeLevels: { [string]: number } = {}
	for minionType, level in state.minionEnergyUpgradeLevels do
		local safeLevel = sanitizeMinionUpgradeLevel(level)
		if safeLevel > 0 then
			minionEnergyUpgradeLevels[minionType] = safeLevel
		end
	end

	return {
		version = 1,
		coins = state.coins,
		coinDistanceRemainder = state.coinDistanceRemainder,
		capacityUpgradeLevel = state.capacityUpgradeLevel,
		unlockedMinionTypes = unlockedMinionTypes,
		minionEnergyUpgradeLevels = minionEnergyUpgradeLevels,
	}
end

local function savePlayer(player: Player): boolean
	local state = states[player]
	if state == nil or not state.loaded or not state.dirty then
		return true
	end
	if state.saving then
		return false
	end

	local store = getShopStore()
	if store == nil then
		return false
	end

	state.saving = true
	local savedRevision = state.revision
	local payload = getSavePayload(state)
	local success, err = pcall(function()
		store:SetAsync(tostring(player.UserId), payload)
	end)
	state.saving = false
	if not success then
		warn("[PlayerShopService] failed to save shop state for " .. player.Name .. ": " .. tostring(err))
		return false
	end
	if state.revision == savedRevision then
		state.dirty = false
	end
	return true
end

local function buildSnapshot(player: Player): ShopSnapshot
	local state = states[player] or getDefaultState()
	local experienceConfig = ExperienceConfigService.getSnapshot()
	local minionShop = experienceConfig.minionShop
	local capacityCurve = experienceConfig.capacityUpgradeCurve
	local minions: { MinionSnapshot } = {}
	for _, minionType in getKnownMinionTypes() do
		local baseEnergy = getTemplateBaseEnergy(minionType)
		local energyUpgradePerLevel = getTemplateEnergyUpgradePerLevel(minionType)
		if baseEnergy == nil or energyUpgradePerLevel == nil then
			continue
		end
		local upgradeLevel = sanitizeMinionUpgradeLevel(state.minionEnergyUpgradeLevels[minionType])
		local unlocked = hasPermanentMinionUnlock(state, minionType)
		table.insert(minions, {
			minionType = minionType,
			displayName = ShopConfig.getMinionDisplayName(minionType),
			iconImage = getTemplateIconImage(minionType),
			unlocked = unlocked,
			baseEnergy = math.floor(baseEnergy),
			currentEnergy = math.floor(math.clamp(
				baseEnergy + ShopConfig.getMinionEnergyBonus(upgradeLevel, energyUpgradePerLevel),
				1,
				GameplayConfig.Limits.MaxEnergyValue
			)),
			energyUpgradePerLevel = energyUpgradePerLevel,
			upgradeLevel = upgradeLevel,
			upgradeCost = ShopConfig.getMinionUpgradeCost(minionType, upgradeLevel, minionShop),
			unlockCoinCost = ShopConfig.getMinionUnlockCost(minionType, minionShop),
			gamePassId = getGamePassId(minionType),
		})
	end

	table.sort(minions, function(left, right)
		if left.unlocked ~= right.unlocked then
			return left.unlocked
		end
		return left.displayName < right.displayName
	end)

	return {
		coins = state.coins,
		capacityUpgradeLevel = sanitizeCapacityUpgradeLevel(state.capacityUpgradeLevel),
		capacityUpgradeCost = ShopConfig.getCapacityUpgradeCost(state.capacityUpgradeLevel, capacityCurve),
		capacityBonus = ShopConfig.getCapacityBonus(state.capacityUpgradeLevel, capacityCurve),
		minions = minions,
	}
end

local function notifyPlayer(player: Player)
	local remote = updatedRemote
	if remote ~= nil then
		remote:FireClient(player, buildSnapshot(player))
	end
end

local function syncOwnedGamePasses(player: Player, notifyOnChange: boolean): boolean
	local state = states[player]
	if state == nil or not state.loaded then
		return false
	end

	local changed = false
	for _, minionType in getKnownMinionTypes() do
		if state.unlockedMinionTypes[minionType] then
			continue
		end
		local gamePassId = getGamePassId(minionType)
		if gamePassId == nil then
			continue
		end
		local success, ownsPassOrError = pcall(function()
			return MarketplaceService:UserOwnsGamePassAsync(player.UserId, gamePassId)
		end)
		if success and ownsPassOrError == true then
			state.unlockedMinionTypes[minionType] = true
			changed = true
		elseif not success then
			warn("[PlayerShopService] failed to check Game Pass " .. gamePassId .. ": " .. tostring(ownsPassOrError))
		end
	end

	if changed then
		markDirty(state)
		syncAttributes(player, state)
		if notifyOnChange then
			notifyPlayer(player)
		end
		task.spawn(savePlayer, player)
	end
	return changed
end

local function loadPlayer(player: Player)
	local state = states[player]
	if state == nil then
		return
	end

	local store = getShopStore()
	local success = false
	local savedOrError: unknown = nil
	if store ~= nil then
		success, savedOrError = pcall(function()
			return store:GetAsync(tostring(player.UserId))
		end)
	end
	if states[player] ~= state then
		return
	end
	if success then
		applySavedState(state, savedOrError)
	elseif store ~= nil then
		warn("[PlayerShopService] failed to load shop state for " .. player.Name .. ": " .. tostring(savedOrError))
	end
	state.loaded = true
	if not ExperienceConfigService.getSnapshot().features.runCoinRewardsEnabled
		and state.coinDistanceRemainder ~= 0
	then
		state.coinDistanceRemainder = 0
		markDirty(state)
	end
	state.revision += 1
	syncOwnedGamePasses(player, false)
	syncAttributes(player, state)
	notifyPlayer(player)
end

local function getStateForPurchase(player: Player): PlayerState?
	local state = states[player]
	if state == nil or not state.loaded or player.Parent ~= Players then
		return nil
	end
	return state
end

local function makeResponse(player: Player, success: boolean, message: string): { [string]: any }
	return {
		success = success,
		message = message,
		snapshot = buildSnapshot(player),
	}
end

local function unlockMinionFromGamePassId(player: Player, gamePassId: number)
	local state = states[player]
	if state == nil or not state.loaded then
		return
	end
	local changed = false
	for _, minionType in getKnownMinionTypes() do
		if getGamePassId(minionType) == gamePassId and not state.unlockedMinionTypes[minionType] then
			state.unlockedMinionTypes[minionType] = true
			changed = true
		end
	end
	if not changed then
		return
	end
	markDirty(state)
	syncAttributes(player, state)
	player:SetAttribute(ATTRIBUTE.StatusMessage, "New minion unlocked!")
	notifyPlayer(player)
	task.spawn(savePlayer, player)
end

local function onPurchaseRequested(player: Player, actionValue: unknown, minionTypeValue: unknown): { [string]: any }
	local state = getStateForPurchase(player)
	if state == nil then
		return makeResponse(player, false, "The shop is loading. Please try again.")
	end

	local now = os.clock()
	if now - state.lastPurchaseAt < PURCHASE_COOLDOWN_SECONDS then
		return makeResponse(player, false, "Slow down and try again.")
	end
	state.lastPurchaseAt = now

	if typeof(actionValue) ~= "string" then
		return makeResponse(player, false, "Invalid purchase action.")
	end

	local action = actionValue
	if action ~= ACTION.UnlockMinion and action ~= ACTION.UpgradeMinionEnergy then
		return makeResponse(player, false, "Invalid purchase action.")
	end

	if typeof(minionTypeValue) ~= "string" or minionTypeValue == "" then
		return makeResponse(player, false, "Please choose a valid minion.")
	end
	local minionType = minionTypeValue
	if getTemplateBaseEnergy(minionType) == nil or getTemplateEnergyUpgradePerLevel(minionType) == nil then
		return makeResponse(player, false, "This minion is not available.")
	end

	if action == ACTION.UnlockMinion then
		if PlayerShopService.isMinionUnlocked(player, minionType) then
			return makeResponse(player, false, "This minion is already unlocked.")
		end
		local cost = ShopConfig.getMinionUnlockCost(
			minionType,
			ExperienceConfigService.getSnapshot().minionShop
		)
		if not PlayerShopService.spendCoins(player, cost) then
			return makeResponse(player, false, "Not enough Coins.")
		end
		state.unlockedMinionTypes[minionType] = true
		markDirty(state)
		syncAttributes(player, state)
		player:SetAttribute(ATTRIBUTE.StatusMessage, ShopConfig.getMinionDisplayName(minionType) .. " unlocked!")
		notifyPlayer(player)
		task.spawn(savePlayer, player)
		return makeResponse(player, true, "Minion unlocked!")
	elseif action == ACTION.UpgradeMinionEnergy then
		if not PlayerShopService.isMinionUnlocked(player, minionType) then
			return makeResponse(player, false, "Unlock this minion first.")
		end
		local level = sanitizeMinionUpgradeLevel(state.minionEnergyUpgradeLevels[minionType])
		local cost = ShopConfig.getMinionUpgradeCost(
			minionType,
			level,
			ExperienceConfigService.getSnapshot().minionShop
		)
		if cost == nil then
			return makeResponse(player, false, "This minion is already at max energy.")
		end
		if not PlayerShopService.spendCoins(player, cost) then
			return makeResponse(player, false, "Not enough Coins.")
		end
		state.minionEnergyUpgradeLevels[minionType] = level + 1
		markDirty(state)
		syncAttributes(player, state)
		player:SetAttribute(ATTRIBUTE.StatusMessage, ShopConfig.getMinionDisplayName(minionType) .. " energy upgraded!")
		notifyPlayer(player)
		task.spawn(savePlayer, player)
		return makeResponse(player, true, "Minion energy upgraded!")
	end

	return makeResponse(player, false, "Invalid purchase action.")
end

local function bindPlayer(player: Player)
	if states[player] ~= nil then
		return
	end
	local state = getDefaultState()
	states[player] = state
	syncAttributes(player, state)
	task.spawn(loadPlayer, player)
end

local function unbindPlayer(player: Player)
	local state = states[player]
	while state ~= nil and state.saving do
		task.wait()
	end
	savePlayer(player)
	states[player] = nil
end

function PlayerShopService.addRunningDistance(player: Player, distance: number)
	local state = states[player]
	if state == nil or not state.loaded or distance <= 0 then
		return
	end

	local experienceConfig = ExperienceConfigService.getSnapshot()
	if not experienceConfig.features.runCoinRewardsEnabled then
		if state.coinDistanceRemainder ~= 0 then
			state.coinDistanceRemainder = 0
			markDirty(state)
		end
		return
	end

	local distancePerAward = experienceConfig.runCoinDistance
	local awardCount = math.floor((state.coinDistanceRemainder + distance) / distancePerAward)
	state.coinDistanceRemainder = (state.coinDistanceRemainder + distance) - awardCount * distancePerAward
	if awardCount <= 0 then
		markDirty(state)
		return
	end

	local awardedCoins = experienceConfig.runCoinReward * awardCount
	PlayerShopService.addCoins(player, awardedCoins)
end

-- The optional presentation flag only changes the receiving client's popup
-- anchor. Currency amount and persistence remain entirely server-authoritative.
function PlayerShopService.addCoins(player: Player, amount: number, showAtCharacterHead: boolean?): boolean
	local state = states[player]
	if state == nil or not state.loaded or amount ~= amount or amount <= 0 then
		return false
	end

	local awardedCoins = math.floor(amount)
	if awardedCoins <= 0 then
		return false
	end
	state.coins += awardedCoins
	markDirty(state)
	syncAttributes(player, state)
	notifyPlayer(player)
	local feedbackRemote = coinAwardFeedbackRemote
	if feedbackRemote ~= nil then
		feedbackRemote:FireClient(player, awardedCoins, showAtCharacterHead == true)
	end
	return true
end

function PlayerShopService.spendCoins(player: Player, amount: number): boolean
	local state = states[player]
	if state == nil or not state.loaded or amount ~= amount or amount < 0 then
		return false
	end
	local cost = math.floor(amount)
	if state.coins < cost then
		return false
	end
	state.coins -= cost
	return true
end

-- Server-only entry point used by EnergyCapacityUpgradeService. The touching
-- client never supplies a price or level; both are resolved from trusted state.
function PlayerShopService.tryUpgradeEnergyCapacity(player: Player): (boolean, string)
	local state = getStateForPurchase(player)
	if state == nil then
		local message = "The shop is loading. Step onto the upgrade zone again in a moment."
		player:SetAttribute(ATTRIBUTE.StatusMessage, message)
		return false, message
	end

	local level = sanitizeCapacityUpgradeLevel(state.capacityUpgradeLevel)
	local cost = ShopConfig.getCapacityUpgradeCost(
		level,
		ExperienceConfigService.getSnapshot().capacityUpgradeCurve
	)
	if cost == nil then
		local message = "Energy capacity is already at max level."
		player:SetAttribute(ATTRIBUTE.StatusMessage, message)
		return false, message
	end
	if not PlayerShopService.spendCoins(player, cost) then
		local message = "Not enough Coins. The capacity upgrade costs " .. cost .. " Coins."
		player:SetAttribute(ATTRIBUTE.StatusMessage, message)
		return false, message
	end

	local energyBeforeUpgrade = player:GetAttribute(ATTRIBUTE.CurrentEnergy)
	local preservedEnergy = if typeof(energyBeforeUpgrade) == "number" and energyBeforeUpgrade == energyBeforeUpgrade
		then math.max(0, energyBeforeUpgrade)
		else 0
	state.capacityUpgradeLevel = level + 1
	markDirty(state)
	syncAttributes(player, state)
	-- Capacity attribute listeners normally preserve energy as well. Writing the
	-- snapshot explicitly closes ordering gaps and guarantees an upgrade never
	-- grants current energy. Invalid over-cap values are clamped to the old/new cap.
	local capacity = player:GetAttribute(ATTRIBUTE.EnergyCapacity)
	if typeof(capacity) == "number" and capacity == capacity and capacity > 0 then
		preservedEnergy = math.min(preservedEnergy, capacity)
	end
	player:SetAttribute(ATTRIBUTE.CurrentEnergy, preservedEnergy)
	local message = "Spent " .. cost .. " Coins. Energy capacity upgraded!"
	player:SetAttribute(ATTRIBUTE.StatusMessage, message)
	notifyPlayer(player)
	task.spawn(savePlayer, player)
	return true, message
end

function PlayerShopService.isMinionUnlocked(player: Player, minionType: string): boolean
	if minionType == ShopConfig.DefaultUnlockedMinionType then
		return true
	end
	local state = states[player]
	return state ~= nil and state.loaded and state.unlockedMinionTypes[minionType] == true
end

function PlayerShopService.isLoaded(player: Player): boolean
	local state = states[player]
	return state ~= nil and state.loaded
end

function PlayerShopService.getUnlockedMinionTypes(player: Player): { string }
	local unlocked: { string } = {}
	for _, minionType in getKnownMinionTypes() do
		if PlayerShopService.isMinionUnlocked(player, minionType) then
			table.insert(unlocked, minionType)
		end
	end
	return unlocked
end

function PlayerShopService.getMinionEnergyValue(player: Player, minionType: string, baseEnergy: number?): number?
	local baseValue = baseEnergy or getTemplateBaseEnergy(minionType)
	local energyUpgradePerLevel = getTemplateEnergyUpgradePerLevel(minionType)
	if baseValue == nil or energyUpgradePerLevel == nil then
		return nil
	end
	local state = states[player]
	local upgradeLevel = if state ~= nil and state.loaded
		then sanitizeMinionUpgradeLevel(state.minionEnergyUpgradeLevels[minionType])
		else 0
	return math.clamp(
		baseValue + ShopConfig.getMinionEnergyBonus(upgradeLevel, energyUpgradePerLevel),
		1,
		GameplayConfig.Limits.MaxEnergyValue
	)
end

function PlayerShopService.getCapacityBonus(player: Player): number
	local state = states[player]
	local level = if state ~= nil and state.loaded then state.capacityUpgradeLevel else 0
	return ShopConfig.getCapacityBonus(level, ExperienceConfigService.getSnapshot().capacityUpgradeCurve)
end

function PlayerShopService.getSnapshot(player: Player): ShopSnapshot
	syncOwnedGamePasses(player, true)
	return buildSnapshot(player)
end

function PlayerShopService.start()
	if started then
		return
	end
	started = true
	snapshotRemote = createRemoteFunction(INSTANCE_NAME.ShopGetSnapshot)
	purchaseRemote = createRemoteFunction(INSTANCE_NAME.ShopPurchase)
	updatedRemote = createRemoteEvent(INSTANCE_NAME.ShopUpdated)
	openRemote = createRemoteEvent(INSTANCE_NAME.ShopOpenRequested)
	coinAwardFeedbackRemote = createRemoteEvent(INSTANCE_NAME.CoinAwardFeedback)

	local resolvedSnapshotRemote = snapshotRemote :: RemoteFunction
	local resolvedPurchaseRemote = purchaseRemote :: RemoteFunction
	resolvedSnapshotRemote.OnServerInvoke = function(player: Player)
		return PlayerShopService.getSnapshot(player)
	end
	resolvedPurchaseRemote.OnServerInvoke = onPurchaseRequested

	CollectionService:GetInstanceAddedSignal(TAG):Connect(bindShop)
	CollectionService:GetInstanceRemovedSignal(TAG):Connect(function(instance)
		if instance.Name ~= SHOP_MODEL_NAME then
			unbindShop(instance)
		end
	end)
	Workspace.DescendantAdded:Connect(function(instance)
		if instance.Name == SHOP_MODEL_NAME then
			bindShop(instance)
		end
	end)
	bindAuthoredShops()

	MarketplaceService.PromptGamePassPurchaseFinished:Connect(function(player: Player, gamePassId: number, wasPurchased: boolean)
		if wasPurchased then
			unlockMinionFromGamePassId(player, gamePassId)
		end
	end)
	for _, player in Players:GetPlayers() do
		bindPlayer(player)
	end
	Players.PlayerAdded:Connect(bindPlayer)
	Players.PlayerRemoving:Connect(unbindPlayer)
	ExperienceConfigService.getChangedSignal():Connect(function()
		local experienceConfig = ExperienceConfigService.getSnapshot()
		for player, state in states do
			if not experienceConfig.features.runCoinRewardsEnabled and state.coinDistanceRemainder ~= 0 then
				state.coinDistanceRemainder = 0
				markDirty(state)
				task.spawn(savePlayer, player)
			end
			notifyPlayer(player)
		end
	end)

	game:BindToClose(function()
		for player in states do
			local state = states[player]
			while state ~= nil and state.saving do
				task.wait()
			end
			savePlayer(player)
		end
	end)
	task.spawn(function()
		while started do
			task.wait(60)
			for player in states do
				task.spawn(savePlayer, player)
			end
		end
	end)

	print("[PlayerShopService] started")
end

return PlayerShopService
