--!strict

local PlayerEnergyService = require(script.Parent.Services:WaitForChild("PlayerEnergyService"))
local PlayerProgressionService = require(script.Parent.Services:WaitForChild("PlayerProgressionService"))
local MinionSpawnService = require(script.Parent.Services:WaitForChild("MinionSpawnService"))
local MinionService = require(script.Parent.Services:WaitForChild("MinionService"))
local BossService = require(script.Parent.Services:WaitForChild("BossService"))
local DemoArenaService = require(script.Parent.Services:WaitForChild("DemoArenaService"))

PlayerProgressionService.start()
PlayerEnergyService.start()
MinionSpawnService.start()
MinionService.start()
BossService.start()
DemoArenaService.buildIfNeeded()

print("[GameplayBootstrap] gameplay services started")
