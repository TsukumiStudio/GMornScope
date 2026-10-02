extends SceneTree

const Scope = preload("gmorn_scope.gd")
const MAX_FRAMES: int = 240

class Receiver extends Node:
	var calls: int = 0
	func receive() -> void:
		calls += 1

class LifetimeProbe extends RefCounted:
	func clean() -> void:
		pass

class VisitOwner extends Node:
	const ScopeScript = preload("gmorn_scope.gd")
	var visit = null
	var counts: Dictionary = {"old": 0, "new": 0}
	func begin() -> void:
		stop()
		visit = ScopeScript.new()
	func stop() -> void:
		if visit != null:
			visit.cancel()
			visit = null
	func completion(label: String) -> Callable:
		var captured_visit = visit
		return func():
			captured_visit.dispatch(func(): counts[label] += 1)
	func _exit_tree() -> void:
		stop()

var _checks: int = 0
var _failures: Array[String] = []
var _frames: int = 0
var _finished: bool = false


func _initialize() -> void:
	AudioServer.set_bus_mute(0, true)
	call_deferred("_run")


func _process(_delta: float) -> bool:
	_frames += 1
	if _frames >= MAX_FRAMES and not _finished:
		_expect(false, "frame watchdog exceeded")
		_finish()
	return false


func _expect(condition: bool, label: String) -> void:
	_checks += 1
	if not condition:
		_failures.append(label)


func _run() -> void:
	var force_failure: bool = false
	var fault_callback_error: bool = false
	for argument: String in OS.get_cmdline_user_args():
		if argument == "--force-failure":
			force_failure = true
		elif argument == "--fault-callback-error":
			fault_callback_error = true
		else:
			_expect(false, "unknown argument: " + argument)
	_test_dispatch()
	_test_cleanup_order()
	_test_reentrant_and_late()
	_test_release_and_reference()
	_test_freed_callable()
	await _test_visit_reentry()
	await _test_tween_ownership()
	if fault_callback_error:
		_test_callback_error()
	if force_failure:
		_expect(false, "deliberate failure verifies nonzero exit")
	_finish()


func _test_callback_error() -> void:
	# Deliberate runtime errors, not a normal passing test. Godot has no generic
	# script exception handling here; the invoking fixture must reject the log
	# even if subsequent caller code reaches a positive JSON summary.
	var scope = Scope.new()
	scope.dispatch(_callback_error)
	scope.add_cleanup(_callback_error)
	scope.cancel()
	_expect(scope.is_cancelled(), "callback error cannot reopen a closed scope")
	scope.cancel()


func _callback_error() -> void:
	var empty: Array = []
	var value: Variant = empty[0]
	print(value) # Unreachable: deliberate invalid-index runtime error above.


func _test_dispatch() -> void:
	var scope = Scope.new()
	var received: Array = []
	var action: Callable = func(value: int): received.append(value)
	_expect(not scope.is_cancelled(), "new scope is active")
	_expect(scope.dispatch(action, [7]), "active dispatch accepted")
	_expect(received == [7], "dispatch forwards arguments exactly once")
	_expect(not scope.dispatch(Callable()), "invalid dispatch rejected")
	scope.cancel()
	_expect(scope.is_cancelled(), "cancel marks terminal")
	_expect(not scope.dispatch(action, [8]), "stale dispatch rejected")
	_expect(received == [7], "stale dispatch leaves prior result unchanged")
	_expect(scope.add_cleanup(Callable()) == 0, "invalid cleanup rejected")


func _test_cleanup_order() -> void:
	var scope = Scope.new()
	var order: Array = []
	scope.add_cleanup(func(): order.append("A"))
	scope.add_cleanup(func(): order.append("B"))
	scope.add_cleanup(func(): order.append("C"))
	scope.cancel()
	_expect(order == ["C", "B", "A"], "cleanup reverses registration order")
	scope.cancel()
	_expect(order == ["C", "B", "A"], "double cancel executes each cleanup once")


func _test_reentrant_and_late() -> void:
	var scope = Scope.new()
	var order: Array = []
	var results: Array = []
	var first_id: int = scope.add_cleanup(func(): order.append("first"))
	scope.add_cleanup(func():
		order.append("outer")
		results.append(scope.is_cancelled())
		scope.cancel()
		results.append(scope.dispatch(func(): order.append("wrong")))
		results.append(scope.release_cleanup(first_id))
		results.append(scope.add_cleanup(func(): order.append("late")))
	)
	scope.cancel()
	_expect(order == ["outer", "late", "first"], "reentrant cancel and late cleanup order")
	_expect(results == [true, false, false, 0], "closed before cleanup and snapshot immutable")
	var late_id: int = scope.add_cleanup(func(): order.append("after"))
	_expect(late_id == 0, "registration after cancellation returns zero")
	scope.cancel()
	_expect(order == ["outer", "late", "first", "after"], "late cleanup runs immediately once")


