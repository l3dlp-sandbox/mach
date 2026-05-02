const std = @import("std");
const mach = @import("../main.zig");
const Core = @import("../Core.zig");
const gpu = mach.gpu;
const Event = Core.Event;
const KeyEvent = Core.KeyEvent;
const MouseButtonEvent = Core.MouseButtonEvent;
const MouseButton = Core.MouseButton;
const Size = Core.Size;
const DisplayMode = Core.DisplayMode;
const CursorShape = Core.CursorShape;
const VSyncMode = Core.VSyncMode;
const CursorMode = Core.CursorMode;
const Position = Core.Position;
const Key = Core.Key;
const KeyMods = Core.KeyMods;
const objc = @import("objc");
const metal = @import("../sysgpu/metal.zig");

const log = std.log.scoped(.mach);

pub const Darwin = @This();

/// Queued resize or vsync-mode change, written by the main thread and consumed by render thread
/// in renderThreadFn before each frame.
const PendingSwapChainUpdate = struct {
    width: u32,
    height: u32,
    framebuffer_width: u32,
    framebuffer_height: u32,
    vsync_mode: Core.VSyncMode,
};

/// Per-window platform state stored in `Core.windows` via `.native` field.
///
/// Copied by value when read/written through the objects system, so any data that must have a
/// stable address (e.g. display_link_ctx, which is captured by an objc block) is heap
/// allocated.
pub const Native = struct {
    window: *objc.app_kit.Window = undefined,
    view: *objc.mach.View = undefined,
    metal_descriptor: *gpu.Surface.DescriptorFromMetalLayer = undefined,
    display_link_ctx: ?*DisplayLinkContext = null,

    /// Global event monitor for command-key keyUp workaround. Must be removed on window teardown.
    key_up_monitor: ?*objc.objc.Id = null,

    /// Set by the main thread (windowDidResize / vsync change); consumed by the render thread to
    /// recreate the swap chain before the next frame.
    pending_swap_chain_update: ?PendingSwapChainUpdate = null,
};

/// Per-window context for CAMetalDisplayLink. Heap-allocated so the pointer remains stable when
/// Native is copied through the objects system. Passed as the block context to displayLinkWake.
const DisplayLinkContext = struct {
    /// Signaled by displayLinkWake on each vsync; the render thread waits on this to pace itself to
    /// the display refresh rate.
    ready_sem: objc.system.dispatch_semaphore_t,

    surface: *metal.Surface,
};

var global_render_loop: ?*RenderLoop = null;
var did_set_app_activation_policy: bool = false;

