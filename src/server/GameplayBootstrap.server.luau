--!strict

local Players = game:GetService("Players")

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local GameplayConfig = require(Shared:WaitForChild("GameplayConfig"))

local PlayerEnergyService = require(script.Parent.Services:WaitForChild("PlayerEnergyService"))
local ForcedRunService = require(script.Parent.Services:WaitForChild("ForcedRunService"))
local PlayerProgressionService = require(script.Parent.Services:WaitForChild("PlayerProgressionService"))
local MinionSpawnService = require(script.Parent.Services:WaitForChild("MinionSpawnService"))
local MinionService = require(script.Parent.Services:WaitForChild("MinionService"))
local MinionModifierService = require(script.Parent.Services:WaitForChild("MinionModifierService"))
local RandomMinionModifierGroupService = require(script.Parent.Services:WaitForChild("RandomMinionModifierGroupService"))
local TrapService = require(script.Parent.Services:WaitForChild("TrapService"))
local KillZoneService = require(script.Parent.Services:WaitForChild("KillZoneService"))
local BossService = require(script.Parent.Services:WaitForChild("BossService"))
local DemoArenaService = require(script.Parent.Services:WaitForChild("DemoArenaService"))

Players.RespawnTime = GameplayConfig.Defaults.PlayerRespawnSeconds

PlayerProgressionService.start()
PlayerEnergyService.start()
ForcedRunService.start()
MinionSpawnService.start()
MinionService.start()
MinionModifierService.start()
RandomMinionModifierGroupService.start()
TrapService.start()
KillZoneService.start()
BossService.start()
DemoArenaService.buildIfNeeded()

print("[GameplayBootstrap] gameplay services started")
