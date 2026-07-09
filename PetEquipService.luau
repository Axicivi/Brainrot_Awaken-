local PetEquipHandlerService = {}

local ServerScriptService = game:GetService("ServerScriptService")
local ReplicatedStorage   = game:GetService("ReplicatedStorage")

local PetService = require(ServerScriptService.Services.PlayerService.PetService)
local PetMovementFlow = require(ServerScriptService.Flow.PlayerFlow.PetFlow.PetMovementFlow)
local LogMath = require(ReplicatedStorage.Shared.Frameworks.LogMath)
local PetsConfig = require(ReplicatedStorage.Configs.PetsConfig)
local PetTutorialUIService = require(ServerScriptService.Services.UIService.PetTutorialUIService)

-- EVENTS
local petEquipRemote     = ReplicatedStorage.Events.Remotes.PetEquip     :: RemoteEvent
local petUnequipRemote   = ReplicatedStorage.Events.Remotes.PetUnequip   :: RemoteEvent
local petEquipUpdate     = ReplicatedStorage.Events.Remotes.PetEquipUpdate :: RemoteEvent
local petRequestData     = ReplicatedStorage.Events.Remotes.PetRequestData
local petInventoryUpdate = ReplicatedStorage.Events.Remotes.PetInventoryUpdate
local petIconUpdateRemote = ReplicatedStorage.Events.Remotes.PetIconUpdateRemote
local petEquipBest = ReplicatedStorage.Events.Remotes.PetEquipBest :: RemoteEvent

local PAID_SLOTS = { [4] = true, [5] = true }

-- HELPERS
local function calculateDisplayPercent(player: Player): number
	local manager = PetService:GetManager(player)
	if not manager then return 0 end

	local petTypeCounts: { [string]: number } = {}
	local totalPetPercent = 0

	for _, slotData in pairs(manager:GetEquipped()) do
		if slotData then
			local petKey = slotData.key
			local petData = PetsConfig.GetPetData(petKey)
			local levelData = petData and petData.Levels[slotData.level]
			if levelData then
				totalPetPercent += (LogMath.toRaw(levelData.MultiplierLog) - 1) * 100
				petTypeCounts[petKey] = (petTypeCounts[petKey] or 0) + 1
			end
		end
	end

	local comboPercent = 0
	for _, count in pairs(petTypeCounts) do
		if count == 2 then
			comboPercent += 25
		elseif count >= 3 then
			comboPercent += 50
		end
	end

	return totalPetPercent + comboPercent
end

local function calculateComboBonus(equipped: { [number]: any }): number
	local keyCounts: { [string]: number } = {}
	for _, data in pairs(equipped) do
		if data then
			keyCounts[data.key] = (keyCounts[data.key] or 0) + 1
		end
	end

	local totalBonus = 0
	for _, count in pairs(keyCounts) do
		if count == 2 then
			totalBonus += 25
		elseif count >= 3 then
			totalBonus += 50
		end
	end
	return totalBonus
end

local function fireComboAnnouncement(player: Player, oldEquipped: { [number]: any }, newEquipped: { [number]: any })
	local PetAnnouncement = ReplicatedStorage.Events.Remotes.PetAnnouncement
	local oldBonus = calculateComboBonus(oldEquipped)
	local newBonus = calculateComboBonus(newEquipped)

	if newBonus == oldBonus then return end  -- không thay đổi → không fire

	if newBonus > 0 then
		PetAnnouncement:FireClient(player, "ComboActivated", newBonus)
	else
		PetAnnouncement:FireClient(player, "ComboDeactivated", 0)
	end
end

