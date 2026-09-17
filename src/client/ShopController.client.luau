--!strict

local MarketplaceService = game:GetService("MarketplaceService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")
local Shared = ReplicatedStorage:WaitForChild("Shared")
local GameplayConfig = require(Shared:WaitForChild("GameplayConfig"))
local ShopConfig = require(Shared:WaitForChild("ShopConfig"))

local snapshotRemote = ReplicatedStorage:WaitForChild(GameplayConfig.InstanceNames.ShopGetSnapshot)
local purchaseRemote = ReplicatedStorage:WaitForChild(GameplayConfig.InstanceNames.ShopPurchase)
local updatedRemote = ReplicatedStorage:WaitForChild(GameplayConfig.InstanceNames.ShopUpdated)
local openRemote = ReplicatedStorage:WaitForChild(GameplayConfig.InstanceNames.ShopOpenRequested)

if not snapshotRemote:IsA("RemoteFunction")
	or not purchaseRemote:IsA("RemoteFunction")
	or not updatedRemote:IsA("RemoteEvent")
	or not openRemote:IsA("RemoteEvent")
then
	warn("[ShopController] shop remotes are not configured correctly")
	return
end

local resolvedSnapshotRemote = snapshotRemote :: RemoteFunction
local resolvedPurchaseRemote = purchaseRemote :: RemoteFunction
local resolvedUpdatedRemote = updatedRemote :: RemoteEvent
local resolvedOpenRemote = openRemote :: RemoteEvent

local ACTION = ShopConfig.PurchaseActions
local COIN_ICON = ShopConfig.CoinPresentation.IconImage
local snapshot: any = nil
local isOpen = false
local isBusy = false

local gui = Instance.new("ScreenGui")
gui.Name = "ShopGui"
gui.ResetOnSpawn = false
gui.IgnoreGuiInset = true
gui.Parent = playerGui

local openButton = Instance.new("TextButton")
openButton.Name = "OpenShop"
openButton.AnchorPoint = Vector2.new(1, 0.5)
openButton.Size = UDim2.fromOffset(150, 56)
openButton.Position = UDim2.new(1, -22, 0.5, 0)
openButton.BackgroundColor3 = Color3.fromRGB(255, 88, 156)
openButton.Text = "SHOP"
openButton.TextColor3 = Color3.fromRGB(255, 255, 255)
openButton.Font = Enum.Font.GothamBlack
openButton.TextSize = 24
openButton.AutoButtonColor = true
openButton.Visible = false
openButton.Active = false
openButton.Parent = gui
local openCorner = Instance.new("UICorner")
openCorner.CornerRadius = UDim.new(0, 16)
openCorner.Parent = openButton
local openStroke = Instance.new("UIStroke")
openStroke.Thickness = 3
openStroke.Color = Color3.fromRGB(255, 226, 78)
openStroke.Transparency = 0
openStroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
openStroke.Parent = openButton

local panel = Instance.new("Frame")
panel.Name = "ShopPanel"
panel.AnchorPoint = Vector2.new(0.5, 0.5)
panel.Size = UDim2.fromOffset(760, 650)
panel.Position = UDim2.fromScale(0.5, 0.5)
panel.BackgroundColor3 = Color3.fromRGB(255, 242, 168)
panel.BackgroundTransparency = 0
panel.Visible = false
panel.Parent = gui
local panelScale = Instance.new("UIScale")
panelScale.Parent = panel

local function updatePanelScale()
	local camera = workspace.CurrentCamera
	if camera == nil then
		return
	end
	local viewportSize = camera.ViewportSize
	panelScale.Scale = math.clamp(math.min(viewportSize.X / 840, viewportSize.Y / 700), 0.44, 1)
end

local viewportConnection: RBXScriptConnection? = nil
local function bindViewportUpdates()
	if viewportConnection ~= nil then
		viewportConnection:Disconnect()
		viewportConnection = nil
	end
	local camera = workspace.CurrentCamera
	if camera ~= nil then
		viewportConnection = camera:GetPropertyChangedSignal("ViewportSize"):Connect(updatePanelScale)
	end
	updatePanelScale()
end

