--!strict

-- Creates one local-only, non-interactive floor strip for the current tutorial target.

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local player = Players.LocalPlayer
local Shared = ReplicatedStorage:WaitForChild("Shared")
local GameplayConfig = require(Shared:WaitForChild("GameplayConfig"))
local TutorialConfig = require(Shared:WaitForChild("TutorialConfig"))

type Bounds = {
	cframe: CFrame,
	size: Vector3,
}

local TAG = GameplayConfig.Tags
local ATTRIBUTE = GameplayConfig.Attributes
local STAGE = TutorialConfig.Stages
local GUIDE = TutorialConfig.Guide
local SHOP_NAME = "Shop"

local targetReachedRemote = ReplicatedStorage:WaitForChild(TutorialConfig.TargetReachedRemoteName)
if not targetReachedRemote:IsA("RemoteEvent") then
	warn("[TutorialPresentation] TutorialTargetReached must be a RemoteEvent")
	return
end
local resolvedRemote = targetReachedRemote :: RemoteEvent

local gameZones: { [Instance]: boolean } = {}
local capacityUpgrades: { [Instance]: boolean } = {}
local shops: { [Instance]: boolean } = {}
local connections: { RBXScriptConnection } = {}
local characterConnections: { RBXScriptConnection } = {}
local character: Model? = nil
local humanoid: Humanoid? = nil
local rootPart: BasePart? = nil
local guidePart: Part? = nil
local lastRequestedStage: string? = nil
local lastRequestAt = -math.huge
local stopped = false

local function disconnectAll(items: { RBXScriptConnection })
	for _, connection in items do
		connection:Disconnect()
	end
	table.clear(items)
end

local function destroyGuide()
	if guidePart ~= nil then
		guidePart:Destroy()
		guidePart = nil
	end
end

local function getBounds(instance: Instance): Bounds?
	if instance:IsA("BasePart") then
		return { cframe = instance.CFrame, size = instance.Size }
	end
	if instance:IsA("Model") and instance:FindFirstChildWhichIsA("BasePart", true) ~= nil then
		local boundsCFrame, boundsSize = instance:GetBoundingBox()
		return { cframe = boundsCFrame, size = boundsSize }
	end
	return nil
end

local function closestPointOnBounds(bounds: Bounds, point: Vector3): Vector3
	local localPoint = bounds.cframe:PointToObjectSpace(point)
	local half = bounds.size * 0.5
	return bounds.cframe:PointToWorldSpace(Vector3.new(
		math.clamp(localPoint.X, -half.X, half.X),
		math.clamp(localPoint.Y, -half.Y, half.Y),
		math.clamp(localPoint.Z, -half.Z, half.Z)
	))
end

local function distanceToBounds(instance: Instance, point: Vector3): (number?, Vector3?)
	local bounds = getBounds(instance)
	if bounds == nil then
		return nil, nil
	end
	local closest = closestPointOnBounds(bounds, point)
	local flatClosest = Vector3.new(closest.X, point.Y, closest.Z)
	return (closest - point).Magnitude, flatClosest
end

local function isWorkspaceTarget(instance: Instance): boolean
	return instance:IsDescendantOf(Workspace)
end

local function addCandidate(instance: Instance)
	if not instance:IsDescendantOf(Workspace) then
		return
	end
	if CollectionService:HasTag(instance, TAG.GameZone) then
		gameZones[instance] = true
	end
	if CollectionService:HasTag(instance, TAG.EnergyCapacityUpgrade) then
		capacityUpgrades[instance] = true
	end
	if CollectionService:HasTag(instance, TAG.Shop) or instance.Name == SHOP_NAME then
		shops[instance] = true
	end
end

local function removeCandidate(instance: Instance)
	gameZones[instance] = nil
	capacityUpgrades[instance] = nil
	shops[instance] = nil
end

local function chooseGameZone(position: Vector3): (Instance?, Vector3?)
	local selected: Instance? = nil
	local selectedPoint: Vector3? = nil
	local selectedIndex = math.huge
	local selectedDistance = math.huge
	for instance in gameZones do
		if not isWorkspaceTarget(instance) then
			continue
		end
		local zoneIndex = instance:GetAttribute(ATTRIBUTE.ZoneIndex)
		if typeof(zoneIndex) ~= "number" or zoneIndex ~= math.floor(zoneIndex)
			or zoneIndex < 0 or zoneIndex > GameplayConfig.Limits.MaxGameZoneIndex
		then
			continue
		end
		local distance, point = distanceToBounds(instance, position)
		if distance ~= nil and point ~= nil
			and (zoneIndex < selectedIndex or (zoneIndex == selectedIndex and distance < selectedDistance))
		then
			selected = instance
			selectedPoint = point
			selectedIndex = zoneIndex
			selectedDistance = distance
		end
	end
	return selected, selectedPoint
