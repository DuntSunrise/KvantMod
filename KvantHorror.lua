local ok, DuntUI = pcall(function()
	return loadstring(game:HttpGet("https://raw.githubusercontent.com/DuntSunrise/DuntLibrary/refs/heads/main/DuntUI.lua"))()
end)
if not ok or not DuntUI then
	warn("[KvantHorror] DuntUI failed")
	return
end

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")
local Lighting = game:GetService("Lighting")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local LP = Players.LocalPlayer

local MUTANT_NAMES = {
	"GhostChild", "GhostChild2", "Pine", "LowPine", "Intruder",
	"WeirdDad", "Winterhorn", "Mutant", "Dad", "MutantTrap"
}

local State = {
	InfStamina = false,
	InfBreath = false,
	NoOverheat = false,
	FullBright = false,
	ESP = false,
	ItemESP = false,
	NoClip = false,
	FreezeMonsters = false,
	FreeCam = false,
	FOV = false,
	FOVValue = 70,
	ChinaHat = false,
	ChinaHatColor = Color3.fromRGB(255, 105, 180),
}

local defaultFOV = 70
pcall(function()
	if Workspace.CurrentCamera then
		defaultFOV = Workspace.CurrentCamera.FieldOfView
	end
end)

local function applyFOV()
	local cam = Workspace.CurrentCamera
	if not cam then return end
	if State.FOV then
		cam.FieldOfView = State.FOVValue
	else
		cam.FieldOfView = defaultFOV
	end
end

local function getChar()
	return LP.Character
end

local function findStam()
	local c = getChar()
	if not c then return nil end
	local sprint = c:FindFirstChild("Sprint")
	if sprint then
		local stam = sprint:FindFirstChild("Stam")
		if stam and (stam:IsA("NumberValue") or stam:IsA("IntValue")) then
			return stam
		end
	end
	return nil
end

local function findBreath()
	local c = getChar()
	if not c then return nil end
	local b = c:FindFirstChild("Breath")
	if b and (b:IsA("NumberValue") or b:IsA("IntValue")) then
		return b
	end
	return nil
end

local function isPlayerChar(model)
	for _, plr in ipairs(Players:GetPlayers()) do
		if plr.Character == model then
			return true
		end
	end
	return false
end

local function isMutantName(name)
	local n = string.lower(tostring(name or ""))
	for i = 1, #MUTANT_NAMES do
		if string.find(n, string.lower(MUTANT_NAMES[i]), 1, true) then
			return true
		end
	end
	return false
end

local function optimizePlace()
	pcall(function()
		Lighting.GlobalShadows = false
		Lighting.FogEnd = 999999
		for _, v in ipairs(Lighting:GetChildren()) do
			if v:IsA("PostEffect") or v:IsA("Atmosphere") or v:IsA("Sky") then
				v:Destroy()
			end
		end
		for _, v in ipairs(Workspace:GetDescendants()) do
			if v:IsA("ParticleEmitter") or v:IsA("Trail") or v:IsA("Fire") or v:IsA("Smoke") then
				v.Enabled = false
			elseif v:IsA("BasePart") then
				v.CastShadow = false
			end
		end
	end)
end

local function clearBlurEffects()
	pcall(function()
		for _, v in ipairs(Lighting:GetChildren()) do
			if v:IsA("BlurEffect") or v:IsA("DepthOfFieldEffect") then
				v.Enabled = false
			end
		end
		local cam = Workspace.CurrentCamera
		if cam then
			for _, v in ipairs(cam:GetChildren()) do
				if v:IsA("BlurEffect") or v:IsA("DepthOfFieldEffect") then
					v.Enabled = false
				end
			end
		end
	end)
end

local function applyMonsterFreeze()
	pcall(function()
		for _, d in ipairs(Workspace:GetDescendants()) do
			if d:IsA("Model") and not isPlayerChar(d) then
				local hum = d:FindFirstChildOfClass("Humanoid")
				local mHrp = d:FindFirstChild("HumanoidRootPart") or d.PrimaryPart
				if hum and mHrp and isMutantName(d.Name) then
					if State.FreezeMonsters then
						mHrp.Anchored = true
						mHrp.AssemblyLinearVelocity = Vector3.zero
						mHrp.AssemblyAngularVelocity = Vector3.zero
						hum.WalkSpeed = 0
					else
						mHrp.Anchored = false
					end
				end
			end
		end
	end)
end

local espMap = {}

