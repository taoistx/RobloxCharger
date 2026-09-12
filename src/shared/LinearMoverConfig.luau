--!strict

--[[
	`LinearMover` tag: Model with a PrimaryPart.
	Required root attributes:
	- MoveAxis: "X", "Y", or "Z" in world space.
	- MoveRange: total endpoint-to-endpoint distance in studs, 0.01..10,000.
	- MoveSpeed: travel speed in studs per second, 0.01..1,000.
	Optional root attribute:
	- MovePhase: normalized cycle offset in 0..1 (default 0).

	The authored model pivot is the center of travel. Motion is derived from
	Workspace:GetServerTimeNow(), so clients render smoothly without server CFrame
	replication and the server can evaluate the same authoritative trajectory.
]]

local LinearMoverConfig = {}

LinearMoverConfig.Defaults = {
	Phase = 0,
	KnockbackSpeed = 60,
	KnockbackUpwardSpeed = 35,
}

LinearMoverConfig.Limits = {
	MinRange = 0.01,
	MaxRange = 10_000,
	MinSpeed = 0.01,
	MaxSpeed = 1_000,
}

function LinearMoverConfig.getAxisVector(axis: string): Vector3?
	if axis == "X" then
		return Vector3.xAxis
	elseif axis == "Y" then
		return Vector3.yAxis
	elseif axis == "Z" then
		return Vector3.zAxis
	end
	return nil
end

function LinearMoverConfig.getOffsetAndDirection(moveRange: number, moveSpeed: number, phase: number, serverTime: number): (number, number)
	local cycleDistance = moveRange * 2
	local phaseDistance = ((serverTime * moveSpeed) + (phase % 1) * cycleDistance) % cycleDistance
	local halfRange = moveRange * 0.5

	if phaseDistance < halfRange then
		return phaseDistance, 1
	elseif phaseDistance < moveRange + halfRange then
		return moveRange - phaseDistance, -1
	end
	return phaseDistance - cycleDistance, 1
end

function LinearMoverConfig.getCFrame(baseCFrame: CFrame, axisVector: Vector3, moveRange: number, moveSpeed: number, phase: number, serverTime: number): CFrame
	local offset = LinearMoverConfig.getOffsetAndDirection(moveRange, moveSpeed, phase, serverTime)
	return baseCFrame + axisVector * offset
end

return LinearMoverConfig
