--
-- Root build.ninja solution file generator
--

local ninja = premake.actions.ninja
local solution = premake.solution
local project = premake5.project
local config = premake5.config
local ninjaVarLevel = 2		-- higher = use more ninja build vars
local toolsetDef = {}
ninja.helpMsg = {}

local function mergeTargets(dest, src)
	for k,v in pairs(src or {}) do
		local v = dest[k] or {}
		dest[k] = concat(v, src[k])
	end
end

-- don't extract everything
ninja.notBuildVar = { input=1, output=1, depfileOutput=1 }

ninja.buildEdges = {}

local function addBuildEdge(targetName, inputs, implicitDeps, overrides)
	--[[local t = {}
	t.inputs = inputs
	t.implicitDeps = implicitDeps
	t.overrides = overrides
	ninja.buildEdges[targetName] = t]]
	ninja.buildEdges[targetName] = inputs
end

--
-- The actual rules & actions to build the solution. Always invoked by the default build.ninja, which contains its dependencies
--
function ninja.generateSolution(sln, scope)
	--_p('# %s solution build.ninja autogenerated by Premake', sln.name)
	--_p('#  This file is not designed to be invoked directly, the build.ninja header file specifies the dependencies')
	--_p('')
	if not scope:get('__header') then 
		ninja.writeExecRule()
		scope:set('__header', true)
	end

	local first = true
	local slnPrjTargets = {}
	for _,prj in ipairs(sln.projects) do
		
		if not prj.isUsage then
			local cfgs = project.getConfigs(prj)
			ninja.writeToolsets(cfgs, scope)
		end
		
		if first then
			_p('#############################################')
			_p('# Solution ' .. sln.name)
			_p('#############################################')
			_p('')
			first = false
		end		
	
		local prjTargets = ninja.generateProject(prj, scope)
		mergeTargets(slnPrjTargets, prjTargets)
	end
	
	local slnTargets = {}
	for cfgName,targets in pairs(slnPrjTargets) do
		local slnCfg = sln.name
		if #cfgName > 0 then
			slnCfg = slnCfg ..'.'..cfgName
		end
		local prjTargets = table.concat(targets, ' ')
		if slnCfg ~= prjTargets then
			local buildCmd = 'phony '.. prjTargets
			addBuildEdge(slnCfg, buildCmd)
			_p('build '..slnCfg..': '..buildCmd)
		end
		slnTargets[cfgName] = slnTargets[cfgName] or {}
		table.insert( slnTargets[cfgName], slnCfg )
	end
	_p('')
	scope.alltargets = scope.alltargets or {}
	scope.slntargets = scope.slntargets or {}
	scope.slntargets[sln.name] = slnTargets
	mergeTargets(scope.alltargets, slnTargets)
	
	if sln.exports then
		for alias,fullProjName in pairs(sln.exports) do
			if alias ~= fullProjName then
				_p('build '..alias..': phony '..fullProjName)
			end
		end
		_p('')
	end
end

function ninja.writeFooter(scope)
	-- Write help
	if #ninja.helpMsg > 0 then
		_p('# Ninja help message')
		_p('#######################################')
		_p('')
		local echoNewLine = "\\n$"
		_p('ninjaHelpMsg="$')
		for _,line in ipairs(ninja.helpMsg) do
			_p(line..echoNewLine)
		end
		local slnList = mkstring(getKeys(scope.slntargets))
		_p(echoNewLine)
		_p(' Solutions : '.. slnList..echoNewLine)
		_p('"')
		_p('build help: exec\n cmd=echo -e $ninjaHelpMsg\n description=\t')
		_p('')		
	end
	
	-- Write the global configuration build targets
	if scope.alltargets then
		_p('# Global configuration build targets')
		_p('#######################################')
		_p('')
		for cfgName,targetList in pairs(scope.alltargets) do
			if #cfgName>0 then
				local buildCmd = 'phony '..table.concat(targetList, ' ')
				addBuildEdge(cfgName, buildCmd)
				_p('build '..cfgName..': '..buildCmd)
			end
		end		
		_p('')
	end	
end

function ninja.writeDefaultTargets(targetsByCfg)
	-- Write the global configuration build targets
	if targetsByCfg then
		local defaultTarget = targetsByCfg[''] or {}
		if #defaultTarget == 0 then
			-- No default project targets, so build all the configurations instead 
			defaultTarget = getKeys(targetsByCfg)
		end
		
		if #defaultTarget > 0 then
			-- Build all configurations by default
			_p('# Default build targets')
			_p('#######################################')
			_p('')
			_p('default '..table.concat(defaultTarget, ' '))
		_p('')
		end
	end
