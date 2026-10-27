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
`y` and `inside`; it updates for mouse movement too. The pointer layout does not
emulate multitouch gestures. `setTouchMode` accepts `Auto`, `On`, `Off`.

Call `app:destroy()` when unloading. All input, camera and character listeners
are disconnected. Destroying the viewport also tears down the shell.

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
