--!strict

local GameplayConfig = {}

GameplayConfig.Tags = {
	GameZone = "GameZone",
	Minion = "Minion",
	MinionPicker = "MinionPicker",
	SwingHammer = "SwingHammer",
	LinearMover = "LinearMover",
	MinionModifier = "MinionModifier",
	RandomMinionModifierGroup = "RandomMinionModifierGroup",
	Trap = "Trap",
	KillZone = "KillZone",
	Boss = "Boss",
	Shop = "Shop",
	EnergyCapacityUpgrade = "EnergyCapacityUpgrade",
	Treadmill = "Treadmill",
	FinalZone = "FinalZone",
	-- 仅用于开发期能量验证的独立触碰 Part，不参与小兵或成长系统。
	TestEnergyReward = "TestEnergyReward",
}

GameplayConfig.Attributes = {
	PlayerLevel = "PlayerLevel",
	CurrentExperience = "CurrentExperience",
	ExperienceToNextLevel = "ExperienceToNextLevel",
	CurrentEnergy = "CurrentEnergy",
	EnergyCapacity = "EnergyCapacity",
	Coins = "Coins",
	EnergyCapacityUpgradeLevel = "EnergyCapacityUpgradeLevel",
	ShopRevision = "ShopRevision",
	IsInGameZone = "IsInGameZone",
	ZoneIndex = "ZoneIndex",
	CurrentGameZoneIndex = "CurrentGameZoneIndex",
	ForcedRunSpeed = "ForcedRunSpeed",
	ForcedRunDirection = "ForcedRunDirection",
	ForcedRunActive = "ForcedRunActive",
	MinionSpawnCount = "MinionSpawnCount",
	StatusMessage = "StatusMessage",
	BossImpactSequence = "BossImpactSequence",
	BossOwnerUserId = "BossOwnerUserId",
	EnergyValue = "EnergyValue",
	-- Minion 模板每购买一级商店能量升级所增加的能量。
	EnergyUpgradePerLevel = "EnergyUpgradePerLevel",
	-- Minion 模板在商店卡片中显示的图片资源 ID。
	MinionIconId = "MinionIconId",
	EnergyDamage = "EnergyDamage",
	MinionType = "MinionType",
	Operation = "Operation",
	Operand = "Operand",
	Enabled = "Enabled",
	FollowerCount = "FollowerCount",
	FollowerOrder = "FollowerOrder",
	FollowerOwnerUserId = "FollowerOwnerUserId",
	FollowerState = "FollowerState",
	MinionVisualMode = "MinionVisualMode",
	FacingYawDegrees = "FacingYawDegrees",
	GroundOffsetStuds = "GroundOffsetStuds",
	SpawnOwnerUserId = "SpawnOwnerUserId",
	RequiredEnergy = "RequiredEnergy",
	Defeated = "Defeated",
	Collected = "Collected",
	-- 每个运行时 picker 的不可变标识；仅用于客户端确认本地拾取反馈。
	PickupId = "PickupId",
	-- 摆锤根 Model 的可选表现/判定参数。
	SwingAmplitudeDegrees = "SwingAmplitudeDegrees",
	SwingSpeedRadians = "SwingSpeedRadians",
	SwingPhaseRadians = "SwingPhaseRadians",
	-- LinearMover 根 Model 的世界轴往复运动参数。
	MoveAxis = "MoveAxis",
	MoveRange = "MoveRange",
	MoveSpeed = "MoveSpeed",
	MovePhase = "MovePhase",
	TreadmillEnabled = "TreadmillEnabled",
	TreadmillGamePassId = "TreadmillGamePassId",
	ActiveTreadmillMultiplier = "ActiveTreadmillMultiplier",
}

GameplayConfig.FollowerStates = {
	Following = "Following",
	Knockback = "Knockback",
	Removed = "Removed",
}

GameplayConfig.MinionVisual = {
	-- 跟随小兵的视觉模式枚举；Auto 会根据模型是否具备完整关节自动选择表现。
	Modes = {
		Auto = "Auto",
		Animated = "Animated",
		Static = "Static",
	},
	-- 小兵没有单独设置 MinionVisualMode 时使用的默认模式。
	DefaultMode = "Auto",
	-- 场景 FacingYawDegrees 属性允许的绝对值上限（度）。
	MaxAbsFacingYawDegrees = 3600,
	-- 场景 GroundOffsetStuds 属性允许的绝对值上限（stud）。
	MaxAbsGroundOffsetStuds = 20,
}

