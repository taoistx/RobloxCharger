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
openButton.Size = UDim2.fromOffset(104, 42)
openButton.Position = UDim2.new(1, -22, 0.5, 0)
openButton.BackgroundColor3 = Color3.fromRGB(35, 81, 110)
openButton.Text = "商店"
openButton.TextColor3 = Color3.fromRGB(255, 255, 255)
openButton.Font = Enum.Font.GothamBlack
openButton.TextSize = 18
openButton.AutoButtonColor = true
openButton.Visible = false
openButton.Active = false
openButton.Parent = gui
local openCorner = Instance.new("UICorner")
openCorner.CornerRadius = UDim.new(0, 8)
openCorner.Parent = openButton
local openStroke = Instance.new("UIStroke")
openStroke.Thickness = 2
openStroke.Color = Color3.fromRGB(113, 225, 255)
openStroke.Transparency = 0.2
openStroke.Parent = openButton

local panel = Instance.new("Frame")
panel.Name = "ShopPanel"
panel.AnchorPoint = Vector2.new(0.5, 0.5)
panel.Size = UDim2.fromOffset(560, 520)
panel.Position = UDim2.fromScale(0.5, 0.5)
panel.BackgroundColor3 = Color3.fromRGB(14, 20, 30)
panel.BackgroundTransparency = 0.04
panel.Visible = false
panel.Parent = gui
local panelCorner = Instance.new("UICorner")
panelCorner.CornerRadius = UDim.new(0, 8)
panelCorner.Parent = panel
local panelStroke = Instance.new("UIStroke")
panelStroke.Thickness = 2
panelStroke.Color = Color3.fromRGB(83, 178, 214)
panelStroke.Transparency = 0.25
panelStroke.Parent = panel

local title = Instance.new("TextLabel")
title.Name = "Title"
title.Size = UDim2.new(1, -80, 0, 42)
title.Position = UDim2.fromOffset(18, 10)
title.BackgroundTransparency = 1
title.TextXAlignment = Enum.TextXAlignment.Left
title.Text = "商店"
title.TextColor3 = Color3.fromRGB(239, 250, 255)
title.Font = Enum.Font.GothamBlack
title.TextSize = 24
title.Parent = panel

local closeButton = Instance.new("TextButton")
closeButton.Name = "Close"
closeButton.AnchorPoint = Vector2.new(1, 0)
closeButton.Size = UDim2.fromOffset(40, 34)
closeButton.Position = UDim2.new(1, -12, 0, 12)
closeButton.BackgroundColor3 = Color3.fromRGB(45, 53, 67)
closeButton.Text = "X"
closeButton.TextColor3 = Color3.fromRGB(255, 255, 255)
closeButton.Font = Enum.Font.GothamBlack
closeButton.TextSize = 18
closeButton.Parent = panel
local closeCorner = Instance.new("UICorner")
closeCorner.CornerRadius = UDim.new(0, 8)
closeCorner.Parent = closeButton

local coinsLabel = Instance.new("TextLabel")
coinsLabel.Name = "Coins"
coinsLabel.Size = UDim2.new(1, -66, 0, 26)
coinsLabel.Position = UDim2.fromOffset(48, 52)
coinsLabel.BackgroundTransparency = 1
coinsLabel.TextXAlignment = Enum.TextXAlignment.Left
coinsLabel.TextColor3 = Color3.fromRGB(255, 218, 90)
coinsLabel.Font = Enum.Font.GothamBold
coinsLabel.TextSize = 17
coinsLabel.Parent = panel

local coinsIcon = Instance.new("ImageLabel")
coinsIcon.Name = "CoinIcon"
coinsIcon.Size = UDim2.fromOffset(26, 26)
coinsIcon.Position = UDim2.fromOffset(18, 52)
coinsIcon.BackgroundTransparency = 1
coinsIcon.Image = COIN_ICON
coinsIcon.ScaleType = Enum.ScaleType.Fit
coinsIcon.Parent = panel

local statusLabel = Instance.new("TextLabel")
statusLabel.Name = "Status"
statusLabel.Size = UDim2.new(1, -36, 0, 22)
statusLabel.Position = UDim2.fromOffset(18, 78)
statusLabel.BackgroundTransparency = 1
statusLabel.TextXAlignment = Enum.TextXAlignment.Left
statusLabel.TextColor3 = Color3.fromRGB(180, 218, 232)
statusLabel.Font = Enum.Font.GothamMedium
statusLabel.TextSize = 13
statusLabel.Text = ""
statusLabel.TextTruncate = Enum.TextTruncate.AtEnd
statusLabel.Parent = panel

local list = Instance.new("ScrollingFrame")
list.Name = "ItemList"
list.Size = UDim2.new(1, -36, 1, -116)
list.Position = UDim2.fromOffset(18, 102)
list.BackgroundTransparency = 1
list.BorderSizePixel = 0
list.ScrollBarThickness = 6
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
	stroke.Thickness = 1.5
	stroke.Color = color
	stroke.Transparency = transparency
	stroke.Parent = parent
end