func _test_release_and_reference() -> void:
	var scope = Scope.new()
	var calls: Array = []
	var id: int = scope.add_cleanup(func(): calls.append(1))
	_expect(id > 0, "active cleanup has a positive ID")
	_expect(scope.release_cleanup(id), "completed cleanup can be released")
	_expect(not scope.release_cleanup(id), "released ID is absent")
	_expect(not scope.release_cleanup(-1), "invalid ID rejected")
	var next_id: int = scope.add_cleanup(func(): calls.append(2))
	_expect(next_id > id, "released IDs are never reused")
	scope.cancel()
	_expect(calls == [2], "released cleanup is not executed")
	_expect(not scope.release_cleanup(next_id), "closed registry cannot be released")
	var reference_scope = Scope.new()
	# Separate stack frames keep temporary Callable/get_ref values from retaining
	# the probe while checking whether release removes the registry's ownership.
	var registration: Dictionary = _register_probe(reference_scope)
	var weak_probe: WeakRef = registration["weak"]
	var reference_id: int = registration["id"]
	_expect(_probe_is_alive(weak_probe), "registration retains reference-counted target")
	_expect(reference_scope.release_cleanup(reference_id), "target cleanup registration released")
	_expect(not _probe_is_alive(weak_probe), "release drops target reference")
	reference_scope.cancel()


func _register_probe(scope) -> Dictionary:
	var probe = LifetimeProbe.new()
	var result: Dictionary = {"weak": weakref(probe)}
	result["id"] = scope.add_cleanup(_probe_cleanup(probe))
	return result


func _probe_is_alive(probe: WeakRef) -> bool:
	return probe.get_ref() != null


func _probe_cleanup(probe: LifetimeProbe) -> Callable:
	# Capture a strong reference explicitly; plain object-method Callable ownership
	# is not used as an assumption for this lifetime check.
	return func(): probe.clean()


func _test_freed_callable() -> void:
	var scope = Scope.new()
	var receiver = Receiver.new()
	var action: Callable = receiver.receive
	var live_calls: Array = []
	scope.add_cleanup(func(): live_calls.append("live"))
	scope.add_cleanup(action)
	receiver.free()
	_expect(not action.is_valid(), "freed Node invalidates callable")
	_expect(not scope.dispatch(action), "freed target dispatch rejected")
	scope.cancel()
	_expect(live_calls == ["live"], "invalid cleanup does not prevent live cleanup")
	var during_cancel = Receiver.new()
	var later_action: Callable = during_cancel.receive
	var destruction_scope = Scope.new()
	destruction_scope.add_cleanup(later_action)
	destruction_scope.add_cleanup(func(): during_cancel.free())
	destruction_scope.cancel()
	_expect(not later_action.is_valid(), "earlier cleanup may destroy a later callable target")
	_expect(destruction_scope.is_cancelled(), "target destruction does not reopen cleanup registration")


func _test_visit_reentry() -> void:
	var owner = VisitOwner.new()
	root.add_child(owner)
	owner.begin()
	var old_completion: Callable = owner.completion("old")
	# Schedule actual deferred work; cancel and reenter before it is delivered.
	old_completion.call_deferred()
	owner.stop()
	root.remove_child(owner) # _exit_tree also calls stop.
	root.add_child(owner)
	owner.begin()
	var new_completion: Callable = owner.completion("new")
	new_completion.call_deferred()
	await process_frame
	await process_frame
	_expect(owner.counts == {"old": 0, "new": 1}, "deferred old work cannot affect a new visit")
	var last_completion: Callable = owner.completion("new")
	last_completion.call_deferred()
	root.remove_child(owner)
	await process_frame
	_expect(owner.counts["new"] == 1, "tree exit cancels delayed visit work")
	owner.free()


func _test_tween_ownership() -> void:
	var first_scope = Scope.new()
	var second_scope = Scope.new()
	var first = Node2D.new()
	var second = Node2D.new()
	root.add_child(first)
	root.add_child(second)
	var first_tween: Tween = first.create_tween()
	var second_tween: Tween = second.create_tween()
	# Paused tweens are manually stepped to avoid dependence on wall-clock FPS.
	first_tween.pause()
	second_tween.pause()
	first_tween.tween_property(first, "position:x", 100.0, 1.0)
	second_tween.tween_property(second, "position:x", 100.0, 1.0)
	first_scope.add_cleanup(func():
		if first_tween.is_valid(): first_tween.kill()
	)
	second_scope.add_cleanup(func():
		if second_tween.is_valid(): second_tween.kill()
	)
	first_tween.custom_step(0.25)
	second_tween.custom_step(0.25)
	_expect(is_equal_approx(first.position.x, 25.0), "owned tween progresses before cancellation")
	first_scope.cancel()
	var stopped_position: float = first.position.x
	_expect(not first_tween.is_valid(), "cancel invalidates the owned tween")
	_expect(second_tween.is_valid(), "other scope's tween remains valid")
	second_tween.custom_step(0.25)
	await process_frame
	await process_frame
	_expect(is_equal_approx(first.position.x, stopped_position), "cancelled property remains unchanged later")
	_expect(is_equal_approx(second.position.x, 50.0), "independent scope's tween continues")
	var second_calls: Array = []
	_expect(second_scope.dispatch(func(): second_calls.append(1)), "independent scope remains active")
	_expect(second_calls == [1], "independent callback delivered once")
	second_scope.cancel()
	first.free()
	second.free()


func _finish() -> void:
	if _finished:
		return
	_finished = true
	var passed: bool = _failures.is_empty() and _checks > 0
	print("GMORN_SCOPE_VERIFY_JSON " + JSON.stringify({
		"schema": 1, "status": "pass" if passed else "fail",
		"checks": _checks, "failures": _failures, "frames": _frames,
		"max_frames": MAX_FRAMES, "engine_execution": "executed"
	}))
	quit(0 if passed else 1)
