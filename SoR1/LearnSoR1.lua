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

GameState = "sor1.State"

ButtonNames = {
	"A",
	"B",
	"C",
	"Up",
	"Down",
	"Left",
	"Right",
}

CellType = {
	Empty = 0,
	Goodie = 1,
	Enemy = 2,
	AttackingEnemy = 3,
	Container = 4,
	Obstacle = 5,
	Count = 5
}

-- how many output values
user.OutputsCount = #ButtonNames

local MaxObjects = 30

local InputFrequency = 2

-- Reduce resolution to simplify neuronal activity
local PositionDivider = 8
-- How much character sees ahead
local MatrixRangeX = 10
local MatrixRangeY = 5

-- Fitness variables
-- Tell if game clock is counting, so that it ignores cut-scenes
-- local previousClock
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
local NoAttackMaxTime = 1800
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

local clockToggle
local clock

local totalEnemies
local previousEnemies


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
	clock = 0
	previousPlayerX = -1
	previousPlayerY = -1
	iddleTimer = 0
	noEnemiesTimer = 0
	noAttackTimer = 0
	previousScore = 0
	gameplayTime = 0
	clockToggle = false
	totalEnemies = 0
	previousEnemies = {}
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
	local dx = read(base + 0x10)
	local dy = read(base + 0x14)
	dx = math.floor(dx / PositionDivider) - playerX
	dy = math.floor(dy / PositionDivider) - playerY
	return dx, dy
end

local function isInvincible(base)
	local status = readByte(base + 0x58)
	return not bit.check(status, 1)
end


local function readObjectState(base, playerX, playerY)
	local type = readByte(base)
	if type == 0 then
		return CellType.Empty
	end
	local dx, dy = readDeltaPos(base, playerX, playerY)
	if type >= 0x17 and type <= 0x1f or type == 0x41 then
		-- It's a container
		state = CellType.Container
	elseif type == 0x3F or type == 0x40 or type == 0x4F or type == 0x4B or type == 0x47 then
		-- Goodie!
		state = CellType.Goodie
	elseif type < 0x20 or (type > 0x2A and type < 54) or type > 58 then
		-- ignore others
		return CellType.Empty
	end
	state = CellType.Enemy
	local isAttacking = bit.check(read(base + 0x08), 4)
	if isAttacking then
		state = CellType.AttackingEnemy
	end
	return state, dx, dy
end


local function readPlayerState(base)
	local state = read(base)
	if state == 0 or isInvincible(base) then
		return 0
	end
	local hasWeapon = readByte(base + 0x60) ~= 0 -- Weapon
	local grabbing = read(base + 0x4C) ~= 0
	if read(base + 0x56) ~= 0 then
		-- being thrown
		return 4
	elseif grabbing then
		-- grabbing someone
		return 3
	elseif hasWeapon then
		return 2
	else
		return 1
	end
end



local function coordinatesToIndex(x, y)
	local row = y + MatrixRangeY
	local column = x + MatrixRangeX + 1
	local width = 2 * MatrixRangeX + 1
	return row * width + column
end


-- return an array containing input values
user.produceInputFunction = function(forceProduce)
	-- If clock is not counting, no need for input
	-- local clock = read(0xFB00)
	if not forceProduce and clock % InputFrequency ~= 0 then
		ui.updateInput()
		return nil
	end
	local playerX, playerY = readDeltaPos(0xB800, 0, 0)
	local state, x, y
	local result = {}
	-- initialize space matrix
	local matrixWidth = 2 * MatrixRangeX + 1
	local matrixHeight = 2 * MatrixRangeY + 1
	local maxIndex = matrixWidth * matrixHeight
	for i = 1, maxIndex do
		result[i] = 0
	end
	-- enemies and objects
	for i = 0, MaxObjects - 1 do
		state, x, y = readObjectState(0xB900 + i * 0x80, playerX, playerY)
		if state ~= 0 then
			if x < -MatrixRangeX then x = -MatrixRangeX end
			if x > MatrixRangeX then x = MatrixRangeX end
			if y < -MatrixRangeY then y = -MatrixRangeY end
			if y > MatrixRangeY then y = MatrixRangeY end
			local current = result[coordinatesToIndex(x, y)]
			if state > current then
				result[coordinatesToIndex(x, y)] = state
			end
		end
	end

	-- additional information
	-- player state
	result[maxIndex + 1] = readPlayerState(0xB800)
	-- Camera
	local realPlayerX = read(0xFB10)
	local cameraX = read(0xE002)
	cameraX = math.floor((realPlayerX + cameraX) / 103) - 1
	if cameraX <= 0 then cameraX = 1 elseif cameraX == 1 then cameraX = 0 end
	result[maxIndex + 2] = cameraX

	-- Force camera Y to be used as a clock also
	result[maxIndex + 3] = clockToggle and 1 or 0
	clockToggle = not clockToggle

	ui.updateInput(result)
	return result
