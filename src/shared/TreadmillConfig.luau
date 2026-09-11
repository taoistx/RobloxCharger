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

-- x1 免费；x3、x15、x50 通过一次性 Game Pass 永久解锁。
TreadmillConfig.PaidMultiplierThreshold = 3
TreadmillConfig.GamePassIdByMultiplier = {
	-- 各倍率对应的 Game Pass ID，必须与 Creator Dashboard 中的通行证一致。
	[3] = 1976612913, -- Gold Treadmill
	[15] = 1979882458, -- Candy Treadmill
	[50] = 1975304919, -- Jade Treadmill
	[100] = 0,
} :: { [number]: number }

TreadmillConfig.Prompt = {
	-- 付费跑步机 ProximityPrompt 的实例名称。
	Name = "TreadmillUnlockPrompt",
	-- 玩家看到的交互对象文本。
	ObjectText = "永久解锁跑步机",
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

return TreadmillConfig