end

function ninja.generateProject(prj, scope)
	if not prj.isUsage then
		_p('# Project ' .. prj.name)
		_p('##############################')
		_p('')
		return ninja.writeProjectTargets(prj, scope)
	else
		return nil
	end
end

function ninja.getToolOverrides(cfg, tool, scope)
	local toolInputs = tool:decorateInputs(cfg, '$out', '$in')
	local toolDef = scope:get(tool.ruleName)
	
	if not toolDef then return nil end
	-- add any missing vars
	for k,_ in pairs(toolDef) do
		toolInputs[k] = toolInputs[k] or ""
	end
	
	-- See if we need to override any flags
	local toolOverrides = {}
	
	for k,v in pairs(toolInputs) do
		v = ninja.esc(v)
		if not ninja.notBuildVar[k] then
			if toolDef[k] ~= v then
				k = tool.ruleName .. '_' .. k
				toolOverrides[k] = v
			end
		end
	end
	
	return toolOverrides
end

function ninja.getCompileTool(cfg, fileExt, scope)
	local toolsetName = cfg.toolset
	local toolset = premake.tools[toolsetName]
	
	local compileTool = toolset:getCompileTool(cfg, fileExt)
	local compileOverrides
	if compileTool then
		compileOverrides = ninja.getToolOverrides(cfg, compileTool, scope)
	end

	return compileTool, compileOverrides
end

function ninja.getLinkTool(cfg, scope)
	local toolset = premake.tools[cfg.toolset]
	
	local linkTool = toolset:getLinkTool(cfg)
	local linkOverrides
	if linkTool then
		linkOverrides = ninja.getToolOverrides(cfg, linkTool, scope)
	end
	
	return linkTool, linkOverrides
end

local function makeShorterBuildVars(scope, inputs, weight, newVarPrefix)
	-- See if it's worth creating extra build vars
	local extraBuildVars = scope:getBuildVars(inputs, weight, newVarPrefix)
	for k,v in pairs(extraBuildVars) do
		_p(k .. '=' .. v)
	end			
end

