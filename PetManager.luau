-- ReplicatedStorage/Shared/Class/Pet
--
--
--   SERVER  (Pet.new)   authors the model: clone, scale, attributes, physics
--                       constraints, VFX, network ownership, and the
--                       CollectionService tag.
--   CLIENT  (Pet.bind)  attaches to the replicated, tagged model and drives
--                       it: movement (the AlignPosition target), animations,
--                       summon / recall.
-- Pet.Bind on client would help to reduce the bandwith of script by the way


local Pet = {}
Pet.__index = Pet

local RunService        = game:GetService("RunService")
local Players           = game:GetService("Players")
local CollectionService = game:GetService("CollectionService")
local TweenService      = game:GetService("TweenService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local AurasConfig = require(ReplicatedStorage.Configs.AurasConfig)
local TextAnimationUtil = require(ReplicatedStorage:WaitForChild("UI"):WaitForChild("Utils"):WaitForChild("TextAnimationUtil"))

local IS_SERVER = RunService:IsServer()

local PetsConfig      = require(ReplicatedStorage.Configs.PetsConfig)
local BrainrotsFolder = ReplicatedStorage:WaitForChild("Assets"):WaitForChild("Brainrots")
local InfoGuiTemplate = ReplicatedStorage:WaitForChild("Assets"):WaitForChild("BrainrotGuiTemplate"):WaitForChild("InfoGui")
-- ── Shared model contract ──────────────────────────────────────────────────
local PET_TAG       = "ActiveBrainrotPet"
local DEFAULT_SCALE = 0.6
local SPECIAL_SCALE = {
	Tung_Tung_God = 0.011,
}
local function scaleFor(petKey: string): number
	local petData = PetsConfig.GetPetData(petKey)
	return (petData and petData.ModelScale) or DEFAULT_SCALE
end

-- ── Registries (one per VM) ─────────────────────────────────────────────────
-- Server : activePets[player][slot] = pet
-- Client : clientPets[model]        = pet
local activePets: { [Player]: { [number]: any } } = {}
local clientPets: { [Model]: any } = {}

-- SERVER

local _firstAuraLevel: { [string]: number }? = nil


 -- get aura level
local function getFirstAuraLevel(petKey: string): number?
	if not _firstAuraLevel then
		_firstAuraLevel = {}
		for i, levelData in ipairs(AurasConfig.Levels) do
			local brainrot = levelData.Brainrot
			if brainrot and not _firstAuraLevel[brainrot] then
				_firstAuraLevel[brainrot] = i
			end
		end
	end
	return _firstAuraLevel[petKey]
end


--get id of vfx
function Pet:_getVFXId(): string?
	local petData = PetsConfig.GetPetData(self.PetKey)
	if petData and petData.VFXId then
		return petData.VFXId
	end

	local level = getFirstAuraLevel(self.PetKey)
	if not level then return nil end

	return AurasConfig:GetIdForLevel(level)
end


--  require keeps the client (and server load order) clean.
local _petVfxFlow
local function getVfxFlow()
	if _petVfxFlow == nil then
		_petVfxFlow = require(game.ServerScriptService.Flow.PlayerFlow.PetFlow.PetVFXFlow)
	end
	return _petVfxFlow
end

function Pet.new(owner: Player, petKey: string, slot: number, level: number?): any?
	assert(IS_SERVER, "Pet.new is server-only — use Pet.bind on the client")

	-- Guarantee at most one pet per (owner, slot): replace any existing one so
	-- re-equipping a slot never orphans a model.
	local existing = activePets[owner] and activePets[owner][slot]
	if existing then
		existing:Despawn()
	end

	local self = setmetatable({}, Pet)
	self.Owner       = owner
	self.Level       = level or 1
	self.Slot        = slot
	self.PetKey      = petKey
	self.Mode        = "walk"
	self.Model       = nil
	self.PrimaryPart = nil
	self.TargetAtt   = nil -- Terrain attachment; server owns it -> destroy on Despawn

	if not self:_buildModel() then
		return nil
	end

	activePets[owner] = activePets[owner] or {}
	activePets[owner][slot] = self
	return self
end
function Pet:_buildModel(): boolean
	local template = BrainrotsFolder:FindFirstChild(self.PetKey)
	if not template then
		warn("[Pet] No model template for:", self.PetKey)
		return false
	end

	local model = template:Clone()
	model.Name = self.PetKey .. "_Slot" .. self.Slot

	local scale = scaleFor(self.PetKey)
	--model:ScaleTo(scale)

	local primary = model.PrimaryPart or model:FindFirstChildWhichIsA("BasePart", true)
	if not primary then
		model:Destroy()
		warn("[Pet] No PrimaryPart for:", self.PetKey)
		return false
	end

	model:SetAttribute("OwnerId",  self.Owner.UserId)
	model:SetAttribute("Slot",     self.Slot)
	model:SetAttribute("PetKey",   self.PetKey)
	model:SetAttribute("PetScale", scale)
	model:SetAttribute("Mode",     self.Mode)

	-- Gui tag
		-- Gui tag
	-- Gui tag
	local gui = InfoGuiTemplate:Clone()
	gui.Adornee = primary
	gui.Parent  = primary

	local petData = PetsConfig.GetPetData(self.PetKey)
	gui.Frame.RarityLabel.RarityLabelUp.Text   = petData.RarityLabel
	gui.Frame.RarityLabel.RarityLabelDown.Text = petData.RarityLabel

	local yOffset = petData.TagStudsOffset or 2
	local currentOffset = gui.StudsOffset
	gui.StudsOffset = Vector3.new(currentOffset.X, yOffset, currentOffset.Z)


	local infoGuiRef = Instance.new("ObjectValue")
	infoGuiRef.Name   = "InfoGuiRef"
	infoGuiRef.Value  = gui
	infoGuiRef.Parent = model

	self.Model       = model
	self.PrimaryPart = primary
	return true
end

function Pet:Spawn()
	assert(IS_SERVER, "Pet:Spawn is server-only")
	if not self.Model or not self.PrimaryPart then return end

	local char     = self.Owner.Character or self.Owner.CharacterAdded:Wait()
	local hrp      = char:WaitForChild("HumanoidRootPart")
	local humanoid = self.Model:FindFirstChildWhichIsA("Humanoid")

	self.Model.Parent = workspace
	
	-- 1) VFX first, so the client binds to a fully-dressed model.
	local vfxId = self:_getVFXId()
	if vfxId then
		getVfxFlow().ApplyVFXToPet(self.Owner, self.Model, vfxId)
	end
	self.Model:ScaleTo(scaleFor(self.PetKey))

	-- Physics
	self.PrimaryPart.CanCollide = false
	self.PrimaryPart.CastShadow = false
	self.PrimaryPart.Anchored   = false

	if humanoid then
		humanoid:SetStateEnabled(Enum.HumanoidStateType.FallingDown, false)
		humanoid:SetStateEnabled(Enum.HumanoidStateType.Ragdoll,     false)
		humanoid:SetStateEnabled(Enum.HumanoidStateType.Jumping,     false)
		humanoid.JumpPower = 0
	end

	-- Start fully transparent; the client fades the body in on bind.
	for _, p in self.Model:GetDescendants() do
		if p:IsA("BasePart") then p.Transparency = 1 end
	end

	-- Constraint target on Terrain so the client can drive it every frame.
	local partAtt = Instance.new("Attachment")
	partAtt.Name   = "PetAnchor"
	partAtt.Parent = self.PrimaryPart -- (was self.Primary -> nil, so the attachment never parented)

	local targetAtt = Instance.new("Attachment")
	targetAtt.Name   = "Target_" .. self.Model.Name
	targetAtt.Parent = workspace.Terrain
	self.TargetAtt   = targetAtt

	local targetRef = Instance.new("ObjectValue")
	targetRef.Name   = "TargetRef"
	targetRef.Value  = targetAtt
	targetRef.Parent = self.Model

	local alignPos = Instance.new("AlignPosition")
	alignPos.Attachment0    = partAtt
	alignPos.Attachment1    = targetAtt
	alignPos.MaxForce       = math.huge
	alignPos.MaxVelocity    = 50
	alignPos.Responsiveness = 20
	alignPos.Parent         = self.PrimaryPart

	local alignOri = Instance.new("AlignOrientation")
	alignOri.Attachment0    = partAtt
	alignOri.Attachment1    = targetAtt
	alignOri.MaxTorque      = math.huge
	alignOri.Responsiveness = 10
	alignOri.Parent         = self.PrimaryPart
	local startFrame = hrp.CFrame * CFrame.new(3, 0.5, 0)
	targetAtt.WorldCFrame = startFrame
	self.Model:PivotTo(startFrame)

	-- 2) Hand EVERY BasePart to the client so its transparency/scale tweens
	--    replicate (mesh parts included, not just the primary).
	for _, part in self.Model:GetDescendants() do
		if part:IsA("BasePart") then
			pcall(function() part:SetNetworkOwner(self.Owner) end)
		end
	end
	pcall(function() self.PrimaryPart:SetNetworkOwner(self.Owner) end)


	CollectionService:AddTag(self.Model, PET_TAG)
