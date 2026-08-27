--!strict

local GameplayConfig = {}

GameplayConfig.Tags = {
	GameZone = "GameZone",
	Minion = "Minion",
	Boss = "Boss",
}

GameplayConfig.Attributes = {
	PlayerLevel = "PlayerLevel",
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

return GameplayConfig