/// Shared render loop for all windows. The render thread waits for the app thread's snapshot
/// (frame_ready), then waits for vsync via one window's display link semaphore, applies pending
/// swap chain updates, and calls Core.renderFrame to render all windows sequentially.
const RenderLoop = struct {
    core: *Core = undefined,
    core_mod: mach.Mod(Core) = undefined,
    io: std.Io = undefined,
    running: std.atomic.Value(bool) = .init(true),
    thread: std.Thread = undefined,

    /// Spawns the render thread.
    fn start(self: *RenderLoop) error{ThreadSpawnFailed}!void {
        self.thread = std.Thread.spawn(.{}, renderThreadFn, .{self}) catch return error.ThreadSpawnFailed;
    }

    /// Registers displayLinkWake as the CAMetalDisplayLink callback for a window's view. Called
    /// during window creation and when vsync is re-enabled at runtime.
    fn attachDisplayLink(ctx: *DisplayLinkContext, view: *objc.mach.View) void {
        // Create an objc block that captures the DisplayLinkContext pointer, then register
        // it as the view's display link render block.
        var render_block = objc.foundation.stackBlockLiteral(displayLinkWake, ctx, null, null);
        view.setBlock_render(render_block.asBlock().copy());

        // Tell SwapChain.getCurrentTextureView (on the render thread) to consume display link
        // drawables instead of calling nextDrawable. This MUST be set before startDisplayLink,
        // because once the display link is started, Metal forbids nextDrawable() calls and the
        // render thread could race in between.
        @atomicStore(bool, &ctx.surface.use_display_link, true, .release);

        // The display link provides external vsync pacing, so disable the layer's own
        // displaySyncEnabled to prevent present() from blocking a second time.
        ctx.surface.layer.setDisplaySyncEnabled(false);

        // Start the display link.
        if (!view.startDisplayLink()) {
            log.err("CAMetalDisplayLink unavailable (requires macOS 14+)", .{});
            @atomicStore(bool, &ctx.surface.use_display_link, false, .release);
            return;
        }
    }

    /// Stops the CAMetalDisplayLink for a window's view. Called when vsync is disabled  or when a
    /// window is being destroyed.
    fn detachDisplayLink(ctx: *DisplayLinkContext, view: *objc.mach.View) void {
        // Stop the display link.
        view.stopDisplayLink();

        // Release any unconsumed drawable left by displayLinkWake.
        const pending_ptr: *usize = @ptrCast(&ctx.surface.pending_drawable);
        const prev = @atomicRmw(usize, pending_ptr, .Xchg, 0, .acq_rel);
        if (prev != 0) {
            const prev_ptr: *objc.quartz_core.MetalDrawable = @ptrFromInt(prev);
            prev_ptr.release();
        }

        // Tell SwapChain.getCurrentTextureView to use nextDrawable again.
        @atomicStore(bool, &ctx.surface.use_display_link, false, .release);
    }

    /// Stops the render loop, tears down all display links, and joins the render thread. Called
    /// during app exit.
    fn stop(self: *RenderLoop) void {
        // Signal the render thread to exit.
        self.running.store(false, .release);

        // The render thread may be blocked on dispatch_semaphore_wait for a vsync signal. Stop each
        // window's display link and signal its semaphore to unblock the render thread.
        {
            self.core.windows.lockShared();
            defer self.core.windows.unlockShared();
            var windows = self.core.windows.slice();
            while (windows.next()) |window_id| {
                if (self.core.windows.get(window_id, .native)) |native| {
                    if (native.display_link_ctx) |ctx| {
                        native.view.stopDisplayLink();
                        _ = objc.system.dispatch_semaphore_signal(ctx.ready_sem);
                    }
                }
            }
        }

        // The render thread may also be blocked on frame_ready (waiting for the app thread's
        // snapshot), so wake it / allow it to observe running=false.
        self.core.frame_ready.set(self.io);

        // Wait for render thread to exit.
        self.thread.join();
    }

    /// Render thread entry point.
    fn renderThreadFn(self: *RenderLoop) void {
        while (self.running.load(.acquire)) {
            // Wait for the app to signal snapshotEnd() and indicate a frame is ready for drawing.
            self.core.frame_ready.waitUncancelable(self.io);
            self.core.frame_ready.reset();

            // If we want to stop the render loop, exit now.
            if (!self.running.load(.acquire)) break;

            // vsync: if ALL windows have an active display link, wait for one to signal vsync. If
            // ANY window lacks a display link (vsync off, or not yet attached), skip the wait: that
            // window needs uncapped rendering, and display-link windows will naturally skip frames
            // when no drawable is available (getCurrentTextureView returns null). We check
            // use_display_link (the actual hardware state) rather than vsync_mode (the desired
            // state that the main thread hasn't applied yet).
            {
                var all_have_display_link = true;
                var wait_ctx: ?*DisplayLinkContext = null;
                {
                    self.core.windows.lockShared();
                    defer self.core.windows.unlockShared();

                    var windows = self.core.windows.slice();
                    while (windows.next()) |window_id| {
                        const native_opt = self.core.windows.get(window_id, .native);
                        const native = native_opt orelse continue;
                        const ctx = native.display_link_ctx orelse {
                            all_have_display_link = false;
                            break;
                        };
                        if (!@atomicLoad(bool, &ctx.surface.use_display_link, .acquire)) {
                            all_have_display_link = false;
                            break;
                        }
                        if (wait_ctx == null) wait_ctx = ctx;
                    }
                }

                if (all_have_display_link) {
                    if (wait_ctx) |ctx| {
                        _ = objc.system.dispatch_semaphore_wait(
                            ctx.ready_sem,
                            objc.system.DISPATCH_TIME_FOREVER,
                        );
                    }
                }
            }

            // Now that we waited for vsync, check if we should exit again before rendering the
            // frame.
            if (!self.running.load(.acquire)) break;

            // Apply any pending swap chain updates (resizes, vsync changes) before rendering.
            {
                self.core.windows.lock();
                defer self.core.windows.unlock();
                var windows = self.core.windows.slice();
                while (windows.next()) |window_id| {
                    var core_window = self.core.windows.getValue(window_id);
                    const native = core_window.native orelse continue;
                    const update = native.pending_swap_chain_update orelse continue;

                    core_window.native.?.pending_swap_chain_update = null;
                    core_window.width = update.width;
                    core_window.height = update.height;
                    core_window.framebuffer_width = update.framebuffer_width;
                    core_window.framebuffer_height = update.framebuffer_height;
                    core_window.swap_chain_descriptor.width = update.framebuffer_width;
                    core_window.swap_chain_descriptor.height = update.framebuffer_height;
                    core_window.swap_chain_descriptor.present_mode = switch (update.vsync_mode) {
                        .none_low_latency, .none_max_throughput => .immediate,
                        .double, .adaptive, .low_latency => .fifo,
                        .triple => .fifo,
                    };
                    core_window.swap_chain_descriptor.max_buffered_frames = switch (update.vsync_mode) {
                        .double, .adaptive, .low_latency => 2,
                        .triple, .none_low_latency, .none_max_throughput => 3,
                    };
                    core_window.swap_chain.release();
                    core_window.swap_chain = core_window.device.createSwapChain(
                        core_window.surface,
                        &core_window.swap_chain_descriptor,
                    );
                    self.core.windows.setValueRaw(window_id, core_window);
                }
            }

            // Render a frame on all windows.
            self.core.renderFrame(self.core_mod, self.io) catch {
                self.core.oom.store(true, .release);
            };
        }
    }

    // CAMetalDisplayLink callback, invoked on every vsync for the window.
    fn displayLinkWake(block: *objc.foundation.BlockLiteral(*DisplayLinkContext), drawable: *objc.quartz_core.MetalDrawable) callconv(.c) void {
        const ctx = block.context;

        // Retain the drawable so it survives beyond this callback. It will be released in either
        // SwapChain.getCurrentTextureView or SwapChain.deinit
        _ = drawable.retain();

        // When the render thread is slower than the display refresh rate, the display link still
        // fires every vsync, so if the render thread hasn't consumed the previous drawable yet we
        // should release the old one and replace it with the new one.
        const pending_ptr: *usize = @ptrCast(&ctx.surface.pending_drawable);
        const prev = @atomicRmw(usize, pending_ptr, .Xchg, @intFromPtr(drawable), .acq_rel);
        if (prev != 0) {
            const prev_ptr: *objc.quartz_core.MetalDrawable = @ptrFromInt(prev);
            prev_ptr.release();
        }

        // Signal to the render thread that a vsync has occurred.
        _ = objc.system.dispatch_semaphore_signal(ctx.ready_sem);
    }
};