end

function Pet:Despawn()
	assert(IS_SERVER, "Pet:Despawn is server-only")

	if self.TargetAtt then
		self.TargetAtt:Destroy() -- the Terrain attachment does NOT die with the model
		self.TargetAtt = nil
	end
	if self.Model then
		self.Model:Destroy()
		self.Model = nil
	end

	local byOwner = activePets[self.Owner]
	if byOwner then
		byOwner[self.Slot] = nil
		if next(byOwner) == nil then
			activePets[self.Owner] = nil
		end
	end
end

-- Server static helpers --------------------------------------------------------

function Pet.get(owner: Player, slot: number): any?
	return activePets[owner] and activePets[owner][slot]
end

function Pet.despawn(owner: Player, slot: number)
	local pet = Pet.get(owner, slot)
	if pet then pet:Despawn() end
end

function Pet.despawnAll(owner: Player)
	local byOwner = activePets[owner]
	if not byOwner then return end
	-- Snapshot slots first; Despawn mutates the table.
	local slots = {}
	for slot in pairs(byOwner) do
		table.insert(slots, slot)
	end
	for _, slot in ipairs(slots) do
		local pet = byOwner[slot]
		if pet then pet:Despawn() end
	end
	activePets[owner] = nil
end

-- CLIENT

local LocalPlayer = Players.LocalPlayer -- nil on the server; only read in client paths
local petsVisible = true

