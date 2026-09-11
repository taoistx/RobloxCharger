--!strict

-- Player-local presentation for RandomMinionModifierGroup. The server owns each
-- character's assignment and all gameplay; this script only requests and renders it.
-- A group consumed by this player is hidden locally until their next character
-- receives a fresh assignment; it remains visible and usable for other players.

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local player = Players.LocalPlayer
local Shared = ReplicatedStorage:WaitForChild("Shared")
local GameplayConfig = require(Shared:WaitForChild("GameplayConfig"))
local ModifierConfig = require(Shared:WaitForChild("MinionModifierConfig"))

type SlotVisual = {
	part: BasePart,
	surfaceGui: SurfaceGui,
	label: TextLabel,
	icon: ImageLabel,
	originalPartColor: Color3,
	originalGuiEnabled: boolean,
	originalText: string,
	originalLabelPosition: UDim2,
	originalLabelSize: UDim2,
	originalTextXAlignment: Enum.TextXAlignment,
	originalIconImage: string,
	originalIconPosition: UDim2,
	originalIconSize: UDim2,
	originalIconVisible: boolean,
}

type GroupBinding = {
	model: Model,
	visuals: { [BasePart]: SlotVisual },
	missingUiWarnings: { [BasePart]: boolean },
	visualConnections: { RBXScriptConnection },
	connections: { RBXScriptConnection },
	requestSerial: number,
	hidden: boolean,
	hiddenSurfaceGuiEnabled: { [SurfaceGui]: boolean },
}

local TAG = GameplayConfig.Tags.RandomMinionModifierGroup
local assignmentRemote = ReplicatedStorage:WaitForChild(
	GameplayConfig.InstanceNames.RandomMinionModifierAssignment
) :: RemoteFunction
local updateRemote = ReplicatedStorage:WaitForChild(
	GameplayConfig.InstanceNames.RandomMinionModifierUpdate
) :: RemoteEvent
local bindings: { [Model]: GroupBinding } = {}

local POSITIVE_COLOR = Color3.fromRGB(65, 205, 95)
local NEGATIVE_COLOR = Color3.fromRGB(230, 70, 75)
local MINION_ICON = "rbxassetid://91566702509972"
local ICON_WIDTH_SHARE = 0.42

local function isSlotDescendant(binding: GroupBinding, descendant: Instance): boolean
	if descendant:IsA("BasePart") then
		return descendant.Parent == binding.model
	end
	local ancestorPart = descendant:FindFirstAncestorWhichIsA("BasePart")
	return ancestorPart ~= nil and ancestorPart.Parent == binding.model
end

local function hideDescendant(binding: GroupBinding, descendant: Instance)
	if not isSlotDescendant(binding, descendant) then
		return
	end
	if descendant:IsA("BasePart") then
		descendant.LocalTransparencyModifier = 1
	elseif descendant:IsA("SurfaceGui") then
		if binding.hiddenSurfaceGuiEnabled[descendant] == nil then
			binding.hiddenSurfaceGuiEnabled[descendant] = descendant.Enabled
		end
		descendant.Enabled = false
	end
end

local function setGroupHidden(binding: GroupBinding, hidden: boolean)
	if hidden then
		binding.hidden = true
		for _, descendant in binding.model:GetDescendants() do
			hideDescendant(binding, descendant)
		end
		return
	end

	binding.hidden = false
	-- Visibility restoration must not depend on the hide-time cache. A slot can
	-- be rebound or streamed while the player is passing several groups, so
	-- always reconcile every currently present slot to its visible local state.
	for _, descendant in binding.model:GetDescendants() do
		if descendant:IsA("BasePart") and descendant.Parent == binding.model then
			descendant.LocalTransparencyModifier = 0
		end
	end
	for surfaceGui, originalEnabled in binding.hiddenSurfaceGuiEnabled do
		if surfaceGui.Parent ~= nil then
			surfaceGui.Enabled = originalEnabled
		end
	end
	table.clear(binding.hiddenSurfaceGuiEnabled)
end

local function restoreVisual(visual: SlotVisual)
	if visual.part.Parent ~= nil then
		visual.part.Color = visual.originalPartColor
	end
	if visual.surfaceGui.Parent ~= nil then
		visual.surfaceGui.Enabled = visual.originalGuiEnabled
	end
	if visual.label.Parent ~= nil then
		visual.label.Text = visual.originalText
		visual.label.Position = visual.originalLabelPosition
		visual.label.Size = visual.originalLabelSize
		visual.label.TextXAlignment = visual.originalTextXAlignment
	end
	if visual.icon.Parent ~= nil then
		visual.icon.Image = visual.originalIconImage
		visual.icon.Position = visual.originalIconPosition
		visual.icon.Size = visual.originalIconSize
		visual.icon.Visible = visual.originalIconVisible
	end
