--!strict

local Players = game:GetService("Players")

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local GameplayConfig = require(Shared:WaitForChild("GameplayConfig"))

local PlayerShopService = require(script.Parent.Services:WaitForChild("PlayerShopService"))
local PlayerEnergyService = require(script.Parent.Services:WaitForChild("PlayerEnergyService"))
local EnergyCapacityUpgradeService = require(script.Parent.Services:WaitForChild("EnergyCapacityUpgradeService"))
local ForcedRunService = require(script.Parent.Services:WaitForChild("ForcedRunService"))
local PlayerProgressionService = require(script.Parent.Services:WaitForChild("PlayerProgressionService"))
local MinionSpawnService = require(script.Parent.Services:WaitForChild("MinionSpawnService"))
local MinionService = require(script.Parent.Services:WaitForChild("MinionService"))
local MinionModifierService = require(script.Parent.Services:WaitForChild("MinionModifierService"))
local RandomMinionModifierGroupService = require(script.Parent.Services:WaitForChild("RandomMinionModifierGroupService"))
local TrapService = require(script.Parent.Services:WaitForChild("TrapService"))
local KillZoneService = require(script.Parent.Services:WaitForChild("KillZoneService"))
local BossService = require(script.Parent.Services:WaitForChild("BossService"))
local TreadmillService = require(script.Parent.Services:WaitForChild("TreadmillService"))
local DemoArenaService = require(script.Parent.Services:WaitForChild("DemoArenaService"))
local TestEnergyRewardService = require(script.Parent.Services:WaitForChild("TestEnergyRewardService"))

Players.RespawnTime = GameplayConfig.Defaults.PlayerRespawnSeconds

PlayerShopService.start()
PlayerProgressionService.start()
PlayerEnergyService.start()
EnergyCapacityUpgradeService.start()
ForcedRunService.start()
MinionSpawnService.start()
MinionService.start()
MinionModifierService.start()
RandomMinionModifierGroupService.start()
TrapService.start()
KillZoneService.start()
BossService.start()
TreadmillService.start()
DemoArenaService.buildIfNeeded()
TestEnergyRewardService.start()

print("[GameplayBootstrap] gameplay services started")
