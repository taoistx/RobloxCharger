--!strict

local GameplayConfig = {}

GameplayConfig.Tags = {
	GameZone = "GameZone",
	Minion = "Minion",
	MinionPicker = "MinionPicker",
	MinionModifier = "MinionModifier",
	RandomMinionModifierGroup = "RandomMinionModifierGroup",
	Trap = "Trap",
	KillZone = "KillZone",
	Boss = "Boss",
}

GameplayConfig.Attributes = {
	PlayerLevel = "PlayerLevel",
	CurrentExperience = "CurrentExperience",
	ExperienceToNextLevel = "ExperienceToNextLevel",
	CurrentEnergy = "CurrentEnergy",
	EnergyCapacity = "EnergyCapacity",
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
}

GameplayConfig.FollowerStates = {
	Following = "Following",
	Knockback = "Knockback",
	Removed = "Removed",
}

GameplayConfig.MinionVisual = {
	Modes = {
		Auto = "Auto",
		Animated = "Animated",
		Static = "Static",
	},
	DefaultMode = "Auto",
	MaxAbsFacingYawDegrees = 3600,
	MaxAbsGroundOffsetStuds = 20,
}

GameplayConfig.InstanceNames = {
	MinionFollowerStorage = "MinionFollowerStorage",
	MinionSpawnSessions = "MinionSpawnSessions",
	MinionTemplates = "MinionTemplates",
	MinionPickupTemplate = "pickBall",
	MinionPickupFeedback = "MinionPickupFeedback",
	ProgressionFeedback = "ProgressionFeedback",
	RandomMinionModifierAssignment = "RandomMinionModifierAssignment",
	RandomMinionModifierUpdate = "RandomMinionModifierUpdate",
	BossDefeatFeedback = "BossDefeatFeedback",
}

GameplayConfig.Defaults = {
	PlayerLevel = 1,
	PlayerRespawnSeconds = 0.5,
	BaseCapacity = 120,
	CapacityPerLevel = 100,
	EnergyPerStud = 0.1,
	-- Running distance accumulated before energy is awarded.
	DistancePerEnergyAward = 10,
	IdleEnergyDrainPerSecond = 5,
	MinionEnergyValue = 10,
	MinionSpawnCount = 10,
	MinionSpawnMinSpacing = 5,
	TrapTouchCooldownSeconds = 1,
	BossRequiredEnergy = 100,
}

GameplayConfig.MinionPickup = {
	Feedback = {
		SoundId = "rbxassetid://15004790432",
		SoundVolume = 0.6,
	},
}

GameplayConfig.Boss = {
	TouchValidationDistance = 12,
	ObjectiveRefreshSeconds = 0.1,
	Fragments = {
		Color = Color3.fromRGB(220, 38, 52),
		Count = 24,
		SizeMin = 0.4,
		SizeMax = 0.75,
		SpreadCap = 8,
		LifetimeSeconds = 4,
		HorizontalImpulseMin = 14,
		HorizontalImpulseMax = 28,
		UpwardImpulseMin = 30,
		UpwardImpulseMax = 55,
		AngularImpulseMax = 12,
	},
}

-- Experience requirements are keyed by the level the player is reaching.
-- Example: ExperienceRequiredByTargetLevel[2] is the XP needed from level 1 to 2.
GameplayConfig.Progression = {
	StartingLevel = 1,
	InitialExperienceRequired = 100,
	ExperienceRequiredByTargetLevel = {
		[2] = 100,
		[3] = 200,
		[4] = 400,
		[5] = 800,
	},
	FallbackExperienceIncreasePercent = 100,
	-- Distance in studs per experience award.
    DistancePerExperienceAward = 100,
    -- Experience per distance award.
	ExperiencePerDistanceAward = 1,
	DataStoreName = "PlayerProgression_v1",
	SaveIntervalSeconds = 60,
	Feedback = {
		ExperienceSoundId = "rbxassetid://9113856580",
		SoundVolume = 0.55,
		PopupDurationSeconds = 0.7,
		PopupRiseStuds = 2.5,
	},
}

GameplayConfig.Limits = {
	MaxPlayerLevel = 1000,
	MaxEnergyValue = 1000000,
	MaxBossRequiredEnergy = 1000000,
	MaxGameZoneIndex = 1000000,
	MaxForcedRunSpeed = 200,
	MaxMinionsPerGameZone = 1000,
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
