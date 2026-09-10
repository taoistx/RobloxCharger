--!strict

local TreadmillConfig = {}

-- 带 Treadmill Tag 的模型名称格式；倍率从名称解析，名称是奖励倍率的权威来源。
TreadmillConfig.ModelNamePattern = "^x(%d+)%s+treadmill$"
-- 跑步机模型内承载玩家的传送带 BasePart 名称。
TreadmillConfig.ConveyorPartName = "Conveyor"
-- 模型名称允许解析出的最大倍率。
TreadmillConfig.MaxMultiplier = 100000

TreadmillConfig.Rewards = {
	-- 每次结算发放的基础 Coins 数量，再乘以跑步机倍率。
	CoinsPerAward = 1,
	-- 跑步机奖励结算间隔（秒）。
	AwardIntervalSeconds = 1,
	-- 检测传送带上方角色时允许的最大高度（stud）。
	CharacterCheckHeight = 6,
	-- 检测角色是否位于传送带水平范围内时向内缩小的边距（stud）。
	HorizontalInsetStuds = 0.35,
}

-- 跑步机永久权限通过 Game Pass 销售；x1 免费，x3 及以上需要对应权限。
-- 达到此倍率及以上的跑步机需要匹配的 Game Pass；x1 免费。
TreadmillConfig.PaidMultiplierThreshold = 3
TreadmillConfig.GamePassIdByMultiplier = {
	-- 各倍率对应的 Game Pass ID；创建商品后将 0 替换为正整数。
	[3] = 0,
	[15] = 0,
	[50] = 0,
	[100] = 0,
} :: { [number]: number }

-- 这里的价格只用于世界内提示，实际扣费以 Creator Dashboard 中的 Game Pass 定价为准。
TreadmillConfig.RobuxPriceByMultiplier = {
	-- 世界内提示使用的目标价格；实际价格以 Creator Dashboard 为准。
	[3] = 500,
} :: { [number]: number }

TreadmillConfig.Prompt = {
	-- 付费跑步机 ProximityPrompt 的实例名称。
	Name = "TreadmillUnlockPrompt",
	-- 玩家看到的交互对象文本。
	ObjectText = "Robux Treadmill",
	-- 打开购买框所需的键盘按键。
	KeyboardKeyCode = Enum.KeyCode.E,
	-- 玩家可以触发提示的最大距离（stud）。
	MaxActivationDistance = 12,
	-- 按键需要持续按住的时间（秒）。
	HoldDuration = 0,
	-- 服务端校验玩家与传送带距离时相对提示距离增加的容差（stud）。
	ServerDistanceTolerance = 3,
	-- 同一玩家重复请求购买提示的服务端冷却时间（秒）。
	CooldownSeconds = 1,
}

function TreadmillConfig.parseMultiplier(modelName: string): number?
	local multiplierText = string.match(string.lower(modelName), TreadmillConfig.ModelNamePattern)
	if multiplierText == nil then
		return nil
	end

	local multiplier = tonumber(multiplierText)
	if multiplier == nil or multiplier < 1 or multiplier > TreadmillConfig.MaxMultiplier then
		return nil
	end
	return math.floor(multiplier)
end

function TreadmillConfig.getConfiguredGamePassId(multiplier: number): number?
	local gamePassId = TreadmillConfig.GamePassIdByMultiplier[multiplier]
	if typeof(gamePassId) ~= "number" or gamePassId ~= gamePassId or gamePassId <= 0 then
		return nil
	end
	return math.floor(gamePassId)
end

function TreadmillConfig.getExpectedRobuxPrice(multiplier: number): number?
	local price = TreadmillConfig.RobuxPriceByMultiplier[multiplier]
	if typeof(price) ~= "number" or price ~= price or price <= 0 then
		return nil
	end
	return math.floor(price)
end

return TreadmillConfig