end


-- receive an array containing the output values
user.consumeOutputFunction = function(outputs)
	controls = {}
	local firstButton = 1
	for i = firstButton, user.OutputsCount do
		local button = "P1 " .. ButtonNames[i]
		controls[button] = outputs[i] > 0
	end
	joypad.set(controls)
end


local function isEnemy(type)
	return (type >= 0x20 and type <= 0x2A) or (type >= 54 and type <= 58)
end

local function hasActiveEnemies()
	for i = 0, MaxObjects - 1 do
		local type = readByte(0xB900 + i * 0x80)
		if isEnemy(type) then
			return true
		end
	end
	return false
end

local function isPlayerMoving()
	local playerX = read(0xFB10)	-- X
	local playerY = read(0xFB14)	-- Y
	return playerX ~= previousPlayerX or playerY ~= previousPlayerY
end

local function hasScoreIncreased()
	return read(0xFF08)	> previousScore
end

local function checkEndCondition()
	-- End if game-over (lives < 0 or no longer in game mode)
	if readByte(0xFF20) < 0 or readByte(0xFF00) > 0x1A then
		print("Game Over: lives " .. read(0xFF20) .. " and state is " .. readByte(0xFF00))
		return true
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
	previousPlayerX = read(0xFB10)	-- X
	previousPlayerY = read(0xFB14)	-- Y
	previousScore = read(0xFF08)	-- Score
	clock = clock + 1
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
		fitness = fitness + read(0xFF08) * ScoreMultiplier
		-- Global time penalty
		fitness = fitness + gameplayTime * TimePenaltyPerFrame
		-- Health and lifes bonus
		fitness = fitness + read(0xB832) * HealthBonusMultiplier
		fitness = fitness + readByte(0xFF20) * LifeBonusMultiplier
		-- Enemy health and lifes bonus
		for i = 0, MaxObjects - 1 do
			local enemyType = read(0xB900 + i * 0x80)
			if isEnemy(enemyType) then
				fitness = fitness + read(0xB932 + i * 0x80) * EnemyHealthBonusMultiplier
				if previousEnemies[i] == false then
					previousEnemies[i] = true
					totalEnemies = totalEnemies + 1
				end
			else
				previousEnemies[i] = false
			end
		end
		-- KO counter
		fitness = fitness + totalEnemies * EnemiesCountMultiplier

		ui.updateFitness(fitness)
	end
	updateVariables()
	-- return fitness; only ckecking runEnded because we may be showing realtime fitness
	return runEnded and fitness or nil
end