local FLAT_VECTOR       = Vector3.new(1, 0, 1)
local TELEPORT_DISTANCE = 45
local STUCK_TIME_LIMIT  = 0.75
local BOB_SPEED         = 2.2
local BOB_HEIGHT        = 0.35
local FADE_TIME         = 0.3
local SUMMON_TIME       = 0.45
local RECALL_TIME       = 0.2

local OFFSETS_FLY = {
	[1] = CFrame.new( 3.5, 5, 0),
	[2] = CFrame.new(-3.5, 5, 0),
	[3] = CFrame.new(0, 6, -3),
	[4] = CFrame.new( 3.5, 4, 2.5),
	[5] = CFrame.new(-3.5, 4, 2.5),
}
local OFFSETS_WALK = {
	[1] = CFrame.new(-8, 0, 9.5),
	[2] = CFrame.new(8, 0, 9.5),
	[3] = CFrame.new(0, 0, 14.5),
	[4] = CFrame.new(-8, 0, 19.5),
	[5] = CFrame.new(8, 0, 19.5),
}

-- A "body" part is a visible mesh part: not a VFX_ part and not VFX-tagged.
local function isBodyPart(p: Instance): boolean
	return p:IsA("BasePart")
		and p.Name:sub(1, 4) ~= "VFX_"
		and not CollectionService:HasTag(p, PetsConfig.VFXTag)
end

