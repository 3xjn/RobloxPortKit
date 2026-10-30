# RobloxPortKit

## Phase 1 Asset Pipeline: Upfront Upload, Pruning, and Moderation Curation

- **Publish static art upfront.** Upload every static texture page to `rbxassetid://` before normal gameplay, and deliver it to GPU sprite and mesh draws through `Content.fromUri`. URI resolution can take less than 0.001 ms and uses no EditableImage budget; this is not a guarantee of asset download, loading, or GPU residency time. Never leave static game sheets on the runtime ModuleScript decompression fallback path in production. Hundreds of megabytes of static art in ReplicatedStorage ModuleScripts can cause 5-15 ms main-thread decompression and `WritePixelsBuffer` stalls during room or menu transitions, evict legitimate dynamic caches from `StaticImagePool`, and hit Roblox Cloud HTTP 413 place-size limits. These timings are observed examples, not universal guarantees.
- **Keep dynamic staging, and test it.** Runtime CPU decompression and EditableImage staging through `StaticImagePool` remain essential for truly dynamic or CPU-synthesized surfaces, such as runtime-baked tile grids, dynamic bitmap text caches, and procedural masks. Cover this path with targeted SDK tests.
- **Choose CPU pruning independently of GPU delivery.** Use `prune: true` for pure-GPU pages, such as backgrounds, illustrations, 3D mesh textures, UI, and portraits, to remove their compressed ModuleScript chunks from build output. Use `prune: false` for mixed pages that need CPU pixel readback, such as tilemap autotilers, 1x1 texel samplers, and silhouette masks: render the same pages via `rbxassetid://` on the GPU while retaining only the required CPU chunk data. Apply these settings in the consumer's asset pipeline.
- **Curate before batch upload.** Run an automated scan and crop audit of decals, posters, portraits, dialog art, and audio for potential Roblox terms and moderation issues, including bikini or beachwear posters, gore, alcohol or tobacco signage, profanity, and copyrighted music. Review flagged material; an automated scan alone cannot establish compliance or rights. Rather than deleting level art, restyle sensitive sprites in the same pixel-art or original art style and palette. Always show the user a before-and-after preview and obtain approval before patching and uploading the restyled assets.

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

`disableBackpack` defaults to `true`. Set it to `false`, or set
`coreGui.Backpack = true`, to opt into Roblox's inventory. Suppression also
owns a priority-3500 Backquote action; retain the cleanup function returned by
`Shell.configureCoreGui(config, isAlive)` when hosting without `Shell.new`.
Pass `playerGui` for landscape orientation; the local player's touch movement
mode is set to Scriptable. Shell destruction releases all owned actions.

`pauseKeys` defaults to Tab and Backquote when the backpack is disabled, and
Tab otherwise. A configured key calls the hosted `shell.pauseHandler`, or
toggles the shell menu. Text-box focus passes the key through. Configured pause
keys are consumed so Tab cannot also activate a game's journal. Physical Escape
remains reserved by Roblox; games should expose a pause button in the safe HUD.

`MobileProfile.detect({mobile, uis, viewport, maxParkedNodes, residencyWindow})`
detects touch-only devices or a viewport short side at most 540 pixels. Its
parked-node budget defaults to 384 on mobile and 2048 on desktop; its residency
window defaults to 5 screens. GpuScene detects this profile at construction, or
accepts `config.mobileProfile`. Excess parked nodes unused for 180 presentations
become hidden and detached. Crop recycling still requires a completed hidden
presentation. Active scrolling crops reuse bounded hidden banks without repeated
detach/reparent writes. This is an interpreter optimization, not a native-code
or device FPS guarantee.

Touch action specs accept `position`, `size`, and `anchorPoint`. Input's
`touchLayout` accepts `movePosition` and `moveSize`. Mount the controls inside
`Shell.HudGui` or another ScreenGui with DeviceSafeInsets. Movement supports eight
directions; separate fingers hold and release actions independently, including
sliding out of and back into buttons. `touchMode = 'Auto'` follows the last input
device, and focus loss clears held touches.

`Kit.Preloader.new({title, subtitle, accentColor, secondaryColor})` displays a
responsive startup screen. Call `preloader:preload({sounds = {...}, images =
{...}})` before game initialization, then `setStage(label, fraction)` for boot
milestones and `finish()` to fade out. `fail(message)` leaves an error visible.
Preloading deduplicates URIs, uses batches of 10, and returns a result with
`status`, `total`, `completed`, and `failures`. `timeoutSec` (default 8),
`batchSize`, and `skipAfterSec` (default 3; false disables Skip) are configurable
on construction. A timeout, skipped load, or failed fetch can leave assets cold;
Roblox may also evict hidden textures after preloading. Temporary instances are
destroyed when the preloader is destroyed. Headless consumers can inject
`contentProvider`, `instanceFactory`, and `scheduler`.

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
are disabled by default. The camera is scriptable, and device orientation follows landscape.

