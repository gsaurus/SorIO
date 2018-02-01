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

	NeatUI.lua
	Public functions:
		ui.updateFitness
		ui.updateInput
		ui.isRealTimeFitnessEnabled
		ui.initForm
]]


local module = {}


local bestFitness = 0

local form
local maxFitnessLabel
local showRealtimeFitnessCheckbox
local showInputCheckbox
local showCustomCheckbox
local previousInput
local showCustomFunction


module.isShowCustomEnabled = function()
	return forms.ischecked(showCustomCheckbox)
end

module.updateFitness = function(fitness, runEnded)
	if runEnded and fitness > bestFitness then
		bestFitness = fitness
		forms.settext(maxFitnessLabel, "Max Fitness: " .. math.floor(bestFitness))
	end
	if forms.ischecked(showRealtimeFitnessCheckbox) then
		local backgroundColor = 0xD0FFFFFF
		local width = client.bufferwidth()
		local height = client.bufferheight()
		gui.drawBox(width - 150, height - 16, width, height, backgroundColor, backgroundColor)
		gui.drawText(width - 150, height - 16, "Fitness: " .. math.floor(fitness), 0xFF000000, 11)
	end
end



local function displayInput(input)
	local backgroundColor = 0xE0FFFFFF
	local screenWidth = client.bufferwidth()
	local screenHeight = client.bufferheight()

	local rows = math.floor(math.sqrt(#input));
	local columns = math.ceil(1.0 * #input / rows);
	local frameWidth = screenWidth / (columns + 1);
	local frameHeight = math.min(screenHeight / (rows + 1), frameWidth * 9 / 16);
	screenHeight = math.min(screenHeight, frameHeight * (rows - 1))
	gui.drawBox(0, 0, screenWidth, screenHeight, backgroundColor, backgroundColor)
	local count = 1
	for y = 0, rows do
		for x = 0, columns do
			if count > #input then
				break
			end
			gui.drawText(x * frameWidth, y * frameHeight, input[count], 0xFF000000, 11)
			count = count + 1
		end
	end
end


module.updateInput = function(input)

	if input == nil then
		if previousInput == nil then
			-- No inputs yet
			return
		end
		input = previousInput
	else
		previousInput = {}
		for k, v in ipairs(input) do
			previousInput[k] = v
		end
	end
	if forms.ischecked(showInputCheckbox) then
		displayInput(input)
	end
	if forms.ischecked(showCustomCheckbox) then
		showCustomFunction(input)
	end
end


local function replayBestRun(neat)
	bestFitness = neat.replayBestRun()
	forms.settext(maxFitnessLabel, "Max Fitness: " .. math.floor(bestFitness))
end


module.initForm = function(neat, showCustomText, customFunction)
	-- Control Panel
	form = forms.newform(200, 150, "Fitness")
	maxFitnessLabel = forms.label(form, "Max Fitness: 0", 5, 5)
	forms.button(
		form, "Replay Best Run",
		function() replayBestRun(neat) end,
		5, 25
	)
	showRealtimeFitnessCheckbox = forms.checkbox(form, "Show Fitness", 5, 50)
	showInputCheckbox = forms.checkbox(form, "Show Input", 5, 75)
	showCustomCheckbox = forms.checkbox(form, showCustomText, 5, 100)
	showCustomFunction = customFunction
end

module.isRealTimeFitnessEnabled = function()
	return forms.ischecked(showRealtimeFitnessCheckbox)
end

module.onExit = function()
	if form ~= nil then
		forms.destroy(form)
	end
end


return module