local function clearESP()
	for model, data in pairs(espMap) do
		pcall(function()
			if data.bb then data.bb:Destroy() end
		end)
	end
	espMap = {}
end

local function addESP(model)
	if espMap[model] then return end
	if not model or not model.Parent then return end
	local head = model:FindFirstChild("Head") or model:FindFirstChild("HumanoidRootPart") or model.PrimaryPart
	if not head then return end

	local pg = LP:FindFirstChild("PlayerGui") or LP:WaitForChild("PlayerGui")
	local bb = Instance.new("BillboardGui")
	bb.Name = "MutantBB"
	bb.Adornee = head
	bb.Size = UDim2.fromOffset(140, 40)
	bb.StudsOffset = Vector3.new(0, 2.5, 0)
	bb.AlwaysOnTop = true
	bb.Parent = pg

	local label = Instance.new("TextLabel")
	label.Size = UDim2.new(1, 0, 0.5, 0)
	label.BackgroundTransparency = 1
	label.Text = model.Name
	label.TextColor3 = Color3.fromRGB(255, 80, 80)
	label.TextStrokeTransparency = 0.3
	label.Font = Enum.Font.GothamBold
	label.TextSize = 12
	label.Parent = bb

	local distLabel = Instance.new("TextLabel")
	distLabel.Size = UDim2.new(1, 0, 0.5, 0)
	distLabel.Position = UDim2.new(0, 0, 0.5, 0)
	distLabel.BackgroundTransparency = 1
	distLabel.TextColor3 = Color3.fromRGB(200, 200, 200)
	distLabel.TextStrokeTransparency = 0.3
	distLabel.Font = Enum.Font.Gotham
	distLabel.TextSize = 11
	distLabel.Parent = bb

	espMap[model] = { bb = bb, label = label, distLabel = distLabel }
end

local function refreshESP()
	if not State.ESP then
		clearESP()
		return
	end
	local c = getChar()
	local hrp = c and c:FindFirstChild("HumanoidRootPart")

	local seen = {}
	for _, d in ipairs(Workspace:GetDescendants()) do
		if d:IsA("Model") and not isPlayerChar(d) then
			local hum = d:FindFirstChildOfClass("Humanoid")
			if hum and (isMutantName(d.Name) or (hum.MaxHealth > 0 and d:FindFirstChild("HumanoidRootPart"))) then
				if isMutantName(d.Name) then
					seen[d] = true
					addESP(d)
				end
			end
		end
	end

	for model, data in pairs(espMap) do
		if not seen[model] or not model.Parent then
			pcall(function()
				if data.bb then data.bb:Destroy() end
			end)
			espMap[model] = nil
		else
			if hrp then
				local targetPart = model:FindFirstChild("HumanoidRootPart") or model:FindFirstChild("Head") or model.PrimaryPart
				if targetPart then
					local dist = math.floor((hrp.Position - targetPart.Position).Magnitude)
					data.distLabel.Text = "[" .. dist .. " studs]"
				end
			end
		end
	end
end

local itemEspMap = {}

local function clearItemESP()
	for obj, data in pairs(itemEspMap) do
		pcall(function()
			if data.bb then data.bb:Destroy() end
		end)
	end
	itemEspMap = {}
end

local function refreshItemESP()
	if not State.ItemESP then
		clearItemESP()
		return
	end

	local seen = {}
	for _, d in ipairs(Workspace:GetDescendants()) do
		if d:IsA("Tool") or (d:IsA("Model") and (string.find(string.lower(d.Name), "cola") or string.find(string.lower(d.Name), "food"))) then
			local part = d:IsA("Tool") and d:FindFirstChild("Handle") or d.PrimaryPart or d:FindFirstChildWhichIsA("BasePart")
			if part then
				seen[d] = part
				if not itemEspMap[d] then
					local pg = LP:FindFirstChild("PlayerGui") or LP:WaitForChild("PlayerGui")
					local bb = Instance.new("BillboardGui")
					bb.Name = "ItemBB"
					bb.Adornee = part
					bb.Size = UDim2.fromOffset(100, 25)
					bb.StudsOffset = Vector3.new(0, 1.5, 0)
					bb.AlwaysOnTop = true
					bb.Parent = pg

					local label = Instance.new("TextLabel")
					label.Size = UDim2.fromScale(1, 1)
					label.BackgroundTransparency = 1
					label.Text = d.Name
					label.TextColor3 = Color3.fromRGB(80, 255, 120)
					label.TextStrokeTransparency = 0.3
					label.Font = Enum.Font.GothamBold
					label.TextSize = 11
					label.Parent = bb

					itemEspMap[d] = { bb = bb }
				end
			end
		end
	end

	for obj, data in pairs(itemEspMap) do
		if not seen[obj] or not obj.Parent then
			pcall(function()
				if data.bb then data.bb:Destroy() end
			end)
			itemEspMap[obj] = nil
		end
	end
