--!strict

-- Presentation/input support only. ForcedRunService owns the actual movement.

local ContextActionService = game:GetService("ContextActionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local player = Players.LocalPlayer
local Shared = ReplicatedStorage:WaitForChild("Shared")
local GameplayConfig = require(Shared:WaitForChild("GameplayConfig"))

local ACTION_NAME = "BlockForcedRunBackwardMovement"
local ATTRIBUTE = GameplayConfig.Attributes
local ACTION_PRIORITY = Enum.ContextActionPriority.High.Value + 1

local isBound = false

local function sinkBackwardMovement(
	_actionName: string,
	_inputState: Enum.UserInputState,
	_inputObject: InputObject
): Enum.ContextActionResult
	return Enum.ContextActionResult.Sink
end

local function refreshBinding()
	local shouldBind = player:GetAttribute(ATTRIBUTE.ForcedRunActive) == true and player.Character ~= nil
	if shouldBind == isBound then
		return
	end
	isBound = shouldBind
	if shouldBind then
		ContextActionService:BindActionAtPriority(
			ACTION_NAME,
			sinkBackwardMovement,
			false,
			ACTION_PRIORITY,
			Enum.PlayerActions.CharacterBackward
		)
	else
		ContextActionService:UnbindAction(ACTION_NAME)
	end
end

player:GetAttributeChangedSignal(ATTRIBUTE.ForcedRunActive):Connect(refreshBinding)
player.CharacterAdded:Connect(function()
	refreshBinding()
end)
player.CharacterRemoving:Connect(function()
	ContextActionService:UnbindAction(ACTION_NAME)
	isBound = false
end)

refreshBinding()