Pass `singlePlayer = true` or `chat = false` to `createApp` (or `Shell.new`)
to hide CoreGui Chat and disable the TextChatService window, input bar and bubble
chat. Chat is otherwise left alone; `chat = true` preserves it even in single-player
mode. `coreGui = {Backpack = true, Health = false, EmotesMenu = false,
PlayerList = true, Chat = false}` overrides individual CoreGui enabled states;
omitted non-chat entries default to false. `chat` takes precedence over the Chat
override when explicitly true or when chat is suppressed. A Chat override alone
only affects CoreGui, not TextChatService configurations. CoreGui calls retry for
up to ten attempts while the shell is alive. Service objects can be injected as
`starterGui` and `textChatService` for headless testing. These settings hide UI;
they do not disable the underlying chat service or prevent messages.

For a fresh Studio place, set `StarterPlayer.EnableMouseLockOption` to false in
Edit mode and remove the default SpawnLocation/Baseplate if your port does not
need them. For single-player places, also disable the window, input bar and bubble
chat configurations under TextChatService in Edit mode to avoid startup UI flashes.
PortKit does not currently provide a Studio place setup or sync helper.

`setScaleMode` accepts `Fit`, `PixelPerfect` or `Stretch`. Stretch changes the
logical canvas size, so fill it using scale coordinates if content should stretch.
The canvas exposes `LogicalWidth` and `LogicalHeight` attributes for renderers
that transform a fixed-resolution command stream into the resized canvas.
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

## Static texture pages

`StaticImagePool` is for immutable atlas pages. `request(id, width, height,
pixels)` returns a cached `{content = Content}` entry, or `nil` while a background
job prepares it. `pixels` may be an RGBA buffer or a deferred decoding function.
Requests for the same pending page share one job. `await(...)` is available to
loading workers; do not call it from a frame callback.

Each job creates one temporary EditableImage, writes the pixels, converts it with
`AssetService:CreateDataModelContentAsync`, and destroys the editable allocation.
ImageLabels and MeshParts can share the resulting immutable Content. Roblox
controls its GPU residency; an ImageLabel is not a separate VRAM snapshot.
`maxPages` and `maxBytes` bound cached content references; `pin`/`unpin` protect
active pages from LRU eviction. `GpuScene` clears hidden labels' ImageContent so
they do not retain pages that the cache has released. Use `AtlasPool` for images
that must remain editable, such as changing render targets.

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

`AudioPool.new({wireable=true, audioGraph=graph, ...})` creates native AudioPlayer
sources for `AudioBusGraph`, including atlas regions and route-safe recycling.
Supply explicit `info.bus` routes and verified DSP/property bindings; ordinary
Sounds cannot feed Wires. Graph failures warn `[PORT-ERROR]`, record diagnostics
and disconnect affected output. Source FMOD authoring data and acoustic parity
remain separate requirements. See the canonical SDK's
[mixer contracts](../xna2luau/docs/fmod-mixer.md) and
[Phase 2 evidence](../xna2luau/docs/phase2-sdk-verification.md).

GpuScene reuses unused ImageLabels across crop keys within the same immutable
ImageContent bucket, hiding them while publishing updated geometry and crop.
Idle labels are detached from the rendered hierarchy and retained in the bounded
Lua pool until reused or expired; attached DataModel labels are active draws.
`imageReserve` optionally warms detached spare labels per texture bucket (the
Monocle graphics host uses four). Active buckets retain their high-water count;
idle buckets expire, and the global inactive budget still caps retained objects.
`createdImages`, `destroyedImages` and `recycledImages` expose lifetime counters.
`StaticImagePool:import(id, content, width, height, prepare?)` leases an already published
image without pixel decoding, EditableImage staging or editable-material clones.
Published leases share pinning/eviction with staged pages and charge zero staging
bytes; actual Roblox texture/GPU memory remains outside this CPU-side counter.
An optional preparation callback runs on the pool's background queue before the
lease becomes ready; `awaitImport` waits for that readiness without pixel staging.


### Agent phone performance gate

Run `python tools/mobile_perf_gate.py` from this repository. It runs compiled
Jump King jumping/screen changes and Celeste Chapter Select/Prologue frames in
Lune with codegen disabled, then replays captured GUI frames in the two assigned
Studios only while they remain in Edit. A Play session receives only a state
query; its game uses the interpreter/metadata results instead. `--offline`
explicitly skips Studio. No Play controls or screen captures are used.

The command prints a table and writes `.cache/mobile-perf-gate.json` plus raw
frame samples. It reports mean/p95 CPU, 3.5x/5x phone estimates, texture metadata,
retained image nodes, writes, net heap changes and the EditableImage policy
counter. With Studio evidence, phone estimates use the sum of phase p95 Lune
simulation/submission and Studio GUI replay times. This is a conservative CPU
estimate, not paired end-to-end frame latency or measured device FPS. RGBA8
bytes deduplicate published URIs and exclude mips, compression and driver costs.

Exit 1 indicates a CPU budget/error failure; exit 2 indicates incomplete device
evidence despite passing CPU checks. The harness never certifies live phone
60 FPS: GPU/mesh composition, texture decode and Heavenly's full boot/mesh pin
set are unavailable to this native-boundary fixture. Jump King's real streamer
is swept across 166 screens for mobile/desktop pin counts. Celeste sheet counts
cover referenced 2D sheets; the full source catalog is labeled separately.
Heap KB/frame is net heap change and can be negative after GC; it is not an
allocation counter. Temporary Edit GUI probes are destroyed and HTTP settings
are restored. Re-run after publishing on actual devices for complete evidence.
