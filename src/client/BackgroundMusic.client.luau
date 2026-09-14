--!strict

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local SoundService = game:GetService("SoundService")
local TweenService = game:GetService("TweenService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local GameplayConfig = require(Shared:WaitForChild("GameplayConfig"))

type MusicTrack = {
	sound: Sound,
	tween: Tween?,
}

local player = Players.LocalPlayer
local attributes = GameplayConfig.Attributes
local musicConfig = GameplayConfig.BackgroundMusic

local function createTrack(name: string, soundId: string): MusicTrack
	local sound = Instance.new("Sound")
	sound.Name = name
	sound.SoundId = soundId
	sound.Looped = true
	sound.Volume = 0
	sound.Parent = SoundService

	return {
		sound = sound,
		tween = nil,
	}
end

local defaultTrack = createTrack("BackgroundMusic", musicConfig.SoundId)
local gameZoneTrack = createTrack("GameZoneBackgroundMusic", musicConfig.GameZoneSoundId)
local transitionInfo = TweenInfo.new(musicConfig.TransitionSeconds, Enum.EasingStyle.Linear)

local function fadeTrack(track: MusicTrack, targetVolume: number, stopWhenSilent: boolean)
	if track.tween ~= nil then
		track.tween:Cancel()
		track.tween = nil
	end

	if targetVolume > 0 and not track.sound.IsPlaying then
		track.sound:Play()
	end

	local tween = TweenService:Create(track.sound, transitionInfo, { Volume = targetVolume })
	track.tween = tween
	tween.Completed:Connect(function(playbackState: Enum.PlaybackState)
		if track.tween ~= tween then
			return
		end
		track.tween = nil

		if stopWhenSilent and playbackState == Enum.PlaybackState.Completed then
			track.sound:Stop()
			track.sound.TimePosition = 0
		end
	end)
	tween:Play()
end

local function setMusicForZone(isInGameZone: boolean, instant: boolean)
	local activeTrack = if isInGameZone then gameZoneTrack else defaultTrack
	local inactiveTrack = if isInGameZone then defaultTrack else gameZoneTrack
	local activeVolume = if isInGameZone then musicConfig.GameZoneSoundVolume else musicConfig.SoundVolume

	if instant then
		activeTrack.sound.Volume = activeVolume
		activeTrack.sound:Play()
		inactiveTrack.sound.Volume = 0
		inactiveTrack.sound:Stop()
		inactiveTrack.sound.TimePosition = 0
		return
	end

	fadeTrack(activeTrack, activeVolume, false)
	fadeTrack(inactiveTrack, 0, true)
end

-- GameZone detection can briefly become false while jumping. Once a life has
-- entered a GameZone, retain its music until the character respawns.
local enteredGameZoneThisLife = player:GetAttribute(attributes.IsInGameZone) == true
setMusicForZone(enteredGameZoneThisLife, true)

player:GetAttributeChangedSignal(attributes.IsInGameZone):Connect(function()
	if enteredGameZoneThisLife or player:GetAttribute(attributes.IsInGameZone) ~= true then
		return
	end
	enteredGameZoneThisLife = true
	setMusicForZone(true, false)
end)

-- ReturnToSpawn keeps the same character alive, so its server-authoritative
-- reset signal deliberately overrides the usual per-life GameZone music lock.
player:GetAttributeChangedSignal(attributes.MusicResetSequence):Connect(function()
	enteredGameZoneThisLife = false
	setMusicForZone(false, false)
end)

player.CharacterAdded:Connect(function()
	enteredGameZoneThisLife = false
	setMusicForZone(false, false)
end)
