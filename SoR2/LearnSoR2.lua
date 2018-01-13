--[[
	SorI/O
	An adaptation from MarI/O by SethBling
	Adapted by gsaurus

	"MarI/O is a program made of neural networks and genetic algorithms that
	kicks butt at Super Mario World."
	Source Code by SethBling: http://pastebin.com/ZZmSNaHX
	"NEAT" Paper: http://nn.cs.utexas.edu/downloads/papers/stanley.ec02.pdf

	SorI/O separates the algorithm from game specific configuration,
	making it easier to adapt to other games.

	LearnSoR2.lua
	Learning module for Streets of Rage 2 (SEGA Genesis/Megadrive)

]]

----------------------------------
--      Game Specific Data      --
----------------------------------

local neat = require("Neat/NeatEvolve")
local ui = require("Neat/NeatUI")

local user = {}

GameState = "sor2.State"

ButtonNames = {
	"A",
	"B",
	"C",
	"Up",
	"Down",
	"Left",
	"Right",
}

-- how many output values
user.OutputsCount = #ButtonNames

local MaxEnemies = 6
local MaxItems	 = 6

local InputFrequency = 2

-- Reduce resolution to simplify neuronal activity
local PositionDivider = 8
local InvalidValue = 999

-- Fitness variables
-- Tell if game clock is counting, so that it ignores cut-scenes
local previousClock
-- Tells if player is moving
local previousPlayerX
local previousPlayerY
-- if there are no enemies, must move
local MaxIdleTime = 120
local iddleTimer
-- if there are no enemies, must look for them
local NoEnemiesMaxTime = 600
local noEnemiesTimer
-- if there are enemies, must attack them
local NoAttackMaxTime = 1200
local noAttackTimer
local previousScore -- use score to detect it
-- Global time penalty
local TimePenaltyPerFrame = -0.033
local gameplayTime
-- Health and lifes bonus
local HealthBonusMultiplier = 10
local LifeBonusMultiplier = 1000
local ScoreMultiplier = 10
-- Enemy health and lifes bonus
local EnemyHealthBonusMultiplier = -1
local EnemyLifeBonusMultiplier = -100
local EnemiesCountMultiplier = 990


----------------------------------
-- Neural Network Configuration --
----------------------------------


local function clearJoypad()
	controller = {}
	for b = 1,#ButtonNames do
		controller["P1 " .. ButtonNames[b]] = false
	end
	joypad.set(controller)
end


-- used when starting a new run
user.onInitializeFunction = function()
	savestate.load(GameState);
	previousClock = 9999999
	previousPlayerX = -1
	previousPlayerY = -1
	iddleTimer = 0
	noEnemiesTimer = 0
	noAttackTimer = 0
	previousScore = 0
	gameplayTime = 0
	clearJoypad()
end


-- Read information from game's RAM --

local function read(address)
	return mainmemory.read_s16_be(address)
end

local function readByte(address)
	return mainmemory.readbyte(address)
end


local function readDeltaPos(base, playerX, playerY)
	local dx = read(base + 0x20)
	local dy = read(base + 0x24)
	dx = math.floor(dx / PositionDivider) - playerX
	dy = math.floor(dy / PositionDivider) - playerY
	return dx, dy
end


local function readEnemy(base, inputs, index, playerX, playerY)
	local isActive = read(base) ~= 0
	if isActive then
		inputs[index] = read(base + 0x0C)			-- Character type
		inputs[index + 1], inputs[index + 2] = readDeltaPos(base, playerX, playerY)
		inputs[index + 3] = read(base + 0x10)		-- Animation
		inputs[index + 4] = read(base + 0x38)		-- Weapon
	else
		inputs[index] = 0
		for i = 1, 4 do
			inputs[index + i] = InvalidValue
		end
	end
	return index + 5
end


local function readPlayer(base, inputs, index)
	local isActive = read(base) ~= 0
	if isActive then
		inputs[index] = read(base + 0x10)		-- Animation
		inputs[index + 1] = read(base + 0x38)	-- Weapon
	else
		for i = 0, 1 do
			inputs[index + i] = InvalidValue
		end
	end
	return index + 2
end

local function readItem(base, inputs, index, playerX, playerY)
	local isActive = read(base) ~= 0
	if isActive then
		inputs[index] = read(base + 0x0C) -- Type
		inputs[index + 1], inputs[index + 2] = readDeltaPos(base, playerX, playerY)
	else
		inputs[index] = 0
		for i = 1, 2 do
			inputs[index + i] = InvalidValue
		end
	end
	return index + 3
end



