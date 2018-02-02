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


local ai_input = true

----------------------------------
--      Game Specific Data      --
----------------------------------

local neat = require("Neat/NeatEvolve")
local ui = require("Neat/NeatUI")

local user = {}

GameState = "sor2.State"

CellType = {
	Goodie = 1,
	Container = 0.5,
	Empty = 0,
	Enemy = -0.3,
	AttackingEnemy = -0.6,
	FlyingEnemy = -0.9,
}

-- how many output values
user.OutputsCount = 3

local MaxEnemies = 6
local MaxItems	 = 6

local InputFrequency = 1

-- Reduce resolution to simplify neuronal activity
local PositionDivider = 16
-- How much character sees ahead
local MatrixRangeX = 6

-- Fitness variables
-- Tell if game clock is counting, so that it ignores cut-scenes
local previousClock
-- Tells if player is moving
local previousPlayerX
local previousPlayerY
-- if there are no enemies, must move
local MaxIdleTime = 60 -- 120
local iddleTimer
-- if there are no enemies, must look for them
local NoEnemiesMaxTime = 600 --600
local noEnemiesTimer
-- if there are enemies, must attack them
local NoAttackMaxTime = 1200 -- 1800
local noAttackTimer
local previousScore -- use score to detect it
-- Global time penalty
local TimePenaltyPerFrame = -0.05
local gameplayTime
-- Health and lifes bonus
local HealthBonusMultiplier = 20
local LifeBonusMultiplier = 2000
local ScoreMultiplier = 13
-- Enemy health and lifes bonus
local EnemyHealthBonusMultiplier = -10
local EnemyLifeBonusMultiplier = -1000
local EnemiesCountMultiplier = 990

local clockToggle


local minDeltaY = 9
local minDeltaXForContainer = 34

-- Training mode
local EnemiesToKill = 99999999 --7 -- 22 -- 1 enemy -- 31 -- 10 enemies


----------------------------------
-- Neural Network Configuration --
----------------------------------


local function clearJoypad()
	if not ai_input then return end
	controller = {
		["P1 A"] = false,
		["P1 B"] = false,
		["P1 C"] = false,
		["P1 X"] = false,
		["P1 Y"] = false,
		["P1 Z"] = false,
		["P1 Up"] = false,
		["P1 Down"] = false,
		["P1 Left"] = false,
		["P1 Right"] = false,
	}
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
	clockToggle = false
	clearJoypad()
end


-- Read information from game's RAM --

local function read(address)
	return mainmemory.read_s16_be(address)
end

local function readByte(address)
	return mainmemory.readbyte(address)
end


local function readDeltaPos(base)
	local dx = read(base + 0x20)
	local dy = read(base + 0x24)
	return dx, dy
end

local function isInvincible(base)
	local status = readByte(base + 0x49)
	return not bit.check(status, 7)
end


local function readEnemyState(base, playerX, playerY)
	local state = read(base)
	if state == 0 then
		return CellType.Empty
	end
	local dx, dy = readDeltaPos(base)
	local isAttacking = read(base + 0x10) >= 0x30 -- Is using an agressive animation
	local inTheAir = read(base + 0x5E) < 0
	-- local isGrabbed = bit.check(state, 3)
	state = CellType.Enemy
	if inTheAir then
		state = CellType.FlyingEnemy
	elseif isAttacking then
		state = CellType.AttackingEnemy
	end
	return state, dx, dy
end


local function readPlayerState(base)
	local state = read(base)
	if state == 0 or isInvincible(base) then
		return -1
	end
	local hasWeapon = read(base + 0x38) ~= 0 -- Weapon
	local animation = read(base + 0x10)
	if animation == 0x8 then
		-- grabbing someone
		return 0.5
	elseif animation == 0xA then
		-- grabbing someone
		return 1
	elseif hasWeapon then
		return -0.5
	elseif animation == 36 then
		-- being thrown
		return -1
	else
		return 0
	end
end

local function readItemState(base, playerX, playerY)
	local state = read(base)
	if state == 0 then
		return CellType.Empty
	end

	local dx, dy = readDeltaPos(base)
	if dx == nil then return 0 end
	local state = CellType.Empty
	local type = read(base + 0x0C) -- Type
	if type >= 0x4C and type <= 0x8A then
		-- It's a container
		state = CellType.Container
	elseif type >= 0x8C and type <= 0x94 then
		-- Goodie!
		state = CellType.Goodie
	end
	return state, dx, dy
