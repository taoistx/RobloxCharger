--!strict

-- Boss accepts BasePart or Model containing BaseParts. RequiredEnergy: 1..1,000,000.
-- Server-owned clones have BossOwnerUserId and Defeated (default false).
-- Only the local player's undefeated clones receive a private energy sign.
-- The server remains authoritative for energy spending and collision outcomes.

local CollectionService = game:GetService("CollectionService")
local ContentProvider = game:GetService("ContentProvider")
local Debris = game:GetService("Debris")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local SoundService = game:GetService("SoundService")
local TweenService = game:GetService("TweenService")

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")
local Shared = ReplicatedStorage:WaitForChild("Shared")
local GameplayConfig = require(Shared:WaitForChild("GameplayConfig"))

type WorldGui = BillboardGui | SurfaceGui
type Binding = {
	instance: Instance,
	connections: { RBXScriptConnection },
	partTransparency: { [BasePart]: number },
	guiEnabled: { [WorldGui]: boolean },
}
type Objective = {
	binding: Binding,
	attachment: Attachment,
	gui: BillboardGui,
	icon: ImageLabel,
	amount: TextLabel,
	scale: UIScale,
	tween: Tween?,
}
type Bounds = {
	part: BasePart,
	center: Vector3,
	half: Vector3,
}

local TAG = GameplayConfig.Tags.Boss
local ATTRIBUTE = GameplayConfig.Attributes
local BOSS_CONFIG = GameplayConfig.Boss
local OBJECTIVE_CONFIG = BOSS_CONFIG.Objective
local FRAGMENT_CONFIG = BOSS_CONFIG.Fragments
local DEFEAT_SOUND_CONFIG = BOSS_CONFIG.DefeatSound
local OBJECTIVE_REFRESH_SECONDS = math.max(0.02, BOSS_CONFIG.ObjectiveRefreshSeconds)
-- boss需求显示的图标
local BOSS_ENERGY_ICON = "rbxassetid://109506052270768"
local bindings: { [Instance]: Binding } = {}
-- Weak keys preserve the once-per-life reminder across temporary unbind/rebind.
local reminded: { [Instance]: boolean } = setmetatable({}, { __mode = "k" })
local objective: Objective? = nil
local connections: { RBXScriptConnection } = {}
local characterConnections: { RBXScriptConnection } = {}
local refreshTask: thread? = nil
local stopped = false

local feedbackRemote = ReplicatedStorage:WaitForChild(
	GameplayConfig.InstanceNames.BossDefeatFeedback
) :: RemoteEvent
local defeatSoundRemote = ReplicatedStorage:WaitForChild(
	GameplayConfig.InstanceNames.BossDefeatSound
) :: RemoteEvent

local defeatSound = Instance.new("Sound")
defeatSound.Name = "BossDefeatSound"
defeatSound.SoundId = DEFEAT_SOUND_CONFIG.SoundId
defeatSound.Volume = DEFEAT_SOUND_CONFIG.SoundVolume
defeatSound.Parent = SoundService
task.spawn(function()
	local success, errorMessage = pcall(function()
		ContentProvider:PreloadAsync({ defeatSound })
	end)
	if not success then
		warn("[BossPresentation] unable to preload Boss defeat sound", errorMessage)
	end
end)

local function disconnectAll(list: { RBXScriptConnection })
	for _, connection in list do
		connection:Disconnect()
	end
	table.clear(list)
end

local function clearObjective()
	local current = objective
	objective = nil
	if current == nil then
		return
	end
	if current.tween ~= nil then
		current.tween:Cancel()
		current.tween:Destroy()
	end
	current.gui:Destroy()
	current.attachment:Destroy()
end

local function isLocalBoss(binding: Binding): boolean
	return binding.instance:GetAttribute(ATTRIBUTE.BossOwnerUserId) == player.UserId
		and binding.instance:GetAttribute(ATTRIBUTE.Defeated) ~= true
end

