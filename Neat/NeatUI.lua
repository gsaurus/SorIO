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

module.PlotFileName = "neat.plot"

local bestFitness = 0

local form
local maxFitnessLabel
local showRealtimeFitnessCheckbox
local showInputCheckbox
local showPlotCheckbox
local showCustomCheckbox
local previousInput
local showCustomFunction

local plotFile
local plotDots = {}






local function openPlotFile()
	plotDots = {}
	local file = io.open(module.PlotFileName, "r")
	if file ~= nil then
		local fitness
		repeat
			fitness = file:read("*number")
			if fitness ~= nil then
				plotDots[#plotDots + 1] = fitness
			end
		until fitness == nil
		file:close()
	end

	plotFile = io.open(module.PlotFileName, "a")
end

local function backupPlot()
	if plotFile ~= nil then plotFile:close() end
	local infile = io.open(module.PlotFileName, "r")
	if infile ~= nil then
		local instr = infile:read("*a")
		infile:close()
		local outfile = io.open("backup.plot", "w")
		outfile:write(instr)
		outfile:close()
	end
	plotFile = io.open(module.PlotFileName, "a")
end

local function appendToPlot(fitness)
	fitness = math.floor(fitness)
	if plotDots ~= nil then
		plotDots[#plotDots + 1] = fitness
	end
	if plotFile ~= nil then
		plotFile:write(fitness .. "\n")
	end
end

local function displayPlot()
	local backgroundColor = 0xE0FFFFFF
	local width = client.bufferwidth()
	local height = client.bufferheight()
	gui.drawBox(0, 0, width, height, backgroundColor, backgroundColor)
	local final_dots = plotDots

	if #plotDots > width then
		-- Need to shrink graph
		final_dots = {}
		local fraction = width / #plotDots
		local index = 1
		for i = 1, #plotDots do
			local intIndex = math.floor(index)
			if #final_dots < intIndex or final_dots[intIndex] < plotDots[i] then
				final_dots[intIndex] = plotDots[i]
			end
			index = index + fraction
		end
	end
	wrote = true

	-- get best fitness to scale the graph
	local bestFitness = 0
	for i = 1, #plotDots do
		if plotDots[i] > bestFitness then
			bestFitness = plotDots[i]
		end
	end
	-- No fitness, no plot
	if bestFitness == 0 or #final_dots == 0 then return end

	-- Draw plot
	local x = 1
	local deltaX = width / (#final_dots - 1)
	local color = 0xFF000000
	local heightFraction = height / bestFitness
	for i = 2, #final_dots do
		gui.drawLine(x, height - final_dots[i - 1] * heightFraction, x + deltaX, height - final_dots[i] * heightFraction, color)
		x = x + deltaX
	end
end




module.isShowCustomEnabled = function()
	return forms.ischecked(showCustomCheckbox)
end

module.updateFitness = function(fitness, runEnded)
	if runEnded then
		if fitness > bestFitness then
			bestFitness = fitness
			forms.settext(maxFitnessLabel, "Max Fitness: " .. math.floor(bestFitness))
			-- good time to backup plot
			-- backupPlot()
		end
		appendToPlot(fitness)
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
	if forms.ischecked(showPlotCheckbox) then
		displayPlot()
	end
	if forms.ischecked(showCustomCheckbox) then
		showCustomFunction(input)
	end
end


local function replayBestRun(neat)
	neat.replayBestRun()
	forms.settext(maxFitnessLabel, "Max Fitness: " .. math.floor(bestFitness))
end


module.initForm = function(neat, showCustomText, customFunction)
	-- Control Panel
	form = forms.newform(200, 180, "Fitness")
	maxFitnessLabel = forms.label(form, "Max Fitness: 0", 5, 5)
	forms.button(
		form, "Replay Best Run",
		function() replayBestRun(neat) end,
		5, 25
	)
	forms.button(
		form, "Save",
		neat.save,
		100, 25
	)
	showRealtimeFitnessCheckbox = forms.checkbox(form, "Show Fitness", 5, 50)
	showInputCheckbox = forms.checkbox(form, "Show Input", 5, 75)
	showCustomCheckbox = forms.checkbox(form, showCustomText, 5, 100)
	showPlotCheckbox = forms.checkbox(form, "Show Plot", 5, 125)
	showCustomFunction = customFunction

	-- Read plot
	openPlotFile()
end

module.isRealTimeFitnessEnabled = function()
	return forms.ischecked(showRealtimeFitnessCheckbox)
end

module.onExit = function()
	if form ~= nil then
		forms.destroy(form)
	end
	if plotFile ~= nil then
		plotFile:close()
	end
end


return module
