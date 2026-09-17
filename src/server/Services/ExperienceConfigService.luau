--!strict

--[[
	Loads Creator Hub experience configuration on the server and exposes one
	validated, immutable snapshot to gameplay services. Missing values use the
	checked-in Luau defaults. Invalid remote values are rejected per field.
]]

local ConfigService = game:GetService("ConfigService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local GameplayConfig = require(Shared:WaitForChild("GameplayConfig"))
local ShopConfig = require(Shared:WaitForChild("ShopConfig"))
local TreadmillConfig = require(Shared:WaitForChild("TreadmillConfig"))

type MinionShopBalance = ShopConfig.MinionShopBalance
type CapacityUpgradeCurve = ShopConfig.CapacityUpgradeCurve

export type FeatureFlags = {
	runCoinRewardsEnabled: boolean,
	returnRewardsEnabled: boolean,
	treadmillRewardsEnabled: boolean,
	tutorialEnabled: boolean,
}

export type TreadmillBalance = {
	coinsPerAward: number,
	awardIntervalSeconds: number,
	multiplierRemap: { [number]: number },
}

export type Snapshot = {
	version: number,
	runCoinDistance: number,
	runCoinReward: number,
	returnFollowerCoinRate: number,
	returnBaseRewardMultiplier: number,
	minionShop: MinionShopBalance,
	capacityUpgradeCurve: CapacityUpgradeCurve,
	treadmill: TreadmillBalance,
	features: FeatureFlags,
}

local ExperienceConfigService = {}

ExperienceConfigService.Keys = table.freeze({
	RunCoinDistance = "economy_run_coin_distance",
	RunCoinReward = "economy_run_coin_reward",
	ReturnFollowerCoinRate = "economy_return_follower_coin_rate",
	ReturnBaseRewardMultiplier = "economy_return_base_reward_multiplier",
	MinionShop = "economy_minion_shop",
	CapacityUpgradeCurve = "economy_capacity_upgrade_curve",
	TreadmillBalance = "economy_treadmill_balance",
	RunCoinRewardsEnabled = "feature_run_coin_rewards_enabled",
	ReturnRewardsEnabled = "feature_return_rewards_enabled",
	TreadmillRewardsEnabled = "feature_treadmill_rewards_enabled",
	TutorialEnabled = "feature_tutorial_enabled",
})

local KEYS = ExperienceConfigService.Keys
local MAX_REWARD = GameplayConfig.Limits.MaxCoinReward
local MAX_DISTANCE = 1000000
local MAX_RETURN_MULTIPLIER = 100
local MAX_SAFE_INTEGER = 9007199254740991
local MIN_COST_MULTIPLIER = 1
local MAX_COST_MULTIPLIER = 10
local MIN_TREADMILL_INTERVAL = 0.1
local MAX_TREADMILL_INTERVAL = 3600
local INITIAL_LOAD_RETRY_SECONDS = 5
local MAX_INITIAL_LOAD_RETRY_SECONDS = 60

local changedEvent = Instance.new("BindableEvent")
changedEvent.Name = "ExperienceConfigChanged"

local started = false
local refreshing = false
local refreshRequested = false
local sourceSnapshot: ConfigSnapshot? = nil

local function isFiniteNumber(value: unknown): boolean
	if typeof(value) ~= "number" then
		return false
	end
	return value == value and math.abs(value) < math.huge
end

local function warnInvalid(key: string, field: string?, expected: string)
	local suffix = if field ~= nil then "." .. field else ""
	warn("[ExperienceConfigService] invalid " .. key .. suffix .. "; expected " .. expected .. ", using local default")
end

local function copyStringNumberMap(source: { [string]: number }): { [string]: number }
	local copy: { [string]: number } = {}
	for key, value in source do
		copy[key] = value
	end
	return table.freeze(copy)
end

local function copyNumberMap(source: { [number]: number }): { [number]: number }
	local copy: { [number]: number } = {}
	for key, value in source do
		copy[key] = value
	end
	return table.freeze(copy)
end

local function buildDefaultMinionShop(): MinionShopBalance
	local unlockCosts: { [string]: number } = {}
	local upgradeCosts: { [string]: number } = {}
	for minionType in ShopConfig.Minions do
		unlockCosts[minionType] = ShopConfig.getMinionUnlockCost(minionType)
		local config = ShopConfig.getMinionConfig(minionType)
		upgradeCosts[minionType] = if typeof(config.upgradeBaseCost) == "number"
			then math.max(0, math.floor(config.upgradeBaseCost))
			else ShopConfig.MinionEnergyUpgrades.BaseCost
	end
	return table.freeze({
		defaultUnlockCoinCost = ShopConfig.MinionUnlocks.DefaultCoinCost,
		unlockCoinCostByMinionType = copyStringNumberMap(unlockCosts),
		defaultUpgradeBaseCost = ShopConfig.MinionEnergyUpgrades.BaseCost,
		upgradeBaseCostByMinionType = copyStringNumberMap(upgradeCosts),
		upgradeCostMultiplier = ShopConfig.MinionEnergyUpgrades.CostMultiplier,
	})
end

local function buildDefaultCapacityCurve(): CapacityUpgradeCurve
	return table.freeze({
		baseCost = ShopConfig.EnergyCapacityUpgrades.BaseCost,
		costMultiplier = ShopConfig.EnergyCapacityUpgrades.CostMultiplier,
		capacityPerLevel = ShopConfig.EnergyCapacityUpgrades.CapacityPerLevel,
	})
end

local function buildDefaultTreadmillBalance(): TreadmillBalance
	return table.freeze({
		coinsPerAward = TreadmillConfig.Rewards.CoinsPerAward,
		awardIntervalSeconds = TreadmillConfig.Rewards.AwardIntervalSeconds,
		multiplierRemap = copyNumberMap(TreadmillConfig.MultiplierRemap),
	})
end

local function buildDefaultSnapshot(version: number): Snapshot
	return table.freeze({
		version = version,
		runCoinDistance = ShopConfig.CoinRewards.DistancePerAward,
		runCoinReward = ShopConfig.CoinRewards.CoinsPerAward,
		returnFollowerCoinRate = GameplayConfig.ReturnToSpawn.CoinsPerFollower,
		returnBaseRewardMultiplier = 1,
		minionShop = buildDefaultMinionShop(),
		capacityUpgradeCurve = buildDefaultCapacityCurve(),
		treadmill = buildDefaultTreadmillBalance(),
		features = table.freeze({
			runCoinRewardsEnabled = true,
			returnRewardsEnabled = true,
			treadmillRewardsEnabled = true,
			tutorialEnabled = true,
		}),
	})
end

local currentSnapshot = buildDefaultSnapshot(0)

local function getRemoteValue(snapshot: ConfigSnapshot, key: string): unknown
	local success, valueOrError = pcall(function()
		return snapshot:GetValue(key)
	end)
	if not success then
		warn("[ExperienceConfigService] failed to read " .. key .. ": " .. tostring(valueOrError))
		return nil
	end
	return valueOrError
end

local function validatedNumber(
	value: unknown,
	fallback: number,
	minimum: number,
	maximum: number,
	requireInteger: boolean,
	key: string,
	field: string?
): number
	if value == nil then
		return fallback
	end
	if not isFiniteNumber(value) then
		warnInvalid(key, field, if requireInteger then "an integer in range" else "a finite number in range")
		return fallback
	end
	local numberValue = value :: number
	if numberValue < minimum
		or numberValue > maximum
		or (requireInteger and numberValue ~= math.floor(numberValue))
	then
		warnInvalid(key, field, if requireInteger then "an integer in range" else "a finite number in range")
		return fallback
	end
	return numberValue
end

local function validatedBoolean(value: unknown, fallback: boolean, key: string): boolean
	if value == nil then
		return fallback
	end
	if typeof(value) ~= "boolean" then
		warnInvalid(key, nil, "a boolean")
		return fallback
	end
	return value
end

local function asJsonObject(value: unknown, key: string): { [string]: any }?
	if value == nil then
		return nil
	end
	if typeof(value) ~= "table" then
		warnInvalid(key, nil, "a JSON object")
		return nil
	end
	return value :: { [string]: any }
end

local function parseKnownStringMap(
	rawValue: unknown,
	fallback: { [string]: number },
	minimum: number,
	maximum: number,
	key: string,
	field: string
): { [string]: number }
	if rawValue ~= nil and typeof(rawValue) ~= "table" then
		warnInvalid(key, field, "a JSON object")
		return fallback
	end
	local rawMap = if typeof(rawValue) == "table" then rawValue :: { [string]: any } else nil
	local result: { [string]: number } = {}
	for knownName, fallbackValue in fallback do
		result[knownName] = validatedNumber(
			if rawMap ~= nil then rawMap[knownName] else nil,
			fallbackValue,
			minimum,
			maximum,
			true,
			key,
			field .. "." .. knownName
		)
	end
	return table.freeze(result)
end

local function parseMinionShop(snapshot: ConfigSnapshot, fallback: MinionShopBalance): MinionShopBalance
	local key = KEYS.MinionShop
	local raw = asJsonObject(getRemoteValue(snapshot, key), key)
	if raw == nil then
		return fallback
	end
	return table.freeze({
		defaultUnlockCoinCost = validatedNumber(
			raw.defaultUnlockCoinCost,
			fallback.defaultUnlockCoinCost,
			0,
			MAX_SAFE_INTEGER,
			true,
			key,
			"defaultUnlockCoinCost"
		),
		unlockCoinCostByMinionType = parseKnownStringMap(
			raw.unlockCoinCostByMinionType,
			fallback.unlockCoinCostByMinionType,
			0,
			MAX_SAFE_INTEGER,
			key,
			"unlockCoinCostByMinionType"
		),
		defaultUpgradeBaseCost = validatedNumber(
			raw.defaultUpgradeBaseCost,
			fallback.defaultUpgradeBaseCost,
			0,
			MAX_SAFE_INTEGER,
			true,
			key,
			"defaultUpgradeBaseCost"
		),
		upgradeBaseCostByMinionType = parseKnownStringMap(
			raw.upgradeBaseCostByMinionType,
			fallback.upgradeBaseCostByMinionType,
			0,
			MAX_SAFE_INTEGER,
			key,
			"upgradeBaseCostByMinionType"
		),
		upgradeCostMultiplier = validatedNumber(
			raw.upgradeCostMultiplier,
			fallback.upgradeCostMultiplier,
			MIN_COST_MULTIPLIER,
			MAX_COST_MULTIPLIER,
			false,
			key,
			"upgradeCostMultiplier"
		),
	})
end

local function parseCapacityCurve(snapshot: ConfigSnapshot, fallback: CapacityUpgradeCurve): CapacityUpgradeCurve
	local key = KEYS.CapacityUpgradeCurve
	local raw = asJsonObject(getRemoteValue(snapshot, key), key)
	if raw == nil then
		return fallback
	end
	return table.freeze({
		baseCost = validatedNumber(raw.baseCost, fallback.baseCost, 0, MAX_SAFE_INTEGER, true, key, "baseCost"),
		costMultiplier = validatedNumber(
			raw.costMultiplier,
			fallback.costMultiplier,
			MIN_COST_MULTIPLIER,
			MAX_COST_MULTIPLIER,
			false,
			key,
			"costMultiplier"
		),
		capacityPerLevel = validatedNumber(
			raw.capacityPerLevel,
			fallback.capacityPerLevel,
			0,
			GameplayConfig.Limits.MaxEnergyValue,
			true,
			key,
			"capacityPerLevel"
		),
	})
end

local function parseTreadmillMap(
	rawValue: unknown,
	fallback: { [number]: number },
	key: string
): { [number]: number }
	if rawValue ~= nil and typeof(rawValue) ~= "table" then
		warnInvalid(key, "multiplierRemap", "a JSON object")
		return fallback
	end
	local rawMap = if typeof(rawValue) == "table" then rawValue :: { [string]: any } else nil
	local result: { [number]: number } = {}
	for modelMultiplier, fallbackValue in fallback do
		local stringKey = tostring(modelMultiplier)
		result[modelMultiplier] = validatedNumber(
			if rawMap ~= nil then rawMap[stringKey] else nil,
			fallbackValue,
			1,
			TreadmillConfig.MaxMultiplier,
			true,
			key,
			"multiplierRemap." .. stringKey
		)
	end
	return table.freeze(result)
end

local function parseTreadmill(snapshot: ConfigSnapshot, fallback: TreadmillBalance): TreadmillBalance
	local key = KEYS.TreadmillBalance
	local raw = asJsonObject(getRemoteValue(snapshot, key), key)
	if raw == nil then
		return fallback
	end
	return table.freeze({
		coinsPerAward = validatedNumber(
			raw.coinsPerAward,
			fallback.coinsPerAward,
			0,
			MAX_REWARD,
			true,
			key,
			"coinsPerAward"
		),
		awardIntervalSeconds = validatedNumber(
			raw.awardIntervalSeconds,
			fallback.awardIntervalSeconds,
			MIN_TREADMILL_INTERVAL,
			MAX_TREADMILL_INTERVAL,
			false,
			key,
			"awardIntervalSeconds"
		),
		multiplierRemap = parseTreadmillMap(raw.multiplierRemap, fallback.multiplierRemap, key),
	})
end

local function buildSnapshot(snapshot: ConfigSnapshot, version: number): Snapshot
	local fallback = buildDefaultSnapshot(version)
	return table.freeze({
		version = version,
		runCoinDistance = validatedNumber(
			getRemoteValue(snapshot, KEYS.RunCoinDistance),
			fallback.runCoinDistance,
			1,
			MAX_DISTANCE,
			false,
			KEYS.RunCoinDistance,
			nil
		),
		runCoinReward = validatedNumber(
			getRemoteValue(snapshot, KEYS.RunCoinReward),
			fallback.runCoinReward,
			0,
			MAX_REWARD,
			true,
			KEYS.RunCoinReward,
			nil
		),
		returnFollowerCoinRate = validatedNumber(
			getRemoteValue(snapshot, KEYS.ReturnFollowerCoinRate),
			fallback.returnFollowerCoinRate,
			0,
			MAX_REWARD,
			true,
			KEYS.ReturnFollowerCoinRate,
			nil
		),
		returnBaseRewardMultiplier = validatedNumber(
			getRemoteValue(snapshot, KEYS.ReturnBaseRewardMultiplier),
			fallback.returnBaseRewardMultiplier,
			0,
			MAX_RETURN_MULTIPLIER,
			false,
			KEYS.ReturnBaseRewardMultiplier,
			nil
		),
		minionShop = parseMinionShop(snapshot, fallback.minionShop),
		capacityUpgradeCurve = parseCapacityCurve(snapshot, fallback.capacityUpgradeCurve),
		treadmill = parseTreadmill(snapshot, fallback.treadmill),
		features = table.freeze({
			runCoinRewardsEnabled = validatedBoolean(
				getRemoteValue(snapshot, KEYS.RunCoinRewardsEnabled),
				fallback.features.runCoinRewardsEnabled,
				KEYS.RunCoinRewardsEnabled
			),
			returnRewardsEnabled = validatedBoolean(
				getRemoteValue(snapshot, KEYS.ReturnRewardsEnabled),
				fallback.features.returnRewardsEnabled,
				KEYS.ReturnRewardsEnabled
			),
			treadmillRewardsEnabled = validatedBoolean(
				getRemoteValue(snapshot, KEYS.TreadmillRewardsEnabled),
				fallback.features.treadmillRewardsEnabled,
				KEYS.TreadmillRewardsEnabled
			),
			tutorialEnabled = validatedBoolean(
				getRemoteValue(snapshot, KEYS.TutorialEnabled),
				fallback.features.tutorialEnabled,
				KEYS.TutorialEnabled
			),
		}),
	})
end

local function publishSnapshot(nextSnapshot: Snapshot)
	currentSnapshot = nextSnapshot
	changedEvent:Fire(nextSnapshot)
end

local function refreshFromSource()
	if refreshing then
		refreshRequested = true
		return
	end
	refreshing = true
	repeat
		refreshRequested = false
		local snapshot = sourceSnapshot
		if snapshot == nil then
			break
		end
		local success, refreshError = pcall(function()
			snapshot:Refresh()
		end)
		if not success then
			warn("[ExperienceConfigService] failed to refresh configuration; keeping last valid snapshot: " .. tostring(refreshError))
			break
		end
		publishSnapshot(buildSnapshot(snapshot, currentSnapshot.version + 1))
	until not refreshRequested
	refreshing = false
end

local function loadInitialSnapshot()
	local retrySeconds = INITIAL_LOAD_RETRY_SECONDS
	while sourceSnapshot == nil do
		local success, snapshotOrError = pcall(function()
			return ConfigService:GetConfigAsync()
		end)
		if success then
			local snapshot = snapshotOrError :: ConfigSnapshot
			sourceSnapshot = snapshot
			snapshot.UpdateAvailable:Connect(function()
				task.spawn(refreshFromSource)
			end)
			publishSnapshot(buildSnapshot(snapshot, currentSnapshot.version + 1))
			print("[ExperienceConfigService] remote configuration synchronized")
			return
		end

		warn(
			"[ExperienceConfigService] initial configuration load failed; using local defaults and retrying in "
				.. retrySeconds
				.. " seconds: "
				.. tostring(snapshotOrError)
		)
		task.wait(retrySeconds)
		retrySeconds = math.min(retrySeconds * 2, MAX_INITIAL_LOAD_RETRY_SECONDS)
	end
end

function ExperienceConfigService.start()
	if started then
		return
	end
	started = true
	task.defer(loadInitialSnapshot)
	print("[ExperienceConfigService] started with local defaults; synchronizing remote configuration in background")
end

function ExperienceConfigService.getSnapshot(): Snapshot
	return currentSnapshot
end

function ExperienceConfigService.getChangedSignal(): RBXScriptSignal
	return changedEvent.Event
end

return ExperienceConfigService
