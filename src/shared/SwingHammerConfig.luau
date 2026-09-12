--!strict

--[[
	`SwingHammer` tag: Model.
	Required direct children: BaseParts named `Arm`, `HammerHead`, and `Post`.
	Despite its legacy name, `HammerHead` is the fixed pivot part. `Arm` and `Post`
	(the visible impact head) rotate together around the `SwingPivot` Attachment,
	which must be a direct child of `HammerHead`. The server evaluates the same
	virtual `Post` trajectory for authoritative knockback and energy damage.

	Optional root attributes:
	- SwingAmplitudeDegrees: number in 0..180 (default 75).
	- SwingSpeedRadians: number in 0.01..20 (default 2.7).
	- SwingPhaseRadians: number in -1000..1000 (default 0).
]]

local SwingHammerConfig = {}

SwingHammerConfig.Names = {
	AnimatedArm = "Arm",
	PivotPart = "HammerHead",
	ImpactPart = "Post",
	PivotAttachment = "SwingPivot",
}

SwingHammerConfig.Defaults = {
	AmplitudeDegrees = 75,
	SpeedRadians = 2.7,
	PhaseRadians = 0,
	KnockbackSpeed = 60,
	KnockbackUpwardSpeed = 50,
	HitCooldownSeconds = 0.5,
}

SwingHammerConfig.Limits = {
	MaxAmplitudeDegrees = 180,
	MinSpeedRadians = 0.01,
	MaxSpeedRadians = 20,
	MaxAbsPhaseRadians = 1000,
}

function SwingHammerConfig.getAngleRadians(amplitudeDegrees: number, speedRadians: number, phaseRadians: number, serverTime: number): number
	return math.sin(serverTime * speedRadians + phaseRadians) * math.rad(amplitudeDegrees)
end

function SwingHammerConfig.getRotatedCFrame(baseCFrame: CFrame, pivotCFrame: CFrame, angleRadians: number): CFrame
	return pivotCFrame * CFrame.Angles(0, 0, angleRadians) * pivotCFrame:Inverse() * baseCFrame
end

return SwingHammerConfig
