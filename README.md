# RobloxPortKit

Reusable client shell, input, GPU scene and cloud-save infrastructure for Roblox
ports. PortKit owns platform behavior; each game owns simulation, assets and its
save schema. No game cheats or chapter-skipping UI are provided.

## Build and test

Requires Python 3.10+ and [Lune](https://lune-org.github.io/docs/).

```powershell
python build.py --test
```

This runs Python packing/package tests and Luau runtime regressions, then emits
`dist/RobloxPortKit.rbxmx`. Insert its ModuleScript in ReplicatedStorage. The
equivalent Rojo mapping points a ModuleScript at `runtime/init.luau` with the
other runtime modules as children. Do not include the optional `.server.luau`
launcher as a child of a running client SDK.

## Client

```luau
local Kit = require(game.ReplicatedStorage.RobloxPortKit)
local app = Kit.createApp({
    name = "MyPort", width = 320, height = 180, scaleMode = "Fit",
    input = {
        bindings = {
            left = {"A", "Left", "DPadLeft"},
            right = {"D", "Right", "DPadRight"},
            up = {"W", "Up", "DPadUp"}, down = {"S", "Down", "DPadDown"},
            jump = {"Space", "ButtonA"}, grab = {"Z", "ButtonL2", "ButtonR2"},
        },
        layout = "Platformer", touchMode = "Auto",
        actions = {{action = "jump", label = "Jump"}},
    },
})
local canvas = app.shell.Canvas
-- Mount game graphics under canvas; settings under app.shell.Modal.
-- app.shell:setOpen(true) pauses input and focuses Resume.
-- The game must also pause its own simulation using app.shell.open.
```

`shell.ViewportGui` ignores insets; `shell.HudGui` uses the supported Roblox
`DeviceSafeInsets` enum (the API does not call it `DeviceSafeArea`). Character
parts, including parts added after spawn, are hidden, anchored and nonphysical.
PlayerModule controls and Roblox's Backpack, Health, PlayerList and EmotesMenu
are disabled. The camera is scriptable, and device orientation follows landscape.

`setScaleMode` accepts `Fit`, `PixelPerfect` or `Stretch`. Stretch changes the
logical canvas size, so fill it using scale coordinates if content should stretch.
`PixelPerfect` uses integer scaling when the screen is larger than the canvas;
smaller screens fit down proportionally instead of clipping.

Input bindings use KeyCode names or `MouseButton1` / `MouseButton2`.
`check(action)`, `axis(negative, positive, "X" or "Y")` and
`consumeBuffer(action, seconds)` work across input sources. Axes retain analog
magnitude. L2/R2 use 0.25/0.18 hysteresis, and Gamepad2+ are ignored. `setBehavior`
accepts `Hold`, `Invert` and `Toggle`. Focus loss and opening a modal clear held
inputs and toggles to avoid unintended actions after returning.

`layout = "Pointer"` maps direct canvas touch/drag to `primary` or `secondary`
using an explicit right-click toggle. `input.pointer` contains normalized `x`,
`y` and `inside`; it updates for mouse movement too. `virtualX` / `virtualY`
give unclamped canvas-pixel coordinates for hover footprints and range rings.
`createApp` accounts for the shell's current UI scale, including Fit,
PixelPerfect and Stretch. When constructing `Kit.Input` directly, pass `canvas`
and its `canvasScale` UIScale if scaled; without `canvasScale`, pixels are 1:1.

Primary mouse presses and touches beginning inside the canvas set `pointer.down`.
While held, `startX` / `startY` record the initial virtual coordinates and
`deltaX` / `deltaY` track displacement. `dragging` becomes true once Euclidean
distance **exceeds** `input.dragDeadzone` (default `4` virtual pixels), and stays
true until release. Configure it with `input = {layout = "Pointer",
dragDeadzone = 4, ...}`. Moving outside the canvas continues tracking the drag.

Call `input:consumeDrop()` once per update. It returns the latest unconsumed
primary release as `{startX, startY, x, y, wasDrag, inside}`, or `nil`; all drop
coordinates are virtual pixels. The release position is sampled even if there
was no intervening movement event. A click has `wasDrag = false`. Consumption
is one-shot, and a later release replaces an unconsumed one. No separate edge
flag reset is required. After release, `down` and `dragging` are false, while
the final start/displacement values remain available.

Opening a modal or losing window focus cancels an active press, clears pending
drops, and sets `pointer.cancelled = true`. Cancellation never produces a drop;
the flag remains set until the next accepted primary press. Use it to discard a
placement preview. Only one pointer owns a gesture; other touches cannot move or
release it. Secondary-touch mode produces the `secondary` action without a
primary drag/drop. Processed UI presses are ignored. The pointer layout does
not emulate multitouch gestures. `setTouchMode` accepts `Auto`, `On`, `Off`;
disabling/hiding touch controls also cancels an active touch.

Call `app:destroy()` when unloading. All input, camera and character listeners
are disconnected. Destroying the viewport also tears down the shell.

## Fixed-step simulation and tower defense / strategy

`Kit.Stepper.new({rate = 60, maxDelta = 0.25, maxStepsPerFrame = 8})` creates a
fixed-timestep accumulator with `stepDt = 1 / rate`. Alternatively, pass
`stepper = {rate = 60, maxSteps = 6}` to `createApp` and use `app.stepper`.
`maxSteps` is an alias for `maxStepsPerFrame`; the latter takes precedence.
The app only creates the clock; the game advances it and runs the simulation.

`stepper:setSpeed(1)` runs at normal speed, `setSpeed(3)` runs three times as
many fixed ticks, and `setSpeed(0)` pauses. Fractional positive speeds also work.
Speed changes preserve the fractional accumulator and never change `stepDt`.
`stepper:advance(dt)` returns `(stepsToRun, alpha)`, where `alpha` is in `[0, 1)`
for interpolating previous/current simulation snapshots. Paused calls return
zero steps and preserve the fraction without accumulating elapsed time.

Each call clamps wall-clock `dt` to `maxDelta` **before** applying speed, and
caps work at `ceil(maxStepsPerFrame * speed)` ticks (8 at 1x, 24 at 3x by default).
Excess whole ticks are discarded while retaining the interpolation fraction,
so lag spikes cannot create an ever-growing catch-up backlog. Overload therefore
drops simulation time. With the same input, elapsed-time sequence and settings,
the tick schedule is deterministic; gameplay randomness and input application
must also be deterministic if the game needs replay/lockstep behavior.

This example uses game-provided shop, placement, simulation and rendering helpers:

```luau
local app = Kit.createApp({
    name = "StrategyPort", width = 960, height = 540,
    input = {layout = "Pointer", dragDeadzone = 4,
        bindings = {primary = {"MouseButton1"}, secondary = {"MouseButton2"}}},
    stepper = {rate = 60, maxSteps = 6},
})
local clock, input = app.stepper, app.input
local requestedSpeed = 1
-- Wire the game's speed control to requestedSpeed = 1, 3, or 0.
game:GetService("RunService").RenderStepped:Connect(function(dt)
    local pointer = input.pointer
    local tower = if pointer.down then shopTowerAt(pointer.startX, pointer.startY) else nil
    if pointer.cancelled or not tower then
        hideFootprint()
    else
        showFootprint(tower, pointer.virtualX, pointer.virtualY,
            pointer.inside and canPlace(tower, pointer.virtualX, pointer.virtualY))
    end
    local drop = input:consumeDrop()
    if drop and drop.wasDrag and drop.inside then
        local draggedTower = shopTowerAt(drop.startX, drop.startY)
        if draggedTower and canPlace(draggedTower, drop.x, drop.y) then
            placeTower(draggedTower, drop.x, drop.y)
        end
    end
    clock:setSpeed(if app.shell.open then 0 else requestedSpeed)
    local steps, alpha = clock:advance(dt)
    for _ = 1, steps do simTick(clock.stepDt) end
    renderInterpolated(alpha) -- Includes bloons, projectiles and tower visuals.
end)
```

## GPU

`AtlasPool.new({maxPages = 32})` supplies `acquire(id,w,h,rgbaOrLoader)`, `pin`,
`unpin`, `releasePins`, `remove`, and `destroy`. IDs identify immutable pages.
Dimensions must be integers in 1..1024. A loader is evaluated only on a cache
miss. Pin every page referenced by visible ImageLabels; an unpinned page may be
evicted. The hard limit includes pinned pages: an over-budget scene fails with a
clear error instead of exceeding the configured budget. Repeated acquisition
updates LRU age; allocation failures evict unpinned pages before retrying.
Entries cache `Content.fromObject` values and expose `images[id].content`.

`GpuScene.new(parent)` exposes `begin`, `image(properties)`,
`frame(properties, cornerRadius?, stroke?)`, and `finish`. Submit objects in stable
order with complete properties for their type. Slots are reused and every
assignment is compared with its previous value; unchanged objects incur no
property writes. `finish` hides surplus slots. `writes` is reset by `begin`.
Scenes must release references before their atlas pages are unpinned.

## Cloud saves

On the server, require `Kit.SaveServer` directly and call `start` with:

```luau
require(game.ReplicatedStorage.RobloxPortKit.SaveServer).start({
    parent = game.ReplicatedStorage.MyPort, remoteName = "CloudSave",
    storeName = "myport_v1",
    blank = function() return {wins = 0} end,
    validate = function(data)
        if type(data) ~= "table" or type(data.wins) ~= "number"
            or data.wins % 1 ~= 0 or data.wins < 0 or data.wins > 1000000 then
            return false, "invalid wins"
        end
        return true, {wins = data.wins}
    end,
    merge = function(old, incoming, sessionId)
        old.wins = math.max(old.wins, incoming.wins)
        return old
    end,
})
```

Choose a remote name distinct from ModuleScript names. Alternatively install
`SaveServer.server.luau` beside a `PortKitSaveConfig` ModuleScript returning this
configuration, with the SDK named `RobloxPortKit` in ReplicatedStorage.

The service loads before writing, validates each payload, serializes a session's
requests, and merges inside UpdateAsync. Server revisions advance monotonically;
client revision claims never replace server state. Per-session sequence receipts
make retrying an acknowledged request idempotent. Merge callbacks must be pure,
non-yielding and tolerate stale incoming progress. Use union/max for permanent
progress, or a per-session cumulative counter for additive values. Receipt and
counter retention/migration must be planned for very long-lived save schemas.

`SaveClient.new({remote, snapshot, apply, onStatus, isDirty?, isStudio?})` supplies
`start`, `sync` and `destroy`. `snapshot` must return detached data. `apply(data,
sentSnapshotOrNil)` must preserve local progress made during a request. Failed
requests retain the same sequence/payload for retry; a later sync captures newer
changes. Wire a user-visible **Sync Now** button to `sync`. Studio API failure is
reported as offline and never pretends to have saved. Pending received data is
flushed on PlayerRemoving and BindToClose. Unsynchronized client changes cannot
be recovered by server shutdown; periodically send changes during normal play.

## Baking and performance

`tools/portkit_bake.py` provides stable RGBA shelf packing with gutters and
oversized-image tiling, compressed payload modules strictly below 180,000
characters, XML packaging and explicit hash-manifest vendoring. It has no third
party dependencies. Consumers should check in their vendor copy and update it
explicitly; builds should not silently depend on a sibling checkout.

`Benchmark:record(callbackSeconds, renderInterval)` and `stats()` report rolling
mean/p50/p95/max CPU milliseconds and observed RenderStepped FPS. Source can be
prepared with `Benchmark.stripNative` or Python `strip_native` before installing
it in Studio. Never equate CPU callback time with total frame/GPU time.

Celeste is the first integrated consumer. Unit tests and Studio emulation are
regression evidence, not certification across real phones/consoles. Published
client, physical-device, memory-pressure and successful production DataStore
measurements must be recorded separately.