GameplayConfig.InstanceNames = {
	MinionFollowerStorage = "MinionFollowerStorage",
	MinionSpawnSessions = "MinionSpawnSessions",
	MinionTemplates = "MinionTemplates",
	MinionPickupTemplate = "pickBall",
	MinionPickupFeedback = "MinionPickupFeedback",
	ProgressionFeedback = "ProgressionFeedback",
	CoinAwardFeedback = "CoinAwardFeedback",
	RandomMinionModifierAssignment = "RandomMinionModifierAssignment",
	RandomMinionModifierUpdate = "RandomMinionModifierUpdate",
	BossDefeatFeedback = "BossDefeatFeedback",
	ShopGetSnapshot = "ShopGetSnapshot",
	ShopPurchase = "ShopPurchase",
	ShopUpdated = "ShopUpdated",
	ShopOpenRequested = "ShopOpenRequested",
	EnergyCapacityUpgradeFeedback = "EnergyCapacityUpgradeFeedback",
	TreadmillPromptPurchase = "TreadmillPromptPurchase",
	FinalCelebration = "FinalCelebration",
}

GameplayConfig.Final = {
	-- 终点音效接近播放完毕后，由服务端执行清场和传送。
	CelebrationDurationSeconds = 2,
	Celebration = {
		-- Creator Store: APMOfficial / Early Bird - Hit1（约 2 秒）。
		SoundId = "rbxassetid://9040476898",
		SoundVolume = 0.7,
		R6AnimationId = "rbxassetid://129423030",
		R15AnimationId = "rbxassetid://507770677",
	},
}

GameplayConfig.Defaults = {
	-- 玩家没有等级属性时使用的默认等级。
	PlayerLevel = 1,
	-- 玩家死亡后由 GameplayBootstrap 写入 Players.RespawnTime 的重生间隔（秒）。
	PlayerRespawnSeconds = 0.5,
	-- 玩家基础战力容量；当前容量公式为基础容量加 EnergyCapacityUpgrade 区域购买的升级加成。
	BaseCapacity = 50,
	-- 预留的等级容量增量配置；当前容量不再按等级增长。
	CapacityPerLevel = 100,
	-- 每个完整跑动距离结算段换算的战力（战力/stud）。
	EnergyPerStud = 0,
	-- 累计多少 studs 才结算一份跑动战力，未满部分保留到下一次跑动。
	DistancePerEnergyAward = 1000,
	-- 玩家位于 GameZone 但没有有效跑动时每秒消耗的战力。
	IdleEnergyDrainPerSecond = 0,
	-- 未单独配置士兵模板 EnergyValue 时的保留默认战力。
	MinionEnergyValue = 10,
	-- GameZone 未设置或填写无效 MinionSpawnCount 时的默认拾取物数量。
	MinionSpawnCount = 10,
	-- 同一玩家同一区域内拾取物之间的最小水平间距（stud）。
	MinionSpawnMinSpacing = 5,
	-- 同一玩家触发同一个陷阱的服务端冷却时间（秒）。
	TrapTouchCooldownSeconds = 1,
	-- 未设置 Boss RequiredEnergy 属性时的保留默认门槛。
	BossRequiredEnergy = 100,
}

GameplayConfig.MinionPickup = {
	Feedback = {
		-- 玩家拾取小兵时客户端播放的音效资源。
		SoundId = "rbxassetid://15004790432",
		-- 拾取音效音量，通常范围为 0..1。
		SoundVolume = 0.6,
	},
}

GameplayConfig.Boss = {
	-- 服务端判定角色接触 Boss 时允许的额外距离容差（stud）。
	TouchValidationDistance = 12,
	-- 客户端刷新最近 Boss 目标提示的间隔（秒）。
	ObjectiveRefreshSeconds = 0.1,
	Objective = {
		-- Boss 目标提示开始显示的最大距离（stud）。
		DisplayDistance = 200,
		-- 玩家接近到该距离内时切换为近距离提示样式（stud）。
		NearDistance = 44,
		-- Boss 目标提示的像素尺寸。
		Size = Vector2.new(120, 110),
		-- 目标提示宽度占屏幕宽度的最大比例。
		MaxViewportWidthFraction = 0.8,
		-- 目标提示相对角色脚底的高度（stud）。
		FootHeight = 1.5,
		-- 目标提示在角色前方的偏移（stud）。
		FrontOffset = 0.5,
		-- 目标提示脉冲时的最大缩放倍数。
		PulseScale = 1.1,
		-- 目标提示完成一次脉冲所需的时间（秒）。
		PulseDurationSeconds = 0.35,
		-- 目标提示面板背景颜色。
		BackgroundColor = Color3.fromRGB(18, 23, 34),
		-- 目标提示强调色。
		AccentColor = Color3.fromRGB(255, 196, 74),
	},
	Fragments = {
		-- Boss 被击败后碎片的颜色。
		Color = Color3.fromRGB(220, 38, 52),
		-- Boss 被击败后生成的碎片数量。
		Count = 24,
		-- 碎片随机尺寸的最小值。
		SizeMin = 0.4,
		-- 碎片随机尺寸的最大值。
		SizeMax = 0.75,
		-- 碎片初始散开的最大距离（stud）。
		SpreadCap = 8,
		-- 碎片存在时间（秒）。
		LifetimeSeconds = 4,
		-- 碎片水平冲量的最小值。
		HorizontalImpulseMin = 14,
		-- 碎片水平冲量的最大值。
		HorizontalImpulseMax = 28,
		-- 碎片向上冲量的最小值。
		UpwardImpulseMin = 30,
		-- 碎片向上冲量的最大值。
		UpwardImpulseMax = 55,
		-- 碎片随机角冲量的最大值。
		AngularImpulseMax = 12,
	},
}