/// Captured context for objc block callbacks (view events, window delegate). Heap-allocated
/// per window in initWindow so the pointer remains stable for the lifetime of the window's blocks.
const WindowContext = struct {
    core: *Core,
    core_mod: mach.Mod(Core),
    window_id: mach.ObjectID,
    io: std.Io,
};

// TODO(core): port libdispatch and use it instead of doing this directly.
extern "System" fn dispatch_async(queue: *anyopaque, block: *objc.foundation.Block(fn () void)) void;
extern "System" var _dispatch_main_q: anyopaque;

// Called by wakeMainThread when set.
var main_tick_block: ?*objc.foundation.Block(fn () void) = null;

// When true, a main tick is already enqueued on the main dispatch queue and additional wakes are
// deduplicated. Required because `dispatch_async` (unlike e.g. `std.Io.Event.set`) does NOT
// coalesce, so without this flag every wake would enqueue another tick with no upper bound on
// backlog.
var main_tick_pending: std.atomic.Value(bool) = .init(false);

// Called by Core when the user calls Core.snapshotStart, Core.events, core.exit
pub fn wakeMainThread(_: *Core) void {
    if (main_tick_pending.cmpxchgStrong(false, true, .acq_rel, .acquire) == null) {
        const block = main_tick_block orelse return;
        dispatch_async(&_dispatch_main_q, block);
    }
}

/// Application entry point called by Core.main. Sets up the NSApplication delegate and run loop.
/// The main thread does NOT busy-loop: each tick runs once per call to `wakeMainThread`, which
/// is invoked by the app thread from `events()` and `snapshotStart()`.
pub fn run(comptime on_each_update_fn: anytype, args_tuple: std.meta.ArgsTuple(@TypeOf(on_each_update_fn))) noreturn {
    const Args = @TypeOf(args_tuple);
    const args_bytes = std.mem.asBytes(&args_tuple);
    const ArgsBytes = @TypeOf(args_bytes.*);
    const Helper = struct {
        pub fn cCallback(block: *objc.foundation.BlockLiteral(ArgsBytes)) callconv(.c) void {
            const args: *Args = @ptrCast(&block.context);

            // Reset the wake flag BEFORE running tick so any wake that arrives during tick
            // re-arms a follow-up dispatch.
            main_tick_pending.store(false, .release);

            if (@call(.auto, on_each_update_fn, args.*) catch false) {
                // Do not auto-redispatch. The next tick happens only when `wakeMainThread`
                // is called (e.g. from the app thread's `events()` / `snapshotStart()`).
            } else {
                // We copied the block when we called `setRunBlock()`, so we release it here when the looping will end.
                block.release();
                // NSApp.run() never returns, so exit the process here.
                std.process.exit(0);
            }
        }
    };
    var block_literal = objc.foundation.stackBlockLiteral(Helper.cCallback, args_bytes.*, null, null);

    // Copy the block once; this stable, heap-owned reference is what `wakeMainThread` will
    // re-dispatch for the lifetime of Core.
    const dispatch_block = block_literal.asBlock().copy();
    main_tick_block = dispatch_block;

    // `NSApplicationMain()` and `UIApplicationMain()` never return, so there's no point in trying to add any kind of cleanup work here.
    const ns_app = objc.app_kit.Application.sharedApplication();

    const delegate = objc.mach.AppDelegate.allocInit();
    // AppDelegate.applicationDidFinishLaunching invokes this block synchronously once, kicking
    // off the very first main tick. Subsequent main ticks are driven by `wakeMainThread`.
    delegate.setRunBlock(dispatch_block);
    ns_app.setDelegate(@ptrCast(delegate));

    ns_app.run();
    unreachable;
}