-- return an array containing input values
user.produceInputFunction = function()
	-- If clock is not counting, no need for input
	local clock = read(0xFC3C)
	if clock == previousClock or clock % InputFrequency ~= 0 then
		return nil
	end

	local result = {}
	-- player
	local index = readPlayer(0xEF00, result, 1)
	local playerX, playerY = readDeltaPos(0xEF00, 0, 0)
	-- Enemies
	for i = 0, MaxEnemies - 1 do
		index = readEnemy(0xF100 + i * 0x100, result, index, playerX, playerY)
	end
	-- Items (containers, goodies)
	for i = 0, MaxItems - 1 do
		index = readItem(0xF700 + i * 0x80, result, index, playerX, playerY)
	end
	-- Camera
	local realPlayerX = read(0xEF20)
	local cameraX = read(0xFC22)
	result[index] = math.floor((realPlayerX + cameraX) / 103) - 1
	local cameraY = read(0xFC26)
	result[index + 1] = (cameraY > 0 and cameraY < 255) and 1 or 0
	index = index + 2

	ui.updateInput(result)
	return result
end


-- receive an array containing the output values
user.consumeOutputFunction = function(outputs)
	controls = {}
	for i = 1, user.OutputsCount do
		local button = "P1 " .. ButtonNames[i]
		controls[button] = outputs[i] > 0
	end
	joypad.set(controls)
end


local function hasActiveEnemies()
	for i = 0, MaxEnemies - 1 do
		if read(0xF100 + i * 0x100) ~= 0 then
			return true
		end
	end
	return false
end

local function isPlayerMoving()
	local playerX = read(0xEF20)	-- X
	local playerY = read(0xEF24)	-- Y
	return playerX ~= previousPlayerX or playerY ~= previousPlayerY
end

local function hasScoreIncreased()
	return read(0xEF96)	> previousScore
end

local function checkEndCondition()
	-- End if game-over (lives < 0 or no longer in game mode)
	if read(0xEF82) < 0 or readByte(0xFC03) ~= 0x14 then
		print("Game Over: lives " .. read(0xEF82) .. " and state is " .. readByte(0xFC03))
		return true
	end
	-- Only end if clock is counting
	local clock = read(0xFC3C)
	if clock == previousClock then
		return false
	end
	gameplayTime = gameplayTime + 1
	if hasActiveEnemies() then
		iddleTimer = 0
		noEnemiesTimer = 0
		-- if there are enemies, must attack them
		if hasScoreIncreased() then
			noAttackTimer = 0
		else
			if noAttackTimer > NoAttackMaxTime then
				print("No attack timeout")
				return true
			end
			noAttackTimer = noAttackTimer + 1
		end
	else
		noAttackTimer = 0
		-- if there are no enemies, must move
		if isPlayerMoving() then
			iddleTimer = 0
		else
			if iddleTimer > MaxIdleTime then
				print("Iddle timeout")
				return true
			end
			iddleTimer = iddleTimer + 1
		end
		-- if there are no enemies, must look for them
		if noEnemiesTimer > NoEnemiesMaxTime then
			return true
		end
		noEnemiesTimer = noEnemiesTimer + 1
	end
	return false
end


local function updateVariables()
	previousClock = read(0xFC3C)	-- Clock
	previousPlayerX = read(0xEF20)	-- X
	previousPlayerY = read(0xEF24)	-- Y
	previousScore = read(0xEF96)	-- Score
end



-- return nil to indicate that this run didn't end yet
-- fitness value otherwise
user.checkFinalFitnessFunction = function()
	local fitness = nil
	local runEnded = checkEndCondition()
	if runEnded or ui.isRealTimeFitnessEnabled() then
		-- Ended, compute final fitness
		fitness = 0
		-- Score
		fitness = fitness + read(0xEF96) * ScoreMultiplier
		-- Global time penalty
		fitness = fitness + gameplayTime * TimePenaltyPerFrame
		-- Health and lifes bonus
		fitness = fitness + read(0xEF80) * HealthBonusMultiplier
		fitness = fitness + read(0xEF82) * LifeBonusMultiplier
		-- Enemy health and lifes bonus
		for i = 0, MaxEnemies - 1 do
			fitness = fitness + read(0xF180 + i * 0x100) * EnemyHealthBonusMultiplier
			fitness = fitness + read(0xF182 + i * 0x100) * EnemyLifeBonusMultiplier
		end
		-- KO counter
		fitness = fitness + read(0xEF4C) * EnemiesCountMultiplier

		ui.updateFitness(fitness)
	end
	updateVariables()
	-- return fitness; only ckecking runEnded because we may be showing realtime fitness
	return runEnded and fitness or nil
end


----------------------------------
--          Launch NEAT         --
----------------------------------
ui.initForm(neat)
neat.run(user)