end

local chinaHatPart = nil

local function destroyChinaHat()
	if chinaHatPart then
		pcall(function() chinaHatPart:Destroy() end)
		chinaHatPart = nil
	end
end

local function createChinaHat(character)
	destroyChinaHat()
	if not State.ChinaHat or not character then return end
	local head = character:FindFirstChild("Head")
	if not head then return end

	local cone = Instance.new("Part")
	cone.Name = "HubChinaHat"
	cone.Size = Vector3.new(1, 1, 1)
	cone.Material = Enum.Material.SmoothPlastic
	cone.Transparency = 0.15
	cone.Anchored = false
	cone.CanCollide = false
	cone.CanQuery = false
	cone.CanTouch = false
	cone.Massless = true
	cone.Color = State.ChinaHatColor

	local mesh = Instance.new("SpecialMesh")
	mesh.MeshType = Enum.MeshType.FileMesh
	mesh.MeshId = "rbxassetid://1033714"
	mesh.Scale = Vector3.new(1.7, 1.1, 1.7)
	mesh.Parent = cone

	local weld = Instance.new("Weld")
	weld.Part0 = head
	weld.Part1 = cone
	weld.C0 = CFrame.new(0, 0.95, 0)
	weld.Parent = cone

	cone.Parent = character
	chinaHatPart = cone
end

local function updateHatColor(color)
	State.ChinaHatColor = color
	if chinaHatPart and chinaHatPart.Parent then
		chinaHatPart.Color = color
	elseif State.ChinaHat then
		createChinaHat(getChar())
	end
end

RunService.RenderStepped:Connect(function()
	if State.FreeCam then
		pcall(function()
			LP.CameraMode = Enum.CameraMode.Classic
			LP.DevComputerCameraMode = Enum.DevComputerCameraMode.Classic
			LP.DevTouchCameraMode = Enum.DevTouchCameraMode.Classic
		end)
	end

	if State.NoClip then
		pcall(function()
			local c = getChar()
			if c then
				for _, part in ipairs(c:GetDescendants()) do
					if part:IsA("BasePart") then
						part.CanCollide = false
					end
				end
			end
		end)
	end
end)

local espAcc = 0
local itemEspAcc = 0
local freezeAcc = 0

RunService.Heartbeat:Connect(function(dt)
	local c = getChar()
	if not c then return end

	if State.InfStamina then
		local stam = findStam()
		if stam then
			pcall(function()
				if stam.Value < 5 then stam.Value = 5 end
			end)
		end
	end

	if State.InfBreath then
		local breath = findBreath()
		if breath then
			pcall(function()
				if breath.Value < 20 then breath.Value = 20 end
			end)
		end
		clearBlurEffects()
	end

	if State.NoOverheat then
		pcall(function()
			local cameraHeat = ReplicatedStorage:FindFirstChild("GameState")
			if cameraHeat then
				local heatVal = cameraHeat:FindFirstChild("CameraHeat")
				if heatVal and (heatVal:IsA("NumberValue") or heatVal:IsA("IntValue")) then
					heatVal.Value = 0
				end
			end
			local pyro = ReplicatedStorage:FindFirstChild("Assets")
			if pyro then
				local pAsset = pyro:FindFirstChild("Pyro")
				if pAsset then
					local burning = pAsset:FindFirstChild("Burning")
					if burning and burning:IsA("BoolValue") then
						burning.Value = false
					end
				end
			end
		end)
	end

	if State.FullBright then
		pcall(function()
			Lighting.Brightness = 2
			Lighting.ClockTime = 14
			Lighting.GlobalShadows = false
			Lighting.OutdoorAmbient = Color3.fromRGB(150, 150, 150)
		end)
	end

	if State.FOV then
		applyFOV()
	end

	espAcc = espAcc + dt
	if State.ESP and espAcc >= 0.1 then
		espAcc = 0
		pcall(refreshESP)
	end

	itemEspAcc = itemEspAcc + dt
	if State.ItemESP and itemEspAcc >= 0.5 then
		itemEspAcc = 0
		pcall(refreshItemESP)
	end

	freezeAcc = freezeAcc + dt
	if freezeAcc >= 0.1 then
		freezeAcc = 0
		applyMonsterFreeze()
	end
end)