/// Called by Core.tick on the main thread each application tick. Creates new windows, applies
/// changes (window title, size, vsync, etc.), and handles pending window destruction.
pub fn tick(core: *Core, core_mod: mach.Mod(Core), io: std.Io) !void {
    core.windows.lock();
    var unlocked = false;
    defer if (!unlocked) core.windows.unlock();

    // Tear down native resources for deleted windows on the main thread where AppKit calls are safe.
    var deleted_windows = core.windows.sliceDeleted();
    while (deleted_windows.next()) |window_id| {
        const native = core.windows.get(window_id, .native) orelse continue;
        if (native.key_up_monitor) |monitor| {
            objc.app_kit.Event.removeMonitor(monitor);
        }
        if (native.display_link_ctx) |ctx| {
            RenderLoop.detachDisplayLink(ctx, native.view);
            _ = objc.system.dispatch_semaphore_signal(ctx.ready_sem);
            core.allocator.destroy(ctx);
        }
        native.window.setIsVisible(false);
        native.view.release();
        native.window.release();
        core.allocator.destroy(native.metal_descriptor);
        core.windows.setRaw(window_id, .native, null);
        // The window_id object itself will be freed inside snapshotStart()
    }

    var windows = core.windows.slice();
    while (windows.next()) |window_id| {
        const core_window = core.windows.getValue(window_id);

        const native = core_window.native orelse {
            if (core_window.on_render != null) try initWindow(core, core_mod, window_id, io);
            continue;
        };

        // Update window decoration color.
        const native_window: *objc.app_kit.Window = native.window;
        if (core.windows.updated(window_id, .decoration_color)) {
            if (core_window.decoration_color) |decoration_color| {
                const color = objc.app_kit.Color.colorWithRed_green_blue_alpha(
                    decoration_color.r,
                    decoration_color.g,
                    decoration_color.b,
                    decoration_color.a,
                );
                native_window.setBackgroundColor(color);
                native_window.setTitlebarAppearsTransparent(true);
            } else {
                native_window.setTitlebarAppearsTransparent(false);
            }
        }

        // Update window title.
        if (core.windows.updated(window_id, .title)) {
            const string = objc.foundation.String.allocInit();
            defer string.release();
            native.window.setTitle(string.initWithUTF8String(core_window.title));
        }

        // Update window width/height.
        if (core.windows.updated(window_id, .width) or core.windows.updated(window_id, .height)) {
            var frame = native_window.frame();
            frame.size.width = @floatFromInt(core.windows.get(window_id, .width));
            frame.size.height = @floatFromInt(core.windows.get(window_id, .height));
            native_window.setFrame_display_animate(
                native_window.frameRectForContentRect(frame),
                true,
                true,
            );
        }

        // Update window cursor mode.
        if (core.windows.updated(window_id, .cursor_mode)) {
            switch (core_window.cursor_mode) {
                .normal => objc.app_kit.Cursor.unhide(),
                .disabled, .hidden => objc.app_kit.Cursor.hide(),
            }
        }

        // Update window cursor shape.
        if (core.windows.updated(window_id, .cursor_shape)) {
            const Cursor = objc.app_kit.Cursor;

            // Pop the current cursor, then push the new one so AppKit's
            // cursor stack reflects the updated shape.
            Cursor.T_pop();
            switch (core_window.cursor_shape) {
                .arrow => Cursor.arrowCursor().push(),
                .ibeam => Cursor.IBeamCursor().push(),
                .crosshair => Cursor.crosshairCursor().push(),
                .pointing_hand => Cursor.pointingHandCursor().push(),
                .not_allowed => Cursor.operationNotAllowedCursor().push(),
                .resize_ns => Cursor.resizeUpDownCursor().push(),
                .resize_ew => Cursor.resizeLeftRightCursor().push(),
                .resize_all => Cursor.closedHandCursor().push(),
                else => std.log.warn("Unsupported cursor", .{}),
            }
        }

        // Update window vsync.
        if (core.windows.updated(window_id, .vsync_mode)) {
            try ensureRenderLoop(core, core_mod, io);
            const want_vsync = !core_window.vsync_mode.isNone();

            // Only detach/attach the display link when transitioning between vsync-on and
            // vsync-off. Switching between vsync-on modes (e.g. .double → .triple) only
            // needs a swap chain recreation — the display link is already running.
            if (native.display_link_ctx) |ctx| {
                const have_display_link = @atomicLoad(bool, &ctx.surface.use_display_link, .acquire);
                if (want_vsync and !have_display_link) {
                    RenderLoop.attachDisplayLink(ctx, native.view);
                } else if (!want_vsync and have_display_link) {
                    RenderLoop.detachDisplayLink(ctx, native.view);
                }
            }

            // Queue a swap chain recreation for the render thread.
            var updated_native = native;
            updated_native.pending_swap_chain_update = .{
                .width = core_window.width,
                .height = core_window.height,
                .framebuffer_width = core_window.framebuffer_width,
                .framebuffer_height = core_window.framebuffer_height,
                .vsync_mode = core_window.vsync_mode,
            };
            core.windows.setRaw(window_id, .native, updated_native);

            // Wake the render thread so it picks up the swap chain update promptly.
            if (native.display_link_ctx) |ctx| {
                _ = objc.system.dispatch_semaphore_signal(ctx.ready_sem);
            }
        }
    }

    // Release the windows lock before stopping the render loop: rl.stop() acquires it itself.
    core.windows.unlock();
    unlocked = true;

    // Consider mach.Core exiting/exited state.
    const state = core.state.load(.acquire);
    if (state == .exiting or state == .exited) {
        // Stop the render loop before GPU resources are released.
        if (global_render_loop) |rl| {
            rl.stop();
            core.allocator.destroy(rl);
            global_render_loop = null;
        }
    } else if (global_render_loop == null) {
        // Ensure a render loop is always running (with or without display link).
        try ensureRenderLoop(core, core_mod, io);
    }
}

