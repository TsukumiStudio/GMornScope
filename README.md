# GMornScope

## Overview

A small, explicit cancellation scope for Godot callbacks and owned cleanup.
Use one scope per scene visit, notification, or temporary effect to block old
callbacks after cancellation and run owned cleanup once.

## Requirements

- Godot standard types only. Verified with Godot 4.7
  (`4.7.stable.official.5b4e0cb0f`); other versions have not been tested.
- No plugin, autoload, game assets, network access, or other GMorn runtime dependency.
- Optional verification tools: POSIX shell; Python 3 for static protocol tests.
  Wall-time and process-group supervision are the calling environment's responsibility.

**Verification status:** 38 runtime checks passed with Dummy audio and headless
execution. Editor import, a renamed-addon consumer, PCK export, and startup from
that PCK in an empty directory passed without errors or warnings. Deliberate
assertion-result failure and callback runtime errors were rejected; a separate
faulty copy retaining released cleanup failed three checks. Seven Python
fixture-protocol tests and the shell syntax check also passed. These checks cover
the scope API, not visual rendering or other Godot versions.

## Features

- Reject callbacks after a one-way cancellation boundary.
- Run registered cleanup once in reverse order, including reentrant cancellation.
- Release completed cleanup without executing it and keep independent scopes separate.

This clean implementation does not schedule work, replace an audio clock,
collect traces, or run a test suite for your project.

| Method | Behavior |
| --- | --- |
| `is_cancelled() -> bool` | Read the one-way terminal state. |
| `add_cleanup(action: Callable) -> int` | Register a zero-argument cleanup and return a positive ID. An invalid callable returns 0. A valid action registered after cancellation runs immediately and returns 0. |
| `release_cleanup(id: int) -> bool` | Remove a completed operation's cleanup without running it. Unknown, nonpositive, or closed-scope IDs return false. IDs are never reused within one scope. |
| `dispatch(action: Callable, args: Array = []) -> bool` | Call synchronously if the scope is active and the callable is valid. Return false without calling otherwise. Return true means the call was attempted, not that arbitrary user code completed successfully. |
| `cancel() -> void` | Mark closed, detach the registry, then run valid cleanup in reverse registration order. Repeated or reentrant cancellation does nothing. |

Cancellation is terminal. Create a new scope instead of resetting one. Once
cancellation starts, releasing entries cannot modify its cleanup snapshot. A
cleanup added during cancellation follows the closed-scope rule and runs
immediately. Keep cleanup finite and do not recursively register itself.

## Usage

### 1. Install

Place this repository's contents directly in `addons/gmorn_scope/`. The runtime
script is at the repository root. There is no root `project.godot`; this prevents
the addon from becoming a nested project excluded from the importing project's
resource scan.

```sh
git submodule add https://github.com/TsukumiStudio/GMornScope.git addons/gmorn_scope
```

```gdscript
const Scope = preload("res://addons/gmorn_scope/gmorn_scope.gd")
var visit = Scope.new()
```

No editor plugin or global class registration is required.

### 2. Capture the scope for each visit

The following methods belong to a `Node2D`. Capture the scope for the particular
visit, rather than reading a mutable `current_visit` member when the callback
finally arrives.

```gdscript
const Scope = preload("res://addons/gmorn_scope/gmorn_scope.gd")
var current_visit = null

func begin_visit() -> void:
    stop_visit()
    current_visit = Scope.new()
    var captured_visit = current_visit
    get_tree().create_timer(0.2).timeout.connect(func():
        captured_visit.dispatch(show_tip)
    )
    var motion = create_tween()
    var cleanup_id = captured_visit.add_cleanup(func():
        if motion.is_valid():
            motion.kill()
    )
    motion.tween_property(self, "position:x", 20.0, 0.1)
    motion.finished.connect(func():
        captured_visit.release_cleanup(cleanup_id)
    )

func stop_visit() -> void:
    if current_visit != null:
        current_visit.cancel()
        current_visit = null

func _exit_tree() -> void:
    stop_visit()

func show_tip() -> void:
    pass # Your own presentation code.
```

Only register resources this operation owns. A shared tween should not be killed
by an unrelated visit. Normal completion should release cleanup registrations so
captured references are not retained until cancellation. Long-lived signal
connections can register a cleanup that disconnects their specific callback.

### 3. Observe ownership and limits

- Main-thread use only; no locking or cross-thread guarantees.
- Cancellation is explicit. Dropping a reference does not run cleanup. Avoid
  reference cycles and call `cancel()` from the owner's stop or `_exit_tree()`.
- Callable validity is checked, but argument counts and user script correctness
  are the caller's responsibility. Script errors are not caught or converted to
  successful operation results.
- Dispatch checks before calling. It cannot interrupt a synchronous callback or
  asynchronous work already started inside that callback.
- A `SceneTreeTimer` is not stopped. Its late callback can be blocked, but its
  connection and captured references may survive until timeout unless the caller
  disconnects them.
- There is no universal cancellable `await`. Killing a tween must not be assumed
  to wake an existing `await tween.finished`. Completion/cancellation races and
  task results remain the caller's responsibility.

### 4. Verify the disposable fixture

`verify.gd` checks deferred work across stop/reentry and tree exit, owned tween
stopping while another scope continues, freed callable targets, reverse cleanup,
exactly-once and reentrant cancellation, late registration, normal completion
release, captured-reference release, and argument forwarding. It uses only
primitive nodes and no media. Checks accumulate failures and emit one JSON line:

```
GMORN_SCOPE_VERIFY_JSON {"schema":1,"status":"pass",...}
```

A failed check returns exit 1. A 240-frame internal guard and `--quit-after 300`
bound normal processing. `verify.sh` creates a disposable renamed-addon fixture;
it rejects a missing positive summary and any script error, error, or warning,
even if the engine exits 0. It is not a general-purpose test runner.

Run the following **only when engine execution is permitted**. Audio uses the
Dummy driver, and the fixture mutes the master bus before any verification work.
The fixture supplies frame limits only; a stalled engine may not advance them.
Wall-time supervision and cleanup of the entire process group belong to the
calling environment. An existing runner such as GMornTestRunner can provide
that supervision, but is an optional integration rather than a dependency.
Do not treat a timeout that kills only the fixture shell as cleanup of its Godot
child. For supervised runs, use the caller's established process-group cleanup.

```sh
GODOT_BIN=godot sh ./verify.sh
# Expected failure: nonzero exit and a JSON status of "fail".
GODOT_BIN=godot sh ./verify.sh --force-failure
# Expected failure: a real runtime error inside dispatched and cleanup callbacks.
# The log must fail verification even if caller code emits a positive summary.
GODOT_BIN=godot sh ./verify.sh --fault-callback-error
```

Static fixture-protocol tests require Python 3 and do not start Godot:

```sh
python3 -m unittest discover -s tests -p 'test_*.py' -v
sh -n verify.sh
```

Those protocol tests use a fake executable to verify that exit 0 without a
summary, an engine error beside a pass summary, and nonzero exit are rejected.
They cannot validate GDScript parsing or runtime semantics.

## License

The Unlicense. The package contains new generic code and asset-free verification
fixtures only. It does not include game data, translated engine code, fonts,
captures, save data, credentials, or service configuration.
