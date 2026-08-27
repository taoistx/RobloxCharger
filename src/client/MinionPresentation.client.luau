--!strict

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local GameplayConfig = require(Shared:WaitForChild("GameplayConfig"))

type VisualRoot = BasePart | Model
type HistoryEntry = {
	time: number,
	cframe: CFrame,
}
type VisualFollower = {
	source: Instance,
	root: VisualRoot,
	owner: Player,
	order: number,
	currentCFrame: CFrame,
	stateConnection: RBXScriptConnection?,
	destroyConnection: RBXScriptConnection?,
}
type PlayerGroup = {
	followers: { VisualFollower },
	history: { HistoryEntry },
	lastRoot: BasePart?,
}
type KnockbackVisual = {
	root: VisualRoot,
	owner: Player,
	referenceCFrame: CFrame,
	startPosition: Vector3,
	startRotation: CFrame,
	peakPosition: Vector3,
	landingPosition: Vector3,
	riseDuration: number,
	fallDuration: number,
	elapsed: number,
	backwardTilt: number,
	outwardYaw: number,
	sideRoll: number,
}

local ATTRIBUTE = GameplayConfig.Attributes
local FOLLOWER_STATE = GameplayConfig.FollowerStates

-- 三角队形参数：第 1 排 2 个、第 2 排 3 个、第 3 排 4 个，以此类推。
local FORMATION_HORIZONTAL_SPACING = 1.8 -- 同一排小兵之间的横向间距。
local FORMATION_FIRST_ROW_DISTANCE = 1 -- 第一排位于玩家身后的距离。
local FORMATION_ROW_SPACING = 1 -- 每增加一排，向后增加的距离。
local FORMATION_HEIGHT_OFFSET = -2.45 -- 小兵相对 HumanoidRootPart 的高度偏移。

-- 同步位移、延迟姿态参数：小兵的水平位置始终跟随玩家，不会因跑动拉开距离。
-- 每一排只读取更早的高度与朝向，因此跳跃和转弯仍会逐排传递。
local FOLLOW_DELAY_PER_ROW = 0.09 -- 每排比上一排晚多少秒复刻高度和朝向；越大波浪感越明显。
local FOLLOW_ORIENTATION_SMOOTHNESS = 18 -- 朝向靠近延迟目标的柔和度；越大转向越利落。
local PATH_HISTORY_SECONDS = 4 -- 保存玩家最近多少秒的路径。

-- 小兵撞飞参数：全部只影响本机表现，可以直接修改后重开 Play 测试。
local KNOCKBACK_DIRECTION_RANDOM_ANGLE = 18 -- 围绕“远离玩家”的方向随机偏转的最大角度（度）。
local KNOCKBACK_PEAK_HEIGHT_MIN = 2 -- 最高点的最小高度。
local KNOCKBACK_PEAK_HEIGHT_RANDOM = 1.8 -- 最高点额外随机的高度。
local KNOCKBACK_PEAK_DISTANCE_MIN = 1.6 -- 飞到最高点前，向外移动的最小距离。
local KNOCKBACK_PEAK_DISTANCE_RANDOM = 1.6 -- 飞到最高点前，额外随机的向外距离。
local KNOCKBACK_LANDING_DISTANCE_MIN = 3.3 -- 落下时，向外移动的最小总距离。
local KNOCKBACK_LANDING_DISTANCE_RANDOM = 2.3 -- 落下时，额外随机的向外总距离。
local KNOCKBACK_PEAK_BACK_CAP = 7.5 -- 最高点在玩家本地后方的最大 Z 距离。
local KNOCKBACK_LANDING_BACK_CAP = 15 -- 落下时在玩家本地后方的最大 Z 距离。
local KNOCKBACK_LANDING_HEIGHT_MIN = 0.2 -- 落下位置比起飞位置高出的最小值。
local KNOCKBACK_LANDING_HEIGHT_RANDOM = 0.5 -- 落下位置额外随机的高度。
local KNOCKBACK_RISE_TIME_MIN = 0.15 -- 上升阶段最短时间。
local KNOCKBACK_RISE_TIME_RANDOM = 0.1 -- 上升阶段额外随机时间。
local KNOCKBACK_FALL_TIME_MIN = 0.15 -- 下落阶段最短时间。
local KNOCKBACK_FALL_TIME_RANDOM = 0.15 -- 下落阶段额外随机时间。
local KNOCKBACK_BACKWARD_TILT_DEGREES = 90 -- 最终向后翻倒的角度；90 表示完全躺倒。
local KNOCKBACK_OUTWARD_YAW_RANDOM = 45 -- 朝远离玩家的方向转向后，额外随机的左右偏角（度）。
local KNOCKBACK_SIDE_ROLL_RANDOM = 45 -- 倒地时额外随机的侧倾角（度），让每个小兵落姿不同。