/// Creates the native AppKit window, Metal layer, view, and display link for a new mach.Core window
/// Called from tick() when a window has on_render set but no native state yet.
fn initWindow(
    core: *Core,
    core_mod: mach.Mod(Core),
    window_id: mach.ObjectID,
    io: std.Io,
) !void {
    var core_window = core.windows.getValue(window_id);

    const win_ctx = try core.allocator.create(WindowContext);
    win_ctx.* = .{ .core = core, .core_mod = core_mod, .window_id = window_id, .io = io };

    // Make the process a foreground UI application on the first window creation.
    if (!did_set_app_activation_policy) {
        did_set_app_activation_policy = true;
        _ = objc.app_kit.Application.sharedApplication().setActivationPolicy(
            objc.app_kit.ApplicationActivationPolicyRegular,
        );
    }

    var key_up_monitor: ?*objc.objc.Id = null;
    {
        // On macos, the command key in particular seems to be handled a bit differently and tends
        // to block the `keyUp` event from firing. To remedy this, we borrow the same fix GLFW uses
        // and add a monitor.
        const commandFn = struct {
            pub fn commandFn(block: *objc.foundation.BlockLiteral(*WindowContext), event: *objc.app_kit.Event) callconv(.c) ?*objc.app_kit.Event {
                const core_: *Core = block.context.core;
                const window_id_ = block.context.window_id;

                core_.windows.lockShared();
                const native_opt = core_.windows.get(window_id_, .native);
                core_.windows.unlockShared();

                if (native_opt) |native| {
                    const native_window: *objc.app_kit.Window = native.window;

                    if (event.modifierFlags() & objc.app_kit.EventModifierFlagCommand != 0)
                        native_window.sendEvent(event);
                }
                return event;
            }
        }.commandFn;

        var commandBlock = objc.foundation.stackBlockLiteral(commandFn, win_ctx, null, null);
        const monitor = objc.app_kit.Event.addLocalMonitorForEventsMatchingMask_handler(
            objc.app_kit.EventMaskKeyUp,
            commandBlock.asBlock().copy(),
        );
        key_up_monitor = monitor;
    }

    // Create the Metal layer.
    const metal_descriptor = try core.allocator.create(gpu.Surface.DescriptorFromMetalLayer);
    const layer = objc.quartz_core.MetalLayer.new();
    defer layer.release();
    metal_descriptor.* = .{ .layer = layer };
    core_window.surface_descriptor = .{};
    core_window.surface_descriptor.next_in_chain = .{ .from_metal_layer = metal_descriptor };

    // Handle window transparency
    if (core_window.transparent) layer.as(objc.quartz_core.Layer).setOpaque(false);

    // Handle window styling
    const screen = objc.app_kit.Screen.mainScreen();
    const rect = objc.core_graphics.Rect{
        .origin = .{ .x = 0, .y = 0 },
        .size = .{ .width = @floatFromInt(core_window.width), .height = @floatFromInt(core_window.height) },
    };
    const window_style =
        (if (core_window.display_mode == .fullscreen) objc.app_kit.WindowStyleMaskFullScreen else 0) |
        (if (core_window.decorated) objc.app_kit.WindowStyleMaskTitled else 0) |
        (if (core_window.decorated) objc.app_kit.WindowStyleMaskClosable else 0) |
        (if (core_window.decorated) objc.app_kit.WindowStyleMaskMiniaturizable else 0) |
        (if (core_window.decorated) objc.app_kit.WindowStyleMaskResizable else 0) |
        (if (!core_window.decorated) objc.app_kit.WindowStyleMaskFullSizeContentView else 0);

    // Create the AppKit window.
    const native_window = objc.app_kit.Window.alloc().initWithContentRect_styleMask_backing_defer_screen(
        rect,
        window_style,
        objc.app_kit.BackingStoreBuffered,
        false,
        screen,
    );
    native_window.setReleasedWhenClosed(false);

    const framebuffer_scale: f32 = @floatCast(native_window.backingScaleFactor());
    const window_width: f32 = @floatFromInt(core_window.width);
    const window_height: f32 = @floatFromInt(core_window.height);

    core_window.framebuffer_width = @intFromFloat(window_width * framebuffer_scale);
    core_window.framebuffer_height = @intFromFloat(window_height * framebuffer_scale);

    // initWithFrame is overridden in our MACHView, which creates a tracking area for mouse
    // tracking
    var view = objc.mach.View.allocInit();
    view = view.initWithFrame(rect);
    view.setLayer(@ptrCast(layer));

    // Register objc block callbacks for view input events.
    {
        const bl = objc.foundation.stackBlockLiteral;

        var keyDown = bl(ViewCallbacks.keyDown, win_ctx, null, null);
        view.setBlock_keyDown(keyDown.asBlock().copy());

        var insertText = bl(ViewCallbacks.insertText, win_ctx, null, null);
        view.setBlock_insertText(insertText.asBlock().copy());

        var keyUp = bl(ViewCallbacks.keyUp, win_ctx, null, null);
        view.setBlock_keyUp(keyUp.asBlock().copy());

        var flagsChanged = bl(ViewCallbacks.flagsChanged, win_ctx, null, null);
        view.setBlock_flagsChanged(flagsChanged.asBlock().copy());

        var magnify = bl(ViewCallbacks.magnify, win_ctx, null, null);
        view.setBlock_magnify(magnify.asBlock().copy());

        var mouseMoved = bl(ViewCallbacks.mouseMoved, win_ctx, null, null);
        view.setBlock_mouseMoved(mouseMoved.asBlock().copy());

        var mouseDown = bl(ViewCallbacks.mouseDown, win_ctx, null, null);
        view.setBlock_mouseDown(mouseDown.asBlock().copy());

        var mouseUp = bl(ViewCallbacks.mouseUp, win_ctx, null, null);
        view.setBlock_mouseUp(mouseUp.asBlock().copy());

        var scrollWheel = bl(ViewCallbacks.scrollWheel, win_ctx, null, null);
        view.setBlock_scrollWheel(scrollWheel.asBlock().copy());
    }
    native_window.setContentView(@ptrCast(view));

    // Center the window
    native_window.center();

    // Set decoration colors
    if (core_window.decoration_color) |decoration_color| {
        const color = objc.app_kit.Color.colorWithRed_green_blue_alpha(
            decoration_color.r,
            decoration_color.g,
            decoration_color.b,
            decoration_color.a,
        );
        native_window.setBackgroundColor(color);
        native_window.setTitlebarAppearsTransparent(true);
    } else {
        // Default to black so the window doesn't flash gray before the first frame.
        native_window.setBackgroundColor(objc.app_kit.Color.colorWithRed_green_blue_alpha(0, 0, 0, 1));
    }

    // Set window title
    const string = objc.foundation.String.allocInit();
    defer string.release();
    native_window.setTitle(string.initWithUTF8String(core_window.title));

    // NSWindowDelegate receives resize and close notifications from AppKit.
    const delegate = objc.mach.WindowDelegate.allocInit();
    defer native_window.setDelegate(@ptrCast(delegate));
    {
        const bl = objc.foundation.stackBlockLiteral;

        var didResize = bl(WindowDelegateCallbacks.windowDidResize, win_ctx, null, null);
        delegate.setBlock_windowDidResize(didResize.asBlock().copy());

        var shouldClose = bl(WindowDelegateCallbacks.windowShouldClose, win_ctx, null, null);
        delegate.setBlock_windowShouldClose(shouldClose.asBlock().copy());
    }

    // Store .native on the mach.Core window object.
    core_window.native = .{
        .window = native_window,
        .view = view,
        .metal_descriptor = metal_descriptor,
        .key_up_monitor = key_up_monitor,
    };
    core.windows.setValueRaw(window_id, core_window);

    // Shared mach.Core.initWindow logic across windowing backends.
    try core.initWindow(window_id);

    // Start or update the global render loop if needed
    try ensureRenderLoop(core, core_mod, core.windows.internal.io);

    // Create a per-window display link context and attach the CAMetalDisplayLink so vsync
    // pacing begins immediately. Re-read the window value because initWindow modified it.
    core_window = core.windows.getValue(window_id);
    {
        const surface: *metal.Surface = @ptrCast(@alignCast(core_window.surface));
        const dl_ctx = try core.allocator.create(DisplayLinkContext);
        dl_ctx.* = .{
            .ready_sem = objc.system.dispatch_semaphore_create(0) orelse
                return error.SemaphoreCreateFailed,
            .surface = surface,
        };

        var native_val = core_window.native.?;
        native_val.display_link_ctx = dl_ctx;
        core.windows.setRaw(window_id, .native, native_val);

        RenderLoop.attachDisplayLink(dl_ctx, view);
    }

    // Show the window only after the surface and display link are ready, so the user never sees
    // the window without rendered content on it.
    native_window.setIsVisible(true);
    native_window.makeKeyAndOrderFront(null);
}