end

local function chooseNearest(candidates: { [Instance]: boolean }, position: Vector3): (Instance?, Vector3?, number)
	local selected: Instance? = nil
	local selectedPoint: Vector3? = nil
	local selectedDistance = math.huge
	for instance in candidates do
		if not isWorkspaceTarget(instance) then
			continue
		end
		local distance, point = distanceToBounds(instance, position)
		if distance ~= nil and point ~= nil and distance < selectedDistance then
			selected = instance
			selectedPoint = point
			selectedDistance = distance
		end
	end
	return selected, selectedPoint, selectedDistance
end

local function characterOverlapsPart(part: BasePart): boolean
	local currentCharacter = character
	if currentCharacter == nil then
		return false
	end
	local overlapParams = OverlapParams.new()
	overlapParams.FilterType = Enum.RaycastFilterType.Include
	overlapParams.FilterDescendantsInstances = { currentCharacter }
	overlapParams.MaxParts = 1
	return #Workspace:GetPartsInPart(part, overlapParams) > 0
end

local function requestCompletion(stage: string)
	local now = os.clock()
	if lastRequestedStage == stage and now - lastRequestAt < GUIDE.RequestRetrySeconds then
		return
	end
	lastRequestedStage = stage
	lastRequestAt = now
	resolvedRemote:FireServer(stage)
end

local function createGuide(): Part
	local part = Instance.new("Part")
	part.Name = "LocalTutorialGuide"
	part.Anchored = true
	part.CanCollide = false
	part.CanTouch = false
	part.CanQuery = false
	part.CastShadow = false
	part.Material = Enum.Material.Neon
	part.Color = GUIDE.Color
	part.Transparency = GUIDE.Transparency
	part.TopSurface = Enum.SurfaceType.Smooth
	part.BottomSurface = Enum.SurfaceType.Smooth

	local texture = Instance.new("Texture")
	texture.Name = "ArrowTexture"
	texture.Face = Enum.NormalId.Top
	texture.Texture = GUIDE.ArrowImage
	texture.Color3 = Color3.new(1, 1, 1)
	texture.Transparency = GUIDE.TextureTransparency
	texture.StudsPerTileU = GUIDE.ArrowTileWidthStuds
	texture.StudsPerTileV = GUIDE.ArrowTileLengthStuds
	texture.Parent = part

	part.Parent = Workspace
	guidePart = part
	return part
end

local function getFootPosition(currentRoot: BasePart, currentHumanoid: Humanoid): Vector3
	return currentRoot.Position
		- Vector3.yAxis * (currentHumanoid.HipHeight + currentRoot.Size.Y * 0.5)
		+ Vector3.yAxis * GUIDE.FootClearanceStuds
end

local function updateGuide(startPosition: Vector3, targetPosition: Vector3)
	local flatTarget = Vector3.new(targetPosition.X, startPosition.Y, targetPosition.Z)
	local offset = flatTarget - startPosition
	local length = offset.Magnitude
	if length < GUIDE.MinVisibleLengthStuds then
		destroyGuide()
		return
	end

	local part = guidePart or createGuide()
	part.Size = Vector3.new(GUIDE.WidthStuds, GUIDE.ThicknessStuds, length)
	local midpoint = startPosition + offset * 0.5
	local cframe = CFrame.lookAt(midpoint, flatTarget, Vector3.yAxis)
	if GUIDE.FlipArrowDirection then
		cframe *= CFrame.Angles(0, math.pi, 0)
	end
	part.CFrame = cframe
end