local function tweenScale(model: Model, fromScale: number, toScale: number, duration: number, easing: string)
	local steps    = 30
	local stepTime = duration / steps
	task.spawn(function()
		for i = 1, steps do
			local t = i / steps
			local eased
			if easing == "back" then
				local c1, c3 = 1.70158, 2.70158
				eased = 1 + c3 * ((t - 1) ^ 3) + c1 * ((t - 1) ^ 2)
			elseif easing == "quad_in" then
				eased = t * t
			else
				eased = t
			end
			eased = math.clamp(eased, 0, 2)
			local current = fromScale + (toScale - fromScale) * eased
			if model and model.Parent then
				model:ScaleTo(math.max(current, 0.001))
			end
			task.wait(stepTime)
		end
		if model and model.Parent then
			model:ScaleTo(math.max(toScale, 0.001))
		end
	end)
end

function Pet:_setupRarityLabel()
	local infoGui = self.Model:FindFirstChild("InfoGui", true)

	local attempts = 0
	while not infoGui and attempts < 10 do
		task.wait(0.1)
		infoGui = self.Model:FindFirstChild("InfoGui", true)
		attempts += 1
	end

	if not infoGui then
		warn("[Pet] InfoGui missing for", self.PetKey)
		return
	end

	local petData = PetsConfig.GetPetData(self.PetKey)
	if not petData then return end

	local rarity = petData.RarityLabel
	if not rarity then return end

	TextAnimationUtil:RarityLabel(rarity, infoGui.Frame.RarityLabel.RarityLabelUp, infoGui.Frame.RarityLabel.RarityLabelDown)
end
function Pet.bind(model: Model): any
	assert(not IS_SERVER, "Pet.bind is client-only — use Pet.new on the server")

	local self = setmetatable({}, Pet)
	self.Model       = model
	self.PrimaryPart = model.PrimaryPart or model:FindFirstChildWhichIsA("BasePart", true)
	self.OwnerId     = model:GetAttribute("OwnerId")
	self.Owner       = Players:GetPlayerByUserId(self.OwnerId)
	self.Slot        = model:GetAttribute("Slot") or 1
	self.Mode        = model:GetAttribute("Mode") or "walk"
	self.PetKey      = model:GetAttribute("PetKey")
	self.PetScale    = model:GetAttribute("PetScale") or DEFAULT_SCALE

	local targetRef = model:WaitForChild("TargetRef", 5)
	self.TargetAtt  = targetRef and targetRef.Value

	self._bobTime     = 0
	self._stuckTimer  = 0
	self._isMoving    = nil
	self._connections = {}

	self:SetupAnimations()
	self:_setupRarityLabel()   -- ← thêm dòng này


	-- Initial visibility for our own pets respects the current toggle state.
	if self.Owner == LocalPlayer then
		if petsVisible then
			self:FadeIn()
		else
			model:ScaleTo(0.001)
			self:SetVFXEnabled(false)
			self:_setBodyTransparency(1)
		end
	else
		self:FadeIn()
	end

	-- Reposition on the owner's respawn instead of rebuilding the pet.
	if self.Owner then
		table.insert(self._connections, self.Owner.CharacterAdded:Connect(function(newChar)
			self._isMoving   = nil
			self._stuckTimer = 0
			local hrp = newChar:WaitForChild("HumanoidRootPart", 3)
			if hrp and self.TargetAtt and self.Model and self.PrimaryPart then
				local frame = hrp.CFrame * CFrame.new(0, 2, 2)
				self.TargetAtt.WorldCFrame = frame
				self.Model:PivotTo(frame)
				self.PrimaryPart.AssemblyLinearVelocity = Vector3.zero
			end
		end))
	end

	-- Only the owner drives movement; everyone runs animations.
	if self.Owner == LocalPlayer then
		table.insert(self._connections, RunService.Heartbeat:Connect(function(dt)
			self:UpdateMovement(dt)
			self:UpdateAnimations()
		end))
	else
		table.insert(self._connections, RunService.RenderStepped:Connect(function()
			self:UpdateAnimations()
		end))
	end

	clientPets[model] = self
	return self