/// Ensures the global render loop is running. Creates one if it doesn't exist yet. The render loop
/// is destroyed in tick() when the app exits.
fn ensureRenderLoop(core: *Core, core_mod: mach.Mod(Core), io: std.Io) !void {
    if (global_render_loop != null) return;

    const rl = try core.allocator.create(RenderLoop);
    rl.* = .{ .core = core, .core_mod = core_mod, .io = io };
    try rl.start();
    global_render_loop = rl;
}

/// Callbacks for NSWindowDelegate, invoked by AppKit on the main thread.
const WindowDelegateCallbacks = struct {
    /// Called by AppKit when the user resizes the window.
    pub fn windowDidResize(block: *objc.foundation.BlockLiteral(*WindowContext)) callconv(.c) void {
        const core: *Core = block.context.core;
        const window_id = block.context.window_id;

        core.windows.lock();
        defer core.windows.unlock();

        const core_window = core.windows.getValue(window_id);

        const native = core_window.native orelse return;
        const native_window: *objc.app_kit.Window = native.window;

        const frame = native_window.frame();
        const content_rect = native_window.contentRectForFrameRect(frame);

        const new_width: u32 = @intFromFloat(content_rect.size.width);
        const new_height: u32 = @intFromFloat(content_rect.size.height);

        if (core_window.width == new_width and core_window.height == new_height) return;

        const framebuffer_scale: f32 = @floatCast(native_window.backingScaleFactor());
        const fb_width: u32 = @intFromFloat(@as(f32, @floatFromInt(new_width)) * framebuffer_scale);
        const fb_height: u32 = @intFromFloat(@as(f32, @floatFromInt(new_height)) * framebuffer_scale);

        // Queue a swap chain recreation for the render thread.
        var updated_native = native;
        updated_native.pending_swap_chain_update = .{
            .width = new_width,
            .height = new_height,
            .framebuffer_width = fb_width,
            .framebuffer_height = fb_height,
            .vsync_mode = core_window.vsync_mode,
        };
        core.windows.setRaw(window_id, .native, updated_native);

        core.pushEvent(.{ .window_resize = .{
            .window_id = window_id,
            .size = .{ .width = new_width, .height = new_height },
        } });
    }

    /// Called by AppKit when the user clicks the window's close button.
    pub fn windowShouldClose(block: *objc.foundation.BlockLiteral(*WindowContext)) callconv(.c) bool {
        const core: *Core = block.context.core;
        const window_id = block.context.window_id;
        core.pushEvent(.{ .close = .{ .window_id = window_id } });
        return false;
    }
};

