--------------------------------------------------------------------------------------------------------------------------------
-- ParallelWorker
-- Author: MaximumADHD (@CloneTrooper1019)
--------------------------------------------------------------------------------------------------------------------------------
--[==========================================================================================================================[--

	== INFO ==
	
	ParallelWorker is a ModuleScript designed to abstract away Roblox's Actor model for parallel execution
	in favor of a simple task distribution module which handles the lifetime execution of a parallel task!

	TaskModules are ModuleScripts that return a table 
	optionally containing any of the following functions:
	
		• TaskModule:Execute(...: any)
		• TaskModule:Update(deltaTime: number)
		• TaskModule:IsFinished() -> boolean
		• TaskModule:GetResults() -> ...any

	When a task is dispatched, each function declared
	in a module will be called as such:

	|  Function  |     When does it get called?    | In Parallel? |
	+------------+---------------------------------+--------------+
	| Execute    | Once when a task is dispatched. |      ye      |
	| Update     | On each RunService Heartbeat.   |      ye      |
	| IsFinished | Before/After Update() calls.    |      ye      |
	| GetResults | When a task is finishing.       |      no      |
	
	The Execute function can be used for a single task to be performed in the dispatched task, 
	or to initialize data for the task instance to use. The 'self' variable in your TaskModule's
	functions will refer to the unique task execution instance, so you can store any lifetime
	variables of the task in that table. Arguments passed into the ParallelWorker's 'Dispatch' 
	and 'Invoke' methods can be accessed from the arguments of the function.
	
	The Update function can be used for a parallel routine that loops on the RunService's Heartbeat.
	In the body of Update, you can cancel execution of the task via self:Finish()
	
	The IsFinished function is called when an Update function is defined and can be used to
	statefully terminate execution of the update task loop, instead of calling self:Finish()
	
	The GetResults function is called upon the task marking itself as complete. This is called
	even if there's only an Execute routine that completes. It can be used to return data back
	if the task was dispatched through ParallelWorker:Invoke()
	
	== API ==
	
	+-----------------------------------------------------------------------------------------------------
	| ParallelWorker.new(taskModule: ModuleScript, allocate: number?) -> ParallelWorker
	+-----------------------------------------------------------------------------------------------------
	  Creates a new ParallelWorker that dispatches parallel tasks of the provided ModuleScript.
	  The optional 'allocate' parameter lets you pre-allocate a set number of actors for tasks to use.
	  
	+-----------------------------------------------------------------------------------------------------
	| ParallelWorker:Dispatch(...any) -> Dispatch
	+-----------------------------------------------------------------------------------------------------
	  Dispatches a new parallel task of the worker's task module and returns a Dispatch object
	  representing the execution of the task. The task can be cancelled outside of a parallel 
	  context by calling Dispatch:Cancel()
	 
	+-----------------------------------------------------------------------------------------------------
	| ParallelWorker:Invoke(...any) -> (boolean, ...any) [Yields]
	+-----------------------------------------------------------------------------------------------------
	  Dispatches a new parallel task of the worker's task module and yields the calling thread
	  until execution is completed. Returns true if the task was finished successfully, as well as
	  any data that was received from the task module's GetResults function (if one was defined)
	  
	+-----------------------------------------------------------------------------------------------------
	| Dispatch:Cancel() -> boolean
	+-----------------------------------------------------------------------------------------------------
	  Cancels the parallel task associated with this dispatch. Returns true if the cancellation
	  was performed, or false if the task was finished/cancelled already.
	
--]==========================================================================================================================]
--
--------------------------------------------------------------------------------------------------------------------------------

--!strict

local ParallelWorker = {}
ParallelWorker.__index = ParallelWorker

local Dispatch = {}
Dispatch.__index = Dispatch

local HttpService = game:GetService("HttpService")
local RunService = game:GetService("RunService")

if not RunService:IsRunning() then
	error("Cannot require ParallelWorker in edit mode at this time!", 2)
end

local baseWorker = script:WaitForChild("Worker")
local bin: any = script:WaitForChild("ParallelTasks")

export type Worker = typeof(baseWorker)
export type Dispatch = typeof(setmetatable({} :: DispatchState, Dispatch))
export type ParallelWorker = typeof(setmetatable({} :: { _module: ModuleScript }, ParallelWorker))

export type DispatchState = {
	_thread: string,
	_worker: Worker,
	_finished: RBXScriptSignal,
}

if RunService:IsClient() then
	local Players = game:GetService("Players")
	local player = assert(Players.LocalPlayer)

	bin = script:WaitForChild("ParallelTasks")
	bin.Parent = player:WaitForChild("PlayerScripts")