LP.CharacterAdded:Connect(function(char)
	task.wait(0.5)
	if State.ChinaHat then
		createChinaHat(char)
	end
end)

local Win = DuntUI.new({
	Title = "KvantHorror (Beta)",
	Subtitle = "by KvantScript",
	ScriptName = "KvantHorror",
	Theme = "Dark",
	Columns = 1,
	Screen = true,
	ToggleKey = Enum.KeyCode.RightShift,
})

local tabSurvival = Win:Tab("Survival")
local tabVisual = Win:Tab("Visual")

local secS = tabSurvival:Section("Survival")
local secGod = tabSurvival:Section("Freeze Monsters")
local secV = tabVisual:Section("ESP & Lighting")
local secC = tabVisual:Section("Movement & Optimization")
local secA = tabVisual:Section("Self Visuals")

secS:Toggle({
	Name = "Infinite Stamina",
	Default = false,
	Callback = function(v) State.InfStamina = v and true or false end,
})

secS:Toggle({
	Name = "Infinite Oxygen & Clear Screen",
	Default = false,
	Callback = function(v)
		State.InfBreath = v and true or false
		if v then clearBlurEffects() end
	end,
})

secS:Toggle({
	Name = "No Overheat / Pyro",
	Default = false,
	Callback = function(v) State.NoOverheat = v and true or false end,
})

secGod:Toggle({
	Name = "Freeze All Monsters",
	Default = false,
	Callback = function(v)
		State.FreezeMonsters = v and true or false
		applyMonsterFreeze()
	end,
})

secV:Toggle({
	Name = "Mutant ESP",
	Default = false,
	Callback = function(v)
		State.ESP = v and true or false
		if v then refreshESP() else clearESP() end
	end,
})

secV:Toggle({
	Name = "Item ESP (Cola / Food)",
	Default = false,
	Callback = function(v)
		State.ItemESP = v and true or false
		if v then refreshItemESP() else clearItemESP() end
	end,
})

secV:Toggle({
	Name = "FullBright (Light)",
	Default = false,
	Callback = function(v)
		State.FullBright = v and true or false
		if not v then
			Lighting.Brightness = 1
			Lighting.GlobalShadows = true
		end
	end,
})

secC:Toggle({
	Name = "NoClip (Walk through walls) (use at your own risk)",
	Default = false,
	Callback = function(v) State.NoClip = v and true or false end,
})

secC:Button({
	Name = "Optimize Place (Boost FPS)",
	Callback = function()
		optimizePlace()
	end,
})

secC:Toggle({
	Name = "Free Camera",
	Default = false,
	Callback = function(v) State.FreeCam = v and true or false end,
})

secC:Toggle({
	Name = "Custom FOV",
	Default = false,
	Callback = function(v)
		State.FOV = v and true or false
		if not v then
			local cam = Workspace.CurrentCamera
			if cam then cam.FieldOfView = defaultFOV end
		else
			applyFOV()
		end
	end,
})

secC:Slider({
	Name = "FOV Value",
	Default = 70,
	Min = 50,
	Max = 120,
	Round = 0,
	Callback = function(v)
		State.FOVValue = tonumber(v) or 70
		if State.FOV then applyFOV() end
	end,
})

secA:Toggle({
	Name = "China Hat",
	Default = false,
	Callback = function(v)
		State.ChinaHat = v and true or false
		if v then
			createChinaHat(getChar())
		else
			destroyChinaHat()
		end
	end,
})

secA:Dropdown({
	Name = "Hat Color Preset",
	Options = {"Pink", "Red", "Cyan", "Green", "Yellow", "Purple", "White"},
	Default = "Pink",
	Callback = function(option)
		local colors = {
			Pink = Color3.fromRGB(255, 105, 180),
			Red = Color3.fromRGB(255, 50, 50),
			Cyan = Color3.fromRGB(0, 235, 255),
			Green = Color3.fromRGB(50, 255, 100),
			Yellow = Color3.fromRGB(255, 220, 0),
			Purple = Color3.fromRGB(180, 50, 255),
			White = Color3.fromRGB(255, 255, 255),
		}
		if colors[option] then
			updateHatColor(colors[option])
		end
	end,
})

print("[KvantHorror] Loaded — RightShift")