end

local function clearVisuals(binding: GroupBinding)
	for _, connection in binding.visualConnections do
		connection:Disconnect()
	end
	table.clear(binding.visualConnections)
	for _, visual in binding.visuals do
		restoreVisual(visual)
	end
	table.clear(binding.visuals)
end

local function findSurfaceVisual(part: BasePart): (SurfaceGui?, TextLabel?, ImageLabel?)
	local surfaceGui = part:FindFirstChildWhichIsA("SurfaceGui", true)
	if surfaceGui == nil then
		return nil, nil, nil
	end
	local label = surfaceGui:FindFirstChildWhichIsA("TextLabel", true)
	local iconValue = surfaceGui:FindFirstChild("MinionIcon", true)
	local icon = if iconValue ~= nil and iconValue:IsA("ImageLabel") then iconValue else nil
	return surfaceGui, label, icon
end

local function createSlotVisual(binding: GroupBinding, part: BasePart, definition: ModifierConfig.Definition)
	local surfaceGui, label, icon = findSurfaceVisual(part)
	if surfaceGui == nil or label == nil or icon == nil then
		if binding.missingUiWarnings[part] ~= true then
			binding.missingUiWarnings[part] = true
			warn(
				"[RandomMinionModifierGroupPresentation] slot requires a SurfaceGui containing a TextLabel and MinionIcon ImageLabel",
				part
			)
		end
		return
	end
	binding.missingUiWarnings[part] = nil

	local effectText = ModifierConfig.getLabel(definition)
	local visual: SlotVisual = {
		part = part,
		surfaceGui = surfaceGui,
		label = label,
		icon = icon,
		originalPartColor = part.Color,
		originalGuiEnabled = surfaceGui.Enabled,
		originalText = label.Text,
		originalLabelPosition = label.Position,
		originalLabelSize = label.Size,
		originalTextXAlignment = label.TextXAlignment,
		originalIconImage = icon.Image,
		originalIconPosition = icon.Position,
		originalIconSize = icon.Size,
		originalIconVisible = icon.Visible,
	}
	binding.visuals[part] = visual

	local effectColor = if ModifierConfig.isReducing(definition) then NEGATIVE_COLOR else POSITIVE_COLOR

	local function refresh()
		local active = bindings[binding.model] == binding
			and CollectionService:HasTag(binding.model, TAG)
			and binding.model:IsDescendantOf(Workspace)
			and part.Parent == binding.model
			and part.Anchored
			and part.CanTouch
		if active then
			surfaceGui.Enabled = true
			local originalPosition = visual.originalLabelPosition
			local originalSize = visual.originalLabelSize
			local iconWidth = UDim.new(
				originalSize.X.Scale * ICON_WIDTH_SHARE,
				originalSize.X.Offset * ICON_WIDTH_SHARE
			)
			label.Text = effectText
			label.Position = UDim2.new(
				originalPosition.X + iconWidth,
				originalPosition.Y
			)
			label.Size = UDim2.new(
				originalSize.X.Scale * (1 - ICON_WIDTH_SHARE),
				originalSize.X.Offset * (1 - ICON_WIDTH_SHARE),
				originalSize.Y.Scale,
				originalSize.Y.Offset
			)
			label.TextXAlignment = Enum.TextXAlignment.Left
			icon.Image = MINION_ICON
			icon.Position = originalPosition
			icon.Size = UDim2.new(iconWidth, originalSize.Y)
			icon.Visible = true
			part.Color = effectColor
		else
			restoreVisual(visual)
		end
	end
	for _, propertyName in { "Anchored", "CanTouch" } do
		table.insert(binding.visualConnections, part:GetPropertyChangedSignal(propertyName):Connect(refresh))
	end
	refresh()
end