local function getRequiredEnergy(instance: Instance): number?
	local requiredEnergy = instance:GetAttribute(ATTRIBUTE.RequiredEnergy)
	if typeof(requiredEnergy) ~= "number"
		or requiredEnergy ~= requiredEnergy
		or requiredEnergy < 1
		or requiredEnergy > GameplayConfig.Limits.MaxBossRequiredEnergy
	then
		return nil
	end
	return requiredEnergy
end

local function formatEnergy(value: number): string
	if value > 0 and value < 0.01 then
		return "<0.01"
	end
	return (string.format("%.2f", value):gsub("%.?0+$", ""))
end

local function updateObjectiveText()
	local current = objective
	if current == nil then
		return
	end
	local requiredEnergy = getRequiredEnergy(current.binding.instance)
	if requiredEnergy == nil then
		clearObjective()
		return
	end

	current.amount.Text = formatEnergy(requiredEnergy)
end

local function getBounds(instance: Instance): Bounds?
	local part: BasePart
	local boundsCFrame: CFrame
	local size: Vector3
	if instance:IsA("BasePart") then
		part = instance
		boundsCFrame, size = instance.CFrame, instance.Size
	elseif instance:IsA("Model") then
		local descendant = instance:FindFirstChildWhichIsA("BasePart", true)
		if descendant == nil then
			return nil
		end
		part = descendant :: BasePart
		boundsCFrame, size = instance:GetBoundingBox()
	else
		return nil
	end
	-- Project the entire oriented box onto world axes, including rotated models.
	local right, up, look = boundsCFrame.RightVector, boundsCFrame.UpVector, boundsCFrame.LookVector
	local half = size / 2
	return {
		part = part,
		center = boundsCFrame.Position,
		half = Vector3.new(
			math.abs(right.X) * half.X + math.abs(up.X) * half.Y + math.abs(look.X) * half.Z,
			math.abs(right.Y) * half.X + math.abs(up.Y) * half.Y + math.abs(look.Y) * half.Z,
			math.abs(right.Z) * half.X + math.abs(up.Z) * half.Y + math.abs(look.Z) * half.Z
		),
	}
end

local function horizontalDistance(bounds: Bounds, position: Vector3): number
	local offset = position - bounds.center
	return Vector2.new(
		math.max(math.abs(offset.X) - bounds.half.X, 0),
		math.max(math.abs(offset.Z) - bounds.half.Z, 0)
	).Magnitude
end

local function updateObjectivePosition(current: Objective, bounds: Bounds, position: Vector3)
	local offset = position - bounds.center
	local horizontal = Vector3.new(offset.X, 0, offset.Z)
	local direction = if horizontal.Magnitude > 0.001 then horizontal.Unit else Vector3.new(0, 0, -1)
	local edgeX = if math.abs(direction.X) > 0.001 then bounds.half.X / math.abs(direction.X) else math.huge
	local edgeZ = if math.abs(direction.Z) > 0.001 then bounds.half.Z / math.abs(direction.Z) else math.huge
	local front = direction * (math.min(edgeX, edgeZ) + OBJECTIVE_CONFIG.FrontOffset)
	local worldPosition = bounds.center
		+ front
		+ Vector3.new(0, -bounds.half.Y + OBJECTIVE_CONFIG.FootHeight, 0)
	current.attachment.Position = bounds.part.CFrame:PointToObjectSpace(worldPosition)
	current.attachment.Parent = bounds.part

	local camera = workspace.CurrentCamera
	local width = if camera ~= nil then camera.ViewportSize.X else OBJECTIVE_CONFIG.Size.X
	local viewportScale = math.min(
		1,
		width * OBJECTIVE_CONFIG.MaxViewportWidthFraction
			/ (OBJECTIVE_CONFIG.Size.X * OBJECTIVE_CONFIG.PulseScale)
	)
	-- Reserve room inside the billboard for the pulse to avoid clipping text.
	current.gui.Size = UDim2.fromOffset(
		OBJECTIVE_CONFIG.Size.X * viewportScale * OBJECTIVE_CONFIG.PulseScale,
		OBJECTIVE_CONFIG.Size.Y * viewportScale * OBJECTIVE_CONFIG.PulseScale
	)
