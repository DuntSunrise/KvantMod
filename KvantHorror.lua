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
local PathfindingService = game:GetService("PathfindingService")
local UserInputService = game:GetService("UserInputService")
local LP = Players.LocalPlayer

local MUTANT_NAMES = {
	"GhostChild", "GhostChild2", "Pine", "LowPine", "Intruder",
	"WeirdDad", "Winterhorn", "Mutant", "Dad", "MutantTrap"
}

local State = {
	InfStamina = false,
	CustomSpeed = false,
	SpeedValue = 22,
	InfBreath = false,
	NoOverheat = false,
	FullBright = false,
	ESP = false,
	NpcESP = false,
	FakeESP = false,
	ItemESP = false,
	NoClip = false,
	AntiMonsterAura = false,
	AuraDistance = 25,
	FreeCam = false,
	FOV = false,
	FOVValue = 70,
	ChinaHat = false,
	ChinaHatColor = Color3.fromRGB(255, 105, 180),
	Fly = false,
	FlySpeed = 50,
	HealthBar = false, -- Новое состояние для полоски хп
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

local function get_hrp()
	local c = getChar()
	return c and c:FindFirstChild("HumanoidRootPart")
end

local controls_ref = nil
local function get_controls()
	if controls_ref then return controls_ref end
	local ok, res = pcall(function()
		local ps = LP:FindFirstChild("PlayerScripts")
		local pm = ps and ps:FindFirstChild("PlayerModule")
		if not pm then return nil end
		return require(pm):GetControls()
	end)
	if ok and res then controls_ref = res end
	return controls_ref
end

local function flat_unit(v)
	local f = Vector3.new(v.X, 0, v.Z)
	if f.Magnitude > 0 then return f.Unit end
	return Vector3.zero
end

local function get_move_vector(cam)
	local c = get_controls()
	if c then
		local ok, v = pcall(function() return c:GetMoveVector() end)
		if ok and typeof(v) == "Vector3" and v.Magnitude > 0.05 then
			return v
		end
	end
	local ch = getChar()
	local hum = ch and ch:FindFirstChildOfClass("Humanoid")
	if hum and cam then
		local md = hum.MoveDirection
		if md.Magnitude > 0.05 then
			local ff, fr = flat_unit(cam.CFrame.LookVector), flat_unit(cam.CFrame.RightVector)
			return Vector3.new(md:Dot(fr), 0, -md:Dot(ff))
		end
	end
	return Vector3.zero
end

local fly_gravity = Workspace.Gravity
local function set_fly(state)
	State.Fly = state
	if state then
		Workspace.Gravity = 0
	else
		Workspace.Gravity = fly_gravity
		local h = get_hrp()
		if h then h.AssemblyLinearVelocity = Vector3.zero end
		local hum = getChar() and getChar():FindFirstChildOfClass("Humanoid")
		if hum then hum:ChangeState(Enum.HumanoidStateType.GettingUp) end
	end
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

local function isMutantName(name, model)
	local n = string.lower(tostring(name or ""))
	for i = 1, #MUTANT_NAMES do
		local mutantLower = string.lower(MUTANT_NAMES[i])
		if n == mutantLower or n:sub(1, #mutantLower) == mutantLower then
			if model and model:FindFirstChildOfClass("Humanoid") then
				return true
			end
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

local cachedMutants = {}
local function updateMutantCache()
	local newCache = {}
	for _, d in ipairs(Workspace:GetChildren()) do
		if d:IsA("Model") and not isPlayerChar(d) and isMutantName(d.Name, d) then
			local mHrp = d:FindFirstChild("HumanoidRootPart") or d.PrimaryPart
			if mHrp then
				table.insert(newCache, { hrp = mHrp })
			end
		end
	end
	cachedMutants = newCache
end

local function runAntiMonsterAura()
	if not State.AntiMonsterAura then return end
	local c = getChar()
	local hrp = c and c:FindFirstChild("HumanoidRootPart")
	if not hrp then return end

	for i = 1, #cachedMutants do
		local data = cachedMutants[i]
		if data.hrp and data.hrp.Parent then
			local dist = (hrp.Position - data.hrp.Position).Magnitude
			if dist <= State.AuraDistance then
				pcall(function()
					local escapeDir = (hrp.Position - data.hrp.Position).Unit
					if escapeDir.Magnitude == 0 or escapeDir ~= escapeDir then
						escapeDir = Vector3.new(0, 0, 1)
					end
					hrp.CFrame = CFrame.new(hrp.Position + (escapeDir * 18) + Vector3.new(0, 3, 0))
					hrp.AssemblyLinearVelocity = Vector3.zero
				end)
			end
		end
	end
end

local function advancedPathTravel(keyword)
	pcall(function()
		local c = getChar()
		local hrp = c and c:FindFirstChild("HumanoidRootPart")
		if not hrp then return end

		local targetPart = nil
		local minDistance = 999999

		for _, d in ipairs(Workspace:GetDescendants()) do
			local name = string.lower(d.Name)
			if string.find(name, keyword) then
				local part = nil
				if d:IsA("BasePart") then
					part = d
				elseif d:IsA("Model") then
					part = d.PrimaryPart or d:FindFirstChildWhichIsA("BasePart")
				elseif d:IsA("Tool") then
					part = d:FindFirstChild("Handle") or d:FindFirstChildWhichIsA("BasePart")
				end
				
				if part then
					local dist = (hrp.Position - part.Position).Magnitude
					if dist < minDistance then
						minDistance = dist
						targetPart = part
					end
				end
			end
		end

		if targetPart then
			local path = PathfindingService:CreatePath({
				AgentRadius = 2,
				AgentHeight = 5,
				AgentCanJump = true,
				WaypointSpacing = 4,
			})

			local destination = targetPart.Position + Vector3.new(0, 1, 0)
			path:ComputeAsync(hrp.Position, destination)

			if path.Status == Enum.PathStatus.Success then
				local waypoints = path:GetWaypoints()
				
				for _, waypoint in ipairs(waypoints) do
					if not getChar() or not hrp.Parent then break end
					
					local targetPos = waypoint.Position + Vector3.new(0, 3, 0)
					local startCF = hrp.CFrame
					local targetCF = CFrame.new(targetPos)
					
					local distance = (targetCF.Position - startCF.Position).Magnitude
					local steps = math.clamp(math.floor(distance * 1.5), 2, 8)

					for i = 1, steps do
						if not getChar() or not hrp.Parent then break end
						local alpha = i / steps
						hrp.CFrame = startCF:Lerp(targetCF, alpha)
						hrp.AssemblyLinearVelocity = Vector3.zero
						task.wait(0.005)
					end
				end

				local finalStartCF = hrp.CFrame
				local finalTargetCF = CFrame.new(targetPart.Position + Vector3.new(0, 2, 0))
				for i = 1, 3 do
					if not getChar() or not hrp.Parent then break end
					hrp.CFrame = finalStartCF:Lerp(finalTargetCF, i / 3)
					hrp.AssemblyLinearVelocity = Vector3.zero
					task.wait(0.005)
				end
				hrp.AssemblyLinearVelocity = Vector3.zero
			else
				local startCF = hrp.CFrame
				local targetCF = CFrame.new(destination + Vector3.new(0, 2, 0))
				local steps = 8
				for i = 1, steps do
					if not getChar() or not hrp.Parent then break end
					hrp.CFrame = startCF:Lerp(targetCF, i / steps)
					hrp.AssemblyLinearVelocity = Vector3.zero
					task.wait(0.005)
				end
				hrp.AssemblyLinearVelocity = Vector3.zero
			end
		end
	end)
end

local espMap = {}
local function clearESP()
	for model, data in pairs(espMap) do
		pcall(function() if data.bb then data.bb:Destroy() end end)
	end
	espMap = {}
end

local function addESP(model, text, color)
	if espMap[model] then return end
	if not model or not model.Parent then return end
	local head = model:FindFirstChild("Head") or model:FindFirstChild("HumanoidRootPart") or model.PrimaryPart or model:FindFirstChildWhichIsA("BasePart")
	if not head then return end

	local pg = LP:FindFirstChild("PlayerGui") or LP:WaitForChild("PlayerGui")
	local bb = Instance.new("BillboardGui")
	bb.Name = "CustomBB"
	bb.Adornee = head
	bb.Size = UDim2.fromOffset(140, 40)
	bb.StudsOffset = Vector3.new(0, 2.5, 0)
	bb.AlwaysOnTop = true
	bb.Parent = pg

	local label = Instance.new("TextLabel")
	label.Size = UDim2.new(1, 0, 0.5, 0)
	label.BackgroundTransparency = 1
	label.Text = text
	label.TextColor3 = color
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

	espMap[model] = { bb = bb, distLabel = distLabel }
end

local function refreshESP()
	if not State.ESP and not State.NpcESP and not State.FakeESP then
		clearESP()
		return
	end
	local c = getChar()
	local hrp = c and c:FindFirstChild("HumanoidRootPart")

	local seen = {}
	for _, d in ipairs(Workspace:GetDescendants()) do
		if d:IsA("Model") and not isPlayerChar(d) then
			local hum = d:FindFirstChildOfClass("Humanoid")
			local nameLower = string.lower(d.Name)
			
			local isFake = string.find(nameLower, "fake") or string.find(nameLower, "dummy") or string.find(nameLower, "placeholder") or string.find(nameLower, "visual")
			local isMutant = hum and isMutantName(d.Name, d)
			local isNpc = hum and not isMutant and not isFake and d ~= c

			if State.FakeESP and isFake then
				seen[d] = true
				addESP(d, "[Fake] " .. d.Name, Color3.fromRGB(255, 200, 50))
			elseif State.ESP and isMutant then
				seen[d] = true
				addESP(d, d.Name, Color3.fromRGB(255, 80, 80))
			elseif State.NpcESP and isNpc then
				seen[d] = true
				addESP(d, "[NPC] " .. d.Name, Color3.fromRGB(80, 180, 255))
			end
		end
	end

	for model, data in pairs(espMap) do
		if not seen[model] or not model.Parent then
			pcall(function() if data.bb then data.bb:Destroy() end end)
			espMap[model] = nil
		else
			if hrp then
				local targetPart = model:FindFirstChild("HumanoidRootPart") or model:FindFirstChild("Head") or model.PrimaryPart or model:FindFirstChildWhichIsA("BasePart")
				if targetPart then
					local dist = math.floor((hrp.Position - targetPart.Position).Magnitude)
					data.distLabel.Text = "[" .. dist .. " studs]"
				end
			end
		end
	end
end

-- Аккуратная безопасная полоска хп для монстров и себя (до 1488 лимит)
local healthBarMap = {}
local function clearHealthBars()
	for model, data in pairs(healthBarMap) do
		pcall(function() if data.bb then data.bb:Destroy() end end)
	end
	healthBarMap = {}
end

local function refreshHealthBars()
	if not State.HealthBar then
		clearHealthBars()
		return
	end

	local seen = {}
	for _, d in ipairs(Workspace:GetDescendants()) do
		if d:IsA("Model") and not isPlayerChar(d) then
			local hum = d:FindFirstChildOfClass("Humanoid")
			if hum and isMutantName(d.Name, d) then
				seen[d] = true
				if not healthBarMap[d] then
					local head = d:FindFirstChild("Head") or d:FindFirstChild("HumanoidRootPart") or d.PrimaryPart or d:FindFirstChildWhichIsA("BasePart")
					if head then
						local pg = LP:FindFirstChild("PlayerGui") or LP:WaitForChild("PlayerGui")
						local bb = Instance.new("BillboardGui")
						bb.Name = "HealthBarBB"
						bb.Adornee = head
						bb.Size = UDim2.fromOffset(100, 16)
						bb.StudsOffset = Vector3.new(0, 3.8, 0)
						bb.AlwaysOnTop = true
						bb.Parent = pg

						local bg = Instance.new("Frame")
						bg.Size = UDim2.fromScale(1, 1)
						bg.BackgroundColor3 = Color3.fromRGB(30, 30, 30)
						bg.BorderSizePixel = 0
						bg.Parent = bb

						local fill = Instance.new("Frame")
						fill.Name = "Fill"
						fill.Size = UDim2.fromScale(1, 1)
						fill.BackgroundColor3 = Color3.fromRGB(0, 235, 100)
						fill.BorderSizePixel = 0
						fill.Parent = bg

						local corner = Instance.new("UICorner")
						corner.CornerRadius = UDim.new(0, 4)
						corner.Parent = bg

						local cornerFill = Instance.new("UICorner")
						cornerFill.CornerRadius = UDim.new(0, 4)
						cornerFill.Parent = fill

						healthBarMap[d] = { bb = bb, fill = fill, humanoid = hum }
					end
				end
			end
		end
	end

	for model, data in pairs(healthBarMap) do
		if not seen[model] or not model.Parent or not data.humanoid or data.humanoid.Health <= 0 then
			pcall(function() if data.bb then data.bb:Destroy() end end)
			healthBarMap[model] = nil
		else
			local hp = data.humanoid.Health
			local maxHp = math.clamp(data.humanoid.MaxHealth, 1, 1488) -- безопасный лимит до 1488
			local ratio = math.clamp(hp / maxHp, 0, 1)
			data.fill.Size = UDim2.fromScale(ratio, 1)
		end
	end
end

local itemEspMap = {}
local function clearItemESP()
	for obj, data in pairs(itemEspMap) do
		pcall(function() if data.bb then data.bb:Destroy() end end)
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
		local name = string.lower(d.Name)
		if d:IsA("Tool") or string.find(name, "cola") or string.find(name, "food") or string.find(name, "generator") then
			local part = d:IsA("Tool") and d:FindFirstChild("Handle") or (d:IsA("Model") and (d.PrimaryPart or d:FindFirstChildWhichIsA("BasePart"))) or (d:IsA("BasePart") and d)
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
			pcall(function() if data.bb then data.bb:Destroy() end end)
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

	if State.Fly then
		local h = get_hrp()
		local hum = getChar() and getChar():FindFirstChildOfClass("Humanoid")
		if h and hum then
			hum:ChangeState(Enum.HumanoidStateType.RunningNoPhysics)

			local cam = Workspace.CurrentCamera
			local dir = Vector3.zero
			if UserInputService:IsKeyDown(Enum.KeyCode.W) then dir = dir + cam.CFrame.LookVector end
			if UserInputService:IsKeyDown(Enum.KeyCode.S) then dir = dir - cam.CFrame.LookVector end
			if UserInputService:IsKeyDown(Enum.KeyCode.A) then dir = dir - cam.CFrame.RightVector end
			if UserInputService:IsKeyDown(Enum.KeyCode.D) then dir = dir + cam.CFrame.RightVector end
			
			local mv = get_move_vector(cam)
			if mv.Magnitude > 0.05 then
				dir = dir + cam.CFrame.LookVector * (-mv.Z) + cam.CFrame.RightVector * mv.X
			end

			if UserInputService:IsKeyDown(Enum.KeyCode.Space) then dir = dir + Vector3.yAxis end
			if UserInputService:IsKeyDown(Enum.KeyCode.LeftControl) then dir = dir - Vector3.yAxis end

			if dir.Magnitude > 0 then 
				dir = dir.Unit * State.FlySpeed 
			end

			h.AssemblyLinearVelocity = dir
			h.AssemblyAngularVelocity = Vector3.zero
		end
	end
end)

local espAcc = 0
local itemEspAcc = 0
local auraAcc = 0
local cacheAcc = 0
local healthBarAcc = 0

RunService.Heartbeat:Connect(function(dt)
	local c = getChar()
	if not c then return end

	local hum = c:FindFirstChildOfClass("Humanoid")
	if State.CustomSpeed and hum then
		pcall(function()
			hum.WalkSpeed = State.SpeedValue
		end)
	end

	if State.InfStamina then
		local stam = findStam()
		if stam then
			pcall(function() if stam.Value < 5 then stam.Value = 5 end end)
		end
	end

	if State.InfBreath then
		local breath = findBreath()
		if breath then
			pcall(function() if breath.Value < 20 then breath.Value = 20 end end)
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
	if (State.ESP or State.NpcESP or State.FakeESP) and espAcc >= 0.15 then
		espAcc = 0
		pcall(refreshESP)
	end

	healthBarAcc = healthBarAcc + dt
	if State.HealthBar and healthBarAcc >= 0.1 then
		healthBarAcc = 0
		pcall(refreshHealthBars)
	end

	itemEspAcc = itemEspAcc + dt
	if State.ItemESP and itemEspAcc >= 0.5 then
		itemEspAcc = 0
		pcall(refreshItemESP)
	end

	cacheAcc = cacheAcc + dt
	if cacheAcc >= 0.8 then
		cacheAcc = 0
		updateMutantCache()
	end

	auraAcc = auraAcc + dt
	if auraAcc >= 0.05 then
		auraAcc = 0
		runAntiMonsterAura()
	end
end)

LP.CharacterAdded:Connect(function(char)
	task.wait(0.5)
	if State.ChinaHat then
		createChinaHat(char)
	end
	if State.Fly then
		set_fly(false)
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
local secGod = tabSurvival:Section("Anti Monstr Aura")
local secV = tabVisual:Section("ESP & Lighting")
local secC = tabVisual:Section("Movement & Optimization")
local secA = tabVisual:Section("Self Visuals")

secS:Toggle({
	Name = "Infinite Stamina",
	Default = false,
	Callback = function(v) State.InfStamina = v and true or false end,
})

secS:Toggle({
	Name = "Custom WalkSpeed (Use at your own risk!)",
	Default = false,
	Callback = function(v)
		State.CustomSpeed = v and true or false
		if not v then
			local c = getChar()
			local hum = c and c:FindFirstChildOfClass("Humanoid")
			if hum then hum.WalkSpeed = 16 end
		end
	end,
})

secS:Slider({
	Name = "WalkSpeed Value",
	Default = 22,
	Min = 22,
	Max = 100,
	Round = 0,
	Callback = function(v) State.SpeedValue = tonumber(v) or 22 end,
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
	Name = "Anti Monstr Aura",
	Default = false,
	Callback = function(v) State.AntiMonsterAura = v and true or false end,
})

secGod:Slider({
	Name = "Aura Trigger Range",
	Default = 25,
	Min = 15,
	Max = 45,
	Round = 0,
	Callback = function(v) State.AuraDistance = tonumber(v) or 25 end,
})

secV:Toggle({
	Name = "Mutant ESP",
	Default = false,
	Callback = function(v)
		State.ESP = v and true or false
		if not v and not State.NpcESP and not State.FakeESP then clearESP() end
	end,
})

-- Добавленный аккуратный тумблер для полосок ХП монстров
secV:Toggle({
	Name = "Monster Health Bars",
	Default = false,
	Callback = function(v)
		State.HealthBar = v and true or false
		if not v then clearHealthBars() end
	end,
})

secV:Toggle({
	Name = "NPC / Ghost ESP",
	Default = false,
	Callback = function(v)
		State.NpcESP = v and true or false
		if not v and not State.ESP and not State.FakeESP then clearESP() end
	end,
})

secV:Toggle({
	Name = "Fake / Dummy ESP",
	Default = false,
	Callback = function(v)
		State.FakeESP = v and true or false
		if not v and not State.ESP and not State.NpcESP then clearESP() end
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

secC:Toggle({
	Name = "Fly (Safe Anti-Cheat)",
	Default = false,
	Callback = function(v)
		set_fly(v)
	end,
})

secC:Slider({
	Name = "Fly Speed",
	Default = 50,
	Min = 20,
	Max = 120,
	Round = 0,
	Callback = function(v)
		State.FlySpeed = tonumber(v) or 50
	end,
})

secC:Button({
	Name = "Smooth Travel to Generator",
	Callback = function()
		advancedPathTravel("generator")
	end,
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
		State.StateFOV = v and true or false
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
			Green = Color3.fromRGB(0, 235, 255),
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