-- SETUP
function GetPetsAuraMultiplier(player: Player): number
	if not player then return 0 end
	local manager = PetService:GetManager(player)
	if not manager then return 0 end

	local totalLog = 0
	local petTypeCounts = {}

	for _, slotData in pairs(manager:GetEquipped()) do
		if slotData then
			local petKey = slotData.key
			local petData = PetsConfig.GetPetData(petKey)
			local levelData = petData and petData.Levels[slotData.level]
			if levelData and typeof(levelData.MultiplierLog) == "number" then
				totalLog += levelData.MultiplierLog
				petTypeCounts[petKey] = (petTypeCounts[petKey] or 0) + 1
			end
		end
	end

	if totalLog <= 0 then return 0 end

	local totalBonusPercent = 0
	for _, count in pairs(petTypeCounts) do
		if count == 2 then
			totalBonusPercent += 0.25
		elseif count == 3 then
			totalBonusPercent += 0.50
		end
	end

	if totalBonusPercent > 0 then
		totalLog += LogMath.fromRaw(1 + totalBonusPercent)
	end

	return totalLog
end


local function buildEquipBestCandidates(manager)
	local candidates: { { key: string, level: number, order: number, multiplierLog: number } } = {}

	for categoryId, catalog in pairs(PetsConfig.CategoryRegistry) do
		local keys = PetsConfig.GetCategoryKeys(categoryId) -- active-only for Limited, all for others
		for _, petKey in ipairs(keys) do
			local petData = catalog[petKey]
			local count = manager:GetPetCount(petKey)
			for level = 1, 3 do
				local required = PetsConfig.GetCumulativeRequirement(petKey, level, catalog)
				if required > 0 and count >= required then
					local levelData = petData.Levels[level]
					table.insert(candidates, {
						key           = petKey,
						level         = level,
						order         = petData.Order or 0,
						multiplierLog = levelData and levelData.MultiplierLog or 0,
					})
				end
			end
		end
	end

	return candidates
end


local function setupEquipEvents()
	petEquipRemote.OnServerEvent:Connect(function(player: Player, petKey: string, level: number)
		if typeof(petKey) ~= "string" or typeof(level) ~= "number" then return end
		local manager = PetService:GetManager(player)
		if not manager then return end

		local oldEquipped = {}
		for k, v in pairs(manager:GetEquipped()) do oldEquipped[k] = v end

		local ok, slotOrMsg = manager:EquipPet(petKey, level)
		if not ok then 
			warn("[PetEquip]", player.Name, slotOrMsg)return end

		if not player:GetAttribute("HasEquippedPet") then          -- NEW
			player:SetAttribute("HasEquippedPet", true)
		end

		PetMovementFlow:Start(player, petKey, slotOrMsg, level)

		local newEquipped = manager:GetEquipped()
		fireComboAnnouncement(player, oldEquipped, newEquipped)
		local multiplier = GetPetsAuraMultiplier(player)
		player:SetAttribute("PetBoost", multiplier)
		player:SetAttribute("PetBoostDisplay", calculateDisplayPercent(player))
		petEquipUpdate:FireClient(player, newEquipped)
		PetTutorialUIService:OnPetEquipped(player)   

		petInventoryUpdate:FireClient(player, manager.Counts, newEquipped)
	end)


	petUnequipRemote.OnServerEvent:Connect(function(player: Player, slot: number)
		if typeof(slot) ~= "number" then return end
		local manager = PetService:GetManager(player)
		if not manager then return end

		local currentEquipped = manager:GetEquipped()
		if not currentEquipped[slot] then return end

		local oldEquipped = {}
		for k, v in pairs(currentEquipped) do oldEquipped[k] = v end

		manager:UnequipPet(slot)
		PetMovementFlow:Cleanup(player, slot)

		local newEquipped = manager:GetEquipped()
		fireComboAnnouncement(player, oldEquipped, newEquipped)
		local multiplier = GetPetsAuraMultiplier(player)
		player:SetAttribute("PetBoost", multiplier)
		player:SetAttribute("PetBoostDisplay", calculateDisplayPercent(player))

		petEquipUpdate:FireClient(player, newEquipped)
		petInventoryUpdate:FireClient(player, manager.Counts, newEquipped)
	end)
end