-- 经验需求表的 key 是玩家即将达到的目标等级，例如 [2] 表示从 1 级升到 2 级所需经验。
GameplayConfig.Progression = {
	-- 新存档的起始等级。
	StartingLevel = 1,
	-- 经验表没有 2 级数据时使用的初始后备需求。
	InitialExperienceRequired = 100,
	-- 以目标等级为 key，填写升到该等级所需的经验。
	ExperienceRequiredByTargetLevel = {
		[2] = 100,
		[3] = 200,
		[4] = 400,
		[5] = 800,
	},
	-- 未显式配置的后续等级，经验需求相对前一级的增长百分比。
	FallbackExperienceIncreasePercent = 100,
	-- 每累计多少 studs 触发一次经验结算；当前跑动经验功能已停用。
	DistancePerExperienceAward = 100,
	-- 每次距离结算获得的经验；当前跑动经验功能已停用。
	ExperiencePerDistanceAward = 1,
	-- 等级、经验和未满一段跑动距离使用的 DataStore 名称。
	DataStoreName = "PlayerProgression_v1",
	-- 在线玩家自动保存进度的间隔（秒）。
	SaveIntervalSeconds = 60,
	Feedback = {
		-- 获得经验时播放的音效资源。
		ExperienceSoundId = "rbxassetid://9113856580",
		-- 经验音效音量。
		SoundVolume = 0.55,
		-- 经验浮字显示时长（秒）。
		PopupDurationSeconds = 0.7,
		-- 经验浮字上升距离（stud）。
		PopupRiseStuds = 2.5,
	},
}

GameplayConfig.Limits = {
	-- 服务端接受的玩家等级最大值。
	MaxPlayerLevel = 1000,
	-- 单个士兵模板 EnergyValue 和陷阱伤害的校验上限。
	MaxEnergyValue = 1000000,
	-- Boss RequiredEnergy 属性的校验上限。
	MaxBossRequiredEnergy = 1000000,
	-- GameZone.ZoneIndex 属性的校验上限。
	MaxGameZoneIndex = 1000000,
	-- GameZone 强制前进速度的校验上限（stud/秒）。
	MaxForcedRunSpeed = 200,
	-- 单个 GameZone 为单名玩家生成的拾取物数量上限。
	MaxMinionsPerGameZone = 1000,
	-- 单名玩家允许拥有的跟随士兵数量上限。
	MaxFollowersPerPlayer = 1000,
}

function GameplayConfig.getCapacityForLevel(level: number): number
	local safeLevel = math.clamp(math.floor(level), 1, GameplayConfig.Limits.MaxPlayerLevel)
	return GameplayConfig.Defaults.BaseCapacity + (safeLevel - 1) * GameplayConfig.Defaults.CapacityPerLevel
end

function GameplayConfig.getExperienceRequiredForTargetLevel(targetLevel: number): number
	local safeTargetLevel = math.clamp(math.floor(targetLevel), 2, GameplayConfig.Limits.MaxPlayerLevel)
	local progression = GameplayConfig.Progression
	local fallbackMultiplier = 1 + math.max(0, progression.FallbackExperienceIncreasePercent) / 100
	local required = math.max(1, math.ceil(progression.InitialExperienceRequired))

	for level = 2, safeTargetLevel do
		local configured = progression.ExperienceRequiredByTargetLevel[level]
		if typeof(configured) == "number" and configured > 0 then
			required = math.ceil(configured)
		elseif level > 2 then
			required = math.max(1, math.ceil(required * fallbackMultiplier))
		end
	end

	return required
end

return GameplayConfig
