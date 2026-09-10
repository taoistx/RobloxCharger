--!strict

-- Keeps treadmill BillboardGui labels aligned with the multiplier encoded in
-- their root model name (for example, "x15 Treadmill"). This is presentation
-- only; Coins rewards remain server-authoritative.

local Workspace = game:GetService("Workspace")

local TREADMILL_NAME_PATTERN = "^x(%d+)%s+Treadmill$"

local function updateLabelFromDescendant(descendant: Instance)
	local current: Instance? = descendant
	while current ~= nil and current ~= Workspace do
		if current:IsA("Model") then
			local multiplierText = string.match(current.Name, TREADMILL_NAME_PATTERN)
			if multiplierText == nil then
				return
			end

			local conveyor = current:FindFirstChild("Conveyor")
			if conveyor == nil or not conveyor:IsA("BasePart") then
				return
			end

			local billboard = conveyor:FindFirstChildWhichIsA("BillboardGui")
			if billboard == nil then
				return
			end

			local label = billboard:FindFirstChildWhichIsA("TextLabel")
			if label ~= nil then
				label.Text = string.format("x%s Coins Boost", multiplierText)
			end
			return
		end

		current = current.Parent
	end
end

for _, descendant in Workspace:GetDescendants() do
	updateLabelFromDescendant(descendant)
end

Workspace.DescendantAdded:Connect(updateLabelFromDescendant)
