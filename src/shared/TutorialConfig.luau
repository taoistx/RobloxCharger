--!strict

local TutorialConfig = {}

TutorialConfig.Stages = {
	GameZone = "GameZone",
	AwaitFirstDeath = "AwaitFirstDeath",
	EnergyCapacityUpgrade = "EnergyCapacityUpgrade",
	AwaitSecondDeath = "AwaitSecondDeath",
	Shop = "Shop",
	Complete = "Complete",
}

TutorialConfig.StageAttribute = "TutorialStage"
TutorialConfig.TargetReachedRemoteName = "TutorialTargetReached"
TutorialConfig.DataStoreName = "PlayerTutorial_v1"
TutorialConfig.SaveVersion = 1
TutorialConfig.SaveIntervalSeconds = 60
TutorialConfig.RequestCooldownSeconds = 0.25

TutorialConfig.Guide = {
	ArrowImage = "rbxassetid://10249261576",
	-- The texture's vertical image axis is aligned with the Part's forward axis.
	-- Set this to true if the uploaded image points away from the target in-game.
	FlipArrowDirection = true,
	WidthStuds = 4,
	ThicknessStuds = 0.08,
	FootClearanceStuds = 0.08,
	MinVisibleLengthStuds = 0.5,
	ArrowTileWidthStuds = 4,
	ArrowTileLengthStuds = 4,
	Color = Color3.fromRGB(69, 211, 255),
	Transparency = 0.35,
	TextureTransparency = 0,
	RequestRetrySeconds = 0.5,
}

TutorialConfig.Targets = {
	-- Avoid running an overlap query until the character is close to an upgrade pad.
	CapacityOverlapCheckDistanceStuds = 8,
	-- Shop completion mirrors the authored ProximityPrompt activation range.
	ShopCompletionDistanceStuds = 12,
}

local validStages: { [string]: boolean } = {}
for _, stage in TutorialConfig.Stages do
	validStages[stage] = true
end

function TutorialConfig.isValidStage(value: unknown): boolean
	return typeof(value) == "string" and validStages[value] == true
end

function TutorialConfig.isActiveStage(stage: unknown): boolean
	if typeof(stage) ~= "string" then
		return false
	end
	local stages = TutorialConfig.Stages
	return stage == stages.GameZone or stage == stages.EnergyCapacityUpgrade or stage == stages.Shop
end

return TutorialConfig