workspace:GetPropertyChangedSignal("CurrentCamera"):Connect(bindViewportUpdates)
bindViewportUpdates()
local panelCorner = Instance.new("UICorner")
panelCorner.CornerRadius = UDim.new(0, 24)
panelCorner.Parent = panel
local panelGradient = Instance.new("UIGradient")
panelGradient.Color = ColorSequence.new({
	ColorSequenceKeypoint.new(0, Color3.fromRGB(255, 246, 166)),
	ColorSequenceKeypoint.new(0.5, Color3.fromRGB(255, 221, 237)),
	ColorSequenceKeypoint.new(1, Color3.fromRGB(205, 245, 255)),
})
panelGradient.Rotation = 25
panelGradient.Parent = panel
local panelStroke = Instance.new("UIStroke")
panelStroke.Thickness = 4
panelStroke.Color = Color3.fromRGB(255, 91, 164)
panelStroke.Transparency = 0
panelStroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
panelStroke.Parent = panel

local title = Instance.new("TextLabel")
title.Name = "Title"
title.Size = UDim2.new(1, -110, 0, 52)
title.Position = UDim2.fromOffset(24, 12)
title.BackgroundTransparency = 1
title.TextXAlignment = Enum.TextXAlignment.Left
title.Text = "MINION SHOP"
title.TextColor3 = Color3.fromRGB(113, 61, 195)
title.Font = Enum.Font.GothamBlack
title.TextSize = 32
title.Parent = panel

local closeButton = Instance.new("TextButton")
closeButton.Name = "Close"
closeButton.AnchorPoint = Vector2.new(1, 0)
closeButton.Size = UDim2.fromOffset(50, 46)
closeButton.Position = UDim2.new(1, -16, 0, 14)
closeButton.BackgroundColor3 = Color3.fromRGB(255, 94, 94)
closeButton.Text = "X"
closeButton.TextColor3 = Color3.fromRGB(255, 255, 255)
closeButton.Font = Enum.Font.GothamBlack
closeButton.TextSize = 22
closeButton.Parent = panel
local closeCorner = Instance.new("UICorner")
closeCorner.CornerRadius = UDim.new(0, 14)
closeCorner.Parent = closeButton
local closeStroke = Instance.new("UIStroke")
closeStroke.Thickness = 2
closeStroke.Color = Color3.fromRGB(255, 255, 255)
closeStroke.Transparency = 0.15
closeStroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
closeStroke.Parent = closeButton

local coinsLabel = Instance.new("TextLabel")
coinsLabel.Name = "Coins"
coinsLabel.Size = UDim2.new(1, -84, 0, 34)
coinsLabel.Position = UDim2.fromOffset(64, 67)
coinsLabel.BackgroundTransparency = 1
coinsLabel.TextXAlignment = Enum.TextXAlignment.Left
coinsLabel.TextColor3 = Color3.fromRGB(119, 73, 20)
coinsLabel.Font = Enum.Font.GothamBlack
coinsLabel.TextSize = 22
coinsLabel.Parent = panel

local coinsIcon = Instance.new("ImageLabel")
coinsIcon.Name = "CoinIcon"
coinsIcon.Size = UDim2.fromOffset(38, 38)
coinsIcon.Position = UDim2.fromOffset(22, 65)
coinsIcon.BackgroundTransparency = 1
coinsIcon.Image = COIN_ICON
coinsIcon.ScaleType = Enum.ScaleType.Fit
coinsIcon.Parent = panel

local statusLabel = Instance.new("TextLabel")
statusLabel.Name = "Status"
statusLabel.Size = UDim2.new(1, -48, 0, 28)
statusLabel.Position = UDim2.fromOffset(24, 103)
statusLabel.BackgroundTransparency = 1
statusLabel.TextXAlignment = Enum.TextXAlignment.Left
statusLabel.TextColor3 = Color3.fromRGB(129, 54, 104)
statusLabel.Font = Enum.Font.GothamBold
statusLabel.TextSize = 16
statusLabel.Text = ""
statusLabel.TextTruncate = Enum.TextTruncate.AtEnd
statusLabel.Parent = panel

local list = Instance.new("ScrollingFrame")
list.Name = "ItemList"
list.Size = UDim2.new(1, -48, 1, -156)
list.Position = UDim2.fromOffset(24, 140)
list.BackgroundTransparency = 1
list.BorderSizePixel = 0
list.ScrollBarThickness = 10
list.ScrollBarImageColor3 = Color3.fromRGB(255, 91, 164)
list.CanvasSize = UDim2.fromOffset(0, 0)
list.Parent = panel

local function setCanvasFromLayout(layout: UIListLayout)
	list.CanvasSize = UDim2.fromOffset(0, layout.AbsoluteContentSize.Y + 10)