local function makeButton(parent: Instance, text: string, color: Color3, enabled: boolean): TextButton
	local button = Instance.new("TextButton")
	button.Size = UDim2.fromOffset(132, 34)
	button.BackgroundColor3 = if enabled then color else Color3.fromRGB(58, 64, 73)
	button.Text = text
	button.TextColor3 = if enabled then Color3.fromRGB(255, 255, 255) else Color3.fromRGB(154, 162, 171)
	button.Font = Enum.Font.GothamBold
	button.TextSize = 13
	button.TextWrapped = true
	button.AutoButtonColor = enabled
	button.Active = enabled
	button.Parent = parent
	makeCorner(button, 8)
	return button
end

local function makeCard(parent: Instance, height: number): Frame
	local card = Instance.new("Frame")
	card.Size = UDim2.new(1, -8, 0, height)
	card.BackgroundColor3 = Color3.fromRGB(25, 34, 46)
	card.Parent = parent
	makeCorner(card, 8)
	makeStroke(card, Color3.fromRGB(66, 91, 111), 0.35)
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
		statusLabel.Text = "商店数据暂时不可用。"
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
		statusLabel.Text = "购买失败，请稍后再试。"
		fetchSnapshot()
	end
end

local render: () -> () = function() end

local function createMinionCard(parent: Instance, minion: any)
	local card = makeCard(parent, 124)

	local icon = Instance.new("ImageLabel")
	icon.Name = "MinionIcon"
	icon.Size = UDim2.fromOffset(76, 76)
	icon.Position = UDim2.fromOffset(14, 24)
	icon.BackgroundColor3 = Color3.fromRGB(18, 26, 36)
	icon.Image = if typeof(minion.iconImage) == "string" then minion.iconImage else ""
	icon.ScaleType = Enum.ScaleType.Fit
	icon.Parent = card
	makeCorner(icon, 8)
	makeStroke(icon, Color3.fromRGB(66, 91, 111), 0.45)

	local name = Instance.new("TextLabel")
	name.Size = UDim2.new(1, -260, 0, 28)
	name.Position = UDim2.fromOffset(104, 12)
	name.BackgroundTransparency = 1
	name.TextXAlignment = Enum.TextXAlignment.Left
	name.Text = tostring(minion.displayName or minion.minionType)
	name.TextColor3 = Color3.fromRGB(239, 250, 255)
	name.Font = Enum.Font.GothamBlack
	name.TextSize = 18
	name.Parent = card

	local unlocked = minion.unlocked == true
	local currentEnergy = math.floor(minion.currentEnergy or 0)
	local detailText: string
	if unlocked and minion.upgradeCost ~= nil then
		local energyUpgradePerLevel = math.floor(minion.energyUpgradePerLevel or 0)
		local nextEnergy = math.min(currentEnergy + energyUpgradePerLevel, GameplayConfig.Limits.MaxEnergyValue)
		detailText = string.format(
			"已解锁 · 能量 %d -> %d · 升级 %d",
			currentEnergy,
			nextEnergy,
			math.floor(minion.upgradeLevel or 0)
		)
	elseif unlocked then
		detailText = string.format("已解锁 · 能量 %d · 已满级", currentEnergy)
	else
		detailText = string.format("未解锁 · 基础能量 %d", math.floor(minion.baseEnergy or 0))
	end
	local details = Instance.new("TextLabel")
	details.Size = UDim2.new(1, -260, 0, 58)
	details.Position = UDim2.fromOffset(104, 42)
	details.BackgroundTransparency = 1
	details.TextXAlignment = Enum.TextXAlignment.Left
	details.TextYAlignment = Enum.TextYAlignment.Top
	details.Text = detailText
	details.TextColor3 = Color3.fromRGB(178, 210, 223)
	details.Font = Enum.Font.GothamMedium
	details.TextSize = 14
	details.TextWrapped = true
	details.Parent = card

	local actionStack = Instance.new("Frame")
	actionStack.AnchorPoint = Vector2.new(1, 0.5)
	actionStack.Size = UDim2.fromOffset(138, 86)
	actionStack.Position = UDim2.new(1, -14, 0.5, 0)
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
			"升级\n" .. formatCost(minion.upgradeCost),
			Color3.fromRGB(36, 129, 190),
			minion.upgradeCost ~= nil
		)
		upgradeButton.Activated:Connect(function()
			purchase(ACTION.UpgradeMinionEnergy, minion.minionType)
			render()
		end)
	else
		local unlockButton = makeButton(
			actionStack,
			"解锁\n" .. formatCost(minion.unlockCoinCost),
			Color3.fromRGB(204, 148, 42),
			true
		)
		unlockButton.Activated:Connect(function()
			purchase(ACTION.UnlockMinion, minion.minionType)
			render()
		end)

		if typeof(minion.gamePassId) == "number" and minion.gamePassId > 0 then
			local robuxButton = makeButton(actionStack, "Robux 解锁", Color3.fromRGB(126, 90, 197), true)
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
		statusLabel.Text = "正在加载商店..."
		setCanvasFromLayout(layout)
		return
	end

	coinsLabel.Text = "Coins: " .. tostring(math.floor(snapshot.coins or 0))
	if typeof(snapshot.minions) == "table" then
		for _, minion in snapshot.minions do
			createMinionCard(list, minion)
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