end


local function coordinatesToIndex(x)
	return x + MatrixRangeX + 1
end


local closestItemDistance = 0


-- return an array containing input values
user.produceInputFunction = function(forceProduce)
	-- If clock is not counting, no need for input
	local clock = read(0xFC3C)
	if not forceProduce and (clock == previousClock or clock % InputFrequency ~= 0) then
		ui.updateInput()
		return nil
	end
	local playerX, playerY = readDeltaPos(0xEF00)
	local state, x, y
	local result = {}
	-- initialize space matrix
	local maxIndex = 2 * MatrixRangeX + 1
	for i = 1, maxIndex do
		result[i] = 0
	end

	local realPlayerX = read(0xEF20)
	local cameraX = read(0xFC22)
	local cameraY = read(0xFC26)

	local closestType = 0
	local closestX = 0
	local closestY = 0
	local closestDistance = 999999
	local distance

	-- enemies
	for i = 0, MaxEnemies - 1 do
		state, x, y = readEnemyState(0xF100 + i * 0x100)
		-- if i ~= 4 then
		-- 	mainmemory.write_s16_be(0xF100 + i * 0x100, 0)
		-- end
		if state ~= 0 then
			local ex = x + cameraX
			x = x - playerX
			y = y - playerY
			if ex > 0 and ex < 320 then
				distance = math.sqrt(x * x + y * y * 15)
				-- print("closest (enemy): X " .. x .. ", y " .. y .. ", distance " .. distance)
				if distance < closestDistance then
					closestX = x
					closestY = y
					closestDistance = distance
					closestType = state
				end
			end
			if math.abs(y) <= minDeltaY then
				x = math.floor(x / PositionDivider + 0.5)
				if x >= -MatrixRangeX and x <= MatrixRangeX then
					local current = result[coordinatesToIndex(x)]
					if state < current then
						result[coordinatesToIndex(x)] = state
					end
				end
			end
		end
	end
	-- items
	for i = 0, MaxItems - 1 do
		state, x, y = readItemState(0xF700 + i * 0x80)
		if state ~= 0 then
			local ex = x + cameraX
			x = x - playerX
			y = y - playerY
			if ex > 0 and ex < 320 then
				distance = math.sqrt(x * x + y * y * 15)
				--print("closest (item): X " .. x .. ", y " .. y .. ", distance " .. distance)
				if distance < closestDistance then
					closestX = x
					closestY = y
					closestDistance = distance
					closestType = state
				end
			end
			if math.abs(y) <= minDeltaY then
				x = math.floor(x / PositionDivider + 0.5)
				if x >= -MatrixRangeX and x <= MatrixRangeX then
					local current = result[coordinatesToIndex(x)]
					if current == CellType.Empty or state < current then
						if state ~= CellType.Goodie or math.abs(x) <= 1 then
							result[coordinatesToIndex(x)] = state
						end
					end
				end
			end
		end
	end

	-- Used for fitness
	if closestDistance ~= 999999 then
		closestItemDistance = closestDistance
	else
		closestItemDistance = 0
	end

	-- additional information
	-- player state
	result[maxIndex + 1] = readPlayerState(0xEF00)
	-- player facing direction, so he knows how to approach surrounding enemies
	result[maxIndex + 2] = bit.check(readByte(0xEF0F), 0) and 1 or 0

	-- Decide where to go
	-- Camera
	cameraX = math.floor((realPlayerX + cameraX) / 103) - 1 -- -1, 0, 1

	result[maxIndex + 3] = 0 -- horizontal
	result[maxIndex + 4] = 0 -- vertical
	-- print("Final closest: type " .. closestType  .. " X " .. closestX .. ", y " .. closestY .. ", distance " .. closestDistance)
	if closestType ~= 0 then
		if closestY >= minDeltaY then
			result[maxIndex + 4] = -1
		elseif closestY <= -minDeltaY then
			result[maxIndex + 4] = 1
		end
		local done = false
		-- check if stuck on box
		if closestType == CellType.Container then
			-- print("container X: " .. closestX)
			if closestX >= -minDeltaXForContainer and closestX <= minDeltaXForContainer and (closestY < -minDeltaY or closestY > minDeltaY) then
				result[maxIndex + 3] = -1
				done = true
			end
		end
		if not done then
			if closestX > 4 then
				result[maxIndex + 3] = 1
			elseif closestX < 4 then
				result[maxIndex + 3] = -1
			end
		end
	else
		if cameraX < 1 then
			result[maxIndex + 3] = 1
		end
		if cameraY > 0 and cameraY < 255 then
			result[maxIndex + 4] = -1
		end
	end

	-- One extra input for clock toggle...
	result[maxIndex + 5] = clockToggle and 1 or 0
	clockToggle = not clockToggle

	ui.updateInput(result)
	return result
