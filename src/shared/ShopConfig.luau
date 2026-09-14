--!strict

local ShopConfig = {}
local MAX_SAFE_INTEGER = 9007199254740991

export type MinionConfig = {
	displayName: string?,
	unlockCoinCost: number?,
	upgradeBaseCost: number?,
	gamePassId: number?,
}

export type MinionShopBalance = {
	defaultUnlockCoinCost: number,
	unlockCoinCostByMinionType: { [string]: number },
	defaultUpgradeBaseCost: number,
	upgradeBaseCostByMinionType: { [string]: number },
	upgradeCostMultiplier: number,
}

export type CapacityUpgradeCurve = {
	baseCost: number,
	costMultiplier: number,
	capacityPerLevel: number,
}

-- 游戏币、容量升级、小兵解锁和小兵能量升级使用的 DataStore 名称。
ShopConfig.DataStoreName = "PlayerShop_v1"
-- 新玩家默认拥有的小兵模板名称，必须匹配 MinionTemplates 下的对象名。
ShopConfig.DefaultUnlockedMinionType = "rabbit"

ShopConfig.CoinRewards = {
	-- 在 GameZone 内累计多少 studs 的有效跑动后结算一次 Coins。
	DistancePerAward = 20,
	-- 每次跑动距离结算获得的 Coins 数量。
	CoinsPerAward = 1,
}

ShopConfig.CoinPresentation = {
	-- Free "Coin For GUI" Creator Store asset:
	-- https://create.roblox.com/store/asset/124427641438396
	-- Coins 反馈界面显示的图标资源。
	IconImage = "rbxassetid://75544237668184",
	Feedback = {
		-- 获得 Coins 时播放的本地音效资源。
		SoundId = "rbxassetid://9113856580",
		-- Coins 音效音量。
		SoundVolume = 0.55,
		-- Coins 浮字显示时长（秒）。
		PopupDurationSeconds = 0.7,
		-- Coins 浮字上升距离（stud）。
		PopupRiseStuds = 2.5,
	},
	-- ReturnToSpawn 的 Coins 在角色头顶显示，节奏比普通 Coins 浮字更慢。
	ReturnToSpawnFeedback = {
		-- 返航奖励浮字显示时长（秒）。
		PopupDurationSeconds = 1.2,
		-- 返航奖励浮字上升距离（stud）。
		PopupRiseStuds = 1.1,
		-- 返航奖励浮字的水平漂移范围（stud）。
		HorizontalDriftMin = 0.2,
		HorizontalDriftMax = 0.55,
	},
}

ShopConfig.MinionEnergyUpgrades = {
	-- 小兵能量升级的默认初始价格（Coins）。
	BaseCost = 10,
	-- 小兵能量升级价格随当前等级增长的倍率。
	CostMultiplier = 1.5,
	-- 每个兵种可购买的能量升级最高等级。
	MaxLevel = 100,
}

ShopConfig.EnergyCapacityUpgrades = {
	-- 玩家通过 EnergyCapacityUpgrade Part 购买容量升级时，每级增加的能量上限。
	CapacityPerLevel = 20,
	-- 玩家持续站在 EnergyCapacityUpgrade Part 上时，自动重复购买的间隔（秒）。
	AutoPurchaseIntervalSeconds = 0.75,
	-- 容量升级的初始价格（Coins）。
	BaseCost = 10,
	-- 容量升级价格随当前等级增长的倍率。
	CostMultiplier = 1.7,
	-- 容量升级最高等级。
	MaxLevel = 100,
	Feedback = {
		-- 玩家成功在 EnergyCapacityUpgrade 区域购买升级时播放的本地音效。
		SoundId = "rbxassetid://131886985",
		SoundVolume = 0.6,
	},
}

ShopConfig.MinionUnlocks = {
	-- 非默认小兵没有单独配置价格时使用的 Coins 解锁价格。
	DefaultCoinCost = 500,
}

ShopConfig.PurchaseActions = {
	-- 客户端请求购买时使用的操作名称。
	UnlockMinion = "UnlockMinion",
	UpgradeMinionEnergy = "UpgradeMinionEnergy",
}

ShopConfig.Prompt = {
	-- 商店 ProximityPrompt 的实例名称。
	Name = "ShopPrompt",
	-- 玩家看到的交互动作文本。
	ActionText = "Open",
	-- 玩家看到的交互对象文本。
	ObjectText = "Shop",
	-- 打开商店所需的键盘按键。
	KeyboardKeyCode = Enum.KeyCode.E,
	-- 玩家可以触发提示的最大距离（stud）。
	MaxActivationDistance = 12,
	-- 按键需要持续按住的时间（秒）。
	HoldDuration = 0,
}

