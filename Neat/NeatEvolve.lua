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

	NeatEvolve.lua
	Public functions:
		neat.run
		neat.replayBestRun
		neat.getCurrentGenome
]]

local module = {}


-- To be configured by the user
local user = {}
---------------------------------
--      Mandatory Options      --
---------------------------------
-- pool file name
user.SaveLoadFile = "neat.pool"
-- how many input values
user.InputsCount = -1
-- how many output values
user.OutputsCount = -1
-- used when starting a new run
user.onInitializeFunction = function() end
-- return an array containing input values
-- or nil, to indicate no need to process input right now
user.produceInputFunction = function() return {1, 5, 3} end
-- receive an array containing the output values
user.consumeOutputFunction = function(outputs) end
-- return nil to indicate that this run didn't end yet
-- fitness value otherwise
user.checkFinalFitnessFunction = function() return 72 end
----------------------------------
--       Optional Options       --
----------------------------------
user.Population = 300
user.DeltaDisjoint = 2.0
user.DeltaWeights = 0.4
user.DeltaThreshold = 1.0
user.StaleSpecies = 15
user.MutateConnectionsChance = 0.25
user.PerturbChance = 0.90
user.CrossoverChance = 0.75
user.LinkMutationChance = 2.0
user.NodeMutationChance = 0.50
user.BiasMutationChance = 0.40
user.StepSize = 0.1
user.DisableMutationChance = 0.4
user.EnableMutationChance = 0.2
user.MaxNodes = 1000000
user.SaveFrequency = 20




-- Our network pool
local pool = nil
local outputs
local totalRuns = 0
local markedToSave = false;




----------------------------------
----------------------------------
----------------------------------



module.sigmoid = function(x)
	return 2/(1+math.exp(-4.9*x))-1
end

local function newInnovation()
	pool.innovation = pool.innovation + 1
	return pool.innovation
end

local function clearPool()
	pool = {}
	pool.species = {}
	pool.generation = 0
	pool.innovation = user.OutputsCount
	pool.currentSpecies = 1
	pool.currentGenome = 1
	pool.maxFitness = 0
end

local function newSpecies()
	local species = {}
	species.topFitness = 0
	species.staleness = 0
	species.genomes = {}
	species.averageFitness = 0

	return species
end

local function newGenome()
	local genome = {}
	genome.genes = {}
	genome.fitness = 0
	genome.adjustedFitness = 0
	genome.network = {}
	genome.maxneuron = 0
	genome.globalRank = 0
	genome.mutationRates = {}
	local mRates = genome.mutationRates
	mRates.connections = user.MutateConnectionsChance
	mRates.link = user.LinkMutationChance
	mRates.bias = user.BiasMutationChance
	mRates.node = user.NodeMutationChance
	mRates.enable = user.EnableMutationChance
	mRates.disable = user.DisableMutationChance
	mRates.step = user.StepSize

	return genome
end


local function newGene()
	local gene = {}
	gene.into = 0
	gene.out = 0
	gene.weight = 0.0
	gene.enabled = true
	gene.innovation = 0

	return gene
end


local function copyGene(gene)
	local gene2 = newGene()
	gene2.into = gene.into
	gene2.out = gene.out
	gene2.weight = gene.weight
	gene2.enabled = gene.enabled
	gene2.innovation = gene.innovation

	return gene2
end

local function copyGenome(genome)
	local genome2 = newGenome()
	for g=1,#genome.genes do
		table.insert(genome2.genes, copyGene(genome.genes[g]))
	end
	genome2.maxneuron = genome.maxneuron
	local mRates1 = genome.mutationRates
	local mRates2 = genome2.mutationRates
	mRates2.connections = mRates1.connections
	mRates2.link = mRates1.link
	mRates2.bias = mRates1.bias
	mRates2.node = mRates1.node
	mRates2.enable = mRates1.enable
	mRates2.disable = mRates1.disable

	return genome2
end


local function newNeuron()
	local neuron = {}
	neuron.incoming = {}
	neuron.value = 0.0

	return neuron
end

local function generateNetwork(genome)
	local network = {}
	network.neurons = {}

	for i = 1, user.InputsCount do
		network.neurons[i] = newNeuron()
	end

	for o = 1, user.OutputsCount do
		network.neurons[user.MaxNodes+o] = newNeuron()
	end

	table.sort(genome.genes, function (a,b)
		return (a.out < b.out)
	end)
	for i=1,#genome.genes do
		local gene = genome.genes[i]
		if gene.enabled then
			if network.neurons[gene.out] == nil then
				network.neurons[gene.out] = newNeuron()
			end
			local neuron = network.neurons[gene.out]
			table.insert(neuron.incoming, gene)
			if network.neurons[gene.into] == nil then
				network.neurons[gene.into] = newNeuron()
			end
		end
	end

	genome.network = network