end

function Pet:_setBodyTransparency(value: number)
	for _, p in self.Model:GetDescendants() do
		if isBodyPart(p) then
			p.Transparency = value
		end
	end
end

function Pet:SetVFXEnabled(enabled: boolean)
	for _, p in self.Model:GetDescendants() do
		if CollectionService:HasTag(p, PetsConfig.VFXTag) then
			if p:IsA("ParticleEmitter") then
				p.Enabled = enabled
				if not enabled then p:Clear() end
			elseif p:IsA("Beam") or p:IsA("Fire") or p:IsA("Smoke")
				or p:IsA("Sparkles") or p:IsA("PointLight")
				or p:IsA("SpotLight") or p:IsA("SurfaceLight") then
				p.Enabled = enabled
			end
		end
	end
end

function Pet:SetupAnimations()
	local controller = self.Model:FindFirstChildWhichIsA("AnimationController")
		or self.Model:FindFirstChild("Humanoid")
	if not controller then return end

	local animator = controller:FindFirstChildWhichIsA("Animator")
		or Instance.new("Animator", controller)

	local petData = PetsConfig.GetPetData(self.PetKey)
	if not petData then return end

	self.SameWalkIdleAnim = petData.WalkAnimation ~= nil
		and petData.IdleAnimation ~= nil
		and petData.WalkAnimation == petData.IdleAnimation

	if petData.WalkAnimation and not self.SameWalkIdleAnim then
		local wAnim = Instance.new("Animation")
		wAnim.AnimationId = petData.WalkAnimation
		self.WalkTrack = animator:LoadAnimation(wAnim)
		self.WalkTrack.Priority = Enum.AnimationPriority.Movement
	end
	if petData.IdleAnimation then
		local iAnim = Instance.new("Animation")
		iAnim.AnimationId = petData.IdleAnimation
		self.IdleTrack = animator:LoadAnimation(iAnim)
		self.IdleTrack.Priority = Enum.AnimationPriority.Idle
	end
end

function Pet:FadeIn()
	for _, p in self.Model:GetDescendants() do
		if isBodyPart(p) then
			TweenService:Create(p, TweenInfo.new(FADE_TIME, Enum.EasingStyle.Quad), { Transparency = 0 }):Play()
		end
	end
end

function Pet:UpdateAnimations()
	if not self.PrimaryPart then
		self.PrimaryPart = self.Model.PrimaryPart or self.Model:FindFirstChildWhichIsA("BasePart", true)
		if self.PrimaryPart then
			self:SetupAnimations()
			self:FadeIn()
		else
			return
		end
	end

	local speed    = (self.PrimaryPart.AssemblyLinearVelocity * FLAT_VECTOR).Magnitude
	local isMoving = speed > 0.5

	if self.SameWalkIdleAnim then
		if self.IdleTrack and not self.IdleTrack.IsPlaying then
			self.IdleTrack:Play()
		end
		self._isMoving = isMoving
		return
	end

	if isMoving ~= self._isMoving then
		self._isMoving = isMoving
		if isMoving then
			if self.IdleTrack then self.IdleTrack:Stop(0.2) end
			if self.WalkTrack then self.WalkTrack:Play(0.2) end
		else
			if self.WalkTrack then self.WalkTrack:Stop(0.2) end
			if self.IdleTrack then self.IdleTrack:Play(0.2) end
		end
	end
end

