--!strict

--[[
	Owns the persisted onboarding stage and validates target completion.
	Clients submit only the stage they believe they reached; target instances,
	death progression, and the saved result are all resolved by the server.
]]

local CollectionService = game:GetService("CollectionService")
local DataStoreService = game:GetService("DataStoreService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local GameplayConfig = require(Shared:WaitForChild("GameplayConfig"))
local TutorialConfig = require(Shared:WaitForChild("TutorialConfig"))
local ExperienceConfigService = require(script.Parent:WaitForChild("ExperienceConfigService"))

type SavedTutorial = {
	version: number,
	stage: string,
}

type PlayerState = {
	stage: string,
	loaded: boolean,
	dirty: boolean,
	revision: number,
	saving: boolean,
	pendingDeaths: number,
	lastRequestAt: number,
	playerConnections: { RBXScriptConnection },
	characterConnections: { RBXScriptConnection },
}

local TutorialService = {}

local TAG = GameplayConfig.Tags
local ATTRIBUTE = GameplayConfig.Attributes
local STAGE = TutorialConfig.Stages
local SHOP_NAME = "Shop"
local MAX_PENDING_DEATHS = 2

local states: { [Player]: PlayerState } = {}
local tutorialStore: GlobalDataStore? = nil
local nextStoreRetryAt = 0
local targetReachedRemote: RemoteEvent? = nil
local started = false

local function isTutorialEnabled(): boolean
	return ExperienceConfigService.getSnapshot().features.tutorialEnabled
end

local function disconnectAll(connections: { RBXScriptConnection })
	for _, connection in connections do
		connection:Disconnect()
	end
	table.clear(connections)
end

local function getTutorialStore(): GlobalDataStore?
	if tutorialStore ~= nil then
		return tutorialStore
	end
	if os.clock() < nextStoreRetryAt then
		return nil
	end

	local success, storeOrError = pcall(function()
		return DataStoreService:GetDataStore(TutorialConfig.DataStoreName)
	end)
	if not success then
		nextStoreRetryAt = os.clock() + 30
		warn("[TutorialService] tutorial storage is unavailable: " .. tostring(storeOrError))
		return nil
	end

	tutorialStore = storeOrError :: GlobalDataStore
	return tutorialStore
end

local function createTargetReachedRemote(): RemoteEvent
	local remoteName = TutorialConfig.TargetReachedRemoteName
	local existing = ReplicatedStorage:FindFirstChild(remoteName)
	if existing ~= nil and not existing:IsA("RemoteEvent") then
		warn("[TutorialService] replacing incorrectly typed target remote", existing)
		existing:Destroy()
		existing = nil
	end
	if existing ~= nil then
		return existing :: RemoteEvent
	end

	local remote = Instance.new("RemoteEvent")
	remote.Name = remoteName
	remote.Parent = ReplicatedStorage
	return remote
end

local function markDirty(state: PlayerState)
	state.dirty = true
	state.revision += 1
end

local function syncStage(player: Player, state: PlayerState)
	player:SetAttribute(TutorialConfig.StageAttribute, state.stage)
end

local function setStage(player: Player, state: PlayerState, stage: string): boolean
	if state.stage == stage then
		return false
	end
	state.stage = stage
	markDirty(state)
	syncStage(player, state)
	return true
end

local function advanceForDeath(player: Player, state: PlayerState): boolean
	if state.stage == STAGE.GameZone or state.stage == STAGE.AwaitFirstDeath then
		return setStage(player, state, STAGE.EnergyCapacityUpgrade)
	end
	if state.stage == STAGE.EnergyCapacityUpgrade or state.stage == STAGE.AwaitSecondDeath then
		return setStage(player, state, STAGE.Shop)
	end
	return false
end

local function savePlayer(player: Player): boolean
	local state = states[player]
	if state == nil or not state.loaded or not state.dirty then
		return true
	end
	if state.saving then
		return false
	end

	local store = getTutorialStore()
	if store == nil then
		return false
	end
	state.saving = true
	local savedRevision = state.revision
	local payload: SavedTutorial = {
		version = TutorialConfig.SaveVersion,
		stage = state.stage,
	}
	local success, err = pcall(function()
		store:SetAsync(tostring(player.UserId), payload)
	end)
	state.saving = false
	if not success then
		warn("[TutorialService] failed to save tutorial for " .. player.Name .. ": " .. tostring(err))
		return false
	end
	if state.revision == savedRevision then
		state.dirty = false
	end
	return true
end

local function applySavedState(state: PlayerState, saved: unknown)
	if typeof(saved) ~= "table" then
		return
	end
	if saved.version ~= TutorialConfig.SaveVersion then
		return
	end
	local savedStage = saved.stage
	if TutorialConfig.isValidStage(savedStage) then
		state.stage = savedStage :: string
	end
end

local function getLivingCharacter(player: Player): (Model?, BasePart?)
	local character = player.Character
	if character == nil or not character:IsDescendantOf(Workspace) then
		return nil, nil
	end
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	local rootPart = character:FindFirstChild("HumanoidRootPart")
	if humanoid == nil
		or humanoid.Health <= 0
		or rootPart == nil
		or not rootPart:IsA("BasePart")
	then
		return nil, nil
	end
	return character, rootPart
end

local function characterOverlapsPart(character: Model, part: BasePart): boolean
	if not part:IsDescendantOf(Workspace) or not part.Anchored or not part.CanCollide or not part.CanTouch then
		return false
	end
	local overlapParams = OverlapParams.new()
	overlapParams.FilterType = Enum.RaycastFilterType.Include
	overlapParams.FilterDescendantsInstances = { character }
	overlapParams.MaxParts = 1
	return #Workspace:GetPartsInPart(part, overlapParams) > 0
end

local function validateCapacityUpgrade(player: Player): boolean
	local character = getLivingCharacter(player)
	if character == nil then
		return false
	end
	for _, instance in CollectionService:GetTagged(TAG.EnergyCapacityUpgrade) do
		if instance:IsA("BasePart") and characterOverlapsPart(character, instance) then
			return true
		end
	end
	return false
end

local function getBounds(instance: Instance): (CFrame?, Vector3?)
	if instance:IsA("BasePart") then
		return instance.CFrame, instance.Size
	end
	if instance:IsA("Model") and instance:FindFirstChildWhichIsA("BasePart", true) ~= nil then
		return instance:GetBoundingBox()
	end
	return nil, nil
end

local function distanceToBounds(instance: Instance, point: Vector3): number?
	local boundsCFrame, boundsSize = getBounds(instance)
	if boundsCFrame == nil or boundsSize == nil then
		return nil
	end
	local localPoint = boundsCFrame:PointToObjectSpace(point)
	local half = boundsSize * 0.5
	local closestLocal = Vector3.new(
		math.clamp(localPoint.X, -half.X, half.X),
		math.clamp(localPoint.Y, -half.Y, half.Y),
		math.clamp(localPoint.Z, -half.Z, half.Z)
	)
	return (point - boundsCFrame:PointToWorldSpace(closestLocal)).Magnitude
end

local function validateShop(player: Player): boolean
	local _, rootPart = getLivingCharacter(player)
	if rootPart == nil then
		return false
	end
	local checked: { [Instance]: boolean } = {}
	for _, instance in CollectionService:GetTagged(TAG.Shop) do
		checked[instance] = true
		if instance:IsDescendantOf(Workspace) then
			local distance = distanceToBounds(instance, rootPart.Position)
			if distance ~= nil and distance <= TutorialConfig.Targets.ShopCompletionDistanceStuds then
				return true
			end
		end
	end
	for _, instance in Workspace:GetDescendants() do
		if instance.Name == SHOP_NAME and not checked[instance] and instance:IsDescendantOf(Workspace) then
			local distance = distanceToBounds(instance, rootPart.Position)
			if distance ~= nil and distance <= TutorialConfig.Targets.ShopCompletionDistanceStuds then
				return true
			end
		end
	end
	return false
end

local function validateTarget(player: Player, stage: string): boolean
	if stage == STAGE.GameZone then
		return player:GetAttribute(ATTRIBUTE.IsInGameZone) == true
	end
	if stage == STAGE.EnergyCapacityUpgrade then
		return validateCapacityUpgrade(player)
	end
	if stage == STAGE.Shop then
		return validateShop(player)
	end
	return false
end

local function getStageAfterTarget(stage: string): string?
	if stage == STAGE.GameZone then
		return STAGE.AwaitFirstDeath
	end
	if stage == STAGE.EnergyCapacityUpgrade then
		return STAGE.AwaitSecondDeath
	end
	if stage == STAGE.Shop then
		return STAGE.Complete
	end
	return nil
end

local function onTargetReached(player: Player, stageValue: unknown)
	local state = states[player]
	if not isTutorialEnabled()
		or state == nil
		or not state.loaded
		or player.Parent ~= Players
		or typeof(stageValue) ~= "string"
	then
		return
	end
	local now = os.clock()
	if now - state.lastRequestAt < TutorialConfig.RequestCooldownSeconds then
		return
	end
	state.lastRequestAt = now

	local requestedStage = stageValue :: string
	if requestedStage ~= state.stage or not TutorialConfig.isActiveStage(requestedStage) then
		return
	end
	local nextStage = getStageAfterTarget(requestedStage)
	if nextStage == nil or not validateTarget(player, requestedStage) then
		return
	end
	if setStage(player, state, nextStage) then
		task.spawn(savePlayer, player)
	end
end

local function onCharacterDied(player: Player)
	if not isTutorialEnabled() then
		return
	end
	local state = states[player]
	if state == nil then
		return
	end
	if not state.loaded then
		state.pendingDeaths = math.min(state.pendingDeaths + 1, MAX_PENDING_DEATHS)
		return
	end
	if advanceForDeath(player, state) then
		task.spawn(savePlayer, player)
	end
end

local function watchCharacter(player: Player, character: Model)
	local state = states[player]
	if state == nil then
		return
	end
	disconnectAll(state.characterConnections)
	local humanoid = character:FindFirstChildOfClass("Humanoid") or character:WaitForChild("Humanoid", 10)
	if states[player] ~= state or player.Character ~= character then
		return
	end
	if humanoid == nil or not humanoid:IsA("Humanoid") then
		warn("[TutorialService] character missing Humanoid", player)
		return
	end
	table.insert(state.characterConnections, humanoid.Died:Connect(function()
		onCharacterDied(player)
	end))
end

local function loadPlayer(player: Player)
	local state = states[player]
	if state == nil then
		return
	end

	local store = getTutorialStore()
	local success = false
	local savedOrError: unknown = nil
	if store ~= nil then
		success, savedOrError = pcall(function()
			return store:GetAsync(tostring(player.UserId))
		end)
	end
	if states[player] ~= state then
		return
	end
	if success then
		applySavedState(state, savedOrError)
	elseif store ~= nil then
		warn("[TutorialService] failed to load tutorial for " .. player.Name .. ": " .. tostring(savedOrError))
	end

	state.loaded = true
	local pendingDeaths = state.pendingDeaths
	state.pendingDeaths = 0
	local changed = false
	if isTutorialEnabled() then
		for _ = 1, pendingDeaths do
			if advanceForDeath(player, state) then
				changed = true
			end
		end
	end
	syncStage(player, state)
	if changed then
		task.spawn(savePlayer, player)
	end
end

local function bindPlayer(player: Player)
	if states[player] ~= nil then
		return
	end
	local state: PlayerState = {
		stage = STAGE.GameZone,
		loaded = false,
		dirty = false,
		revision = 0,
		saving = false,
		pendingDeaths = 0,
		lastRequestAt = -math.huge,
		playerConnections = {},
		characterConnections = {},
	}
	states[player] = state
	player:SetAttribute(TutorialConfig.StageAttribute, nil)
	player:SetAttribute(ATTRIBUTE.TutorialEnabled, isTutorialEnabled())
	table.insert(state.playerConnections, player.CharacterAdded:Connect(function(character)
		task.spawn(watchCharacter, player, character)
	end))
	if player.Character ~= nil then
		task.spawn(watchCharacter, player, player.Character)
	end
	task.spawn(loadPlayer, player)
end

local function unbindPlayer(player: Player)
	local state = states[player]
	if state == nil then
		return
	end
	disconnectAll(state.characterConnections)
	disconnectAll(state.playerConnections)
	while state.saving do
		task.wait()
	end
	savePlayer(player)
	states[player] = nil
	player:SetAttribute(ATTRIBUTE.TutorialEnabled, nil)
end

function TutorialService.start()
	if started then
		return
	end
	started = true
	targetReachedRemote = createTargetReachedRemote()
	local resolvedRemote = targetReachedRemote :: RemoteEvent
	resolvedRemote.OnServerEvent:Connect(onTargetReached)

	for _, player in Players:GetPlayers() do
		bindPlayer(player)
	end
	Players.PlayerAdded:Connect(bindPlayer)
	Players.PlayerRemoving:Connect(unbindPlayer)
	ExperienceConfigService.getChangedSignal():Connect(function()
		local enabled = isTutorialEnabled()
		for player in states do
			player:SetAttribute(ATTRIBUTE.TutorialEnabled, enabled)
		end
	end)

	game:BindToClose(function()
		for player, state in states do
			while state.saving do
				task.wait()
			end
			savePlayer(player)
		end
	end)
	task.spawn(function()
		while started do
			task.wait(math.max(10, TutorialConfig.SaveIntervalSeconds))
			for player in states do
				task.spawn(savePlayer, player)
			end
		end
	end)

	print("[TutorialService] started")
end

return TutorialService
