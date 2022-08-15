# Roblox-Parallel-Worker

A ModuleScript library designed to abstract away Roblox's Actor model for parallel execution in favor of a simple task distribution module which handles the lifetime execution of a parallel task!

## Usage

TaskModules are ModuleScripts that return a table optionally containing any of the following functions:

- `TaskModule:Execute(...: any)`
- `TaskModule:Update(deltaTime: number)`
- `TaskModule:IsFinished() -> boolean`
- `TaskModule:GetResults() -> ...any`

When a task is dispatched, each function declared in a module will be called as such:

|  Function  |     When does it get called?    | In Parallel? |
|------------|---------------------------------|--------------|
| Execute    | Once when a task is dispatched. |      Yes     |
| Update     | On each RunService Heartbeat.   |      Yes     |
| IsFinished | Before/After Update() calls.    |      Yes     |
| GetResults | When a task is finishing.       |      No      |

The `Execute` function can be used for a single task to be performed in the dispatched task, or to initialize data for the task instance to use. The `self` variable in your TaskModule's functions will refer to the unique task execution instance, so you can store any lifetime variables of the task in that table. Arguments passed into the ParallelWorker's `Dispatch` and `Invoke` methods are passed in as parameters.

The `Update` function can be used for a parallel routine that loops on the RunService's Heartbeat. In the body of `Update`, you can cancel execution of the task via `self:Finish()`.

The `IsFinished` function is called when an `Update` function is defined and can be used to statefully terminate execution of the update task loop, instead of calling `self:Finish()`.

The `GetResults` function is called upon the task marking itself as complete. This is called even if there's only an `Execute` routine that completes. It can be used to return data back if the task was dispatched through `ParallelWorker:Invoke(...)`.

## API

`ParallelWorker.new(taskModule: ModuleScript, allocate: number?) -> ParallelWorker`<br/>
Creates a new ParallelWorker that dispatches parallel tasks of the provided ModuleScript.<br/>
The optional `allocate` parameter lets you pre-allocate a set number of actors for tasks to use.

`ParallelWorker:Dispatch(...any) -> Dispatch`<br/>
Dispatches a new parallel task of the worker's task module and returns a Dispatch object representing the execution of the task. The task can be cancelled outside of a parallel context by calling `Dispatch:Cancel()`.

`ParallelWorker:Invoke(...any) -> (boolean, ...any) [Yields]`<br/>
Dispatches a new parallel task of the worker's task module and yields the calling thread until execution is completed. Returns true if the task was finished successfully, as well as any data that was received from the task module's GetResults function (if one was defined).

`Dispatch:Cancel() -> boolean`<br/>
Cancels the parallel task associated with this dispatch. Returns true if the cancellation was performed, or false if the task was finished/cancelled already.