else
	bin = script.ParallelTasks:Clone()
	bin.Parent = game:GetService("ServerScriptService")
end

-- A LinkedList of available Workers
-- to be used by the parallel dispatcher.

local WORKER_POOL = {
	Back = nil :: Worker?,
	Front = nil :: Worker?,
	Next = {} :: { [Worker]: Worker },
}

-- A dictionary mapping thread ids to threads
-- waiting to be resumed from an Invoke call.

local INVOKE_POOL: { [string]: thread } = {}

-- Queues the provided worker back into the
-- worker pool, clearing its label and thread.

local function queueWorker(worker: Worker)
	local back = WORKER_POOL.Back

	if back then
		WORKER_POOL.Next[back] = worker
	elseif not WORKER_POOL.Front then
		WORKER_POOL.Front = worker
		WORKER_POOL.Back = worker
	end

	worker.Name = "[IDLE]"
	WORKER_POOL.Back = worker
	worker:SetAttribute("Thread", nil)
end

-- Allocates a new worker instance with a handler for its
-- Finished event being fired. A Script or LocalScript is
-- dropped into the worker to handle mounting it to the
-- ParallelTasks module. Can optionally be put into
-- queue for any parallel task to immediately use.

local function allocateWorker(intoQueue: boolean?): Worker
	local worker = baseWorker:Clone()
	local finished = worker.Finished
	local thread: BaseScript

	finished.Event:Connect(function(finished, thread, ...)
		local invoke = INVOKE_POOL[thread]

		if invoke then
			task.spawn(invoke, finished, ...)
			INVOKE_POOL[thread] = nil
		end

		queueWorker(worker)
	end)

	if RunService:IsServer() then
		thread = script.Server:Clone()
	else
		thread = script.Client:Clone()
	end

	worker.Parent = bin
	thread.Parent = worker
	thread.Disabled = false

	if intoQueue then
		queueWorker(worker)
	end

	return worker
end

-- Gets or creates a worker to be used for the execution
-- of the provided ModuleScript. The worker gets labeled
-- after the module being executed, and a new thread is
-- generated as a cancellation token for the task.

local function getWorker(module: ModuleScript): (Worker, string)
	local front = WORKER_POOL.Front
	local result: Worker

	if front then
		WORKER_POOL.Front = WORKER_POOL.Next[front]
		WORKER_POOL.Next[front] = nil

		if WORKER_POOL.Back == front then
			WORKER_POOL.Back = nil
		end

		result = front
	else
		result = allocateWorker()
	end

	local id = module.Name
	result.Name = id

	local thread = HttpService:GenerateGUID(false)
	result:SetAttribute("Thread", thread)

	return result, thread
end

-- Creates a new ParallelWorker that will require and execute the provided
-- ModuleScript's routines as a parallel task upon being dispatched or invoked.
-- Optionally allocates a provided number of actors to be ready for use.

function ParallelWorker.new(target: ModuleScript, allocate: number?): ParallelWorker
	local worker = { _module = target }

	for i = 1, allocate or 0 do
		allocateWorker(true)
	end

	return setmetatable(worker, ParallelWorker)
end

-- Dispatches a parallel task and returns a Dispatch object
-- representing that execution. The execution can be cancelled
-- by calling the Dispatch object's Cancel() function.

function ParallelWorker.Dispatch(self: ParallelWorker, ...: any): Dispatch
	local worker, thread = getWorker(self._module)
	local finished = worker.Finished.Event

	local dispatch: DispatchState = {
		_thread = thread,
		_worker = worker,
		_finished = finished,
	}

	local execute = worker.Execute
	execute:Fire(worker, self._module, ...)

	return setmetatable(dispatch, Dispatch)
end

-- Dispatches a parallel task and yields the running thread
-- until completed. Will return a bool describing if the
-- task was completed (true) or cancelled (false),
-- as well as any data provided by the module's
-- optionally defined GetResults function.

function ParallelWorker.Invoke(self: ParallelWorker, ...: any): ...any
	local worker, thread = getWorker(self._module)

	local invoke = coroutine.running()
	INVOKE_POOL[thread] = invoke

	local execute = worker.Execute
	task.defer(execute.Fire, execute, worker, self._module, ...)

	return coroutine.yield()
end

-- Cancels the dispatch task and queues its worker
-- into the back of the worker queue for later use.

function Dispatch.Cancel(self: Dispatch): boolean
	local worker = self._worker

	if worker:GetAttribute("Thread") == self._thread then
		worker:SetAttribute("Thread", nil)
		worker.Finished:Fire(false)
		return true
	end

	return false
end

return ParallelWorker