end

local function makeCorner(parent: Instance, radius: number)
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, radius)
	corner.Parent = parent
end

local function makeStroke(parent: Instance, color: Color3, transparency: number)
	local stroke = Instance.new("UIStroke")
	stroke.Thickness = 2.5
	stroke.Color = color
	stroke.Transparency = transparency
	stroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	stroke.Parent = parent
end

local function makeButton(parent: Instance, text: string, color: Color3, enabled: boolean): TextButton
	local button = Instance.new("TextButton")
	button.Size = UDim2.fromOffset(164, 48)
	button.BackgroundColor3 = if enabled then color else Color3.fromRGB(210, 210, 220)
	button.Text = text
	button.TextColor3 = if enabled then Color3.fromRGB(255, 255, 255) else Color3.fromRGB(115, 115, 130)
	button.Font = Enum.Font.GothamBlack
	button.TextSize = 16
	button.TextWrapped = true
	button.AutoButtonColor = enabled
	button.Active = enabled
	button.Parent = parent
	makeCorner(button, 14)
	makeStroke(button, Color3.fromRGB(255, 255, 255), 0.25)
	return button
end

local CARD_COLORS = {
	Color3.fromRGB(189, 241, 255),
	Color3.fromRGB(255, 207, 231),
	Color3.fromRGB(213, 255, 203),
}

