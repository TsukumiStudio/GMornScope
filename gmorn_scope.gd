extends RefCounted
## A one-way cancellation boundary for main-thread callbacks and owned cleanup.
## Create a new instance for each visit or operation. Explicitly call cancel().

var _cancelled: bool = false
var _next_id: int = 1
var _cleanups: Array[Dictionary] = []


func is_cancelled() -> bool:
	return _cancelled


## Register a zero-argument cleanup. A closed scope runs valid cleanup immediately.
## Returns a positive registration ID, or zero if closed or the callable is invalid.
func add_cleanup(action: Callable) -> int:
	if not action.is_valid():
		return 0
	if _cancelled:
		action.call()
		return 0
	var id: int = _next_id
	_next_id += 1
	_cleanups.append({"id": id, "action": action})
	return id


## Remove a completed operation's cleanup without executing it.
func release_cleanup(id: int) -> bool:
	if _cancelled or id <= 0:
		return false
	for index: int in range(_cleanups.size()):
		if int(_cleanups[index]["id"]) == id:
			_cleanups.remove_at(index)
			return true
	return false


## Call synchronously only while active. Does not interrupt work already started.
## The caller is responsible for supplying the callable's required arguments.
func dispatch(action: Callable, args: Array = []) -> bool:
	if _cancelled or not action.is_valid():
		return false
	action.callv(args)
	return true


## Mark closed before invoking cleanup, detach registrations, then run in reverse.
## Repeated or reentrant cancellation does nothing. Invalid targets are skipped.
func cancel() -> void:
	if _cancelled:
		return
	_cancelled = true
	var pending: Array[Dictionary] = _cleanups
	_cleanups = []
	while not pending.is_empty():
		var entry: Dictionary = pending.pop_back()
		var action: Callable = entry["action"]
		if action.is_valid():
			action.call()
