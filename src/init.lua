local ParallelWorker = {}
ParallelWorker.__index = ParallelWorker

local Dispatch = {}
Dispatch.__index = Dispatch

local HttpService = game:GetService("HttpService")
local RunService = game:GetService("RunService")

local ready = false
local bin

task.spawn(function ()
	if RunService:IsServer() then
		bin = script.ParallelTasks:Clone()
		bin.Parent = game:GetService("ServerScriptService")
	else
		local Players = game:GetService("Players")
		local player = Players.LocalPlayer
		
		while not player do
			Players.Changed:Wait()
			player = Players.LocalPlayer
		end
		
		bin = script:WaitForChild("ParallelTasks")
		bin.Parent = player:WaitForChild("PlayerScripts")
	end
	
	bin.Archivable = false
	ready = true
end)

type _Dispatch =
{
	Thread: string;
	Worker: Worker;
	Finished: RBXScriptSignal;
}

type Worker = Actor &
{
	Finished: BindableEvent;
	Execute: BindableEvent?;
}

type WorkerPool =
{
	Next: { [Worker]: Worker };
	Front: Worker?;
	Back: Worker?;
}

type Dispatch = typeof(setmetatable({} :: _Dispatch, Dispatch))
type ParallelWorker = typeof(setmetatable({} :: { Module: ModuleScript }, ParallelWorker))

local workerPool: WorkerPool =
{
	Next = {};
	Back = nil;
	Front = nil;
}

local function queueWorker(worker: Worker)
	local back = workerPool.Back
	
	if back then
		workerPool.Next[back] = worker
	elseif not workerPool.Front then
		workerPool.Front = worker
		workerPool.Back = worker
	end
	
	workerPool.Back = worker
	worker:SetAttribute("Thread", nil)
end

local function allocateWorker(intoQueue: boolean?): Worker
	local actor = Instance.new("Actor")
	actor.Archivable = false
	actor.Name = "Worker"
	
	local finished = Instance.new("BindableEvent")
	finished.Name = "Finished"
	finished.Parent = actor

	local worker = actor :: Worker
	local thread: BaseScript
	
	finished.Event:Connect(function ()
		queueWorker(worker)
	end)
	
	if RunService:IsServer() then
		thread = script.Server:Clone()
	else
		thread = script.Client:Clone()
	end
	
	actor.Parent = bin
	thread.Parent = actor
	thread.Disabled = false
	
	if intoQueue then
		queueWorker(worker)
	end
	
	return worker
end

local function getWorker(): Worker
	while not ready do
		task.wait()
	end
	
	local front = workerPool.Front
	
	if front then
		workerPool.Front = workerPool.Next[front]
		workerPool.Next[front] = nil
		
		if workerPool.Back == front then
			workerPool.Back = nil
		end

		return front
	else
		return allocateWorker()
	end
end

function ParallelWorker.new(target: ModuleScript, allocate: number?): ParallelWorker
	local worker = { Module = target }
	
	for i = 1, allocate or 0 do
		allocateWorker(true)
	end
	
	return setmetatable(worker, ParallelWorker)
end

function Dispatch.new(worker: Worker): Dispatch
	local finished = worker.Finished
	
	local dispatch =
	{
		Worker = worker;
		Thread = worker.Name;
		Finished = finished.Event;
	}

	return setmetatable(dispatch, Dispatch)
end

function ParallelWorker.Dispatch(self: ParallelWorker, ...: any): Dispatch
	local worker = getWorker()
	
	local thread = HttpService:GenerateGUID(false)
	worker:SetAttribute("Thread", thread)
		
	local execute = worker:WaitForChild("Execute")
	execute:Fire(worker, thread, self.Module, ...)
	
	return Dispatch.new(worker)
end

function ParallelWorker.Invoke(self: ParallelWorker, ...: any): ...any
	local dispatch: Dispatch = self:Dispatch(...)
	return dispatch.Finished:Wait()
end

function Dispatch.Cancel(self: Dispatch): boolean
	local worker = self.Worker
	
	if worker.Name == self.Thread then
		worker:SetAttribute("Thread", nil)
		worker.Finished:Fire(false)
		return true
	end
	
	return false
end

return ParallelWorker