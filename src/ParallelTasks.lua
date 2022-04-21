--!strict
local RunService = game:GetService("RunService")

type Module =
{
	Update: (any, number) -> ()?;
	Execute: (any, ...any) -> ()?;
	GetResults: (any) -> (...any)?;
	IsFinished: (any) -> (boolean)?;
}

type TaskActor = Actor &
{
	Execute:  BindableEvent;
	Finished: BindableEvent;
}

----------------------------------------------------------------

local heartbeat: RBXScriptSignal = RunService.Heartbeat
local connect: (RBXScriptSignal, (...any) -> ()) -> RBXScriptConnection = heartbeat.Connect

local FFlagParallelLua = pcall(function ()
	connect = (heartbeat :: any).ConnectParallel
end)

----------------------------------------------------------------

local Worker = {}

type _Worker = 
{
	_driver: Module, 
	_finished: boolean,
	_taskActor: TaskActor;
}

type Worker = typeof(setmetatable({} :: _Worker, Worker))

function Worker.new(actor: TaskActor, driver: Module): Worker
	local worker = 
	{
		_driver = driver;
		_finished = false;
		_taskActor = actor;
	}
	
	return setmetatable(worker, Worker)
end

function Worker:__index(key: any)
	local driver = rawget(self, "_driver")
	local value
	
	if driver then
		value = driver[key]
	end
	
	if value == nil then
		value = Worker[key]
	end
	
	return value
end

function Worker.Synchronize()
	if FFlagParallelLua then
		task.synchronize()
	end
end

function Worker.Desynchronize()
	if FFlagParallelLua then
		task.desynchronize()
	end
end

function Worker.Finish(self: Worker)
	if self._finished then
		return
	end
	
	local actor = self._taskActor
	local finished = actor.Finished
	
	local module: Module = self._driver
	self._finished = true
	
	if typeof(module.GetResults) == "function" then
		finished:Fire(true, module.GetResults(self))
	else
		finished:Fire(true)
	end
end

function Worker.IsFinished(self: Worker): boolean?
	return self._finished
end

----------------------------------------------------------------

local heartbeat: RBXScriptSignal = RunService.Heartbeat
local connectParallel: (RBXScriptSignal, (...any) -> ()) -> RBXScriptConnection = heartbeat.Connect

local IS_PARALLEL = pcall(function ()
	connectParallel = (heartbeat :: any).ConnectParallel
end)

if not IS_PARALLEL then
	warn("WARNING: Parallel Lua is disabled in this VM! Requests will not be executed in parallel.")
end

local function executeModule(actor: TaskActor, thread: string, target: ModuleScript, ...: any)
	local success, module: Module? = pcall(require, target)
	
	if success and typeof(module) == "table" then
		local worker = Worker.new(actor, module)
		local execute = module.Execute
		local update = module.Update
		
		local canUpdate = false
		actor:SetAttribute("Thread", thread)
		
		if typeof(update) == "function" then
			local conn: RBXScriptConnection
			
			conn = connectParallel(heartbeat, function (dt: number)
				if actor:GetAttribute("Thread") == thread then
					if not worker._finished then
						update(worker, dt)
					end
				else
					worker:Synchronize()
					conn:Disconnect()
					return
				end
				
				if worker._finished then
					worker:Synchronize()
					conn:Disconnect()
				end
			end)
			
			canUpdate = true
		end
		
		worker:Desynchronize()
		
		if typeof(execute) == "function" then
			execute(worker, ...)
		end
		
		if not canUpdate then
			worker:Finish()
		end
	else
		error("No module target while executing actor!")
	end
end

local function mountExecutor(actor)
	local execute = Instance.new("BindableEvent")
	execute.Event:Connect(executeModule)
	execute.Name = "Execute"
	execute.Parent = actor
end

return mountExecutor