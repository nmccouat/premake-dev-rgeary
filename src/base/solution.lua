--
-- solution.lua
-- Work with the list of solutions loaded from the script.
-- Copyright (c) 2002-2012 Jason Perkins and the Premake project
--

	premake.solution = premake.solution or { }
	local solution = premake.solution
	local oven = premake5.oven
	local project = premake5.project


-- The list of defined solutions (which contain projects, etc.)

	premake.solution.list = { }


--
-- Create a new solution and add it to the session.
--
-- @param name
--    The new solution's name.
--

	function solution.new(name)
		local sln = { }
		local prefix

		-- add to master list keyed by both name and index
		if name == '_GLOBAL_CONTAINER' then
			ptypeSet( sln, "globalcontainer" )
		else
			table.insert(premake.solution.list, sln)
			premake.solution.list[name] = sln
			ptypeSet( sln, "solution" )
			prefix = name .. '/' 
		end
			
		sln.name           = name
		sln.basedir        = os.getcwd()			
		sln.projects       = { }		-- real projects, not usages
		sln.projectprefix  = prefix		-- default prefix is solution name
		sln.namespaces     = { name..'/' }

		-- merge in global configuration
		local slnTemplate = premake5.globalContainer.solution 
		if slnTemplate then
			sln.configurations 	= oven.merge({}, slnTemplate.configurations)
			sln.blocks 			= oven.merge({}, slnTemplate.blocks)
			sln.platforms		= oven.merge({}, slnTemplate.platforms or {})
			sln.language		= slnTemplate.language
			
			for name,info in pairs(premake.fields) do
				if slnTemplate[name] and (not sln[name]) then
					sln[name] = slnTemplate[name]
				end
			end
		else
			sln.configurations = { }
			sln.blocks         = { }
		end
		
		return sln
	end



--
-- Iterates through all of the current solutions, bakes down their contents,
-- and then replaces the original solution object with this baked result.
-- This is the entry point to the whole baking process, which happens after
-- the scripts have run, but before the project files are generated.
--

	function solution.bakeall()
		local result = {}
		for i, sln in ipairs(solution.list) do
			local bakedSln = solution.bake(sln)
			
			result[i] = bakedSln
			result[sln.name] = bakedSln
		end
		solution.list = result
	end


--
-- Prepare the contents of a solution for the next stage. Flattens out
-- all configurations, computes composite values (i.e. build targets,
-- objects directories), and expands tokens.
-- @return
--    The baked version of the solution.
--

	function solution.bake(sln)
		
		-- early out
		if sln.isbaked then
			return sln
		end
	
		-- start by copying all field values into the baked result
		local result = oven.merge({}, sln)
		result.isbaked = true
		
		-- Set the defaultconfiguration if there's only one configuration
		if #sln.configurations == 1 and not sln.defaultconfiguration then 
			sln.defaultconfiguration = sln.configurations[1]
		end 
		
		-- keep a reference to the original configuration blocks, in
		-- case additional filtering (i.e. for files) is needed later
		result.blocks = sln.blocks
		
		-- Resolve baked projects
		local prjList = {}	
		for i,prj in ipairs(result.projects) do
			local realProj = project.getRealProject(prj.name)
			
			if realProj and not prjList[realProj.name] then
				table.insert( prjList, realProj )
				prjList[realProj.name] = realProj
			end				
		end
		result.projects = prjList
		
		-- expand all tokens
		oven.expandtokens(result, "project")

		-- build a master list of solution-level configuration/platform pairs
		result.configs = solution.bakeconfigs(result)
		
		-- flatten includesolution
		if sln.includesolution then
			local includeList = {}
			for _,child in ipairs(sln.includesolution) do
				if child == '*' then
					for _,s in ipairs(solution.list) do
						if s.name ~= sln.name then
							table.insert( includeList, s.name )
						end
					end
				else
					table.insert( includeList, child )
				end
			end
			result.includesolution = includeList
		end
		
		return result
	end
	
--
-- Create a list of solution-level build configuration/platform pairs.
--

	function solution.bakeconfigs(sln)
		local buildcfgs = sln.configurations or {}
		local platforms = sln.platforms or {}
		
		local configs = {}
		for _, buildcfg in ipairs(buildcfgs) do
			if #platforms > 0 then
				for _, platform in ipairs(platforms) do
					table.insert(configs, { ["buildcfg"] = buildcfg, ["platform"] = platform })
				end
			else
				table.insert(configs, { ["buildcfg"] = buildcfg })
			end
		end

		-- fill in any calculated values
		for _, cfg in ipairs(configs) do
			premake5.config.bake(cfg)
			ptypeSet( cfg, 'configs' )
		end
		oven.expandtokens(sln, "solution", nil, "ninjaBuildDir", false)
		
		return configs
	end