end

function evaluateNetwork(network, inputs)
	table.insert(inputs, 1)
	if #inputs ~= user.InputsCount then
		console.writeline("Incorrect number of neural network inputs: got " .. (#inputs - 1) .. ", expected " .. (user.InputsCount - 1))
		return {}
	end

	for i=1, user.InputsCount do
		network.neurons[i].value = inputs[i]
	end

	for _,neuron in pairs(network.neurons) do
		local sum = 0
		for j = 1,#neuron.incoming do
			local incoming = neuron.incoming[j]
			local other = network.neurons[incoming.into]
			sum = sum + incoming.weight * other.value
		end

		if #neuron.incoming > 0 then
			neuron.value = module.sigmoid(sum)
		end
	end

	local outputs = {}
	for o = 1, user.OutputsCount do
		outputs[o] = network.neurons[user.MaxNodes+o].value
	end

	return outputs
end

local function crossover(g1, g2)
	-- Make sure g1 is the higher fitness genome
	if g2.fitness > g1.fitness then
		tempg = g1
		g1 = g2
		g2 = tempg
	end

	local child = newGenome()

	local innovations2 = {}
	for i=1,#g2.genes do
		local gene = g2.genes[i]
		innovations2[gene.innovation] = gene
	end

	for i=1,#g1.genes do
		local gene1 = g1.genes[i]
		local gene2 = innovations2[gene1.innovation]
		if gene2 ~= nil and math.random(2) == 1 and gene2.enabled then
			table.insert(child.genes, copyGene(gene2))
		else
			table.insert(child.genes, copyGene(gene1))
		end
	end

	child.maxneuron = math.max(g1.maxneuron,g2.maxneuron)

	for mutation,rate in pairs(g1.mutationRates) do
		child.mutationRates[mutation] = rate
	end

	return child
end

local function randomNeuron(genes, nonInput)
	local neurons = {}
	if not nonInput then
		for i = 1, user.InputsCount do
			neurons[i] = true
		end
	end
	for o = 1, user.OutputsCount do
		neurons[user.MaxNodes+o] = true
	end
	for i = 1, #genes do
		if (not nonInput) or genes[i].into > user.InputsCount then
			neurons[genes[i].into] = true
		end
		if (not nonInput) or genes[i].out > user.InputsCount then
			neurons[genes[i].out] = true
		end
	end

	local count = 0
	for _,_ in pairs(neurons) do
		count = count + 1
	end
	local n = math.random(1, count)

	for k,v in pairs(neurons) do
		n = n-1
		if n == 0 then
			return k
		end
	end

	return 0
end

local function containsLink(genes, link)
	for i=1,#genes do
		local gene = genes[i]
		if gene.into == link.into and gene.out == link.out then
			return true
		end
	end
end

local function pointMutate(genome)
	local step = genome.mutationRates.step

	for i=1,#genome.genes do
		local gene = genome.genes[i]
		if math.random() < user.PerturbChance then
			gene.weight = gene.weight + math.random() * step*2 - step
		else
			gene.weight = math.random()*4-2
		end
	end
end

local function linkMutate(genome, forceBias)
	local neuron1 = randomNeuron(genome.genes, false)
	local neuron2 = randomNeuron(genome.genes, true)

	local newLink = newGene()
	if neuron1 <= user.InputsCount and neuron2 <= user.InputsCount then
		--Both input nodes
		return
	end
	if neuron2 <= user.InputsCount then
		-- Swap output and input
		local temp = neuron1
		neuron1 = neuron2
		neuron2 = temp
	end

	newLink.into = neuron1
	newLink.out = neuron2
	if forceBias then
		newLink.into = user.InputsCount
	end

	if containsLink(genome.genes, newLink) then
		return
	end
	newLink.innovation = newInnovation()
	newLink.weight = math.random()*4-2

	table.insert(genome.genes, newLink)
end

local function nodeMutate(genome)
	if #genome.genes == 0 then
		return
	end

	genome.maxneuron = genome.maxneuron + 1

	local gene = genome.genes[math.random(1,#genome.genes)]
	if not gene.enabled then
		return
	end
	gene.enabled = false

	local gene1 = copyGene(gene)
	gene1.out = genome.maxneuron
	gene1.weight = 1.0
	gene1.innovation = newInnovation()
	gene1.enabled = true
	table.insert(genome.genes, gene1)

	local gene2 = copyGene(gene)
	gene2.into = genome.maxneuron
	gene2.innovation = newInnovation()
	gene2.enabled = true
	table.insert(genome.genes, gene2)
end

local function enableDisableMutate(genome, enable)
	local candidates = {}
	for _,gene in pairs(genome.genes) do
		if gene.enabled == not enable then
			table.insert(candidates, gene)
		end
	end

	if #candidates == 0 then
		return
	end

	local gene = candidates[math.random(1,#candidates)]
	gene.enabled = not gene.enabled
end

local function mutate(genome)
	for mutation,rate in pairs(genome.mutationRates) do
		if math.random(1,2) == 1 then
			genome.mutationRates[mutation] = 0.95*rate
		else
			genome.mutationRates[mutation] = 1.05263*rate
		end
	end

	if math.random() < genome.mutationRates.connections then
		pointMutate(genome)
	end

	local p = genome.mutationRates.link
	while p > 0 do
		if math.random() < p then
			linkMutate(genome, false)
		end
		p = p - 1
	end

	p = genome.mutationRates.bias
	while p > 0 do
		if math.random() < p then
			linkMutate(genome, true)
		end
		p = p - 1
	end

	p = genome.mutationRates.node
	while p > 0 do
		if math.random() < p then
			nodeMutate(genome)
		end
		p = p - 1
	end

	p = genome.mutationRates.enable
	while p > 0 do
		if math.random() < p then
			enableDisableMutate(genome, true)
		end
		p = p - 1
	end

	p = genome.mutationRates.disable
	while p > 0 do
		if math.random() < p then
			enableDisableMutate(genome, false)
		end
		p = p - 1
	end
end


local function basicGenome()
	local genome = newGenome()
	local innovation = 1

	genome.maxneuron = user.InputsCount
	mutate(genome)

	return genome
end


local function disjoint(genes1, genes2)
	local i1 = {}
	for i = 1,#genes1 do
		local gene = genes1[i]
		i1[gene.innovation] = true
	end

	local i2 = {}
	for i = 1,#genes2 do
		local gene = genes2[i]
		i2[gene.innovation] = true
	end

	local disjointGenes = 0
	for i = 1,#genes1 do
		local gene = genes1[i]
		if not i2[gene.innovation] then
			disjointGenes = disjointGenes+1
		end
	end

	for i = 1,#genes2 do
		local gene = genes2[i]
		if not i1[gene.innovation] then
			disjointGenes = disjointGenes+1
		end
	end

	local n = math.max(#genes1, #genes2)

	return disjointGenes / n
end

local function weights(genes1, genes2)
	local i2 = {}
	for i = 1,#genes2 do
		local gene = genes2[i]
		i2[gene.innovation] = gene
	end

	local sum = 0
	local coincident = 0
	for i = 1,#genes1 do
		local gene = genes1[i]
		if i2[gene.innovation] ~= nil then
			local gene2 = i2[gene.innovation]
			sum = sum + math.abs(gene.weight - gene2.weight)
			coincident = coincident + 1
		end
	end

	return sum / coincident
end

local function sameSpecies(genome1, genome2)
	local dd = user.DeltaDisjoint*disjoint(genome1.genes, genome2.genes)
	local dw = user.DeltaWeights*weights(genome1.genes, genome2.genes)
	return dd + dw < user.DeltaThreshold
end

local function rankGlobally()
	local global = {}
	for s = 1,#pool.species do
		local species = pool.species[s]
		for g = 1,#species.genomes do
			table.insert(global, species.genomes[g])
		end
	end
	table.sort(global, function (a,b)
		return (a.fitness < b.fitness)
	end)

	for g=1,#global do
		global[g].globalRank = g
	end
end

local function calculateAverageFitness(species)
	local total = 0

	for g=1,#species.genomes do
		local genome = species.genomes[g]
		total = total + genome.globalRank
	end

	species.averageFitness = total / #species.genomes
end

local function totalAverageFitness()
	local total = 0
	for s = 1,#pool.species do
		local species = pool.species[s]
		total = total + species.averageFitness
	end

	return total
end

local function cullSpecies(cutToOne)
	for s = 1,#pool.species do
		local species = pool.species[s]

		table.sort(species.genomes, function (a,b)
			return (a.fitness > b.fitness)
		end)

		local remaining = math.ceil(#species.genomes/2)
		if cutToOne then
			remaining = 1
		end
		while #species.genomes > remaining do
			table.remove(species.genomes)
		end
	end
end

local function breedChild(species)
	local child = {}
	if math.random() < user.CrossoverChance then
		g1 = species.genomes[math.random(1, #species.genomes)]
		g2 = species.genomes[math.random(1, #species.genomes)]
		child = crossover(g1, g2)
	else
		g = species.genomes[math.random(1, #species.genomes)]
		child = copyGenome(g)
	end

	mutate(child)

	return child
end

local function removeStaleSpecies()
	local survived = {}

	for s = 1,#pool.species do
		local species = pool.species[s]

		table.sort(species.genomes, function (a,b)
			return (a.fitness > b.fitness)
		end)

		if species.genomes[1].fitness > species.topFitness then
			species.topFitness = species.genomes[1].fitness
			species.staleness = 0
		else
			species.staleness = species.staleness + 1
		end
		if species.staleness < user.StaleSpecies or species.topFitness >= pool.maxFitness then
			table.insert(survived, species)
		end
	end

	pool.species = survived
end

local function removeWeakSpecies()
	local survived = {}

	local sum = totalAverageFitness()
	for s = 1,#pool.species do
		local species = pool.species[s]
		breed = math.floor(species.averageFitness / sum * user.Population)
		if breed >= 1 then
			table.insert(survived, species)
		end
	end

	pool.species = survived
end


local function addToSpecies(child)
	local foundSpecies = false
	for s=1,#pool.species do
		local species = pool.species[s]
		if not foundSpecies and sameSpecies(child, species.genomes[1]) then
			table.insert(species.genomes, child)
			foundSpecies = true
		end
	end

	if not foundSpecies then
		local childSpecies = newSpecies()
		table.insert(childSpecies.genomes, child)
		table.insert(pool.species, childSpecies)
	end
end

local function newGeneration()
	cullSpecies(false) -- Cull the bottom half of each species
	rankGlobally()
	removeStaleSpecies()
	rankGlobally()
	for s = 1,#pool.species do
		local species = pool.species[s]
		calculateAverageFitness(species)
	end
	removeWeakSpecies()
	local sum = totalAverageFitness()
	local children = {}
	for s = 1,#pool.species do
		local species = pool.species[s]
		breed = math.floor(species.averageFitness / sum * user.Population) - 1
		for i=1,breed do
			table.insert(children, breedChild(species))
		end
	end
	cullSpecies(true) -- Cull all but the top member of each species
	while #children + #pool.species < user.Population do
		local species = pool.species[math.random(1, #pool.species)]
		table.insert(children, breedChild(species))
	end
	for c=1,#children do
		local child = children[c]
		addToSpecies(child)
	end

	pool.generation = pool.generation + 1

end



module.getCurrentGenome = function()
	local species = pool.species[pool.currentSpecies]
	return species.genomes[pool.currentGenome]
end

local function initializeRun()

	-- call initialization callback
	user.onInitializeFunction()

	-- Restart pool
	generateNetwork(module.getCurrentGenome())

end


local function nextGenome()
	pool.currentGenome = pool.currentGenome + 1
	if pool.currentGenome > #pool.species[pool.currentSpecies].genomes then
		pool.currentGenome = 1
		pool.currentSpecies = pool.currentSpecies+1
		if pool.currentSpecies > #pool.species then
			newGeneration()
			pool.currentSpecies = 1
		end
	end
end

local function fitnessAlreadyMeasured()
	local genome = module.getCurrentGenome()
	return genome.fitness ~= 0
end


module.save = function()
	markedToSave = true
end

local function saveFile()
	markedToSave = false
	local filename = user.SaveLoadFile
	totalRuns = 0
	-- First backup file
	local infile = io.open(filename, "r")
	if infile ~= nil then
		local instr = infile:read("*a")
		infile:close()
		local outfile = io.open("backup.pool", "w")
		outfile:write(instr)
		outfile:close()
	end

    local file = io.open(filename, "w")
	if file == nil then return end
	file:write(pool.generation .. "\n")
	file:write(pool.maxFitness .. "\n")
	file:write(#pool.species .. "\n")
    for n,species in pairs(pool.species) do
		file:write(species.topFitness .. "\n")
		file:write(species.staleness .. "\n")
		file:write(#species.genomes .. "\n")
		for m,genome in pairs(species.genomes) do
			file:write(genome.fitness .. "\n")
			file:write(genome.maxneuron .. "\n")
			for mutation,rate in pairs(genome.mutationRates) do
				file:write(mutation .. "\n")
				file:write(rate .. "\n")
			end
			file:write("done\n")

			file:write(#genome.genes .. "\n")
			for l,gene in pairs(genome.genes) do
				file:write(gene.into .. " ")
				file:write(gene.out .. " ")
				file:write(gene.weight .. " ")
				file:write(gene.innovation .. " ")
				if(gene.enabled) then
					file:write("1\n")
				else
					file:write("0\n")
				end
			end
		end
    end
    file:close()
end


local function loadFile(filename)
    local file = io.open(filename, "r")
	if file == nil then return end
	clearPool()
	pool.generation = file:read("*number")
	pool.maxFitness = file:read("*number")
	if maxFitnessLabel ~= nil then
		forms.settext(maxFitnessLabel, "Max Fitness: " .. math.floor(pool.maxFitness))
	end
    local numSpecies = file:read("*number")
    for s=1,numSpecies do
		local species = newSpecies()
		table.insert(pool.species, species)
		species.topFitness = file:read("*number")
		species.staleness = file:read("*number")
		local numGenomes = file:read("*number")
		for g=1,numGenomes do
			local genome = newGenome()
			table.insert(species.genomes, genome)
			genome.fitness = file:read("*number")
			genome.maxneuron = file:read("*number")
			local line = file:read("*line")
			while line ~= "done" do
				genome.mutationRates[line] = file:read("*number")
				line = file:read("*line")
			end
			local numGenes = file:read("*number")
			for n=1,numGenes do
				local gene = newGene()
				table.insert(genome.genes, gene)
				local enabled
				gene.into, gene.out, gene.weight, gene.innovation, enabled = file:read("*number", "*number", "*number", "*number", "*number")
				if enabled == 0 then
					gene.enabled = false
				else
					gene.enabled = true
				end

			end
		end
	end
    file:close()

	while fitnessAlreadyMeasured() do
		nextGenome()
	end
end


module.replayBestRun = function()
	local maxfitness = 0
	local maxs, maxg
	for s,species in pairs(pool.species) do
		for g,genome in pairs(species.genomes) do
			if genome.fitness > maxfitness then
				maxfitness = genome.fitness
				maxs = s
				maxg = g
			end
		end
	end

	pool.currentSpecies = maxs
	pool.currentGenome = maxg
	pool.maxFitness = maxfitness
	initializeRun()
	print("Replaying fitness " .. pool.maxFitness)
	return pool.maxFitness
end


local function evaluateCurrent()
	local genome = module.getCurrentGenome()

	local inputs = user.produceInputFunction()
	if inputs ~= nil then
		outputs = evaluateNetwork(genome.network, inputs)
	end
	if outputs ~= nil then
		user.consumeOutputFunction(outputs)
	end
end


local function createNewPool()
	clearPool()
	for i = 1, user.Population do
		basic = basicGenome()
		addToSpecies(basic)
	end
end

-- Start the learning process
module.run = function(userSetup)

	-- Override default options from userSetup
	for key, value in pairs(userSetup) do
		user[key] = value
	end
	-- First input is for the house
	if user.InputsCount < 0 then
		-- Automatically set the expected number of inputs
		-- By asking for inputs, even though we're not using them yet
		local inputs = user.produceInputFunction(true)
		user.InputsCount = #inputs
	end
	user.InputsCount = user.InputsCount + 1

	-- Load pool or create new one
	loadFile(user.SaveLoadFile)
	if pool == nil then
		createNewPool()
	end
	initializeRun()

	-- Loop
	while true do

		local genome = module.getCurrentGenome()

		evaluateCurrent()
		local fitness = user.checkFinalFitnessFunction()

		if fitness ~= nil then
			genome.fitness = fitness
			totalRuns = totalRuns + 1
			if fitness > pool.maxFitness then
				pool.maxFitness = fitness
				saveFile()
			elseif totalRuns % user.SaveFrequency == 0 then
				saveFile()
			end
			console.writeline("Gen " .. pool.generation .. " species " .. pool.currentSpecies .. " genome " .. pool.currentGenome .. " fitness: " .. fitness)

			-- Setup next genome
			pool.currentSpecies = 1
			pool.currentGenome = 1
			while fitnessAlreadyMeasured() do
				nextGenome()
			end
			-- run next genome
			initializeRun()
		end

		if markedToSave then
			saveFile()
		end

		emu.frameadvance()
	end
end

module.getSettings = function()
	return user
end


module.onExit = function()
	saveFile()
end


return module
