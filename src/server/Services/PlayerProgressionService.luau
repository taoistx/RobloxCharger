--!strict

--[[
	Owns authoritative player experience, levels, and progression persistence.
	Only server systems may call addRunningDistance. The caller must provide
	movement already validated as real running inside a GameZone.
]]

local DataStoreService = game:GetService("DataStoreService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local GameplayConfig = require(Shared:WaitForChild("GameplayConfig"))

type PlayerState = {
	currentExperience: number,
	distanceRemainder: number,
	dirty: boolean,
	level: number,
	loaded: boolean,
	revision: number,
	saving: boolean,
}

type SavedProgression = {
	distanceRemainder: number,
	experience: number,
	level: number,
	version: number,
}

local PlayerProgressionService = {}

local ATTRIBUTE = GameplayConfig.Attributes
local PROGRESSION = GameplayConfig.Progression
local states: { [Player]: PlayerState } = {}
local started = false
local progressionStore = DataStoreService:GetDataStore(PROGRESSION.DataStoreName)
local feedbackEvent: RemoteEvent? = nil

local function getFeedbackEvent(): RemoteEvent
	if feedbackEvent ~= nil and feedbackEvent.Parent ~= nil then
		return feedbackEvent
	end

	local existing = ReplicatedStorage:FindFirstChild(GameplayConfig.InstanceNames.ProgressionFeedback)
	if existing ~= nil and existing:IsA("RemoteEvent") then
		feedbackEvent = existing
		return existing
	end
	if existing ~= nil then
		error("[PlayerProgressionService] ProgressionFeedback must be a RemoteEvent: " .. existing:GetFullName())
	end

	local remote = Instance.new("RemoteEvent")
	remote.Name = GameplayConfig.InstanceNames.ProgressionFeedback
	remote.Parent = ReplicatedStorage
	feedbackEvent = remote
	return remote
end

local function getSafeLevel(value: unknown): number
	if typeof(value) ~= "number" then
		return PROGRESSION.StartingLevel
	end
	return math.clamp(math.floor(value), PROGRESSION.StartingLevel, GameplayConfig.Limits.MaxPlayerLevel)
end

local function getSafeNonNegativeNumber(value: unknown): number
	if typeof(value) ~= "number" or value < 0 or value ~= value then
		return 0
	end
	return value
end

local function getRequiredExperience(level: number): number
	if level >= GameplayConfig.Limits.MaxPlayerLevel then
		return 0
	end
	return GameplayConfig.getExperienceRequiredForTargetLevel(level + 1)
end

local function syncAttributes(player: Player, state: PlayerState)
	player:SetAttribute(ATTRIBUTE.PlayerLevel, state.level)
	player:SetAttribute(ATTRIBUTE.CurrentExperience, math.floor(state.currentExperience))
	player:SetAttribute(ATTRIBUTE.ExperienceToNextLevel, getRequiredExperience(state.level))
end

local function markDirty(state: PlayerState)
	state.dirty = true
	state.revision += 1
end

local function getDefaultState(): PlayerState
	return {
		currentExperience = 0,
		distanceRemainder = 0,
		dirty = false,
		level = getSafeLevel(PROGRESSION.StartingLevel),
		loaded = false,
		revision = 0,
		saving = false,
	}
end

local function applySavedState(state: PlayerState, saved: unknown)
	if typeof(saved) ~= "table" then
		return
	end

	state.level = getSafeLevel(saved.level)
	state.currentExperience = math.floor(getSafeNonNegativeNumber(saved.experience))
	state.distanceRemainder = getSafeNonNegativeNumber(saved.distanceRemainder)
	if state.level >= GameplayConfig.Limits.MaxPlayerLevel then
		state.currentExperience = 0
		state.distanceRemainder = 0
		return
	end

	local distancePerAward = math.max(0.001, PROGRESSION.DistancePerExperienceAward)
	state.distanceRemainder %= distancePerAward
	while state.level < GameplayConfig.Limits.MaxPlayerLevel do
		local required = getRequiredExperience(state.level)
		if state.currentExperience < required then
			break
		end
		state.currentExperience -= required
		state.level += 1
	end
	if state.level >= GameplayConfig.Limits.MaxPlayerLevel then
		state.currentExperience = 0
		state.distanceRemainder = 0
	end
end

local function savePlayer(player: Player): boolean
	local state = states[player]
	if state == nil or not state.loaded or not state.dirty then
		return true
	end
	if state.saving then
		return false
	end

	state.saving = true
	local savedRevision = state.revision
	local payload: SavedProgression = {
		version = 1,
		level = state.level,
		experience = math.floor(state.currentExperience),
		distanceRemainder = state.distanceRemainder,
	}
	local success, err = pcall(function()
		progressionStore:SetAsync(tostring(player.UserId), payload)
	end)
	state.saving = false
	if not success then
		warn("[PlayerProgressionService] failed to save progression for " .. player.Name .. ": " .. tostring(err))
		return false
	end
	if state.revision == savedRevision then
		state.dirty = false
	end
	return true
end

local function loadPlayer(player: Player)
	local state = states[player]
	if state == nil then
		return
	end

	local success, savedOrError = pcall(function()
		return progressionStore:GetAsync(tostring(player.UserId))
	end)
	if states[player] ~= state then
		return
	end
	if success then
		applySavedState(state, savedOrError)
	else
		warn("[PlayerProgressionService] failed to load progression for " .. player.Name .. ": " .. tostring(savedOrError))
	end
	state.loaded = true
	syncAttributes(player, state)
end

local function bindPlayer(player: Player)
	if states[player] ~= nil then
		return
	end
	local state = getDefaultState()
	states[player] = state
	syncAttributes(player, state)
	task.spawn(loadPlayer, player)
end

local function unbindPlayer(player: Player)
	local state = states[player]
	while state ~= nil and state.saving do
		task.wait()
	end
	savePlayer(player)
	states[player] = nil
end

function PlayerProgressionService.addRunningDistance(player: Player, distance: number)
	local state = states[player]
	if state == nil or not state.loaded or distance <= 0 then
		return
	end
	if player:GetAttribute(ATTRIBUTE.IsInGameZone) ~= true or state.level >= GameplayConfig.Limits.MaxPlayerLevel then
		return
	end

	local distancePerAward = math.max(0.001, PROGRESSION.DistancePerExperienceAward)
	local totalDistance = state.distanceRemainder + distance
	local awardCount = math.floor(totalDistance / distancePerAward)
	state.distanceRemainder = totalDistance - awardCount * distancePerAward
	if awardCount <= 0 then
		markDirty(state)
		return
	end

	local gainedExperience = math.max(1, math.floor(PROGRESSION.ExperiencePerDistanceAward)) * awardCount
	state.currentExperience += gainedExperience
	local levelsGained = 0
	while state.level < GameplayConfig.Limits.MaxPlayerLevel do
		local required = getRequiredExperience(state.level)
		if state.currentExperience < required then
			break
		end
		state.currentExperience -= required
		state.level += 1
		levelsGained += 1
	end
	if state.level >= GameplayConfig.Limits.MaxPlayerLevel then
		state.currentExperience = 0
		state.distanceRemainder = 0
	end

	markDirty(state)
	syncAttributes(player, state)
	if levelsGained > 0 then
		player:SetAttribute(ATTRIBUTE.StatusMessage, string.format("升级至 %d 级！蓄能上限已提高。", state.level))
	end
	getFeedbackEvent():FireClient(player, gainedExperience, levelsGained)
end

function PlayerProgressionService.start()
	if started then
		return
	end
	started = true
	getFeedbackEvent()
	for _, player in Players:GetPlayers() do
		bindPlayer(player)
	end
	Players.PlayerAdded:Connect(bindPlayer)
	Players.PlayerRemoving:Connect(unbindPlayer)
	game:BindToClose(function()
		for player in states do
			local state = states[player]
			while state ~= nil and state.saving do
				task.wait()
			end
			savePlayer(player)
		end
	end)
	task.spawn(function()
		while started do
			task.wait(math.max(10, PROGRESSION.SaveIntervalSeconds))
			for player in states do
				task.spawn(savePlayer, player)
			end
		end
	end)

	print("[PlayerProgressionService] started")
end

return PlayerProgressionService