end


-- receive an array containing the output values
user.consumeOutputFunction = function(outputs)
	if not ai_input then return end
	controls = {}
	-- Attack, Jump, A+B
	if outputs[1] > 0.3 then
		controls["P1 B"] = true
		controls["P1 C"] = false
	elseif outputs[1] < -0.3 then
		controls["P1 B"] = false
		controls["P1 C"] = true
	elseif outputs[1] ~= 0 then -- x >= -0.3 && x <= 0.3
		controls["P1 B"] = true
		controls["P1 C"] = true
	end
	-- Left / Right
	if outputs[2] > 0 then
		controls["P1 Right"] = true
	elseif outputs[2] < 0 then
		controls["P1 Left"] = true
	end
	-- Up / Down
	if outputs[3] > 0 then
		controls["P1 Up"] = true
	elseif outputs[3] < 0 then
		controls["P1 Down"] = true
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
	-- First checkpoint: must pick life
	if read(0xFC22) < -30 and read(0xFC22) > -40 and read(0xF700) ~= 0 then
		print("Didn't pick life.")
		return true
	end
	if read(0xFC22) < -320 and read(0xFC22) > -360 and read(0xF780) ~= 0 then
		print("Didn't pick cash bag.")
		return true
	end
	if read(0xEF4C) == 7 and (read(0xEF82) < 3 or read(0xEF96) < 40) then
		print("Scored " .. read(0xEF96) .. ". Must do better than that")
		return true
	end
	if read(0xEF4C) >= EnemiesToKill then
		print("All enemies killed")
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
			print("No enemies timeout")
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
			if read(0xF100 + i * 0x100) ~= 0 then
				fitness = fitness + read(0xF180 + i * 0x100) * EnemyHealthBonusMultiplier
				fitness = fitness + read(0xF182 + i * 0x100) * EnemyLifeBonusMultiplier
			end
		end
		-- KO counter
		fitness = fitness + read(0xEF4C) * EnemiesCountMultiplier

		-- If nothing else, at least get close to something
		fitness = fitness - closestItemDistance

		ui.updateFitness(fitness, runEnded)
	end
	updateVariables()
	-- return fitness; only ckecking runEnded because we may be showing realtime fitness
	return runEnded and fitness or nil
end