function Pet:UpdateMovement(dt: number)
	if not self.PrimaryPart then return end
	if not self.TargetAtt or not self.Owner or not self.Owner.Character then return end

	local hrp = self.Owner.Character:FindFirstChild("HumanoidRootPart")
	if not hrp then return end

	local rootPos     = hrp.Position
	local flatLookDir = (hrp.CFrame.LookVector * FLAT_VECTOR).Unit
	if flatLookDir.Magnitude < 0.001 then flatLookDir = Vector3.new(0, 0, -1) end

	local flatRootCFrame = CFrame.lookAt(rootPos, rootPos + flatLookDir)
	local baseOffset = (self.Mode == "fly")
		and (OFFSETS_FLY[self.Slot]  or OFFSETS_FLY[1])
		or  (OFFSETS_WALK[self.Slot] or OFFSETS_WALK[1])

	if self.Mode == "fly" then
		self._bobTime += dt
		local bob = math.sin(self._bobTime * BOB_SPEED) * BOB_HEIGHT
		baseOffset = baseOffset * CFrame.new(0, bob, 0)
	end

	local idealCFrame = flatRootCFrame * baseOffset
	self.TargetAtt.WorldCFrame = self.TargetAtt.WorldCFrame:Lerp(idealCFrame, dt * 6)

	local hSpeed       = (self.PrimaryPart.AssemblyLinearVelocity * FLAT_VECTOR).Magnitude
	local flatPetPos   = self.PrimaryPart.Position * FLAT_VECTOR
	local flatIdealPos = idealCFrame.Position * FLAT_VECTOR
	local distance     = (flatPetPos - flatIdealPos).Magnitude

	if distance > TELEPORT_DISTANCE then
		self.TargetAtt.WorldCFrame = idealCFrame
		self.Model:PivotTo(idealCFrame)
		self.PrimaryPart.AssemblyLinearVelocity = Vector3.zero
		self._stuckTimer = 0
	elseif distance > 3 and hSpeed < 1 then
		self._stuckTimer += dt
		if self._stuckTimer >= STUCK_TIME_LIMIT then
			self.TargetAtt.WorldCFrame = idealCFrame
			self.Model:PivotTo(idealCFrame)
			self.PrimaryPart.AssemblyLinearVelocity = Vector3.zero
			self._stuckTimer = 0
		end
	else
		self._stuckTimer = 0
	end
end

function Pet:SetVisible(visible: boolean)
	if not self.Model then return end
	local petScale = self.PetScale or DEFAULT_SCALE

	if visible then
		self.Model:ScaleTo(0.001)
		for _, p in self.Model:GetDescendants() do
			if isBodyPart(p) then
				p.Transparency = 1
				TweenService:Create(p, TweenInfo.new(SUMMON_TIME, Enum.EasingStyle.Quad), { Transparency = 0 }):Play()
			end
		end
		tweenScale(self.Model, 0.001, petScale, SUMMON_TIME, "back")
		task.delay(SUMMON_TIME, function()
			if self.Model and self.Model.Parent then
				self:SetVFXEnabled(true)
			end
		end)
	else
		self:SetVFXEnabled(false)
		for _, p in self.Model:GetDescendants() do
			if isBodyPart(p) then
				TweenService:Create(p, TweenInfo.new(RECALL_TIME, Enum.EasingStyle.Quad), { Transparency = 1 }):Play()
			end
		end
		tweenScale(self.Model, petScale, 0.001, RECALL_TIME, "quad_in")
	end
end

-- Tears down the local wrapper. Does NOT destroy the model — the server owns it.
function Pet:Destroy()
	for _, conn in ipairs(self._connections or {}) do
		conn:Disconnect()
	end
	self._connections = {}
	if self.WalkTrack then self.WalkTrack:Destroy() end
	if self.IdleTrack then self.IdleTrack:Destroy() end
	if self.Model then
		clientPets[self.Model] = nil
	end
end

-- Client static helpers --------------------------------------------------------

function Pet.getByModel(model: Model): any?
	return clientPets[model]
end

function Pet.unbind(model: Model)
	local pet = clientPets[model]
	if pet then
		pet:Destroy() --clear the pet
	end
end

function Pet.setAllVisible(visible: boolean)
	petsVisible = visible
	for _, pet in pairs(clientPets) do
		if pet.Owner == LocalPlayer then
			pet:SetVisible(visible)
		end
	end
end

function Pet.toggleAll()
	Pet.setAllVisible(not petsVisible)
end

function Pet.isVisible(): boolean
	return petsVisible
end

return Pet
