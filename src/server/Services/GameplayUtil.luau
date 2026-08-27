--!strict

local GameplayUtil = {}

export type RootObject = BasePart | Model

function GameplayUtil.getRoot(instance: Instance): RootObject?
	if instance:IsA("BasePart") then
		return instance
	end

	if instance:IsA("Model") then
		local primaryPart = instance.PrimaryPart
		if primaryPart ~= nil then
			return instance
		end

		local firstPart = instance:FindFirstChildWhichIsA("BasePart", true)
		if firstPart ~= nil then
			instance.PrimaryPart = firstPart
			return instance
		end
	end

	return nil
end

function GameplayUtil.getPivot(instance: RootObject): CFrame
	if instance:IsA("BasePart") then
		return instance.CFrame
	end
	return instance:GetPivot()
end

function GameplayUtil.pivotTo(instance: RootObject, cframe: CFrame)
	if instance:IsA("BasePart") then
		instance.CFrame = cframe
	else
		instance:PivotTo(cframe)
	end
end

function GameplayUtil.getPrimaryPart(instance: RootObject): BasePart
	if instance:IsA("BasePart") then
		return instance
	end
	return instance.PrimaryPart :: BasePart
end

function GameplayUtil.getParts(instance: RootObject): { BasePart }
	if instance:IsA("BasePart") then
		return { instance }
	end

	local parts = {}
	for _, descendant in instance:GetDescendants() do
		if descendant:IsA("BasePart") then
			table.insert(parts, descendant)
		end
	end
	return parts
end

function GameplayUtil.getCharacterFromTouch(otherPart: BasePart): (Player?, Model?, Humanoid?, BasePart?)
	local Players = game:GetService("Players")
	local character = otherPart:FindFirstAncestorOfClass("Model")
	if character == nil then
		return nil, nil, nil, nil
	end

	local player = Players:GetPlayerFromCharacter(character)
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	local rootPart = character:FindFirstChild("HumanoidRootPart")
	if player == nil or humanoid == nil or rootPart == nil or not rootPart:IsA("BasePart") then
		return nil, nil, nil, nil
	end

	return player, character, humanoid, rootPart
end

return GameplayUtil