local function setupEquipBest()
	petEquipBest.OnServerEvent:Connect(function(player: Player)
		local manager = PetService:GetManager(player)
		if not manager then return end

		local currentEquipped = manager:GetEquipped()
		for slot in pairs(currentEquipped) do
			manager:UnequipPet(slot)
			PetMovementFlow:Cleanup(player, slot)
		end

		local candidates = buildEquipBestCandidates(manager)

		table.sort(candidates, function(a, b)
			if a.multiplierLog ~= b.multiplierLog then
				return a.multiplierLog > b.multiplierLog
			end
			if a.level ~= b.level then return a.level > b.level end
			return a.order > b.order
		end)

		local availableSlots: { number } = { 1, 2, 3 }
		if player:GetAttribute("SlotOwned_4") then table.insert(availableSlots, 4) end
		if player:GetAttribute("SlotOwned_5") then table.insert(availableSlots, 5) end

		local maxSlots = #availableSlots
		local equipped = 0

		for _, candidate in ipairs(candidates) do
			if equipped >= maxSlots then break end
			local ok, slotOrMsg = manager:EquipPet(candidate.key, candidate.level)
			if ok then
				PetMovementFlow:Start(player, candidate.key, slotOrMsg, candidate.level)
				equipped += 1
			end
		end

		if equipped > 0 and not player:GetAttribute("HasEquippedPet") then   -- NEW
			player:SetAttribute("HasEquippedPet", true)
		end
		if equipped > 0 then
			PetTutorialUIService:OnPetEquipped(player)   
		end
		local newEquipped = manager:GetEquipped()
		local multiplier = GetPetsAuraMultiplier(player)
		player:SetAttribute("PetBoost", multiplier)
		player:SetAttribute("PetBoostDisplay", calculateDisplayPercent(player))
		fireComboAnnouncement(player, {}, newEquipped)
		petEquipUpdate:FireClient(player, newEquipped)
		petInventoryUpdate:FireClient(player, manager.Counts, newEquipped)
	end)
end
-- INIT

function PetEquipHandlerService:Init()
	setupEquipEvents()
	setupEquipBest()

	-- REQUEST DATA
	petRequestData.OnServerEvent:Connect(function(player: Player)
		local manager = PetService:GetManager(player)
		if not manager then return end
		petInventoryUpdate:FireClient(player, manager.Counts, manager.Equipped)
		petEquipUpdate:FireClient(player, manager.Equipped)
	end)
end
function PetEquipHandlerService:InitPlayer(player)
	local multiplier = GetPetsAuraMultiplier(player)
	player:SetAttribute("PetBoost", multiplier)
	player:SetAttribute("PetBoostDisplay", calculateDisplayPercent(player))
	local manager = PetService:GetManager(player)
	if manager then
		local slotsToCheck = { 4, 5 }
		local removedAny = false

		for _, slot in ipairs(slotsToCheck) do
			local ownsSlot = player:GetAttribute("SlotOwned_" .. slot) == true
			if not ownsSlot and manager:GetEquipped()[slot] then
				manager:UnequipPet(slot)   -- saves to profile via syncProfile internally
				removedAny = true
				warn(("[PetEquipHandlerService] Removed illegitimate slot %d pet for %s"):format(slot, player.Name))
			end
		end

		if removedAny then
			local newEquipped = manager:GetEquipped()
			petInventoryUpdate:FireClient(player, manager.Counts, newEquipped)
			petEquipUpdate:FireClient(player, newEquipped)
		end
	end

	-- ── Normal init ──
	local multiplier = GetPetsAuraMultiplier(player)
	player:SetAttribute("PetBoost", multiplier)
	player:SetAttribute("PetBoostDisplay", calculateDisplayPercent(player))

	local mgr = PetService:GetManager(player)
	if mgr then
		local equipped = mgr:GetEquipped()
		fireComboAnnouncement(player, {}, equipped)
	end
end

return PetEquipHandlerService