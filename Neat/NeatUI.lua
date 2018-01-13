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
local showInputCheckbox
local showRealtimeFitnessCheckbox
local previousInput


module.updateFitness = function(fitness)
	if fitness > bestFitness then
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



module.displayInput = function(input)
	local backgroundColor = 0xE0FFFFFF
	local screenWidth = client.bufferwidth()
	local screenHeight = client.bufferheight()
	gui.drawBox(0, 0, screenWidth, screenHeight, backgroundColor, backgroundColor)

	local rows = math.floor(math.sqrt(#input));
	local columns = math.ceil(1.0 * #input / rows);
	local frameWidth = screenWidth / (columns + 1);
	local frameHeight = math.min(screenHeight / (rows + 1), frameWidth * 9 / 16);

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
	if forms.ischecked(showInputCheckbox) then
		if input == nil then
			if previousInput == nil then
				-- No inputs yet
				return
			end
			input = previousInput
		end
		module.displayInput(input)
		previousInput = input
	end
end


local function replayBestRun(neat)
	bestFitness = neat.replayBestRun()
	forms.settext(maxFitnessLabel, "Max Fitness: " .. math.floor(bestFitness))
end


module.initForm = function(neat)
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
end

module.isRealTimeFitnessEnabled = function()
	return forms.ischecked(showRealtimeFitnessCheckbox)
end

local function onExit()
	if form ~= nil then
		forms.destroy(form)
	end
end
event.onexit(onExit)


return module
