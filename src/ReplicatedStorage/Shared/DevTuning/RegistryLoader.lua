-- RegistryLoader: discovers feature registry ModuleScripts and validates them through Schema.

local Schema = require(script.Parent.Schema)

local RegistryLoader = {}
local cachedCatalog

local function getSortedModules(registryFolder)
	local modules = {}
	for _, child in ipairs(registryFolder:GetChildren()) do
		if child:IsA("ModuleScript") then
			table.insert(modules, child)
		end
	end
	table.sort(modules, function(left, right)
		return left.Name < right.Name
	end)
	return modules
end

function RegistryLoader.load(registryFolder)
	local isDefaultFolder = registryFolder == nil
	if isDefaultFolder and cachedCatalog then
		return cachedCatalog
	end

	registryFolder = registryFolder or script.Parent:WaitForChild("Registry")
	local moduleDefinitions = {}
	for _, registryModule in ipairs(getSortedModules(registryFolder)) do
		table.insert(moduleDefinitions, {
			sourceName = registryModule.Name,
			definition = require(registryModule),
		})
	end

	local catalog, validationError = Schema.validate(moduleDefinitions)
	if not catalog then
		error(validationError, 2)
	end

	if isDefaultFolder then
		cachedCatalog = catalog
	end
	return catalog
end

return RegistryLoader