--
-- Iterate over the collection of solutions in a session.
--
-- @returns
--    An iterator function.
--

	function solution.each()
		local i = 0
		return function ()
			i = i + 1
			if i <= #premake.solution.list then
				return premake.solution.list[i]
			end
		end
	end

--
-- Iterate over the configurations of a solution.
--
-- @param sln
--    The solution to query.
-- @return
--    A configuration iteration function.
--

	function solution.eachconfig(sln)
		-- to make testing a little easier, allow this function to
		-- accept an unbaked solution, and fix it on the fly
		if not sln.isbaked then
			sln = solution.bake(sln)
		end

		local i = 0
		return function()
			i = i + 1
			if i > #sln.configs
			 then
				return nil
			else
				return sln.configs[i]
			end
		end
	end
	
	function solution.getConfigs(sln)
		-- to make testing a little easier, allow this function to
		-- accept an unbaked solution, and fix it on the fly
		if not sln.isbaked then
			sln = solution.bake(sln)
		end

		return Seq:new(sln.configs)	
	end


--
-- Iterate over the projects of a solution.
--
-- @param sln
--    The solution.
-- @returns
--    An iterator function.
--

	function solution.eachproject(sln)
		local i = 0
		return function ()
			i = i + 1
			if i <= #sln.projects then
				return premake.solution.getproject(sln, i)
			end
		end
	end


--
-- Iterate over the projects of a solution (next-gen).
--
-- @param sln
--    The solution.
-- @return
--    An iterator function, returning project configurations.
--

	function solution.eachproject_ng(sln)
		local i = 0
		return function ()
			i = i + 1
			if i <= #sln.projects then
				return premake.solution.getproject_ng(sln, i)
			end
		end
	end


--
-- Locate a project by name, case insensitive.
--
-- @param sln
--    The solution to query.
-- @param name
--    The name of the projec to find.
-- @return
--    The project object, or nil if a matching project could not be found.
--

	function solution.findproject(sln, name)
		name = name:lower()
		for _, prj in ipairs(sln.projects) do
			if name == prj.name:lower() then
				return prj
			end
		end
		return nil
	end

--
--  Find a usage configuration
--
	function solution.findusage(sln, useProjName)
		name = name:lower()
		for _, prj in ipairs(sln.projects) do
			if useProjName == prj.name:lower() then
				return iif( prj.usageProj, prj.usageProj, prj )
			end
		end
		for _, prj in ipairs(premake.globalContainer.projects) do
			if useProjName == prj.name:lower() then
				return iif( prj.usageProj, prj.usageProj, prj )
			end
		end
		return nil
	end


--
-- Retrieve a solution by name or index.
--
-- @param key
--    The solution key, either a string name or integer index.
-- @returns
--    The solution with the provided key.
--

	function solution.get(key)
		return premake.solution.list[key]
	end


--
-- Retrieve the solution's file system location.
--
-- @param sln
--    The solution object to query.
-- @return
--    The path to the solutions's file system location.
--

	function solution.getlocation(sln)
		return sln.location or sln.basedir
	end


--
-- Retrieve the project at a particular index.
--
-- @param sln
--    The solution.
-- @param idx
--    An index into the array of projects.
-- @returns
--    The project at the given index.
--

	function solution.getproject(sln, idx)
		-- retrieve the root configuration of the project, with all of
		-- the global (not configuration specific) settings collapsed
		local prj = sln.projects[idx]
		local cfg = premake.getconfig(prj)
		
		-- root configuration doesn't have a name; use the project's
		cfg.name = prj.name
		return cfg
	end


--
-- Retrieve the project configuration at a particular index.
--
-- @param sln
--    The solution.
-- @param idx
--    An index into the array of projects.
-- @return
--    The project configuration at the given index.
--

	function solution.getproject_ng(sln, idx)
		-- to make testing a little easier, allow this function to
		-- accept an unbaked solution, and fix it on the fly
		if not sln.isbaked then
			sln = solution.bake(sln)
		end
		return sln.projects[idx]
	end
	