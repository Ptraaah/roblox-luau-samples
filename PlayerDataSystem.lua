-- PlayerDataSystem.lua
-- One complete player data system for a Roblox game, written in Luau.
-- Put this Script in ServerScriptService, it handles everything by itself:
-- loading and saving player data, leaderstats, coins, xp and levels,
-- a daily login bonus, and autosave. Written by Adel (LynchAlpha Studio)
-- as an original portfolio sample.

-- Services used by this system
local Players = game:GetService("Players")
local DataStoreService = game:GetService("DataStoreService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

-- The DataStore that keeps one record per player
local DATA_STORE_NAME = "PlayerDataSystem_v1"
local store = DataStoreService:GetDataStore(DATA_STORE_NAME)

-- Settings the game owner can change
local STARTING_COINS = 100
local DAILY_BONUS = 250
local DAILY_COOLDOWN = 24 * 60 * 60
local AUTOSAVE_INTERVAL = 300
local MAX_LOAD_RETRIES = 3

-- RemoteEvent the client fires when the player taps the daily bonus button
local bonusEvent = Instance.new("RemoteEvent")
bonusEvent.Name = "ClaimDailyBonus"
bonusEvent.Parent = ReplicatedStorage

-- Data for a brand new player
local function defaultData()
	return {
		Coins = STARTING_COINS,
		XP = 0,
		Level = 1,
		LastBonus = 0,
		PlaySeconds = 0,
	}
end

-- Live data for everyone in the server, keyed by UserId
local sessions = {}

-- Session start times, used to track play time
local joinedAt = {}

-- Builds the DataStore key for a player
local function keyFor(player)
	return "player_" .. tostring(player.UserId)
end

-- XP needed to go from a level to the next one, simple curve
local function xpForNextLevel(level)
	return 100 + (level - 1) * 50
end

-- Pushes the saved numbers into the leaderstats folder so they show in game
local function refreshLeaderstats(player, data)
	local leaderstats = player:FindFirstChild("leaderstats")
	if not leaderstats then
		return
	end
	local coins = leaderstats:FindFirstChild("Coins")
	if coins then
		coins.Value = data.Coins
	end
	local level = leaderstats:FindFirstChild("Level")
	if level then
		level.Value = data.Level
	end
	local xp = leaderstats:FindFirstChild("XP")
	if xp then
		xp.Value = data.XP
	end
end

-- Creates the leaderstats folder and its values for a player
local function buildLeaderstats(player, data)
	local leaderstats = Instance.new("Folder")
	leaderstats.Name = "leaderstats"
	local coins = Instance.new("IntValue")
	coins.Name = "Coins"
	coins.Value = data.Coins
	coins.Parent = leaderstats
	local level = Instance.new("IntValue")
	level.Name = "Level"
	level.Value = data.Level
	level.Parent = leaderstats
	local xp = Instance.new("IntValue")
	xp.Name = "XP"
	xp.Value = data.XP
	xp.Parent = leaderstats
	leaderstats.Parent = player
end

-- Loads a player record from the DataStore, retries a few times on failure
local function loadFromStore(player)
	local key = keyFor(player)
	for attempt = 1, MAX_LOAD_RETRIES do
		local ok, result = pcall(function()
			return store:GetAsync(key)
		end)
		if ok then
			return result
		end
		if attempt < MAX_LOAD_RETRIES then
			task.wait(1)
		end
	end
	return nil
end

-- Fills any missing fields with defaults, protects old saves after updates
local function applyDefaults(raw)
	local data = defaultData()
	if raw then
		for field, value in pairs(raw) do
			data[field] = value
		end
	end
	return data
end

-- Writes a player record back to the DataStore
local function saveToStore(player, data)
	local ok, err = pcall(function()
		store:SetAsync(keyFor(player), data)
	end)
	if not ok then
		warn("Save failed for " .. player.Name .. ": " .. tostring(err))
	end
	return ok
end

-- Adds coins to a player and refreshes what the game shows
local function addCoins(player, amount)
	local data = sessions[player.UserId]
	if not data then
		return
	end
	if amount == 0 then
		return
	end
	data.Coins = math.max(0, data.Coins + amount)
	refreshLeaderstats(player, data)
end

-- Adds xp, handles level ups, one or several levels at a time
local function addXP(player, amount)
	local data = sessions[player.UserId]
	if not data then
		return
	end
	if amount <= 0 then
		return
	end
	data.XP = data.XP + amount
	while data.XP >= xpForNextLevel(data.Level) do
		data.XP = data.XP - xpForNextLevel(data.Level)
		data.Level = data.Level + 1
	end
	refreshLeaderstats(player, data)
end

-- How many coins a full in game day of playtime is worth as a small reward
local function playtimeReward(seconds)
	return math.floor(seconds / 600) * 5
end

-- Tracks play time and pays the small playtime reward when a player leaves
local function settlePlaytime(player, data)
	local start = joinedAt[player.UserId]
	if not start then
		return
	end
	local played = math.floor(os.clock() - start)
	data.PlaySeconds = data.PlaySeconds + played
	local reward = playtimeReward(played)
	if reward > 0 then
		data.Coins = data.Coins + reward
	end
end

-- Full join flow for one player
local function onPlayerAdded(player)
	joinedAt[player.UserId] = os.clock()
	local raw = nil
	if RunService:IsStudio() then
		raw = nil
	else
		raw = loadFromStore(player)
	end
	local data = applyDefaults(raw)
	sessions[player.UserId] = data
	buildLeaderstats(player, data)
end

-- Full leave flow for one player
local function onPlayerRemoving(player)
	local data = sessions[player.UserId]
	if data then
		settlePlaytime(player, data)
		if not RunService:IsStudio() then
			saveToStore(player, data)
		end
	end
	sessions[player.UserId] = nil
	joinedAt[player.UserId] = nil
end

-- Daily bonus claim, fired by the client, checked on the server
local function onBonusClaim(player)
	local data = sessions[player.UserId]
	if not data then
		return
	end
	local now = os.time()
	if now - (data.LastBonus or 0) < DAILY_COOLDOWN then
		return
	end
	data.LastBonus = now
	addCoins(player, DAILY_BONUS)
end

-- Connect everything
Players.PlayerAdded:Connect(onPlayerAdded)
Players.PlayerRemoving:Connect(onPlayerRemoving)
bonusEvent.OnServerEvent:Connect(onBonusClaim)

-- Handle players who joined before this script finished loading
for _, player in ipairs(Players:GetPlayers()) do
	if not sessions[player.UserId] then
		task.spawn(onPlayerAdded, player)
	end
end

-- Save everyone when the server shuts down
game:BindToClose(function()
	if RunService:IsStudio() then
		return
	end
	for _, player in ipairs(Players:GetPlayers()) do
		local data = sessions[player.UserId]
		if data then
			settlePlaytime(player, data)
			saveToStore(player, data)
		end
	end
end)

-- Autosave loop, also grants 1 xp per minute of play as a small touch
task.spawn(function()
	while true do
		task.wait(AUTOSAVE_INTERVAL)
		for _, player in ipairs(Players:GetPlayers()) do
			addXP(player, 5)
			local data = sessions[player.UserId]
			if data and not RunService:IsStudio() then
				saveToStore(player, data)
			end
		end
	end
end)