local function makeCard(parent: Instance, height: number, cardIndex: number): Frame
	local card = Instance.new("Frame")
	card.Size = UDim2.new(1, -8, 0, height)
	card.BackgroundColor3 = CARD_COLORS[(cardIndex - 1) % #CARD_COLORS + 1]
	card.LayoutOrder = cardIndex
	card.Parent = parent
	makeCorner(card, 18)
	makeStroke(card, Color3.fromRGB(255, 255, 255), 0.1)
	return card
end

local function formatCost(cost: number?): string
	if cost == nil then
		return "MAX"
	end
	return tostring(math.floor(cost)) .. " Coins"
end

local function fetchSnapshot()
	local success, result = pcall(function()
		return resolvedSnapshotRemote:InvokeServer()
	end)
	if success and typeof(result) == "table" then
		snapshot = result
	else
		statusLabel.Text = "The shop is unavailable right now."
	end
end

local function purchase(action: string, minionType: string?)
	if isBusy then
		return
	end
	isBusy = true
	local success, result = pcall(function()
		return resolvedPurchaseRemote:InvokeServer(action, minionType)
	end)
	isBusy = false
	if success and typeof(result) == "table" then
		statusLabel.Text = if typeof(result.message) == "string" then result.message else ""
		if typeof(result.snapshot) == "table" then
			snapshot = result.snapshot
		else
			fetchSnapshot()
		end
	else
		statusLabel.Text = "Purchase failed. Please try again."
		fetchSnapshot()
	end
end

local render: () -> () = function() end

local function createMinionCard(parent: Instance, minion: any, cardIndex: number)
	local card = makeCard(parent, 154, cardIndex)

	local icon = Instance.new("ImageLabel")
	icon.Name = "MinionIcon"
	icon.Size = UDim2.fromOffset(98, 98)
	icon.Position = UDim2.fromOffset(16, 28)
	icon.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
	icon.Image = if typeof(minion.iconImage) == "string" then minion.iconImage else ""
	icon.ScaleType = Enum.ScaleType.Fit
	icon.Parent = card
	makeCorner(icon, 16)
	makeStroke(icon, Color3.fromRGB(255, 162, 205), 0.15)

	local name = Instance.new("TextLabel")
	name.Size = UDim2.new(1, -316, 0, 34)
	name.Position = UDim2.fromOffset(130, 18)
	name.BackgroundTransparency = 1
	name.TextXAlignment = Enum.TextXAlignment.Left
	name.Text = tostring(minion.displayName or minion.minionType)
	name.TextColor3 = Color3.fromRGB(70, 52, 104)
	name.Font = Enum.Font.GothamBlack
	name.TextSize = 23
	name.Parent = card

	local unlocked = minion.unlocked == true
	local currentEnergy = math.floor(minion.currentEnergy or 0)
	local detailText: string
	if unlocked and minion.upgradeCost ~= nil then
		local energyUpgradePerLevel = math.floor(minion.energyUpgradePerLevel or 0)
		local nextEnergy = math.min(currentEnergy + energyUpgradePerLevel, GameplayConfig.Limits.MaxEnergyValue)
		detailText = string.format(
			"Unlocked  •  New recruits Energy %d → %d  •  Level %d",
			currentEnergy,
			nextEnergy,
			math.floor(minion.upgradeLevel or 0)
		)
	elseif unlocked then
		detailText = string.format("Unlocked  •  New recruits Energy %d  •  MAX LEVEL", currentEnergy)
	else
		detailText = string.format("Locked  •  Base Energy %d", math.floor(minion.baseEnergy or 0))
	end
	local details = Instance.new("TextLabel")
	details.Size = UDim2.new(1, -316, 0, 76)
	details.Position = UDim2.fromOffset(130, 56)
	details.BackgroundTransparency = 1
	details.TextXAlignment = Enum.TextXAlignment.Left
	details.TextYAlignment = Enum.TextYAlignment.Top
	details.Text = detailText
	details.TextColor3 = Color3.fromRGB(91, 75, 119)
	details.Font = Enum.Font.GothamBold
	details.TextSize = 17
	details.TextWrapped = true
	details.Parent = card

	local actionStack = Instance.new("Frame")
	actionStack.AnchorPoint = Vector2.new(1, 0.5)
	actionStack.Size = UDim2.fromOffset(170, 108)
	actionStack.Position = UDim2.new(1, -16, 0.5, 0)
	actionStack.BackgroundTransparency = 1
	actionStack.Parent = card
	local layout = Instance.new("UIListLayout")
	layout.Padding = UDim.new(0, 8)
	layout.HorizontalAlignment = Enum.HorizontalAlignment.Center
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Parent = actionStack

	if unlocked then
		local upgradeButton = makeButton(
			actionStack,
			"UPGRADE\n" .. formatCost(minion.upgradeCost),
			Color3.fromRGB(48, 180, 228),
			minion.upgradeCost ~= nil
		)
		upgradeButton.Activated:Connect(function()
			purchase(ACTION.UpgradeMinionEnergy, minion.minionType)
			render()
		end)
	else
		local unlockButton = makeButton(
			actionStack,
			"UNLOCK\n" .. formatCost(minion.unlockCoinCost),
			Color3.fromRGB(255, 153, 44),
			true
		)
		unlockButton.Activated:Connect(function()
			purchase(ACTION.UnlockMinion, minion.minionType)
			render()
		end)

		if typeof(minion.gamePassId) == "number" and minion.gamePassId > 0 then
			local robuxButton = makeButton(actionStack, "UNLOCK WITH ROBUX", Color3.fromRGB(151, 91, 227), true)
			robuxButton.Activated:Connect(function()
				MarketplaceService:PromptGamePassPurchase(player, minion.gamePassId)
			end)
		end
	end
end

render = function()
	list:ClearAllChildren()
	local layout = Instance.new("UIListLayout")
	layout.Padding = UDim.new(0, 10)
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Parent = list
	layout:GetPropertyChangedSignal("AbsoluteContentSize"):Connect(function()
		setCanvasFromLayout(layout)
	end)

	if snapshot == nil then
		coinsLabel.Text = "Coins: --"
		statusLabel.Text = "Loading shop..."
		setCanvasFromLayout(layout)
		return
	end

	coinsLabel.Text = "Coins: " .. tostring(math.floor(snapshot.coins or 0))
	if typeof(snapshot.minions) == "table" then
		for index, minion in snapshot.minions do
			createMinionCard(list, minion, index)
		end
	end
	setCanvasFromLayout(layout)
end

local function openShop()
	isOpen = true
	panel.Visible = true
	fetchSnapshot()
	render()
end

resolvedOpenRemote.OnClientEvent:Connect(openShop)

closeButton.Activated:Connect(function()
	isOpen = false
	panel.Visible = false
end)

resolvedUpdatedRemote.OnClientEvent:Connect(function(newSnapshot: any)
	if typeof(newSnapshot) == "table" then
		snapshot = newSnapshot
		if isOpen then
			render()
		end
	end
end)

MarketplaceService.PromptGamePassPurchaseFinished:Connect(function(purchasePlayer: Player, _gamePassId: number, wasPurchased: boolean)
	if purchasePlayer == player and wasPurchased then
		task.delay(0.5, function()
			fetchSnapshot()
			if isOpen then
				render()
			end
		end)
	end
end)

fetchSnapshot()
render()