-- Redefine UI display method
local MapX = 160
local MapY = 106
function showMap(inputs)
	local inputsCount = #inputs + 1
	local backgroundColor = 0xE0FFFFFF
	local screenWidth = client.bufferwidth()
	local screenHeight = client.bufferheight()
	local text = "-"
	local color
	gui.drawBox(0, 0, screenWidth, screenHeight * 0.5, backgroundColor, backgroundColor)

	local genome = neat.getCurrentGenome()
	local network = genome.network
	local cells = {}
	local cell = {}
	local matrixWidth = 2 * MatrixRangeX + 1
	local maxIndex = matrixWidth
	-- Player
	cell = {}
	cell.x = MapX
	cell.y = MapY
	cell.value = network.neurons[maxIndex + 1].value
	cell.color = cell.value * 0x55000000 + 0x00FF00FF
	cells[maxIndex + 1] = cell
	-- Player direction
	cell = {}
	cell.x = 88
	cell.y = 10
	cell.value = network.neurons[maxIndex + 2].value
	cells[maxIndex + 2] = cell
	text = cell.value > 0 and "Facing  ->" or "Facing <-"
	cell.color = cell.value > 0 and 0xFF00AAFF or 0xFFAA00FF
	gui.drawText(5, cell.y - 8, text, 0xFF000000, 9)
	-- Horizontal
	cell = {}
	cell.x = 88
	cell.y = 30
	cell.value = network.neurons[maxIndex + 3].value
	cells[maxIndex + 3] = cell
	if cell.value == 0 then
		text = "Aiming  -"
		cell.color = 0x00000000
	else
		text = cell.value > 0 and "Aiming  ->" or "Aiming <-"
		cell.color = cell.value > 0 and 0xFF00AAFF or 0xFFAA00FF
	end
	gui.drawText(5, cell.y - 8, text, 0xFF000000, 9)
	-- Vertical
	cell = {}
	cell.x = 88
	cell.y = 50
	cell.value = network.neurons[maxIndex + 4].value
	cells[maxIndex + 4] = cell
	if cell.value == 0 then
		text = "Aiming  -"
		cell.color = 0x00000000
	else
		text = cell.value > 0 and "Aiming  ^" or "Aiming  v"
		cell.color = cell.value > 0 and 0xFF00AAFF or 0xFFAA00FF
	end
	gui.drawText(5, cell.y - 8, text, 0xFF000000, 9)
	-- Clock
	cell = {}
	cell.x = 88
	cell.y = 70
	cell.value = network.neurons[maxIndex + 5].value
	cells[maxIndex + 5] = cell
	cell.color = cell.value > 0 and 0xFF00AAFF or 0xFFAA00FF
	text = "Clock" -- .. cell.value
	gui.drawText(5, cell.y - 8, text, 0xFF000000, 9)

	local i = 1
	-- Enemies and items
	for dx=-MatrixRangeX,MatrixRangeX do
		cell = {}
		cell.x = MapX+5*dx
		cell.y = MapY
		cell.value = network.neurons[i].value
		cells[i] = cell
		i = i + 1
	end
	local biasCell = {}
	biasCell.x = 88
	biasCell.y = 90
	biasCell.value = network.neurons[inputsCount].value
	cells[inputsCount] = biasCell
	gui.drawText(5, biasCell.y - 8, "Bias", 0xFF000000, 9)

	local MaxNodes = neat.getSettings().MaxNodes
	for o = 1, user.OutputsCount do
		cell = {}
		cell.x = 240
		cell.y = 8 + 24 * o
		cell.value = network.neurons[MaxNodes + o].value
		cells[MaxNodes+o] = cell
		text = "-"
		if cell.value == 0 then
			color = 0xFF0000FF
		else
			color = 0xFF008800
			if o == 1 then
				if cell.value > 0.3 then
					text = "Attack"
				elseif cell.value < -0.3 then
					text = "Jump"
				else
					text = "Attack + Jump"
				end
			elseif o == 2 then
				if cell.value > 0 then
					text = "Right"
				elseif cell.value < 0 then
					text = "Left"
				end
			elseif o == 3 then
				if cell.value > 0 then
					text = "Up"
				elseif cell.value < 0 then
					text = "Down"
				end
			end
		end
		gui.drawText(244, 24*o, text, color, 9)
	end

	for n,neuron in pairs(network.neurons) do
		cell = {}
		if n > inputsCount and n <= MaxNodes then
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
				if gene.into > inputsCount and gene.into <= MaxNodes then
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
				if gene.out > inputsCount and gene.out <= MaxNodes then
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

	gui.drawBox(MapX-MatrixRangeX*5-3,MapY-3,MapX+MatrixRangeX*5+2,MapY+2,0xFF000000, 0x80808080)
	for n,cell in pairs(cells) do
		if n > maxIndex or cell.value ~= 0 then
			color = cell.color
			local opacity = 0xFF000000
			if cell.value == 0 then
				opacity = 0x50000000
			end
			if color == nil then
				color = 0x00000000
				if cell.value == CellType.Goodie then color = 0xFF00FF00 end
				if cell.value == CellType.Container then color = 0xFFAAFF00 end
				if cell.value == CellType.Enemy then color = 0xFFAA6600 end
				if cell.value == CellType.AttackingEnemy then color = 0xFFFF0000 end
				if cell.value == CellType.FlyingEnemy then color = 0xFFAA0088 end
			end
			gui.drawBox(cell.x-2,cell.y-2,cell.x+2,cell.y+2,opacity,color)
		end
	end
	for _,gene in pairs(genome.genes) do
		if gene.enabled then
			local c1 = cells[gene.into]
			local c2 = cells[gene.out]
			if c1 == nil or c2 == nil then break end
			local opacity = 0xF8000000
			if c1.value == 0 then
				opacity = 0x30000000
			end

			color = 0x80-math.floor(math.abs(neat.sigmoid(gene.weight))*0x80)
			if gene.weight > 0 then
				color = opacity + 0xA000 + 0x10000*color
			else
				color = opacity + 0xA00000 + 0x100*color
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
