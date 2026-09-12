--!strict

-- MinionModifier tag: an anchored BasePart in Workspace with CanTouch = true.
-- Required: Operation = "Add", "Subtract", or "Multiply"; Operand = integer.
-- Add/Subtract Operand: 1..1,000. Multiply Operand: 0..10.
-- Optional: Enabled: boolean, default true. No other attributes are required.
-- Each player can use each part once per character life, including no-op results.
-- MinionModifier Tag 必须放在 Workspace 中已锚定且 CanTouch = true 的 BasePart 上。
-- Operation 必须为 Add、Subtract 或 Multiply；Operand 必须为整数。
-- Add/Subtract 的 Operand 范围为 1..1,000，Multiply 的 Operand 范围为 0..10。
-- Add 新增的士兵复制玩家当前序号最后的跟随士兵；Multiply 按当前完整队伍组成追加副本。
-- Enabled 可选，类型为 boolean，默认开启；每名玩家每条命每个门只能使用一次。

local GameplayConfig = require(script.Parent:WaitForChild("GameplayConfig"))

export type Definition = {
	operation: string,
	operand: number,
	enabled: boolean,
}

local MinionModifierConfig = {}
local ATTRIBUTE = GameplayConfig.Attributes

MinionModifierConfig.Operations = {
	-- 数量门支持的运算类型：增加、减少和倍乘。
	Add = "Add",
	Subtract = "Subtract",
	Multiply = "Multiply",
}

-- Add/Subtract 操作数允许的最大整数值。
MinionModifierConfig.MaxOperand = 1000

-- Multiply 操作数允许的最大倍数。
MinionModifierConfig.MaxMultiplier = 10

-- 服务端判定玩家接触数量门时允许的额外距离容差（stud）。
MinionModifierConfig.TouchDistance = 6

-- 同一玩家对同一门或门组失败后再次尝试的冷却时间（秒）。
MinionModifierConfig.RetryCooldownSeconds = 1

-- 客户端查询个人随机门分配结果的服务端限流间隔（秒）。
MinionModifierConfig.AssignmentRequestCooldownSeconds = 0.05

-- Random groups have no per-instance balance attributes. Edit these global pools
-- to tune every RandomMinionModifierGroup in the place.
MinionModifierConfig.RandomGroup = {
	PositiveEffects = {
		-- 随机门可能抽到的正面效果池；至少会抽取一个正面效果。
		{ operation = MinionModifierConfig.Operations.Add, operand = 3 },
		{ operation = MinionModifierConfig.Operations.Add, operand = 5 },
		{ operation = MinionModifierConfig.Operations.Multiply, operand = 2 },
        { operation = MinionModifierConfig.Operations.Multiply, operand = 3 },
	},
	NegativeEffects = {
		-- 随机门可能抽到的负面效果池；至少会抽取一个负面效果。
		{ operation = MinionModifierConfig.Operations.Subtract, operand = 3 },
		{ operation = MinionModifierConfig.Operations.Subtract, operand = 5 },
        { operation = MinionModifierConfig.Operations.Subtract, operand = 8 },
        --{ operation = MinionModifierConfig.Operations.Multiply, operand = 2 },
	},
	-- 除保证的一正一负以外，其余随机门抽到正面效果的概率。
	PositiveChanceForExtraSlots = 0.5,
}

local OPERATION = MinionModifierConfig.Operations

function MinionModifierConfig.read(instance: Instance): (Definition?, string?)
	local operation = instance:GetAttribute(ATTRIBUTE.Operation)
	if operation ~= OPERATION.Add and operation ~= OPERATION.Subtract and operation ~= OPERATION.Multiply then
		return nil, "Operation must be Add, Subtract, or Multiply"
	end
	local operand = instance:GetAttribute(ATTRIBUTE.Operand)
	local minimum = if operation == OPERATION.Multiply then 0 else 1
	local maximum = if operation == OPERATION.Multiply then MinionModifierConfig.MaxMultiplier else MinionModifierConfig.MaxOperand
	if typeof(operand) ~= "number" or operand ~= operand or operand % 1 ~= 0 or operand < minimum or operand > maximum then
		return nil, "Operand must be an integer in " .. minimum .. ".." .. maximum
	end
	local enabled = instance:GetAttribute(ATTRIBUTE.Enabled)
	if enabled ~= nil and typeof(enabled) ~= "boolean" then
		return nil, "Enabled must be a boolean"
	end
	return {
		operation = operation :: string,
		operand = operand,
		enabled = enabled ~= false,
	}, nil
end

function MinionModifierConfig.getTargetCount(current: number, definition: Definition): number
	local target = current
	if definition.operation == OPERATION.Add then
		target += definition.operand
	elseif definition.operation == OPERATION.Subtract then
		target -= definition.operand
	elseif definition.operation == OPERATION.Multiply then
		target *= definition.operand
	end
	return math.clamp(target, 0, GameplayConfig.Limits.MaxFollowersPerPlayer)
end

function MinionModifierConfig.getLabel(definition: Definition): string
	local symbol = if definition.operation == OPERATION.Add then "+" elseif definition.operation == OPERATION.Subtract then "-" else "×"
	return symbol .. definition.operand
end

local function shuffle<T>(values: { T }, random: Random)
	for index = #values, 2, -1 do
		local otherIndex = random:NextInteger(1, index)
		values[index], values[otherIndex] = values[otherIndex], values[index]
	end
end

local function copyEffect(effect: { operation: string, operand: number }): Definition
	return {
		operation = effect.operation,
		operand = effect.operand,
		enabled = true,
	}
end

-- Returns one definition per slot. Two random, distinct slots are guaranteed to
-- be positive and negative respectively. A pool is exhausted before it repeats.
function MinionModifierConfig.generateRandomGroupDefinitions(slotCount: number, random: Random): { Definition }
	if slotCount < 2 then
		return {}
	end

	local positivePool = MinionModifierConfig.RandomGroup.PositiveEffects
	local negativePool = MinionModifierConfig.RandomGroup.NegativeEffects
	local positiveOrder: { number } = table.create(#positivePool)
	local negativeOrder: { number } = table.create(#negativePool)
	local positiveCursor = 1
	local negativeCursor = 1

	local function refill(order: { number }, poolSize: number)
		table.clear(order)
		for index = 1, poolSize do
			table.insert(order, index)
		end
		shuffle(order, random)
	end

	local function sample(pool: { { operation: string, operand: number } }, order: { number }, cursor: number): (Definition, number)
		if cursor > #order then
			refill(order, #pool)
			cursor = 1
		end
		local effect = pool[order[cursor]]
		return copyEffect(effect), cursor + 1
	end

	refill(positiveOrder, #positivePool)
	refill(negativeOrder, #negativePool)

	local categories: { boolean } = table.create(slotCount)
	categories[1] = true
	categories[2] = false
	for index = 3, slotCount do
		categories[index] = random:NextNumber() < MinionModifierConfig.RandomGroup.PositiveChanceForExtraSlots
	end
	shuffle(categories, random)

	local definitions: { Definition } = table.create(slotCount)
	for index = 1, slotCount do
		if categories[index] then
			definitions[index], positiveCursor = sample(positivePool, positiveOrder, positiveCursor)
		else
			definitions[index], negativeCursor = sample(negativePool, negativeOrder, negativeCursor)
		end
	end
	return definitions
end

function MinionModifierConfig.isReducing(definition: Definition): boolean
	return definition.operation == OPERATION.Subtract
		or (definition.operation == OPERATION.Multiply and definition.operand == 0)
end

return MinionModifierConfig