/// Callbacks for MACHView (NSView subclass), invoked by AppKit on the main thread for input events.
const ViewCallbacks = struct {
    pub fn mouseMoved(block: *objc.foundation.BlockLiteral(*WindowContext), event: *objc.app_kit.Event) callconv(.c) void {
        const core: *Core = block.context.core;
        const window_id = block.context.window_id;
        const mouse_location = event.locationInWindow();

        core.windows.lockShared();
        const window_height: f32 = @floatFromInt(core.windows.get(window_id, .height));
        core.windows.unlockShared();

        core.pushEvent(.{ .mouse_motion = .{
            .window_id = window_id,
            .pos = .{ .x = mouse_location.x, .y = window_height - mouse_location.y },
        } });
    }

    pub fn mouseDown(block: *objc.foundation.BlockLiteral(*WindowContext), event: *objc.app_kit.Event) callconv(.c) void {
        const core: *Core = block.context.core;
        const window_id = block.context.window_id;
        core.pushEvent(.{ .mouse_press = .{
            .window_id = window_id,
            .button = @enumFromInt(event.buttonNumber()),
            .pos = .{ .x = event.locationInWindow().x, .y = event.locationInWindow().y },
            .mods = machModifierFromModifierFlag(event.modifierFlags()),
        } });
    }

    pub fn mouseUp(block: *objc.foundation.BlockLiteral(*WindowContext), event: *objc.app_kit.Event) callconv(.c) void {
        const core: *Core = block.context.core;
        const window_id = block.context.window_id;
        core.pushEvent(.{ .mouse_release = .{
            .window_id = window_id,
            .button = @enumFromInt(event.buttonNumber()),
            .pos = .{ .x = event.locationInWindow().x, .y = event.locationInWindow().y },
            .mods = machModifierFromModifierFlag(event.modifierFlags()),
        } });
    }

    pub fn scrollWheel(block: *objc.foundation.BlockLiteral(*WindowContext), event: *objc.app_kit.Event) callconv(.c) void {
        const core: *Core = block.context.core;
        const window_id = block.context.window_id;
        var scroll_delta_x = event.scrollingDeltaX();
        var scroll_delta_y = event.scrollingDeltaY();
        if (event.hasPreciseScrollingDeltas()) {
            // Trackpad deltas are in pixels; scale down to match the
            // line-based units expected by the scroll event consumer.
            scroll_delta_x *= 0.1;
            scroll_delta_y *= 0.1;
        }

        core.pushEvent(.{ .mouse_scroll = .{
            .window_id = window_id,
            .xoffset = @floatCast(scroll_delta_x),
            .yoffset = @floatCast(scroll_delta_y),
        } });
    }

    // e.g. fired on macOS using a trackpad
    pub fn magnify(block: *objc.foundation.BlockLiteral(*WindowContext), event: *objc.app_kit.Event) callconv(.c) void {
        const core: *Core = block.context.core;
        const window_id = block.context.window_id;
        core.pushEvent(.{ .zoom_gesture = .{
            .window_id = window_id,
            .zoom = @floatCast(event.magnification()),
            .phase = machPhaseFromPhase(event.phase()),
        } });
    }

    pub fn keyDown(block: *objc.foundation.BlockLiteral(*WindowContext), event: *objc.app_kit.Event) callconv(.c) void {
        const core: *Core = block.context.core;
        const window_id = block.context.window_id;

        if (event.isARepeat()) {
            core.pushEvent(.{ .key_repeat = .{
                .window_id = window_id,
                .key = machKeyFromKeycode(event.keyCode()),
                .mods = machModifierFromModifierFlag(event.modifierFlags()),
            } });
        } else {
            core.pushEvent(.{ .key_press = .{
                .window_id = window_id,
                .key = machKeyFromKeycode(event.keyCode()),
                .mods = machModifierFromModifierFlag(event.modifierFlags()),
            } });
        }
    }

    pub fn insertText(block: *objc.foundation.BlockLiteral(*WindowContext), _: *objc.app_kit.Event, codepoint: u32) callconv(.c) void {
        const core: *Core = block.context.core;
        const window_id = block.context.window_id;
        core.pushEvent(.{ .char_input = .{ .codepoint = @intCast(codepoint), .window_id = window_id } });
    }

    pub fn keyUp(block: *objc.foundation.BlockLiteral(*WindowContext), event: *objc.app_kit.Event) callconv(.c) void {
        const core: *Core = block.context.core;
        const window_id = block.context.window_id;
        core.pushEvent(.{ .key_release = .{
            .window_id = window_id,
            .key = machKeyFromKeycode(event.keyCode()),
            .mods = machModifierFromModifierFlag(event.modifierFlags()),
        } });
    }

    pub fn flagsChanged(block: *objc.foundation.BlockLiteral(*WindowContext), event: *objc.app_kit.Event) callconv(.c) void {
        const core: *Core = block.context.core;
        const window_id = block.context.window_id;
        const key = machKeyFromKeycode(event.keyCode());
        const mods = machModifierFromModifierFlag(event.modifierFlags());
        const key_flag = switch (key) {
            .left_shift, .right_shift => objc.app_kit.EventModifierFlagShift,
            .left_control, .right_control => objc.app_kit.EventModifierFlagControl,
            .left_alt, .right_alt => objc.app_kit.EventModifierFlagOption,
            .left_super, .right_super => objc.app_kit.EventModifierFlagCommand,
            .caps_lock => objc.app_kit.EventModifierFlagCapsLock,
            else => 0,
        };

        if (event.modifierFlags() & key_flag != 0) {
            if (core.input_state.isKeyPressed(key)) {
                core.pushEvent(.{ .key_release = .{ .window_id = window_id, .key = key, .mods = mods } });
            } else {
                core.pushEvent(.{ .key_press = .{ .window_id = window_id, .key = key, .mods = mods } });
            }
        } else {
            core.pushEvent(.{ .key_release = .{ .window_id = window_id, .key = key, .mods = mods } });
        }
    }
};