local presentationFolder = Instance.new("Folder")
presentationFolder.Name = "ClientMinionPresentation"
presentationFolder.Parent = Workspace

local groupsByPlayer: { [Player]: PlayerGroup } = {}
local visualsBySource: { [Instance]: VisualFollower } = {}
local knockbackVisuals: { KnockbackVisual } = {}

local function getVisualRoot(instance: Instance): VisualRoot?
	if instance:IsA("BasePart") then
		return instance
	end
	if not instance:IsA("Model") then
		return nil
	end
	if instance.PrimaryPart == nil then
		instance.PrimaryPart = instance:FindFirstChildWhichIsA("BasePart", true)
	end
	if instance.PrimaryPart == nil then
		return nil
	end
	return instance
end

local function getParts(root: VisualRoot): { BasePart }
	if root:IsA("BasePart") then
		return { root }
	end
	local parts: { BasePart } = {}
	for _, descendant in root:GetDescendants() do
		if descendant:IsA("BasePart") then
			table.insert(parts, descendant)
		end
	end
	return parts
end

local function getPivot(root: VisualRoot): CFrame
	if root:IsA("BasePart") then
		return root.CFrame
	end
	return root:GetPivot()
end

local function pivotTo(root: VisualRoot, cframe: CFrame)
	if root:IsA("BasePart") then
		root.CFrame = cframe
	else
		root:PivotTo(cframe)
	end
end

local function getCharacterRoot(player: Player): BasePart?
	local character = player.Character
	if character == nil then
		return nil
	end
	local root = character:FindFirstChild("HumanoidRootPart")
	return if root ~= nil and root:IsA("BasePart") then root else nil
end

local function getGroup(player: Player): PlayerGroup
	local group = groupsByPlayer[player]
	if group == nil then
		group = { followers = {}, history = {}, lastRoot = nil }
		groupsByPlayer[player] = group
	end
	return group
end

local function getFormationSlot(index: number): (number, number, number)
	local row = 1
	local indexInRow = index
	local rowCapacity = row + 1
	while indexInRow > rowCapacity do
		indexInRow -= rowCapacity
		row += 1
		rowCapacity = row + 1
	end

	local centeredColumn = indexInRow - (rowCapacity + 1) / 2
	local x = centeredColumn * FORMATION_HORIZONTAL_SPACING
	local z = FORMATION_FIRST_ROW_DISTANCE + (row - 1) * FORMATION_ROW_SPACING
	return row, x, z
end

