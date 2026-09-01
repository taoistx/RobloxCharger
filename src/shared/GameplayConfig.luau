--!strict

local GameplayConfig = {}

GameplayConfig.Tags = {
	GameZone = "GameZone",
	Minion = "Minion",
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
	MinionSpawnCount = "MinionSpawnCount",
	StatusMessage = "StatusMessage",
	BossImpactSequence = "BossImpactSequence",
	EnergyValue = "EnergyValue",
	FollowerCount = "FollowerCount",
	FollowerOrder = "FollowerOrder",
	FollowerOwnerUserId = "FollowerOwnerUserId",
	FollowerState = "FollowerState",
	SpawnOwnerUserId = "SpawnOwnerUserId",
	RequiredEnergy = "RequiredEnergy",
	Defeated = "Defeated",
	Collected = "Collected",
	RespawnSeconds = "RespawnSeconds",
}

GameplayConfig.FollowerStates = {
	Following = "Following",
	Knockback = "Knockback",
	Removed = "Removed",
}

GameplayConfig.InstanceNames = {
	MinionFollowerStorage = "MinionFollowerStorage",
	MinionSpawnSessions = "MinionSpawnSessions",
	MinionTemplates = "MinionTemplates",
	ProgressionFeedback = "ProgressionFeedback",
}

GameplayConfig.Defaults = {
	PlayerLevel = 1,
	BaseCapacity = 120,
	CapacityPerLevel = 100,
	EnergyPerStud = 0.65,
	IdleEnergyDrainPerSecond = 5,
	MinionEnergyValue = 10,
	MinionSpawnCount = 10,
	MinionSpawnMinSpacing = 5,
	BossRequiredEnergy = 100,
	BossRespawnSeconds = 15,
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
	DistancePerExperienceAward = 10,
	ExperiencePerDistanceAward = 5,
	DataStoreName = "PlayerProgression_v1",
	SaveIntervalSeconds = 60,
	Feedback = {
		ExperienceSoundId = "",
		SoundVolume = 0.55,
		PopupDurationSeconds = 0.7,
		PopupRiseStuds = 2.5,
	},
}

GameplayConfig.Limits = {
	MaxPlayerLevel = 1000,
	MaxEnergyValue = 1000000,
	MaxBossRequiredEnergy = 1000000,
	MaxRespawnSeconds = 3600,
	MaxGameZoneIndex = 1000000,
	MaxMinionsPerGameZone = 1000,
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