fn machPhaseFromPhase(phase: objc.app_kit.EventPhase) Core.GesturePhase {
    return switch (phase) {
        objc.app_kit.EventPhaseNone => .none,
        objc.app_kit.EventPhaseMayBegin => .may_begin,
        objc.app_kit.EventPhaseBegan => .began,
        objc.app_kit.EventPhaseChanged => .changed,
        objc.app_kit.EventPhaseStationary => .stationary,
        objc.app_kit.EventPhaseEnded => .ended,
        objc.app_kit.EventPhaseCancelled => .cancelled,
        else => .none,
    };
}

fn machModifierFromModifierFlag(modifier_flag: usize) Core.KeyMods {
    var modifier: Core.KeyMods = .{
        .alt = false,
        .caps_lock = false,
        .control = false,
        .num_lock = false,
        .shift = false,
        .super = false,
        .help = false,
        .function = false,
    };

    if (modifier_flag & objc.app_kit.EventModifierFlagOption != 0)
        modifier.alt = true;

    if (modifier_flag & objc.app_kit.EventModifierFlagCapsLock != 0)
        modifier.caps_lock = true;

    if (modifier_flag & objc.app_kit.EventModifierFlagControl != 0)
        modifier.control = true;

    if (modifier_flag & objc.app_kit.EventModifierFlagShift != 0)
        modifier.shift = true;

    if (modifier_flag & objc.app_kit.EventModifierFlagCommand != 0)
        modifier.super = true;

    if (modifier_flag & objc.app_kit.EventModifierFlagNumericPad != 0)
        modifier.num_lock = true;

    if (modifier_flag & objc.app_kit.EventModifierFlagHelp != 0)
        modifier.help = true;

    if (modifier_flag & objc.app_kit.EventModifierFlagFunction != 0)
        modifier.function = true;

    return modifier;
}

fn machKeyFromKeycode(keycode: c_ushort) Core.Key {
    comptime var table: [256]Key = undefined;
    comptime for (&table, 1..) |*ptr, i| {
        ptr.* = switch (i) {
            0x35 => .escape,
            0x12 => .one,
            0x13 => .two,
            0x14 => .three,
            0x15 => .four,
            0x17 => .five,
            0x16 => .six,
            0x1A => .seven,
            0x1C => .eight,
            0x19 => .nine,
            0x1D => .zero,
            0x1B => .minus,
            0x18 => .equal,
            0x33 => .backspace,
            0x30 => .tab,
            0x0C => .q,
            0x0D => .w,
            0x0E => .e,
            0x0F => .r,
            0x11 => .t,
            0x10 => .y,
            0x20 => .u,
            0x22 => .i,
            0x1F => .o,
            0x23 => .p,
            0x21 => .left_bracket,
            0x1E => .right_bracket,
            0x24 => .enter,
            0x3B => .left_control,
            0x00 => .a,
            0x01 => .s,
            0x02 => .d,
            0x03 => .f,
            0x05 => .g,
            0x04 => .h,
            0x26 => .j,
            0x28 => .k,
            0x25 => .l,
            0x29 => .semicolon,
            0x27 => .apostrophe,
            0x32 => .grave,
            0x38 => .left_shift,
            //0x2A => .backslash, // Iso backslash instead?
            0x06 => .z,
            0x07 => .x,
            0x08 => .c,
            0x09 => .v,
            0x0B => .b,
            0x2D => .n,
            0x2E => .m,
            0x2B => .comma,
            0x2F => .period,
            0x2C => .slash,
            0x3C => .right_shift,
            0x43 => .kp_multiply,
            0x3A => .left_alt,
            0x31 => .space,
            0x39 => .caps_lock,
            0x7A => .f1,
            0x78 => .f2,
            0x63 => .f3,
            0x76 => .f4,
            0x60 => .f5,
            0x61 => .f6,
            0x62 => .f7,
            0x64 => .f8,
            0x65 => .f9,
            0x6D => .f10,
            0x59 => .kp_7,
            0x5B => .kp_8,
            0x5C => .kp_9,
            0x4E => .kp_subtract,
            0x56 => .kp_4,
            0x57 => .kp_5,
            0x58 => .kp_6,
            0x45 => .kp_add,
            0x53 => .kp_1,
            0x54 => .kp_2,
            0x55 => .kp_3,
            0x52 => .kp_0,
            0x41 => .kp_decimal,
            0x69 => .print,
            0x2A => .iso_backslash,
            0x67 => .f11,
            0x6F => .f12,
            0x51 => .kp_equal,
            //0x64 => .f13, GLFW doesnt have a f13?
            0x6B => .f14,
            0x71 => .f15,
            0x6A => .f16,
            0x40 => .f17,
            0x4F => .f18,
            0x50 => .f19,
            0x5A => .f20,
            0x4C => .kp_enter,
            0x3E => .right_control,
            0x4B => .kp_divide,
            0x3D => .right_alt,
            0x47 => .num_lock,
            0x73 => .home,
            0x7E => .up,
            0x74 => .page_up,
            0x7B => .left,
            0x7C => .right,
            0x77 => .end,
            0x7D => .down,
            0x79 => .page_down,
            0x72 => .insert,
            0x75 => .delete,
            0x37 => .left_super,
            0x36 => .right_super,
            0x6E => .menu,
            else => .unknown,
        };
    };
    return if (keycode > 0 and keycode <= table.len) table[keycode - 1] else if (keycode == 0) .a else .unknown;
}
