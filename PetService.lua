--!strict
local PetService = {}
PetService.__index = PetService

local ProfileHandlerService = require(game:GetService("ServerScriptService").Services.DataStoreService.ProfileHandlerService)

-- CONFIG
local PetsConfig = require(game.ReplicatedStorage.Configs.PetsConfig)
local AurasConfig = require(game.ReplicatedStorage.Configs.AurasConfig)

-- EVENTS
local petInventoryUpdate = game.ReplicatedStorage.Events.Remotes.PetInventoryUpdate :: RemoteEvent
local petEquipUpdate     = game.ReplicatedStorage.Events.Remotes.PetEquipUpdate     :: RemoteEvent

-- VARIABLES
export type PendingSkip = { key: string, level: number }

export type PetManagerObject = typeof(setmetatable(
	{} :: {
		Player    : Player,
		Counts    : { [string]: number },
		Milestone : number,
		Equipped  : { [number]: { key: string, level: number } },
		PendingSkip : PendingSkip?,
	},
	PetService
	))

local FREE_SLOTS = 3  -- slots 1-3 are free
local ActiveManagers: { [Player]: PetManagerObject } = {}

-- HELPERS

local function syncProfile(self: PetManagerObject)
	local profile = ProfileHandlerService:GetProfile(self.Player)
	if not profile then return end
	profile.Pets.counts     = self.Counts
	profile.Pets.milestone  = self.Milestone   
	profile.Pets.equipped   = self.Equipped
	profile.Pets.pendingSkip = self.PendingSkip
end

-- API
function PetService.new(player: Player): PetManagerObject?
	local data = ProfileHandlerService:GetProfile(player)
	if not data then return nil end

	local self = setmetatable({}, PetService)
	self.Player      = player
	self.Counts      = data.Pets.counts      or {}
	self.Milestone   = data.Pets.milestone   or 0
	self.Equipped    = data.Pets.equipped    or {}
	self.PendingSkip = data.Pets.pendingSkip or nil

	for i = 1, 5 do
		if self.Equipped[i] == nil then
			self.Equipped[i] = false
		end
	end

	ActiveManagers[player] = self :: any
	return self :: any
end
-- ─── Counts 
function PetService:AddPet(petName: string)
	local maxRequirement = PetsConfig.GetMaxRequirement(petName)
	local currentCount   = self.Counts[petName] or 0
                                                 
	if maxRequirement > 0 and currentCount >= maxRequirement then
		return
	end

	local increment = self.Player:GetAttribute("PetCounterBoost") and 2 or 1
	self.Counts[petName] = math.min(currentCount + increment, maxRequirement)
	syncProfile(self)
	petInventoryUpdate:FireClient(self.Player, self.Counts, self.Equipped)
end

function PetService:AddPetDirect(petName: string, amount: number)
	amount = amount or 1
	local petData = PetsConfig.GetPetData(petName)
	if not petData then
		warn("[PetService] AddPetDirect — unknown pet:", petName)
		return
	end
	self.Counts[petName] = (self.Counts[petName] or 0) + amount
	syncProfile(self)
	petInventoryUpdate:FireClient(self.Player, self.Counts, self.Equipped)
end

function PetService:GetPetCount(petName: string): number
	return self.Counts[petName] or 0
end

-- ─── Skip purchases ─────────────────────────────────────────────────────────
function PetService:GrantPetUpToLevel(petKey: string, level: number): boolean
	local category = PetsConfig.GetCategoryForKey(petKey)
	local petData = category and category[petKey]
	if not petData then return false end
	if not petData.Levels[level] then return false end

	local requiredCopies = PetsConfig.GetCumulativeRequirement(petKey, level, category)
	local currentCount   = self.Counts[petKey] or 0

	if currentCount >= requiredCopies then
		return false -- already owns this level (or beyond)
	end

	self.Counts[petKey] = requiredCopies
	syncProfile(self)
	petInventoryUpdate:FireClient(self.Player, self.Counts, self.Equipped)
	return true
end

function PetService:SetPendingSkip(petKey: string, level: number)
	self.PendingSkip = { key = petKey, level = level }
	syncProfile(self)
end

function PetService:GetPendingSkip(): PendingSkip?
	return self.PendingSkip
end

function PetService:ClearPendingSkip()
	self.PendingSkip = nil
	syncProfile(self)
end

-- ─── Milestone ───────────────────────────────────────────────────────────────
function PetService:SetGrantedMileStone(milestone: number)
	if not self.Player then return end
	self.Milestone = math.max(self.Milestone, milestone)
	syncProfile(self)
end

function PetService:ResetGrantedMilestone()
	self.Milestone = 0
	syncProfile(self)
end

function PetService:GetGrantedMilestone(): number
	return self.Milestone
end	

-- ─── Equip ───────────────────────────────────────────────────────────────
function PetService:EquipPet(petKey: string, level: number): (boolean, number | string)
	local petData = PetsConfig.GetPetData(petKey)
	if not petData then return false, "Unknown pet" end

	local levelData = petData.Levels[level]
	if not levelData then return false, "Unknown level" end

	local requiredCopies = PetsConfig.GetCumulativeRequirement(petKey, level)
	if (self.Counts[petKey] or 0) < requiredCopies then
		return false, "Not enough copies"
	end

	for _, slot in pairs(self.Equipped) do 
		if slot and slot.key == petKey and slot.level == level then
			return false, "Already equipped"
		end
	end

	local freeSlot = nil

	for i = 1, 3 do 
		if not self.Equipped[i] then 
			freeSlot = i
			break
		end
	end

	if not freeSlot then
		local ownsSlot4 = self.Player:GetAttribute("SlotOwned_4")
		local ownsSlot5 = self.Player:GetAttribute("SlotOwned_5")

		if ownsSlot4 and not self.Equipped[4] then
			freeSlot = 4
		elseif ownsSlot5 and not self.Equipped[5] then
			freeSlot = 5
		end
	end

	if not freeSlot then
		return false, "No free slots or you need to buy more slots!"
	end

	self.Equipped[freeSlot] = { key = petKey, level = level } 
	syncProfile(self)
	return true, freeSlot
end

function PetService:UnequipPet(slot: number): boolean
	if not self.Equipped[slot] then return false end
	self.Equipped[slot] = false 
	syncProfile(self)
	return true
end

function PetService:GetEquipped()
	return self.Equipped
end

-- ─── Grant lookup ────────────────────────────────────────────────────────────
function PetService:GetPetGrantForLevel(level: number): string?
	if typeof(level) ~= "number" then return nil end
	return AurasConfig.PetGrantByLevel[level]
end

-- ─── Manager access ──────────────────────────────────────────────────────────
function PetService:GetManager(player: Player): PetManagerObject
	return ActiveManagers[player] :: any
end

-- INIT
function PetService:InitPlayer(player: Player)
	local manager = PetService.new(player)
	if not manager then return end
	
	petInventoryUpdate:FireClient(player, manager.Counts, manager.Equipped)
	petEquipUpdate:FireClient(player, manager.Equipped)
	print("PetService: created manager for", player.Name)
end

function PetService:RemovePlayer(player: Player)
	local manager = ActiveManagers[player]
	if manager then
		ActiveManagers[player] = nil
	end
end

return PetService