local function renderResponse(binding: GroupBinding, response: any, expectedCharacter: Model): boolean
	if typeof(response) ~= "table" or response.character ~= expectedCharacter
		or player.Character ~= expectedCharacter or typeof(response.entries) ~= "table"
	then
		return false
	end
	clearVisuals(binding)
	if response.consumed == true then
		setGroupHidden(binding, true)
		return true
	end
	setGroupHidden(binding, false)
	for _, entry in response.entries do
		if typeof(entry) ~= "table" then
			continue
		end
		local part = entry.part
		local operation = entry.operation
		local operand = entry.operand
		if typeof(part) ~= "Instance" or not (part :: Instance):IsA("BasePart")
			or (part :: BasePart).Parent ~= binding.model
			or typeof(operation) ~= "string" or typeof(operand) ~= "number"
		then
			continue
		end
		local definition: ModifierConfig.Definition = {
			operation = operation,
			operand = operand,
			minionType = nil,
			enabled = true,
		}
		createSlotVisual(binding, part :: BasePart, definition)
	end
	return true
end

local function requestAssignment(binding: GroupBinding)
	binding.requestSerial += 1
	local serial = binding.requestSerial
	clearVisuals(binding)
	setGroupHidden(binding, false)
	local character = player.Character
	if character == nil then
		return
	end
	task.spawn(function()
		for _ = 1, 3 do
			if bindings[binding.model] ~= binding or binding.requestSerial ~= serial
				or player.Character ~= character or not CollectionService:HasTag(binding.model, TAG)
			then
				return
			end
			local success, response = pcall(function()
				return assignmentRemote:InvokeServer(binding.model)
			end)
			if bindings[binding.model] ~= binding or binding.requestSerial ~= serial
				or player.Character ~= character or not CollectionService:HasTag(binding.model, TAG)
			then
				return
			end
			if success and renderResponse(binding, response, character) then
				return
			end
			task.wait(0.2)
		end
	end)
end

local function unbind(instance: Instance)
	if not instance:IsA("Model") then
		return
	end
	local binding = bindings[instance]
	if binding == nil then
		return
	end
	bindings[instance] = nil
	binding.requestSerial += 1
	for _, connection in binding.connections do
		connection:Disconnect()
	end
	setGroupHidden(binding, false)
	clearVisuals(binding)
end

local function bind(instance: Instance)
	if not instance:IsA("Model") or bindings[instance] ~= nil then
		return
	end
	local binding: GroupBinding = {
		model = instance,
		visuals = {},
		missingUiWarnings = {},
		visualConnections = {},
		connections = {},
		requestSerial = 0,
		hidden = false,
		hiddenSurfaceGuiEnabled = {},
	}
	bindings[instance] = binding
	local function scheduleRequest()
		task.defer(function()
			if bindings[instance] == binding then
				requestAssignment(binding)
			end
		end)
	end
	table.insert(binding.connections, instance.DescendantAdded:Connect(function(descendant)
		if binding.hidden then
			hideDescendant(binding, descendant)
		end
		scheduleRequest()
	end))
	table.insert(binding.connections, instance.DescendantRemoving:Connect(scheduleRequest))
	table.insert(binding.connections, instance.AncestryChanged:Connect(scheduleRequest))
	table.insert(binding.connections, instance.Destroying:Connect(function()
		unbind(instance)
	end))
	requestAssignment(binding)
end

updateRemote.OnClientEvent:Connect(function(groupValue: unknown, characterValue: unknown, consumedValue: unknown)
	if typeof(groupValue) ~= "Instance" or not (groupValue :: Instance):IsA("Model")
		or typeof(characterValue) ~= "Instance" or not (characterValue :: Instance):IsA("Model")
		or player.Character ~= characterValue
	then
		return
	end
	local binding = bindings[groupValue :: Model]
	if binding == nil then
		return
	end
	if consumedValue == true then
		binding.requestSerial += 1
		clearVisuals(binding)
		setGroupHidden(binding, true)
	else
		requestAssignment(binding)
	end
end)

player.CharacterRemoving:Connect(function()
	for _, binding in bindings do
		binding.requestSerial += 1
		clearVisuals(binding)
		setGroupHidden(binding, false)
	end
end)

player.CharacterAdded:Connect(function()
	for _, binding in bindings do
		-- Do not wait for the RemoteFunction round trip before undoing the
		-- previous character's local-only transparency.
		setGroupHidden(binding, false)
		requestAssignment(binding)
	end
end)

CollectionService:GetInstanceAddedSignal(TAG):Connect(bind)
CollectionService:GetInstanceRemovedSignal(TAG):Connect(unbind)
for _, instance in CollectionService:GetTagged(TAG) do
	bind(instance)
end