end

local function createLabel(parent: Instance, name: string, y: number, height: number, maxSize: number): TextLabel
	local label = Instance.new("TextLabel")
	label.Name = name
	label.BackgroundTransparency = 1
	label.Position = UDim2.new(0, 10, y, 0)
	label.Size = UDim2.new(1, -20, height, 0)
	label.Font = Enum.Font.GothamBold
	label.TextColor3 = Color3.fromRGB(237, 242, 250)
	label.TextScaled = true
	label.TextWrapped = true
	label.Parent = parent
	local constraint = Instance.new("UITextSizeConstraint")
	constraint.MinTextSize = 8
	constraint.MaxTextSize = maxSize
	constraint.Parent = label
	return label
end

local function createObjective(binding: Binding, bounds: Bounds): Objective
	local attachment = Instance.new("Attachment")
	attachment.Name = "BossEnergySignAnchor"
	attachment.Parent = bounds.part

	local gui = Instance.new("BillboardGui")
	gui.Name = "BossEnergySign"
	gui.Adornee = attachment
	gui.AlwaysOnTop = true
	gui.LightInfluence = 0
	gui.ResetOnSpawn = false
	gui.Enabled = false
	-- Distance gating uses player-to-bounds distance, not camera-to-anchor distance.
	gui.MaxDistance = 0
	gui.Parent = playerGui

	local panel = Instance.new("Frame")
	panel.Name = "EnergyRequirement"
	panel.AnchorPoint = Vector2.new(0.5, 0.5)
	panel.Position = UDim2.fromScale(0.5, 0.5)
	panel.Size = UDim2.fromScale(1 / OBJECTIVE_CONFIG.PulseScale, 1 / OBJECTIVE_CONFIG.PulseScale)
	panel.BackgroundTransparency = 1
	panel.Parent = gui
	local scale = Instance.new("UIScale")
	scale.Parent = panel

	local icon = Instance.new("ImageLabel")
	icon.Name = "EnergyIcon"
	icon.AnchorPoint = Vector2.new(0.5, 0.5)
	icon.Position = UDim2.fromScale(0.5, 0.5)
	icon.Size = UDim2.fromScale(0.9, 0.98)
	icon.BackgroundTransparency = 1
	icon.Image = BOSS_ENERGY_ICON
	icon.ScaleType = Enum.ScaleType.Fit
	icon.ZIndex = 1
	icon.Parent = panel

	local amount = createLabel(panel, "RequiredEnergy", 0.54, 0.34, 44)
	amount.Position = UDim2.fromScale(0.18, 0.54)
	amount.Size = UDim2.fromScale(0.64, 0.34)
	amount.Font = Enum.Font.GothamBlack
	amount.AutoLocalize = false
	amount.TextColor3 = Color3.fromRGB(10, 10, 12)
	amount.TextXAlignment = Enum.TextXAlignment.Center
	amount.ZIndex = 2
	return {
		binding = binding,
		attachment = attachment,
		gui = gui,
		icon = icon,
		amount = amount,
		scale = scale,
		tween = nil,
	}
end

local function restoreVisuals(binding: Binding)
	for part, transparency in binding.partTransparency do
		if part.Parent ~= nil then
			part.LocalTransparencyModifier = transparency
		end
	end
	table.clear(binding.partTransparency)
	for gui, enabled in binding.guiEnabled do
		if gui.Parent ~= nil then
			gui.Enabled = enabled
		end
	end
	table.clear(binding.guiEnabled)
end

local function hideDescendant(binding: Binding, descendant: Instance)
	if descendant:IsA("BasePart") then
		if binding.partTransparency[descendant] == nil then
			binding.partTransparency[descendant] = descendant.LocalTransparencyModifier
		end
		descendant.LocalTransparencyModifier = 1
	elseif descendant:IsA("BillboardGui") or descendant:IsA("SurfaceGui") then
		local worldGui = descendant :: WorldGui
		if binding.guiEnabled[worldGui] == nil then
			binding.guiEnabled[worldGui] = worldGui.Enabled
		end
		worldGui.Enabled = false
	end