local function update()
	local currentCharacter = character
	local currentHumanoid = humanoid
	local currentRoot = rootPart
	if stopped
		or currentCharacter == nil
		or not currentCharacter:IsDescendantOf(Workspace)
		or currentHumanoid == nil
		or currentHumanoid.Health <= 0
		or currentRoot == nil
		or player:GetAttribute(ATTRIBUTE.TutorialEnabled) ~= true
	then
		destroyGuide()
		return
	end

	local stageValue = player:GetAttribute(TutorialConfig.StageAttribute)
	if typeof(stageValue) ~= "string" or not TutorialConfig.isActiveStage(stageValue) then
		destroyGuide()
		return
	end
	local stage = stageValue :: string
	local footPosition = getFootPosition(currentRoot, currentHumanoid)
	local target: Instance? = nil
	local targetPoint: Vector3? = nil
	local targetDistance = math.huge

	if stage == STAGE.GameZone then
		if player:GetAttribute(ATTRIBUTE.IsInGameZone) == true then
			requestCompletion(stage)
			destroyGuide()
			return
		end
		target, targetPoint = chooseGameZone(footPosition)
	elseif stage == STAGE.EnergyCapacityUpgrade then
		target, targetPoint, targetDistance = chooseNearest(capacityUpgrades, footPosition)
		if target ~= nil
			and target:IsA("BasePart")
			and targetDistance <= TutorialConfig.Targets.CapacityOverlapCheckDistanceStuds
			and characterOverlapsPart(target)
		then
			requestCompletion(stage)
			destroyGuide()
			return
		end
	elseif stage == STAGE.Shop then
		target, targetPoint, targetDistance = chooseNearest(shops, footPosition)
		if target ~= nil and targetDistance <= TutorialConfig.Targets.ShopCompletionDistanceStuds then
			requestCompletion(stage)
			destroyGuide()
			return
		end
	end

	if target == nil or targetPoint == nil then
		destroyGuide()
		return
	end
	updateGuide(footPosition, targetPoint)
end

local function bindCharacter(newCharacter: Model)
	disconnectAll(characterConnections)
	destroyGuide()
	character = newCharacter
	humanoid = nil
	rootPart = nil
	lastRequestedStage = nil
	lastRequestAt = -math.huge

	local newHumanoid = newCharacter:FindFirstChildOfClass("Humanoid") or newCharacter:WaitForChild("Humanoid", 10)
	local newRoot = newCharacter:FindFirstChild("HumanoidRootPart") or newCharacter:WaitForChild("HumanoidRootPart", 10)
	if stopped or player.Character ~= newCharacter then
		return
	end
	if newHumanoid == nil or not newHumanoid:IsA("Humanoid")
		or newRoot == nil or not newRoot:IsA("BasePart")
	then
		warn("[TutorialPresentation] character missing Humanoid or HumanoidRootPart")
		return
	end
	humanoid = newHumanoid
	rootPart = newRoot
	table.insert(characterConnections, newHumanoid.Died:Connect(destroyGuide))
	table.insert(characterConnections, newCharacter.AncestryChanged:Connect(function()
		if not newCharacter:IsDescendantOf(Workspace) then
			destroyGuide()
		end
	end))
end

for _, instance in CollectionService:GetTagged(TAG.GameZone) do
	addCandidate(instance)
end
for _, instance in CollectionService:GetTagged(TAG.EnergyCapacityUpgrade) do
	addCandidate(instance)
end
for _, instance in CollectionService:GetTagged(TAG.Shop) do
	addCandidate(instance)
end
for _, instance in Workspace:GetDescendants() do
	if instance.Name == SHOP_NAME then
		addCandidate(instance)
	end
end

for _, tagName in { TAG.GameZone, TAG.EnergyCapacityUpgrade, TAG.Shop } do
	table.insert(connections, CollectionService:GetInstanceAddedSignal(tagName):Connect(addCandidate))
	table.insert(connections, CollectionService:GetInstanceRemovedSignal(tagName):Connect(function(instance)
		removeCandidate(instance)
		addCandidate(instance)
	end))
end
table.insert(connections, Workspace.DescendantAdded:Connect(addCandidate))
table.insert(connections, Workspace.DescendantRemoving:Connect(removeCandidate))
table.insert(connections, player.CharacterAdded:Connect(function(newCharacter)
	task.spawn(bindCharacter, newCharacter)
end))
table.insert(connections, player.CharacterRemoving:Connect(function()
	disconnectAll(characterConnections)
	character = nil
	humanoid = nil
	rootPart = nil
	destroyGuide()
end))
table.insert(connections, player:GetAttributeChangedSignal(TutorialConfig.StageAttribute):Connect(function()
	lastRequestedStage = nil
	lastRequestAt = -math.huge
	if not TutorialConfig.isActiveStage(player:GetAttribute(TutorialConfig.StageAttribute)) then
		destroyGuide()
	end
end))
table.insert(connections, player:GetAttributeChangedSignal(ATTRIBUTE.TutorialEnabled):Connect(function()
	lastRequestedStage = nil
	lastRequestAt = -math.huge
	if player:GetAttribute(ATTRIBUTE.TutorialEnabled) ~= true then
		destroyGuide()
	end
end))
table.insert(connections, RunService.RenderStepped:Connect(update))

if player.Character ~= nil then
	task.spawn(bindCharacter, player.Character)
end

script.Destroying:Connect(function()
	stopped = true
	disconnectAll(connections)
	disconnectAll(characterConnections)
	destroyGuide()
	table.clear(gameZones)
	table.clear(capacityUpgrades)
	table.clear(shops)
end)