local function sampleHistory(history: { HistoryEntry }, targetTime: number): CFrame?
	if #history == 0 then
		return nil
	end
	if targetTime <= history[1].time then
		return history[1].cframe
	end

	for index = 2, #history do
		local newer = history[index]
		if newer.time >= targetTime then
			local older = history[index - 1]
			local duration = math.max(newer.time - older.time, 0.0001)
			return older.cframe:Lerp(newer.cframe, math.clamp((targetTime - older.time) / duration, 0, 1))
		end
	end
	return history[#history].cframe
end

local function removeFromFormation(follower: VisualFollower)
	local group = groupsByPlayer[follower.owner]
	if group == nil then
		return
	end
	local index = table.find(group.followers, follower)
	if index ~= nil then
		table.remove(group.followers, index)
	end
end

local function disconnectFollower(follower: VisualFollower)
	if follower.stateConnection ~= nil then
		follower.stateConnection:Disconnect()
		follower.stateConnection = nil
	end
	if follower.destroyConnection ~= nil then
		follower.destroyConnection:Disconnect()
		follower.destroyConnection = nil
	end
end

local function destroyFollowerVisual(follower: VisualFollower)
	if visualsBySource[follower.source] ~= follower then
		return
	end
	visualsBySource[follower.source] = nil
	removeFromFormation(follower)
	disconnectFollower(follower)
	if follower.root.Parent ~= nil then
		follower.root:Destroy()
	end
end

local function getOutwardDirection(startLocalPosition: Vector3, order: number): Vector3
	local horizontalDirection = Vector3.new(startLocalPosition.X, 0, startLocalPosition.Z)
	if horizontalDirection.Magnitude < 0.05 then
		local fallbackSide = if order % 2 == 0 then -0.35 else 0.35
		horizontalDirection = Vector3.new(fallbackSide, 0, 1)
	end

	local baseDirection = horizontalDirection.Unit
	local angle = math.rad((math.random() * 2 - 1) * KNOCKBACK_DIRECTION_RANDOM_ANGLE)
	local cosine = math.cos(angle)
	local sine = math.sin(angle)
	return Vector3.new(
		baseDirection.X * cosine - baseDirection.Z * sine,
		0,
		baseDirection.X * sine + baseDirection.Z * cosine
	)
end

local function startKnockback(follower: VisualFollower)
	if visualsBySource[follower.source] ~= follower then
		return
	end
	visualsBySource[follower.source] = nil
	removeFromFormation(follower)
	disconnectFollower(follower)

	local worldStart = getPivot(follower.root)
	local playerRoot = getCharacterRoot(follower.owner)
	local referenceCFrame = if playerRoot ~= nil then playerRoot.CFrame else CFrame.new(worldStart.Position)
	local startLocalCFrame = referenceCFrame:ToObjectSpace(worldStart)
	local startPosition = startLocalCFrame.Position
	local direction = getOutwardDirection(startPosition, follower.order)
	-- 让倒下后的身体朝向远离玩家的方向，而不是所有小兵都平行躺倒。
	local outwardYaw = math.atan2(direction.X, direction.Z) + math.rad((math.random() * 2 - 1) * KNOCKBACK_OUTWARD_YAW_RANDOM)
	local peakDistance = KNOCKBACK_PEAK_DISTANCE_MIN + math.random() * KNOCKBACK_PEAK_DISTANCE_RANDOM
	local landingDistance = KNOCKBACK_LANDING_DISTANCE_MIN + math.random() * KNOCKBACK_LANDING_DISTANCE_RANDOM
	local peakPosition = startPosition + direction * peakDistance + Vector3.new(0, KNOCKBACK_PEAK_HEIGHT_MIN + math.random() * KNOCKBACK_PEAK_HEIGHT_RANDOM, 0)
	local landingPosition = startPosition + direction * landingDistance + Vector3.new(0, KNOCKBACK_LANDING_HEIGHT_MIN + math.random() * KNOCKBACK_LANDING_HEIGHT_RANDOM, 0)
	peakPosition = Vector3.new(peakPosition.X, peakPosition.Y, math.min(peakPosition.Z, KNOCKBACK_PEAK_BACK_CAP))
	landingPosition = Vector3.new(landingPosition.X, landingPosition.Y, math.min(landingPosition.Z, KNOCKBACK_LANDING_BACK_CAP))

	table.insert(knockbackVisuals, {
		root = follower.root,
		owner = follower.owner,
		referenceCFrame = referenceCFrame,
		startPosition = startPosition,
		startRotation = startLocalCFrame - startLocalCFrame.Position,
		peakPosition = peakPosition,
		landingPosition = landingPosition,
		riseDuration = KNOCKBACK_RISE_TIME_MIN + math.random() * KNOCKBACK_RISE_TIME_RANDOM,
		fallDuration = KNOCKBACK_FALL_TIME_MIN + math.random() * KNOCKBACK_FALL_TIME_RANDOM,
		elapsed = 0,
		backwardTilt = math.rad(KNOCKBACK_BACKWARD_TILT_DEGREES),
		outwardYaw = outwardYaw,
		sideRoll = math.rad((math.random() * 2 - 1) * KNOCKBACK_SIDE_ROLL_RANDOM),
	})
end

local function onFollowerStateChanged(follower: VisualFollower)
	local state = follower.source:GetAttribute(ATTRIBUTE.FollowerState)
	if state == FOLLOWER_STATE.Knockback then
		startKnockback(follower)
	elseif state == FOLLOWER_STATE.Removed then
		destroyFollowerVisual(follower)
	end
end

local function addVisualSource(source: Instance)
	if visualsBySource[source] ~= nil then
		return
	end
	if source:GetAttribute(ATTRIBUTE.FollowerState) ~= FOLLOWER_STATE.Following then
		return
	end

	local ownerUserId = source:GetAttribute(ATTRIBUTE.FollowerOwnerUserId)
	local order = source:GetAttribute(ATTRIBUTE.FollowerOrder)
	if typeof(ownerUserId) ~= "number" or typeof(order) ~= "number" then
		return
	end
	local owner = Players:GetPlayerByUserId(ownerUserId)
	if owner == nil then
		task.delay(0.15, function()
			if source.Parent ~= nil then
				addVisualSource(source)
			end
		end)
		return
	end

	local clone = source:Clone()
	local visualRoot = getVisualRoot(clone)
	if visualRoot == nil then
		clone:Destroy()
		return
	end
	clone.Name = source.Name .. "_ClientVisual"
	for _, descendant in clone:GetDescendants() do
		if descendant:IsA("LuaSourceContainer") then
			descendant:Destroy()
		end
	end
	for _, part in getParts(visualRoot) do
		part.Anchored = true
		part.CanCollide = false
		part.CanQuery = false
		part.CanTouch = false
		part.Massless = true
		part.LocalTransparencyModifier = 0
	end
	clone.Parent = presentationFolder

	local follower: VisualFollower = {
		source = source,
		root = visualRoot,
		owner = owner,
		order = math.floor(order),
		currentCFrame = getPivot(visualRoot),
		stateConnection = nil,
		destroyConnection = nil,
	}
	visualsBySource[source] = follower
	local group = getGroup(owner)
	table.insert(group.followers, follower)
	table.sort(group.followers, function(left, right)
		return left.order < right.order
	end)

	follower.stateConnection = source:GetAttributeChangedSignal(ATTRIBUTE.FollowerState):Connect(function()
		onFollowerStateChanged(follower)
	end)
	follower.destroyConnection = source.Destroying:Connect(function()
		destroyFollowerVisual(follower)
	end)
	onFollowerStateChanged(follower)
end

local function updateFormation(deltaTime: number, now: number)
	for player, group in groupsByPlayer do
		if #group.followers == 0 then
			group.history = {}
			group.lastRoot = nil
			continue
		end

		local root = getCharacterRoot(player)
		if root == nil then
			continue
		end
		if group.lastRoot ~= root then
			group.lastRoot = root
			group.history = { { time = now, cframe = root.CFrame } }
		else
			table.insert(group.history, { time = now, cframe = root.CFrame })
		end
		while #group.history > 2 and group.history[2].time < now - PATH_HISTORY_SECONDS do
			table.remove(group.history, 1)
		end

		local orientationAlpha = 1 - math.exp(-FOLLOW_ORIENTATION_SMOOTHNESS * deltaTime)
		for index, follower in group.followers do
			local row, x, z = getFormationSlot(index)
			local delayedCFrame = sampleHistory(group.history, now - row * FOLLOW_DELAY_PER_ROW)
			if delayedCFrame ~= nil then
				-- 水平位移使用当前玩家位置，保证小兵速度与玩家完全同步；
				-- 只有高度与旋转读取延迟路径，让队形保留逐排传递的动态。
				local synchronizedBase = CFrame.new(root.Position.X, delayedCFrame.Position.Y, root.Position.Z) * (delayedCFrame - delayedCFrame.Position)
				local targetCFrame = synchronizedBase * CFrame.new(x, FORMATION_HEIGHT_OFFSET, z)
				local currentRotation = follower.currentCFrame - follower.currentCFrame.Position
				local targetRotation = targetCFrame - targetCFrame.Position
				follower.currentCFrame = CFrame.new(targetCFrame.Position) * currentRotation:Lerp(targetRotation, orientationAlpha)
				pivotTo(follower.root, follower.currentCFrame)
			end
		end
	end
end

local function updateKnockbacks(deltaTime: number)
	for index = #knockbackVisuals, 1, -1 do
		local effect = knockbackVisuals[index]
		effect.elapsed += deltaTime
		local totalDuration = effect.riseDuration + effect.fallDuration
		local position: Vector3
		local progress: number
		if effect.elapsed < effect.riseDuration then
			local alpha = math.clamp(effect.elapsed / effect.riseDuration, 0, 1)
			local eased = 1 - (1 - alpha) * (1 - alpha)
			position = effect.startPosition:Lerp(effect.peakPosition, eased)
			progress = eased * 0.5
		else
			local alpha = math.clamp((effect.elapsed - effect.riseDuration) / effect.fallDuration, 0, 1)
			local eased = alpha * alpha
			position = effect.peakPosition:Lerp(effect.landingPosition, eased)
			progress = 0.5 + eased * 0.5
		end

		local playerRoot = getCharacterRoot(effect.owner)
		if playerRoot ~= nil then
			effect.referenceCFrame = playerRoot.CFrame
		end
		-- 先朝远离玩家的方向偏转，再向后翻倒 90°，最后加入小幅侧倾。
		local rotation = effect.startRotation
			* CFrame.Angles(0, effect.outwardYaw * progress, 0)
			* CFrame.Angles(effect.backwardTilt * progress, 0, effect.sideRoll * progress)
		pivotTo(effect.root, effect.referenceCFrame * CFrame.new(position) * rotation)

		local fade = math.clamp((effect.elapsed / totalDuration - 0.72) / 0.28, 0, 1)
		for _, part in getParts(effect.root) do
			part.LocalTransparencyModifier = fade
		end
		if effect.elapsed >= totalDuration then
			effect.root:Destroy()
			table.remove(knockbackVisuals, index)
		end
	end
end

local storage = ReplicatedStorage:WaitForChild(GameplayConfig.InstanceNames.MinionFollowerStorage)
for _, descendant in storage:GetDescendants() do
	addVisualSource(descendant)
end
storage.DescendantAdded:Connect(function(descendant)
	task.defer(addVisualSource, descendant)
end)

Players.PlayerRemoving:Connect(function(player)
	local group = groupsByPlayer[player]
	if group ~= nil then
		for index = #group.followers, 1, -1 do
			destroyFollowerVisual(group.followers[index])
		end
		groupsByPlayer[player] = nil
	end
	for index = #knockbackVisuals, 1, -1 do
		local effect = knockbackVisuals[index]
		if effect.owner == player then
			effect.root:Destroy()
			table.remove(knockbackVisuals, index)
		end
	end
end)

RunService.RenderStepped:Connect(function(deltaTime)
	local now = os.clock()
	updateFormation(deltaTime, now)
	updateKnockbacks(deltaTime)
end)
