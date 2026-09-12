--!strict

-- Creates a small playable arena only when the place has no authored GameZone.
-- Delete the generated `ChargerDemoArena` from Workspace after building a real tagged level.

local CollectionService = game:GetService("CollectionService")

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local GameplayConfig = require(Shared:WaitForChild("GameplayConfig"))

local DemoArenaService = {}

local TAG = GameplayConfig.Tags
local ATTRIBUTE = GameplayConfig.Attributes

local function createPart(parent: Instance, name: string, size: Vector3, cframe: CFrame, color: Color3): Part
	local part = Instance.new("Part")
	part.Name = name
	part.Size = size
	part.CFrame = cframe
	part.Color = color
	part.Material = Enum.Material.SmoothPlastic
	part.TopSurface = Enum.SurfaceType.Smooth
	part.BottomSurface = Enum.SurfaceType.Smooth
	part.Parent = parent
	return part
end

local function addWorldLabel(part: BasePart, text: string, color: Color3)
	local billboard = Instance.new("BillboardGui")
	billboard.Size = UDim2.fromOffset(260, 45)
	billboard.StudsOffsetWorldSpace = Vector3.new(0, 4, 0)
	billboard.AlwaysOnTop = true
	billboard.Adornee = part
	billboard.Parent = part
	local label = Instance.new("TextLabel")
	label.Size = UDim2.fromScale(1, 1)
	label.BackgroundTransparency = 1
	label.Text = text
	label.TextColor3 = color
	label.Font = Enum.Font.GothamBlack
	label.TextScaled = true
	label.TextStrokeTransparency = 0.55
	label.Parent = billboard
end

function DemoArenaService.buildIfNeeded()
	if #CollectionService:GetTagged(TAG.GameZone) > 0 or workspace:FindFirstChild("ChargerDemoArena") ~= nil then
		return
	end

	local arena = Instance.new("Model")
	arena.Name = "ChargerDemoArena"
	arena.Parent = workspace

	local floor = createPart(arena, "ArenaFloor", Vector3.new(100, 1, 210), CFrame.new(0, 0, 0), Color3.fromRGB(44, 52, 68))
	floor.Material = Enum.Material.Slate

	-- Keep the authored SpawnLocation at the origin outside the demo charging area.
	local zone = createPart(arena, "ChargingZone", Vector3.new(86, 1, 40), CFrame.new(0, 0.55, 28), Color3.fromRGB(34, 155, 235))
	zone.Transparency = 0.32
	zone.Material = Enum.Material.Neon
	zone:SetAttribute(ATTRIBUTE.ZoneIndex, 0)
	zone:SetAttribute(ATTRIBUTE.MinionSpawnCount, GameplayConfig.Defaults.MinionSpawnCount)
	CollectionService:AddTag(zone, TAG.GameZone)
	addWorldLabel(zone, "SPRINT ZONE: Keep running to gain Energy", Color3.fromRGB(190, 240, 255))

	local boss = createPart(arena, "DemoBoss", Vector3.new(12, 12, 12), CFrame.new(0, 6.5, 74), Color3.fromRGB(218, 59, 72))
	boss.Shape = Enum.PartType.Ball
	boss.Material = Enum.Material.Neon
	boss:SetAttribute(ATTRIBUTE.RequiredEnergy, 100)
	CollectionService:AddTag(boss, TAG.Boss)

	local finishLine = createPart(arena, "BossApproach", Vector3.new(86, 1, 14), CFrame.new(0, 0.55, 53), Color3.fromRGB(92, 38, 55))
	finishLine.Transparency = 0.3
	finishLine.Material = Enum.Material.Neon
	addWorldLabel(finishLine, "BOSS ZONE: Low Energy means defeat", Color3.fromRGB(255, 193, 200))

	print("[DemoArenaService] created tagged demo arena")
end

return DemoArenaService