end

local function refreshVisibility(binding: Binding)
	restoreVisuals(binding)
	if isLocalBoss(binding) then
		return
	end
	if objective ~= nil and objective.binding == binding then
		clearObjective()
	end
	hideDescendant(binding, binding.instance)
	for _, descendant in binding.instance:GetDescendants() do
		hideDescendant(binding, descendant)
	end
end

local function unbind(instance: Instance)
	local binding = bindings[instance]
	if binding == nil then
		return
	end
	bindings[instance] = nil
	if objective ~= nil and objective.binding == binding then
		clearObjective()
	end
	disconnectAll(binding.connections)
	restoreVisuals(binding)
end

local function bind(instance: Instance)
	if bindings[instance] ~= nil or not instance:IsDescendantOf(workspace) then
		return
	end
	if not instance:IsA("BasePart") and not instance:IsA("Model") then
		warn("[BossPresentation] Boss must be a BasePart or Model", instance)
		return
	end
	-- Keep listeners for partially streamed models/attributes; invalid objects
	-- remain ineligible until complete, without repeatedly warning each tick.
	if getRequiredEnergy(instance) == nil then
		warn("[BossPresentation] Boss requires RequiredEnergy between 1 and "
			.. GameplayConfig.Limits.MaxBossRequiredEnergy, instance)
	end
	local binding: Binding = {
		instance = instance,
		connections = {},
		partTransparency = {},
		guiEnabled = {},
	}
	bindings[instance] = binding
	table.insert(binding.connections, instance:GetAttributeChangedSignal(ATTRIBUTE.BossOwnerUserId):Connect(function()
		refreshVisibility(binding)
	end))
	table.insert(binding.connections, instance:GetAttributeChangedSignal(ATTRIBUTE.Defeated):Connect(function()
		refreshVisibility(binding)
	end))
	table.insert(binding.connections, instance:GetAttributeChangedSignal(ATTRIBUTE.RequiredEnergy):Connect(function()
		if objective ~= nil and objective.binding == binding then
			updateObjectiveText()
		end
	end))
	table.insert(binding.connections, instance.DescendantAdded:Connect(function(descendant)
		if not isLocalBoss(binding) then
			hideDescendant(binding, descendant)
		end
	end))
	table.insert(binding.connections, instance.DescendantRemoving:Connect(function(descendant)
		if objective ~= nil and objective.binding == binding
			and (objective.attachment == descendant or objective.attachment:IsDescendantOf(descendant))
		then
			clearObjective()
		end
		if descendant:IsA("BasePart") then
			local transparency = binding.partTransparency[descendant]
			if transparency ~= nil then
				descendant.LocalTransparencyModifier = transparency
				binding.partTransparency[descendant] = nil
			end
		elseif descendant:IsA("BillboardGui") or descendant:IsA("SurfaceGui") then
			local worldGui = descendant :: WorldGui
			local enabled = binding.guiEnabled[worldGui]
			if enabled ~= nil then
				worldGui.Enabled = enabled
				binding.guiEnabled[worldGui] = nil
			end
		end
	end))
	table.insert(binding.connections, instance.AncestryChanged:Connect(function()
		if not instance:IsDescendantOf(workspace) then
			unbind(instance)
		end
	end))
	table.insert(binding.connections, instance.Destroying:Connect(function()
		unbind(instance)
	end))
	refreshVisibility(binding)
end

local function getPlayerPosition(): Vector3?
	local character = player.Character
	if character == nil or not character:IsDescendantOf(workspace) then
		return nil
	end
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	local rootPart = character:FindFirstChild("HumanoidRootPart")
	if humanoid ~= nil and humanoid.Health > 0 and rootPart ~= nil and rootPart:IsA("BasePart") then
		return rootPart.Position
	end
	return nil