function ninja.writeProjectTargets(prj, scope)

	local filesPerConfig = ninja.getInputFiles(prj)
	
	local cfgs = {}
	local prjTargets = {}
	local isSourceGen = false
	local prjTargetName = prj.name
	
	-- Validate
	for cfg in project.eachconfig(prj) do
		if not cfg.kind then
			--error("Malformed project '"..prj.name.."', has no kind specified")
		end 
		if not cfg.toolset then
			error("Malformed project '"..prj.name.."', has no toolset specified for kind "..cfg.kind)
		end
		
		local linkTool,linkOverrides = ninja.getLinkTool(cfg, scope)
		if linkTool and not isSourceGen then 
			if not cfg.buildtarget then
				error("Malformed project '"..prj.name.."', toolset "..cfg.toolset.." requires buildtarget but none specified")
			end
		end
	
		cfg.language = prj.language

		-- Check if we should include this configuration in the build		
		local buildThis = true
		
		-- Only build source gen & command once
		if cfg.kind == 'SourceGen' or cfg.kind == 'Command' then
			if isSourceGen then
				buildThis = false
			end
			isSourceGen = true
		end
		
		if cfg.kind == 'Command' then
			prjTargetName = prjTargetName:match("[^/]*$")
		end
		
		if buildThis then   
			-- Put the default configuration first. 
			-- This fixes a problem where auto-generated header files put in the src folders are incorrectly updated
			--  as the script name includes the name of the first cfg processed
			if cfg.buildcfg == prj.defaultconfiguration then 
				table.insert(cfgs, 1, cfg)
			else
				table.insert(cfgs, cfg)
			end
		end
	end
	
	local tmr = timer.start('ninja.writeProjectTargets')
	
	-- Compile
	for _,cfg in ipairs(cfgs) do
		local toolsetName = cfg.toolset
		local toolset = premake.tools[toolsetName]
		local allLinkInputs = {}
		
		local compileTool,compileOverrides = ninja.getCompileTool(cfg, nil, scope)
		local linkTool,linkOverrides = ninja.getLinkTool(cfg, scope)
		
		-- List of all files in this config
		local filesInCfg = filesPerConfig[cfg]
		local srcdirFull = prj.basedir
		local hasObjdir = iif( isSourceGen, false, true )
		local srcdir = string.replace(srcdirFull, repoRoot, ninja.rootVar)
		local objdir = ''
		local targetdir = ''
		if hasObjdir then
			objdir = string.replace(cfg.objdir, repoRoot, ninja.rootVar)
			targetdir = string.replace(cfg.targetdir, repoRoot, ninja.rootVar)
		end
		local cfgname = string.replace(cfg.shortname, '_', '.')
		
		local numFilesToCompile = #(filesInCfg['Compile'] or {}) 
		local verboseComments = numFilesToCompile > 5
					
		-- Generate unique ninja build var names
		local objdirN = objdir
		local targetdirN = targetdir
		local srcdirN = srcdir
		
		if not prj.name:find('/test',1,true) then
			local foundO, foundT, foundS
			if hasObjdir then
				objdirN,foundO = scope:set('objdir', objdir)
			end
			if targetdir ~= objdir then
				targetdirN,foundT = scope:set('targetdir_' .. cfgname, targetdir)
			else
				targetdirN = objdirN
				foundT = true
			end
			srcdirN,foundS = scope:set('srcdir', srcdir)
			
			if verboseComments then
				_p('# Compile ' .. prj.name .. ' ['..cfgname..']')
				_p('#------------------------------------')
				_p('')
			end
			if not foundO and hasObjdir then _p(objdirN ..'='..objdir); end
			if not foundT then _p(targetdirN..'='..targetdir); end
			if not foundS then _p(srcdirN..'='..srcdir); end
			_p('')
		else
			objdirN = scope:getBest(objdirN)
			targetdirN = scope:getBest(targetdirN)
			srcdirN = scope:getBest(srcdirN)
		end
		local uniqueObjNameSet = {}
		local finalTargetInputs = {}
		
		objdirN = ninja.escVarName(objdirN)
		targetdirN = ninja.escVarName(targetdirN)
		srcdirN = ninja.escVarName(srcdirN)
		
		-- Compile source -> object files, for all files in the config
		for fileName,fileCfg in pairs(filesInCfg['Compile'] or {}) do
			if type(fileName) ~= 'number' then
				local sourceFileRel = path.getrelative(srcdirFull, fileName)
				local outputFile
				
				local extraTargets = ninja.writeBuildRule(cfg, 'compile', fileName, scope)
				if not isSourceGen then
					-- SourceGen projects can have no compile dependencies, otherwise we end up in a loop
					table.insertflat( extraTargets, cfg.compiledepends )
				end
				
				-- See if it's worth creating extra build vars
				makeShorterBuildVars(scope, extraTargets, numFilesToCompile, 'src')
				
				-- Check if we need to override the compile tool based on the extension
				local fileExt = fileCfg.extension
				local fileCompileTool = toolset:getCompileTool(cfg, fileExt)
				local fileCompileOverrides = compileOverrides
				
				if compileTool ~= fileCompileTool then
					fileCompileTool, fileCompileOverrides = ninja.getCompileTool(cfg, fileExt, scope)
				end
				
				if fileCompileTool then
					-- Check if we can compile the file, and get the object file name
					outputFile = fileCompileTool:getCompileOutput(cfg, fileName, uniqueObjNameSet)
				end
	
				makeShorterBuildVars(scope, fileCompileOverrides, numFilesToCompile)
	
				-- Write the build rule
				-- I assume that any build specialisation is only per project+configuration, not per file
				if outputFile then
					local outputFullpath = objdirN..'/'..outputFile
					
					local buildCmd = fileCompileTool.ruleName..' '..srcdirN..'/'..sourceFileRel
					local buildStr = 'build ' .. outputFullpath ..': '..buildCmd
					
					local implicitDeps
					if extraTargets and #extraTargets > 0 then
						-- Add implicit dependencies
						implicitDeps = table.concat(extraTargets, ' ')
						
						if #extraTargets > 1 then
							local varName, alreadyExists = scope:getName(implicitDeps, 'deps')
							if not alreadyExists then
								_p('build '..varName..': phony '.. implicitDeps)
							end
							implicitDeps = varName
						end
						
						buildStr = buildStr .. ' | '..implicitDeps 
						extraTargets = nil
					end
					
					_p(buildStr)
					for k,v in pairs(fileCompileOverrides) do
		    			--v = scope:getBest(v)
						_p(' ' .. k .. '=' .. v)
					end
	
					addBuildEdge(outputFullpath, buildCmd, implicitDeps, fileCompileOverrides)
					
					table.insert( allLinkInputs, outputFullpath )
				elseif cfg.kind == 'Command' then
					local fileTarget = srcdirN..'/'..sourceFileRel ..'.exec'
					local buildStr = 'build ' .. fileTarget ..': exec '.. srcdirN..'/'..sourceFileRel
					_p(buildStr)
					addBuildEdge(fileTarget, buildStr, nil, nil)
					table.insert( allLinkInputs, fileTarget )				
					
				elseif (linkTool == nil) or linkTool:isLinkInput(cfg, fileExt ) then
					table.insert( allLinkInputs, srcdirN..'/'..sourceFileRel )
				end
							
				table.insertflat(finalTargetInputs, extraTargets)
			end -- ~= number
		end
		_p('')
		
		for _,fileFullpath in ipairs(filesInCfg['Copy'] or {}) do
			local fileName = path.getname(fileFullpath)
			local buildCmd = 'copy ' .. fileFullpath
			local buildTarget = targetdirN..'/'..fileName
			addBuildEdge(buildTarget, buildCmd)
			_p('build ' .. buildTarget..' : '..buildCmd)
		end
		
		for _,fileFullpath in ipairs(filesInCfg['Embed'] or {}) do
			table.insert( allLinkInputs, fileFullpath )
		end

		-- Implicit dependencies : files which affect the build but aren't included in the direct inputs		
		local implicitDeps = {}
		local implicitDepInputFiles = filesInCfg['ImplicitDependency'] or {}
		makeShorterBuildVars(scope, implicitDepInputFiles, #implicitDepInputFiles)
		for _,fileFullpath in ipairs(implicitDepInputFiles) do
			table.insert( implicitDeps, fileFullpath )
		end
		local libs = Seq:ipairs(cfg.linkAsStatic):concat(Seq:ipairs(cfg.linkAsShared))
			:select(function(v) return scope:getBest(v); end)
		for _,lib in libs:each() do
			if path.containsSlash(lib) then
				table.insert( implicitDeps, lib )
			end
		end
		
		-- Link
		local finalTargetN = prj.name.. '.' ..cfgname
		if prj.name == prj.solution.name then
			finalTargetN = prj.name..'.Project.' .. cfgname 
		end
		
		if #allLinkInputs > 0 then
		
			local extraTargets = ninja.writeBuildRule(cfg, 'link', allLinkInputs, scope)
			table.insertflat(implicitDeps, extraTargets)
			
			makeShorterBuildVars(scope, implicitDeps, 1)
			
			local linkToolRuleName
		
			if not linkTool then
				if #extraTargets == 0 then
					if cfg.buildtarget then 
						local buildCmd = 'phony '..table.concat(allLinkInputs, ' ')
						local linkTargetN = targetdirN..'/'..cfg.buildtarget.name
						if isSourceGen then
							linkTargetN = prjTargetName
						end
						addBuildEdge(linkTargetN, buildCmd)
						_p('build '..linkTargetN..': '..buildCmd)
						table.insert(finalTargetInputs,linkTargetN)
					else
						table.insert(finalTargetInputs,targetdirN)
					end
				else
					table.insertflat(finalTargetInputs, extraTargets)
				end
			else
				if verboseComments then
					_p('# Link ' .. prj.name .. ' ['..cfgname..']')
					_p('#++++++++++++++++++++++++++++++++')
				end
			
				local linkTargetN
				if linkTool.getOutputFiles then
					-- Use this if your tool outputs multiple files
					local outputFiles = linkTool:getOutputFiles(cfg, allLinkInputs)
					outputFiles = ninja.escPath(outputFiles)
					makeShorterBuildVars(scope, outputFiles, 1)
					linkTargetN = table.concat(outputFiles, ' ')
				else
					linkTargetN = targetdirN..'/'..cfg.buildtarget.name
				end
				
				local buildCmd = linkTool.ruleName ..' '..table.concat(allLinkInputs, ' ')
				local buildStr = 'build '..linkTargetN..': '..buildCmd
				
				local implicitDepStr = nil
				if #implicitDeps > 0 then
					implicitDepStr = table.concat(implicitDeps, ' ')
					if ninjaVarLevel >= 2 then
						local varName, alreadyExists = scope:getName(implicitDepStr, 'deps')
						if not alreadyExists then
							_p('build '..varName..': phony '.. implicitDepStr)
						end
						implicitDepStr = varName
					end
				 
					buildStr = buildStr .. ' | ' .. implicitDepStr
				end 
	
				makeShorterBuildVars(scope, linkOverrides, 1)
	
				_p(buildStr)
				for k,v in pairs(linkOverrides or {}) do
					_p(' ' .. k .. '=' .. v)
				end
				_p('')

				addBuildEdge(linkTargetN, buildCmd, implicitDepStr, linkOverrides)

				table.insert(finalTargetInputs,linkTargetN)
			end
						
		end
		
		-- Post build commands
		if cfg.postbuildcommands and #cfg.postbuildcommands > 0 then
			cfg.stageNumber = cfg.stageNumber or {}
			if verboseComments then
				_p('# Post build commands')
			end
			local linkTargetN = targetdirN..'/'..cfg.buildtarget.name
			local description = nil
			local stage = 'postbuild'
			for i,cmd in ipairs(cfg.postbuildcommands) do
			
				if string.sub(cmd,1,1) == '#' then
					description = string.sub(cmd,2)
				else
					-- Generate a unique name to reference this post build command
					cfg.stageNumber[stage] = (cfg.stageNumber[stage] or 0) + 1
					local postBuildTarget = finalTargetN..'.'..stage..tostring(cfg.stageNumber[stage])

					repeat
						local cmd2 = cmd
						cmd = scope:getBest(cmd)
					until #cmd2 == #cmd
					local buildCmd = 'exec '..table.concat(finalTargetInputs, ' ')

					addBuildEdge(postBuildTarget, buildCmd, nil, { cmd=cmd, description=description })
					
					_p('build '..postBuildTarget..' : '..buildCmd)
					_p(' cmd='..cmd)
					if description then
					  _p(' description='..description)
					  description=nil
					end
					table.insert(finalTargetInputs, postBuildTarget)
				end 
			end
			_p('')
		end
		
		-- Post build commands v2
		local postbuildTargets = ninja.writeBuildRule(cfg, 'postbuild', finalTargetInputs, scope)
		table.insertflat(finalTargetInputs, postbuildTargets)

		-- Phony rule to build it all
		if cfg.kind == 'Command' and #finalTargetInputs == 1 then
			finalTargetN = finalTargetInputs[1]
		else
			local buildCmd = 'phony '..table.concat(finalTargetInputs, ' ')
			addBuildEdge(finalTargetN, buildCmd)
			_p('build '..finalTargetN..': '..buildCmd)
			_p('')
		end
		
		if cfg.buildwhen ~= 'explicit' then
			prjTargets[cfgname] = { finalTargetN }
		end
				
	end -- for cfgs
timer.stop(tmr)
	
	local defaultTarget = 'donothing'
	if prj.defaultconfiguration and prj.configs[prj.defaultconfiguration] then
		
		local cfg = prj.configs[prj.defaultconfiguration]
		if cfg.buildwhen ~= 'explicit' then
			defaultTarget = prj.name..'.'..prj.defaultconfiguration
			prjTargets[''] = { prj.name }
		end
	end
	if not ninja.buildEdges[prjTargetName] then
		_p('build '..prjTargetName..': phony '..defaultTarget)
		addBuildEdge(prjTargetName, defaultTarget)
	end
	_p('')
	
	return prjTargets
end

function ninja.writeBuildRule(cfg, stage, inputs, scope)
	if cfg.buildrule then
		local finalTargetInputs = {}
		-- split in to stages
		if not cfg.buildruleSet then
			cfg.buildruleSet = {}
			cfg.stageNumber = cfg.stageNumber or {}
						
			for _,b in ipairs(cfg.buildrule) do
				local stage = b.stage or 'postbuild' 
				cfg.buildruleSet[stage] = cfg.buildrule[stage] or {}
				table.insert(cfg.buildruleSet[stage], b) 
			end
		end
		
		if cfg.buildruleSet[stage] then
			for i,buildrule in ipairs(cfg.buildruleSet[stage] or {}) do
			
				-- Generate a unique name to reference this post build command
				cfg.stageNumber[stage] = (cfg.stageNumber[stage] or 0) + 1
				local buildTarget = cfg.project.name..'.'..cfg.buildcfg..'.'..stage..tostring(cfg.stageNumber[stage])
				if cfg.kind == 'Command' then
					buildTarget = cfg.project.name:match("[^/]*$")
				end
				
				local cmd = buildrule.commands or ''
				if type(cmd) == 'table' then cmd = table.concat(cmd, '\n') end
				repeat
					local cmd2 = cmd
					cmd = scope:getBest(cmd)
				until #cmd2 == #cmd
				
				local implicits = buildrule.dependencies or '' 
				if type(implicits) == 'table' then implicits = table.concat(implicits, ' ') end
				
				if buildrule.language then
					-- Write the command to a file, and execute it
					local script = cmd:replace(ninja.rootVar, repoRoot)
					local scriptFilename = cfg.targetdir..'/'..buildTarget..'.'..buildrule.language
					local scriptFilenameFull = scriptFilename:replace(ninja.rootVar, repoRoot)
					
					-- Test if contents are different before writing
					local writeToFile = true
					if os.isfile(scriptFilenameFull) then
						local f = io.open(scriptFilenameFull, 'r')
						local currentScript = f:read('*a')
						io.close(f)
						if currentScript == script then
							writeToFile = false
						end						
					end
					
					if writeToFile then
						local f = io.open(scriptFilenameFull, 'w+')
						f:write(script)
						io.close(f)
					end
					
					cmd = mkstring( { buildrule.language, scriptFilename, buildrule.absoutput })
					
					-- Don't add the script to the implicits 
					--implicits = implicits..' '..scriptFilenameFull
				end
				
				if buildrule.absOutput and #buildrule.absOutput > 0 then
					buildTarget = scope:getBest(buildrule.absOutput)
				end 
 				
				-- This fixes the issue where auto-generated header files placed in the source tree incorrectly get
				--  multiple build edges for the same target output, despite the command being the same for each cfg
				if not ninja.buildEdges[buildTarget] then
					if type(inputs) == 'table' then inputs = table.concat(inputs, ' ') end
	
					if #implicits > 0 then
						inputs = inputs .. ' | '..implicits
					end
	
					local buildCmd = 'exec '..inputs
					_p('build '..buildTarget..' : ' .. buildCmd)
					_p(' cmd='..cmd)
					
					if buildrule.description then
						_p(' description='..buildrule.description)
					end
					
					addBuildEdge(buildTarget, buildCmd, implicits, { cmd=cmd, description=buildrule.description })
				end
				table.insert(finalTargetInputs, buildTarget)
				
			end
			_p('')
		end
		return finalTargetInputs
	end
	return {}
end


function ninja.writeEnvironment(sln)
	local arch = ""
	
	_p('# Environment settings')
	--_p('tooldir=' .. tooldir)
	_p('arch=' .. arch)
	--_p('osver=' .. osver)
	--_p('compilerVer=' .. compilerVer)
	--_p('solution=' .. solutionName)

end

function ninja.writeRoot(buildFileDir)
	if _OPTIONS.absolutepaths then
		_p('workingdir=' .. repoRoot)
		_p('root=.')
		_p('builddir=' .. ninja.builddir)
	else
		_p('workingdir=' .. path.getrelative(buildFileDir, repoRoot))
		_p('root=.')
		_p('builddir=' .. path.getrelative(repoRoot, ninja.builddir))
	end
	_p('')
end

function ninja.writeExecRule()
	_p('rule exec')
	_p(' command=$cmd')
	_p(' description=$description')
	_p('build donothing: phony $builddir/.donothing')
	_p('build $builddir/.donothing: exec')
	_p(' cmd=touch $builddir/.donothing')
	_p(' description=Prepare environment')
	_p('')
end


--
-- Define any toolsets which are not yet defined
--  Run for each config, for each project
--
function ninja.writeToolsets(cfgs, scope)

local tmr = timer.start('ninja.writeToolsets')

	local function _pt(str)
		--toolsetNinjaStr = toolsetNinjaStr .. str .. '\n'
		_p(str)  
	end
	
	for _,cfg in cfgs
		:each() 
	do
		local toolsetName = cfg.toolset
		
		if not toolsetName or toolsetName == '' then
			cfg.toolset = 'gcc'
			printDebug('Toolset not specified for project ' .. cfg.project.name .. ' configuration ' .. cfg.shortname..'. Using '..cfg.toolset)
			toolsetName = cfg.toolset
		end 
		
        local toolset = premake.tools[toolsetName]
		if not toolset then
			error("Invalid toolset '" .. toolsetName .. "' in config " .. cfg.shortname)
		end
		
		-- Make sure we're outputting dependency files as ninja doesn't work properly without them
		if not config.hasDependencyFileOutput(cfg) then
		  	cfg.flags.CreateDependencyFile = 'CreateDependencyFile'
		end
		
		for _,tool in Seq:ipairs(toolset.tools)
			:where(function(t) return not scope:get(toolsetName .. '_' .. t.toolName);end)
			:where(function(t) return t.binaryName ~= '' end)
			:each()
		 do
			local toolName = toolsetName .. '_' .. tool.toolName
			local toolDef = {}
			scope:set(toolName, toolDef)

			local toolInputs = tool:decorateInputs(cfg, '$out', '$in')
			local depfileName = nil
			if tool:hasDependencyFileOutput(cfg) then
				depfileName = '$out' .. (tool.suffixes['depfileOutput'] or '')
			end
			
		    -- Set up tool vars
		    _pt('# Tool ' .. toolName)
		    
		    local toolVars = {}
			
	    	-- Extract command line args as build variables
		   
		    for k,v in pairs(toolInputs) do
		    	
		    	if not ninja.notBuildVar[k] then
		    		-- Register build variable
		    		local varName = toolName .. '_'..k
			    	toolDef[k] = v
			    	toolVars[k] = ninja.escVarName(varName)
			    	
			    	-- Write build variable default value
			    	if v ~= '' then
			    		-- Substitute $root
		    			v = string.replace(v, repoRoot, ninja.rootVar)
			    		
				    	local varName,found = scope:set(varName, v)
				    	if not found then
				    		_pt(varName .. '=' .. tostring(v))
				    	end
			    	else
			    		-- keep a record that it's blank
				    	scope:set(varName, v)
			    	end
			    else
			    	toolVars[k] = v
			    end
			end
			
			-- get the ordering correct
			for _,v in ipairs(tool.decorateArgs) do
				local varName = toolVars[v] or ninja.escVarName(toolName .. '_'..v)
				table.insert( toolVars, varName )
			end
			
			local description
			if tool.getDescription then
				description = ninja.escVarName(toolName..'_description')
			else
				description = tool.toolName.. ' $out'
			end
		    
			_pt('rule ' .. toolName)
				local cmdLine = tool:getCommandLine(toolVars)
				_pt('  command=' .. cmdLine )
				if depfileName then
				_pt('  depfile=' .. depfileName )
				end
				_pt('  description=' ..description)
			_pt('')
		end
	end
	
timer.stop(tmr)	 
end 

--
-- Write out a file which sets build variables & includes, then subninjas to the actual build
--
function ninja.generateDefaultBuild(sln, buildFileDir, scope)
	local filename = path.join(buildFileDir, 'build.ninja')
	local f = premake.generateStart(filename, true)

	if sln then
		_p('# %s solution build.ninja autogenerated by Premake', sln.name)
	else
		_p('# build.ninja autogenerated by Premake')
	end
	_p('# Ninja build is available to download at http://martine.github.com/ninja/')
	_p('# Type "ninja help" for usage help')
	_p('')
	
	ninja.writeRoot(buildFileDir)
		
	_p('# Main Build')
	local mainBuildNinjaFile = path.join(ninja.builddir,'buildedges.ninja')
	if _OPTIONS.absolutepaths then
		_p('subninja '..mainBuildNinjaFile)
	else
		_p('subninja '..path.getrelative(buildFileDir, mainBuildNinjaFile) )
	end
	_p('')
	
	if sln and scope.slntargets then
		local targets = scope.slntargets[sln.name]
		for _,includeSlnName in ipairs(sln.includesolution or {}) do
			mergeTargets(targets, scope.slntargets[includeSlnName])
		end
		
		ninja.writeDefaultTargets(targets)
	else
		ninja.writeDefaultTargets(scope.alltargets)
	end

	--[[
	local scope = ninja.newScope(buildFilename)
	
	_p('# Solution includes')
	if sln.includesolution then
		for _,slnName in ipairs(sln.includesolution) do
			local extSln = solution.list[slnName]
			if extSln then
				_p('subninja '..scope:getBest(ninja.getSolutionBuildFilename(extSln)))
			end 
		end
	end
	_p('')
		
	_p('include ' .. scope:getBest(ninja.getSolutionBuildFilename(sln)))
	]]
	
	premake.generateEnd(f, filename)
end