--------------------------------------------------------------------------------------------------------------------------------
-- ParallelTasks
-- Author: MaximumADHD (@CloneTrooper1019)
--------------------------------------------------------------------------------------------------------------------------------
-- This ModuleScript acts as the hub for actors to bind their tasks to.
-- It is moved to the following locations at run-time:
--
--    • [SERVER] -> ServerScriptService.
--    • [CLIENT] -> LocalPlayer's PlayerScripts.
--
-- Depending on the execution context, ParallelWorker will either drop a Script
-- or a LocalScript into the module to begin parallel execution of an Actor.
--------------------------------------------------------------------------------------------------------------------------------

--!strict
local RunService = game:GetService("RunService")

-- Functions that may be defined for the table returned by
-- the ModuleScript passed into ParallelWorker.new()

export type Module = {
	-- Invoked in parallel on each heartbeat.
	Update: (any, number) -> ()?,

	-- Invoked in parallel once upon a task being started.
	Execute: (any, ...any) -> ()?,

	-- Called when the module is finished to fetch any output data.
	GetResults: (any) -> (...any)?,

	-- Called after each heartbeat to check if the task is finished.
	IsFinished: (any) -> (boolean)?,
}

-- Expected hierarchy of an Actor hooked
-- into this ModuleScript at run-time.

export type TaskActor = Actor & {
	Execute: BindableEvent,
	Finished: BindableEvent,
}

--------------------------------------------------------------------------------------------------------------------------------
-- Worker Class
--------------------------------------------------------------------------------------------------------------------------------

-- The Worker class handles the lifecycle of a parallel task.
-- They are generated when a TaskActor's Execute event is fired
-- with a ModuleScript (returning type 'Module') to execute.

local Worker = {}

export type Worker = {
	_module: Module,
	_thread: string,
	_finished: boolean,
	_taskActor: TaskActor,
}

-- The functions of the Module are called with
-- 'self' assigned to a Worker instance.
--
-- This indexer provides inheritance to the original
-- module table, and the functions of the Worker itself.

function Worker.__index(self: Worker, key: any)
	local module = rawget(self, "_module")
	local value

	if module then
		value = module[key]
	end

	if value == nil then
		value = Worker[key]
	end

	return value
end

-- In a Module that has an Update routine,
-- this can be called to terminate execution.
-- Alternatively, IsFinished can be implemented.

function Worker.Finish(self: Worker)
	if self._finished then
		return
	end

	local actor = self._taskActor
	local finished = actor.Finished

	local module: Module = self._module
	self._finished = true

	if typeof(module.GetResults) == "function" then
		finished:Fire(true, self._thread, module.GetResults(self))
	else
		finished:Fire(true, self._thread)
	end
end

-- Default fallback for IsFinished if unimplemented.
-- Checks if Worker:Finish() has been called.

function Worker.IsFinished(self: Worker): boolean?
	return self._finished
end

--------------------------------------------------------------------------------------------------------------------------------
-- Execution Logic
--------------------------------------------------------------------------------------------------------------------------------

-- Callback function for when an Actor's Execute event is fired.
-- Handles dispatching a parallel task of the provided target
-- ModuleScript, with any provided arguments passed into
-- the module's Execute routine.

local function executeModule(actor: TaskActor, target: ModuleScript, ...: any)
	local success, module: Module? = pcall(require, target)
	assert(success and typeof(module) == "table", "Error loading module while executing actor!")

	local thread = actor:GetAttribute("Thread")
	assert(thread, "No thread assigned while executing actor!")

	local worker = setmetatable({
		_module = module,
		_thread = thread,
		_finished = false,
		_taskActor = actor,
	}, Worker)

	local execute = module.Execute
	local update = module.Update

	local canUpdate = false
	local memCat = actor.Name

	if typeof(update) == "function" then
		local conn: RBXScriptConnection

		conn = RunService.Heartbeat:ConnectParallel(function(dt: number)
			if actor:GetAttribute("Thread") == thread then
				if not worker:IsFinished() then
					debug.setmemorycategory(memCat)
					update(worker, dt)
				end
			else
				-- Task has been cancelled.
				task.synchronize()
				conn:Disconnect()
				return
			end

			if worker:IsFinished() then
				-- Task has been finished.
				task.synchronize()
				conn:Disconnect()
			end
		end)

		canUpdate = true
	end

	-- Desync and call the worker's
	-- 'Execute' routine if it exists.
	task.desynchronize()

	if typeof(execute) == "function" then
		debug.setmemorycategory(memCat)
		execute(worker, ...)
	end

	-- Automatically finish if there's
	-- no 'Update' routine to loop on.

	if not canUpdate then
		worker:Finish()
	end
end

-- Function returned to the Script/LocalScript
-- mounting its parent Actor to ParallelTasks.

return function(actor: TaskActor)
	local execute = actor.Execute
	execute.Event:Connect(executeModule)
end