end

local function updateNearestBossObjective()
	local playerPosition = getPlayerPosition()
	if playerPosition == nil then
		clearObjective()
		return
	end

	local nearestBinding: Binding? = nil
	local nearestBounds: Bounds? = nil
	local nearestDistance = OBJECTIVE_CONFIG.DisplayDistance
	local previousObjective = objective
	for _, binding in bindings do
		if isLocalBoss(binding) and binding.instance:IsDescendantOf(workspace)
			and getRequiredEnergy(binding.instance) ~= nil
		then
			local bounds = getBounds(binding.instance)
			if bounds ~= nil then
				local distance = horizontalDistance(bounds, playerPosition)
				if distance < nearestDistance or (distance == nearestDistance
					and (nearestBinding == nil or (previousObjective ~= nil and previousObjective.binding == binding)))
				then
					nearestBinding = binding
					nearestBounds = bounds
					nearestDistance = distance
				end
			end
		end
	end
	if nearestBinding == nil or nearestBounds == nil then
		clearObjective()
		return
	end

	local selectedBinding = nearestBinding :: Binding
	local selectedBounds = nearestBounds :: Bounds
	local current = objective
	if current == nil or current.binding ~= selectedBinding or current.attachment.Parent ~= selectedBounds.part then
		clearObjective()
		objective = createObjective(selectedBinding, selectedBounds)
		updateObjectiveText()
	end
	local active = objective
	if active == nil then
		return
	end
	updateObjectivePosition(active, selectedBounds, playerPosition)
	active.gui.Enabled = true
	if nearestDistance <= OBJECTIVE_CONFIG.NearDistance and not reminded[selectedBinding.instance] then
		reminded[selectedBinding.instance] = true
		local tween = TweenService:Create(
			active.scale,
			TweenInfo.new(OBJECTIVE_CONFIG.PulseDurationSeconds / 2, Enum.EasingStyle.Quad,
				Enum.EasingDirection.Out, 0, true),
			{ Scale = OBJECTIVE_CONFIG.PulseScale }
		)
		active.tween = tween
		tween:Play()
	end
end

local function stopRefresh()
	if refreshTask ~= nil then
		task.cancel(refreshTask)
		refreshTask = nil
	end
	clearObjective()
end

local function scheduleRefresh()
	if stopped or refreshTask ~= nil then
		return
	end
	refreshTask = task.delay(OBJECTIVE_REFRESH_SECONDS, function()
		refreshTask = nil
		if stopped then
			return
		end
		updateNearestBossObjective()
		if getPlayerPosition() ~= nil then
			scheduleRefresh()
		end
	end)
end

local function watchCharacter(character: Model)
	disconnectAll(characterConnections)
	stopRefresh()
	table.clear(reminded)
	local function watchHumanoid(child: Instance)
		if child:IsA("Humanoid") then
			table.insert(characterConnections, child.Died:Connect(stopRefresh))
		end
		scheduleRefresh()
	end
	table.insert(characterConnections, character.ChildAdded:Connect(watchHumanoid))
	table.insert(characterConnections, character.AncestryChanged:Connect(function()
		if not character:IsDescendantOf(workspace) then
			stopRefresh()
		else
			scheduleRefresh()
		end
	end))
	for _, child in character:GetChildren() do
		watchHumanoid(child)
	end
	scheduleRefresh()
end

table.insert(connections, player.CharacterAdded:Connect(watchCharacter))
table.insert(connections, player.CharacterRemoving:Connect(function()
	disconnectAll(characterConnections)
	stopRefresh()
end))
if player.Character ~= nil then
	watchCharacter(player.Character)
end

local fragmentRandom = Random.new()

local function playDefeatSound()
	defeatSound:Stop()
	defeatSound.TimePosition = 0
	defeatSound:Play()
end