-- Redefine UI display method
function showMap(inputs)
	local genome = neat.getCurrentGenome()
	local network = genome.network
	local cells = {}
	local cell = {}
	-- Player
	cell = {}
	cell.x = 50
	cell.y = 70
	local matrixWidth = 2 * MatrixRangeX + 1
	local matrixHeight = 2 * MatrixRangeY + 1
	local maxIndex = matrixWidth * matrixHeight
	cell.value = network.neurons[maxIndex + 1].value
	cell.color = cell.value * 0x55000000 + 0x00FF00FF
	cells[-999999999] = cell
	local i = 1
	-- Enemies and items
	for dy=-MatrixRangeY,MatrixRangeY do
		for dx=-MatrixRangeX,MatrixRangeX do
			cell = {}
			cell.x = 50+5*dx
			cell.y = 70+5*dy
			cell.value = network.neurons[i].value
			cells[i] = cell
			i = i + 1
		end
	end
	local biasCell = {}
	biasCell.x = 80
	biasCell.y = 110
	biasCell.value = network.neurons[#inputs].value
	cells[#inputs] = biasCell

	local MaxNodes = neat.getSettings().MaxNodes
	for o = 1, user.OutputsCount do
		cell = {}
		cell.x = 220
		cell.y = 30 + 8 * o
		cell.value = network.neurons[MaxNodes + o].value
		cells[MaxNodes+o] = cell
		local color
		if cell.value > 0 then
			color = 0xFF0000FF
		else
			color = 0xFFFFFFFF
		end
		gui.drawText(223, 24+8*o, ButtonNames[o], color, 9)
	end

	for n,neuron in pairs(network.neurons) do
		cell = {}
		if n > #inputs and n <= MaxNodes then
			cell.x = 140
			cell.y = 40
			cell.value = neuron.value
			cells[n] = cell
		end
	end

	for n=1,4 do
		for _,gene in pairs(genome.genes) do
			if gene.enabled then
				local c1 = cells[gene.into]
				local c2 = cells[gene.out]
				if c1 == nil or c2 == nil then break end
				if gene.into > #inputs and gene.into <= MaxNodes then
					c1.x = 0.75*c1.x + 0.25*c2.x
					if c1.x >= c2.x then
						c1.x = c1.x - 40
					end
					if c1.x < 90 then
						c1.x = 90
					end

					if c1.x > 220 then
						c1.x = 220
					end
					c1.y = 0.75*c1.y + 0.25*c2.y

				end
				if gene.out > #inputs and gene.out <= MaxNodes then
					c2.x = 0.25*c1.x + 0.75*c2.x
					if c1.x >= c2.x then
						c2.x = c2.x + 40
					end
					if c2.x < 90 then
						c2.x = 90
					end
					if c2.x > 220 then
						c2.x = 220
					end
					c2.y = 0.25*c1.y + 0.75*c2.y
				end
			end
		end
	end

	gui.drawBox(50-MatrixRangeX*5-3,70-MatrixRangeY*5-3,50+MatrixRangeX*5+2,70+MatrixRangeY*5+2,0xFF000000, 0x80808080)
	for n,cell in pairs(cells) do
		if n > #inputs or cell.value ~= 0 then
			local color = cell.color
			if color == nil then
				local color = math.floor((cell.value / CellType.Count) * 256)
				if color > 255 then color = 255 end
				if color < 0 then color = 0 end
				local opacity = 0xFF000000
				if cell.value == 0 then
					opacity = 0x50000000
				end
				color = opacity + color*0x10000 + color*0x100 + color
				gui.drawBox(cell.x-2,cell.y-2,cell.x+2,cell.y+2,opacity,color)
			else
				gui.drawBox(cell.x-2,cell.y-2,cell.x+2,cell.y+2,0xFFFFFFFF, color)
			end

		end
	end
	for _,gene in pairs(genome.genes) do
		if gene.enabled then
			local c1 = cells[gene.into]
			local c2 = cells[gene.out]
			if c1 == nil or c2 == nil then break end
			local opacity = 0xA0000000
			if c1.value == 0 then
				opacity = 0x20000000
			end

			local color = 0x80-math.floor(math.abs(neat.sigmoid(gene.weight))*0x80)
			if gene.weight > 0 then
				color = opacity + 0x8000 + 0x10000*color
			else
				color = opacity + 0x800000 + 0x100*color
			end
			gui.drawLine(c1.x+1, c1.y, c2.x-3, c2.y, color)
		end
	end
end


function onExit()
	neat.onExit()
	ui.onExit()
end
event.onexit(onExit)

----------------------------------
--          Launch NEAT         --
----------------------------------
ui.initForm(neat, "Show Map", showMap)
neat.run(user)