-- 下方表项以小兵模板名称为 key；gamePassId 用于一次性 Robux 永久解锁。
ShopConfig.Minions = {
	rabbit = {
		-- 商店界面显示的小兵名称，不参与模板匹配。
		displayName = "Rabbit",
		-- 该小兵的 Coins 解锁价格；默认小兵固定为 0。
		unlockCoinCost = 0,
		-- 该小兵能量升级的初始价格（Coins）。
		upgradeBaseCost = 10,
		-- Game Pass ID；大于 0 时显示 Robux 解锁入口。
		gamePassId = 0,
	},
	cat = {
		displayName = "Cat",
		unlockCoinCost = 500,
		upgradeBaseCost = 10,
		-- 玩家可以使用 Coins 或对应 Game Pass 永久解锁。
		gamePassId = 1976408911,
	},
	dog = {
		displayName = "Dog",
		unlockCoinCost = 500,
		upgradeBaseCost = 10,
		-- 玩家可以使用 Coins 或对应 Game Pass 永久解锁。
		gamePassId = 1979360662,
	},
} :: { [string]: MinionConfig }

local function sanitizeLevel(level: number, maximum: number): number
	if level ~= level then
		return 0
	end
	return math.clamp(math.floor(level), 0, maximum)
end

local function getScaledCost(baseCost: number, multiplier: number, currentLevel: number, maxLevel: number): number?
	local safeLevel = sanitizeLevel(currentLevel, maxLevel)
	if safeLevel >= maxLevel then
		return nil
	end
	return math.min(
		MAX_SAFE_INTEGER,
		math.max(0, math.ceil(math.max(0, baseCost) * multiplier ^ safeLevel))
	)
end

function ShopConfig.getMinionConfig(minionType: string): MinionConfig
	return ShopConfig.Minions[minionType] or {}
end

function ShopConfig.getMinionDisplayName(minionType: string): string
	local config = ShopConfig.getMinionConfig(minionType)
	if typeof(config.displayName) == "string" and config.displayName ~= "" then
		return config.displayName
	end
	return minionType
end

function ShopConfig.getMinionUnlockCost(minionType: string, balance: MinionShopBalance?): number
	if minionType == ShopConfig.DefaultUnlockedMinionType then
		return 0
	end
	if balance ~= nil then
		local configuredCost = balance.unlockCoinCostByMinionType[minionType]
		if configuredCost ~= nil then
			return math.floor(configuredCost)
		end
		return math.floor(balance.defaultUnlockCoinCost)
	end
	local config = ShopConfig.getMinionConfig(minionType)
	if typeof(config.unlockCoinCost) == "number" and config.unlockCoinCost >= 0 then
		return math.floor(config.unlockCoinCost)
	end
	return ShopConfig.MinionUnlocks.DefaultCoinCost
end

function ShopConfig.getMinionUpgradeCost(
	minionType: string,
	currentLevel: number,
	balance: MinionShopBalance?
): number?
	local config = ShopConfig.getMinionConfig(minionType)
	local baseCost: number
	local costMultiplier: number
	if balance ~= nil then
		baseCost = balance.upgradeBaseCostByMinionType[minionType] or balance.defaultUpgradeBaseCost
		costMultiplier = balance.upgradeCostMultiplier
	else
		baseCost = if typeof(config.upgradeBaseCost) == "number"
			then config.upgradeBaseCost
			else ShopConfig.MinionEnergyUpgrades.BaseCost
		costMultiplier = ShopConfig.MinionEnergyUpgrades.CostMultiplier
	end
	return getScaledCost(
		baseCost,
		costMultiplier,
		currentLevel,
		ShopConfig.MinionEnergyUpgrades.MaxLevel
	)
end


function ShopConfig.getCapacityUpgradeCost(currentLevel: number, curve: CapacityUpgradeCurve?): number?
	return getScaledCost(
		if curve ~= nil then curve.baseCost else ShopConfig.EnergyCapacityUpgrades.BaseCost,
		if curve ~= nil then curve.costMultiplier else ShopConfig.EnergyCapacityUpgrades.CostMultiplier,
		currentLevel,
		ShopConfig.EnergyCapacityUpgrades.MaxLevel
	)
end

function ShopConfig.getMinionEnergyBonus(upgradeLevel: number, energyUpgradePerLevel: number): number
	local safeLevel = sanitizeLevel(upgradeLevel, ShopConfig.MinionEnergyUpgrades.MaxLevel)
	local safeEnergyUpgradePerLevel = math.max(0, math.floor(energyUpgradePerLevel))
	return safeLevel * safeEnergyUpgradePerLevel
end

function ShopConfig.getCapacityBonus(upgradeLevel: number, curve: CapacityUpgradeCurve?): number
	local safeLevel = sanitizeLevel(upgradeLevel, ShopConfig.EnergyCapacityUpgrades.MaxLevel)
	local capacityPerLevel = if curve ~= nil then curve.capacityPerLevel else ShopConfig.EnergyCapacityUpgrades.CapacityPerLevel
	return safeLevel * capacityPerLevel
end

return ShopConfig