local function spawnFragments(origin: CFrame, boundsSize: Vector3)
	local halfSpread = Vector3.new(
		math.min(math.abs(boundsSize.X) / 2, FRAGMENT_CONFIG.SpreadCap),
		math.min(math.abs(boundsSize.Y) / 2, FRAGMENT_CONFIG.SpreadCap),
		math.min(math.abs(boundsSize.Z) / 2, FRAGMENT_CONFIG.SpreadCap)
	)
	for _ = 1, FRAGMENT_CONFIG.Count do
		local fragment = Instance.new("Part")
		fragment.Name = "BossFragment"
		local size = fragmentRandom:NextNumber(FRAGMENT_CONFIG.SizeMin, FRAGMENT_CONFIG.SizeMax)
		fragment.Size = Vector3.one * size
		fragment.Color = FRAGMENT_CONFIG.Color
		fragment.Material = Enum.Material.SmoothPlastic
		fragment.TopSurface = Enum.SurfaceType.Smooth
		fragment.BottomSurface = Enum.SurfaceType.Smooth
		fragment.CanCollide = false
		fragment.CanQuery = false
		fragment.CanTouch = false
		fragment.CFrame = origin
			* CFrame.new(
				fragmentRandom:NextNumber(-halfSpread.X, halfSpread.X),
				fragmentRandom:NextNumber(-halfSpread.Y, halfSpread.Y),
				fragmentRandom:NextNumber(-halfSpread.Z, halfSpread.Z)
			)
		fragment.Parent = workspace
		local horizontalAngle = fragmentRandom:NextNumber(0, math.pi * 2)
		local horizontalMagnitude = fragmentRandom:NextNumber(
			FRAGMENT_CONFIG.HorizontalImpulseMin,
			FRAGMENT_CONFIG.HorizontalImpulseMax
		)
		fragment:ApplyImpulse(
			Vector3.new(
				math.cos(horizontalAngle) * horizontalMagnitude,
				fragmentRandom:NextNumber(FRAGMENT_CONFIG.UpwardImpulseMin, FRAGMENT_CONFIG.UpwardImpulseMax),
				math.sin(horizontalAngle) * horizontalMagnitude
			) * fragment.AssemblyMass
		)
		fragment:ApplyAngularImpulse(
			Vector3.new(
				fragmentRandom:NextNumber(-FRAGMENT_CONFIG.AngularImpulseMax, FRAGMENT_CONFIG.AngularImpulseMax),
				fragmentRandom:NextNumber(-FRAGMENT_CONFIG.AngularImpulseMax, FRAGMENT_CONFIG.AngularImpulseMax),
				fragmentRandom:NextNumber(-FRAGMENT_CONFIG.AngularImpulseMax, FRAGMENT_CONFIG.AngularImpulseMax)
			) * fragment.AssemblyMass
		)
		Debris:AddItem(fragment, FRAGMENT_CONFIG.LifetimeSeconds)
	end
end

table.insert(connections, feedbackRemote.OnClientEvent:Connect(function(originValue: unknown, boundsSizeValue: unknown)
	if typeof(originValue) ~= "CFrame" or typeof(boundsSizeValue) ~= "Vector3" then
		return
	end
	spawnFragments(originValue, boundsSizeValue)
end))

table.insert(connections, defeatSoundRemote.OnClientEvent:Connect(playDefeatSound))

table.insert(connections, CollectionService:GetInstanceAddedSignal(TAG):Connect(bind))
table.insert(connections, CollectionService:GetInstanceRemovedSignal(TAG):Connect(unbind))
-- A tagged instance can leave Workspace without leaving the DataModel. Its
-- binding is released on exit and recreated here if the same object returns.
table.insert(connections, workspace.DescendantAdded:Connect(function(instance)
	if CollectionService:HasTag(instance, TAG) then
		bind(instance)
	end
end))
for _, instance in CollectionService:GetTagged(TAG) do
	bind(instance)
end

script.Destroying:Connect(function()
	stopped = true
	defeatSound:Destroy()
	disconnectAll(connections)
	disconnectAll(characterConnections)
	stopRefresh()
	for instance in bindings do
		unbind(instance)
	end
	table.clear(reminded)
end)
