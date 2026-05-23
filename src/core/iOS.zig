//! iOS / UIKit backend for `mach.Core`.
//!
//! This is the iOS counterpart to `Darwin.zig` (macOS / AppKit). It follows the same shape and
//! conventions, but adapts to UIKit's scene-based lifecycle:
//!
//!   * The application's entry point hands control to `UIApplicationMain`, which calls into our
//!     `MACHAppDelegate`. AppKit's `applicationDidFinishLaunching:` kicked off the first tick
//!     synchronously; on iOS we instead defer the first tick until a `UIWindowScene` has been
//!     handed to us via `MACHSceneDelegate.scene:willConnectToSession:options:`.
//!   * `UIWindow` requires a `UIWindowScene` (iOS 13+) to be constructed, and that scene is only
//!     available inside the scene delegate callback. So `initWindow` is lazy: it runs from `tick`
//!     once BOTH the application has requested a window (`Core.Window.on_render != null`) AND
//!     the scene has connected (`g_scene` is non-null).
//!   * Mouse / cursor / window-decoration concepts don't apply on iOS. The window covers the
//!     scene's bounds at the device's native scale, and those concept areas of `Darwin.zig` are
//!     simply absent here.
//!
//! Touch / press input mapping, full UIKit event handling, multi-scene support, and the render
//! loop are left as TODOs for follow-up work; this file intentionally provides the minimum
//! surface area needed for the rest of `mach.Core` to compile against the iOS target while
//! enough of the lifecycle is wired up to bring a Metal-backed UIWindow on screen.

const std = @import("std");
const mach = @import("../main.zig");
const Core = @import("../Core.zig");
const gpu = mach.gpu;
const objc = @import("objc");
const metal = @import("../sysgpu/metal.zig");

const log = std.log.scoped(.mach);

pub const iOS = @This();

// --------------------------------------------------------------------------------------------
// Lifecycle globals
//
// UIKit's run loop is single-threaded and reaches into our code through delegate callbacks
// (`applicationDidFinishLaunchingWithOptions:`, `scene:willConnectToSession:options:`). The
// callbacks need a way to wake `tick`, run the user's per-frame work, and hand us the
// `UIWindowScene` once it becomes available. Stashing those in module-level state mirrors the
// approach used in `Darwin.zig` (`main_tick_fn` / `main_tick_ctx`), but with the added wrinkle
// that we have to wait for the scene to connect before we can create the window.

var main_tick_fn: ?*const fn (?*anyopaque) callconv(.c) void = null;
var main_tick_ctx: ?*anyopaque = null;

/// Deduplicates `wakeMainThread` requests: only one `dispatch_async_f` is in flight at a time;
/// further `wakeMainThread` calls coalesce until the next tick consumes the flag.
var main_tick_pending: std.atomic.Value(bool) = .init(false);

/// The `UIWindowScene` handed to us by `MACHSceneDelegate.scene:willConnectToSession:options:`.
/// `initWindow` waits for this to be non-null before constructing the `UIWindow`.
var g_scene: ?*objc.ui_kit.UIWindowScene = null;

/// Pending swap chain change (resize / vsync mode). Consumed by the render thread before the
/// next frame. Same idea as `Darwin.zig`'s field of the same name.
const PendingSwapChainUpdate = struct {
    width: u32,
    height: u32,
    framebuffer_width: u32,
    framebuffer_height: u32,
    pixel_density: f32,
    vsync_mode: Core.VSyncMode,
};

// --------------------------------------------------------------------------------------------
// Per-window native state.
//
// Same heap-stable-pointer trick as `Darwin.zig`: a `*NativeState` is the value stored in
// `Core.Window.native`, and it's also the value we hand to Obj-C classes (the `_state` ivar
// on `MACHView` etc.) so callback IMPs can find their way back to mach state.

pub const Native = *NativeState;

const NativeState = struct {
    core: *Core,
    core_mod: mach.Mod(Core),
    window_id: mach.ObjectID,
    io: std.Io,

    window: *objc.ui_kit.UIWindow,
    view: *objc.ui_kit.UIView,
    view_controller: *objc.ui_kit.UIViewController,

    metal_descriptor: *gpu.Surface.DescriptorFromMetalLayer,
    surface: *metal.Surface,
    ready_sem: objc.system.dispatch_semaphore_t,

    pending_swap_chain_update: ?PendingSwapChainUpdate = null,
};

// --------------------------------------------------------------------------------------------
// Obj-C classes (defined in pure Zig via `DefineClass`).

/// `UIApplicationDelegate` implementation. AppKit's `MACHAppDelegate` kicks off the first tick
/// from `applicationDidFinishLaunching:`; on iOS the first tick is deferred until the scene
/// has connected (see `MACHSceneDelegate.scene:willConnectToSession:options:`).
const MACHAppDelegate = objc.objc.DefineClass(struct {
    pub const class_name = "MACHAppDelegate";
    pub const superclass = objc.foundation.ObjectInterface;
    pub const protocols = &.{objc.ui_kit.UIApplicationDelegate};

    pub const Self = objc.objc.Self(class_name);

    pub const methods = struct {
        /// Called once after process launch. Returning `true` allows the run loop to start
        /// delivering scene callbacks; we do not run the first tick here because no
        /// `UIWindowScene` exists yet.
        pub fn @"application:didFinishLaunchingWithOptions:"(
            _: *Self,
            _: ?*objc.ui_kit.UIApplication,
            _: ?*objc.objc.Id,
        ) bool {
            return true;
        }

        /// Tell UIKit which scene-delegate class to instantiate for a connecting session. We
        /// always point at `MACHSceneDelegate`; multi-scene differentiation can be added
        /// later by stashing extra info on the configuration.
        pub fn @"application:configurationForConnectingSceneSession:options:"(
            _: *Self,
            _: *objc.ui_kit.UIApplication,
            session: *objc.ui_kit.UISceneSession,
            _: *objc.ui_kit.UISceneConnectionOptions,
        ) *objc.ui_kit.UISceneConfiguration {
            const role = session.role();
            const config = objc.ui_kit.UISceneConfiguration.alloc().initWithName_sessionRole(
                null,
                role,
            );
            config.setDelegateClass(@ptrCast(MACHSceneDelegate.class()));
            return config;
        }
    };
});

/// `UIWindowSceneDelegate` implementation. Stashes the scene pointer and triggers the first
/// tick so `initWindow` can run. Subsequent scene activation / deactivation events fire
/// focus_gained / focus_lost just like macOS' windowDidBecomeKey / windowDidResignKey.
const MACHSceneDelegate = objc.objc.DefineClass(struct {
    pub const class_name = "MACHSceneDelegate";
    pub const superclass = objc.foundation.ObjectInterface;
    pub const protocols = &.{objc.ui_kit.UIWindowSceneDelegateProtocol};

    pub const Self = objc.objc.Self(class_name);

    pub const methods = struct {
        pub fn @"scene:willConnectToSession:options:"(
            _: *Self,
            scene: *objc.ui_kit.UIScene,
            _: *objc.ui_kit.UISceneSession,
            _: *objc.ui_kit.UISceneConnectionOptions,
        ) void {
            // The scene's runtime type is `UIWindowScene`; the protocol parameter is the more
            // general `UIScene`. Reinterpret-cast to access window-scene specific APIs from
            // `initWindow`.
            g_scene = @ptrCast(scene);

            // Now that the scene exists, run an immediate tick on the main thread so
            // `initWindow` can create the `UIWindow`. Subsequent ticks are driven by
            // `wakeMainThread` via `dispatch_async_f`.
            if (main_tick_fn) |f| f(main_tick_ctx);
        }

        pub fn @"sceneDidBecomeActive:"(_: *Self, _: *objc.ui_kit.UIScene) void {
            // TODO: push focus_gained for the corresponding window once we support multiple
            // windows / scenes.
        }

        pub fn @"sceneWillResignActive:"(_: *Self, _: *objc.ui_kit.UIScene) void {
            // TODO: push focus_lost for the corresponding window.
        }

        pub fn @"sceneWillEnterForeground:"(_: *Self, _: *objc.ui_kit.UIScene) void {}
        pub fn @"sceneDidEnterBackground:"(_: *Self, _: *objc.ui_kit.UIScene) void {}
    };
});

// --------------------------------------------------------------------------------------------
// Platform interface (called by Core.zig).

/// Wakes the main thread so it processes a new tick. Called by Core from the app thread (e.g.
/// from `events()`, `snapshotStart()`, `exit()`). Same dedup trick as `Darwin.zig`.
pub fn wakeMainThread(_: *Core) void {
    if (main_tick_pending.cmpxchgStrong(false, true, .acq_rel, .acquire) == null) {
        const f = main_tick_fn orelse return;
        objc.system.dispatch_async_f(&objc.system._dispatch_main_q, main_tick_ctx, f);
    }
}

/// Application entry point. Hands control to `UIApplicationMain`, which never returns.
/// `MACHAppDelegate` is the principal delegate; the scene delegate is wired up by the
/// app delegate's `application:configurationForConnectingSceneSession:options:`.
pub fn run(comptime on_each_update_fn: anytype, args_tuple: std.meta.ArgsTuple(@TypeOf(on_each_update_fn))) void {
    const Args = @TypeOf(args_tuple);
    // `UIApplicationMain` never returns, so this local is valid for the lifetime of the process.
    var args = args_tuple;
    const Helper = struct {
        pub fn tick(ctx: ?*anyopaque) callconv(.c) void {
            const a: *Args = @ptrCast(@alignCast(ctx.?));

            // Reset BEFORE running the tick so wakeMainThread() requests that arrive during
            // the tick re-arm a follow-up dispatch.
            main_tick_pending.store(false, .release);

            if (@call(.auto, on_each_update_fn, a.*) catch false) {
                // Don't auto-redispatch; the next tick happens when wakeMainThread is called
                // (from the app thread's events()/snapshotStart()).
            } else {
                // `UIApplicationMain` never returns; exit explicitly.
                std.process.exit(0);
            }
        }
    };
    main_tick_ctx = &args;
    main_tick_fn = &Helper.tick;

    // `UIApplicationMain(argc, argv, principalClassName, delegateClassName)`.
    // We pass `null` for the principal class name to use the default `UIApplication`, and the
    // class name of our delegate (it is registered at process startup via the
    // `MACHAppDelegate` DefineClass invocation above).
    const delegate_name = objc.foundation.String.allocInit()
        .initWithUTF8String("MACHAppDelegate");
    defer delegate_name.release();

    const dummy_argc: c_int = 0;
    const dummy_argv: [*]*c_char = undefined;
    _ = objc.ui_kit.applicationMain(dummy_argc, dummy_argv, null, @ptrCast(delegate_name));
    unreachable;
}

/// Called by `Core.tick` on the main thread. Creates / updates windows; on iOS this currently
/// only handles initial window creation and window-deletion teardown (decoration / cursor
/// updates etc. don't apply).
pub fn tick(core: *Core, core_mod: mach.Mod(Core), io: std.Io) !void {
    core.windows.lock();
    defer core.windows.unlock();

    // Tear down native resources for deleted windows on the main thread where UIKit calls
    // are safe.
    var deleted_windows = core.windows.sliceDeleted();
    while (deleted_windows.next()) |window_id| {
        const n = core.windows.get(window_id, .native) orelse continue;
        // Signal the sem so the render thread (if blocked waiting on it) can unblock.
        _ = objc.system.dispatch_semaphore_signal(n.ready_sem);
        // Hide via a raw msgSend; ui_kit.zig doesn't yet expose `setHidden:` on UIWindow.
        objc.objc.msgSend(n.window, "setHidden:", void, .{true});
        n.view_controller.release();
        n.window.release();
        core.allocator.destroy(n.metal_descriptor);
        core.allocator.destroy(n);
        core.windows.setRaw(window_id, .native, null);
    }

    var windows = core.windows.slice();
    while (windows.next()) |window_id| {
        const core_window = core.windows.getValue(window_id);
        if (core_window.native == null) {
            // Lazy init: wait until BOTH the app has registered an on_render callback AND
            // the scene has connected. Either condition alone is insufficient.
            if (core_window.on_render != null and g_scene != null) {
                try initWindow(core, core_mod, window_id, io);
            }
            continue;
        }
        // TODO: handle title / decoration_color / vsync_mode updates.
    }
}

// --------------------------------------------------------------------------------------------
// Window creation.

/// Lazy initialization of the native UIKit window for a `Core.Window`. Runs on the main
/// thread from `tick` once both the app has set `on_render` and the scene has connected.
fn initWindow(
    core: *Core,
    core_mod: mach.Mod(Core),
    window_id: mach.ObjectID,
    io: std.Io,
) !void {
    var core_window = core.windows.getValue(window_id);
    const scene = g_scene orelse return; // Should not happen given tick() gate.

    // Allocate the heap-stable NativeState up front. ObjC ivars capture this pointer; the
    // window / view / surface fields are populated below.
    const n = try core.allocator.create(NativeState);
    n.* = .{
        .core = core,
        .core_mod = core_mod,
        .window_id = window_id,
        .io = io,
        .ready_sem = objc.system.dispatch_semaphore_create(0) orelse
            return error.SemaphoreCreateFailed,

        .window = undefined,
        .view = undefined,
        .view_controller = undefined,
        .metal_descriptor = undefined,
        .surface = undefined,
    };

    // Create the Metal layer and a sysgpu Surface descriptor pointing at it.
    n.metal_descriptor = try core.allocator.create(gpu.Surface.DescriptorFromMetalLayer);
    const layer = objc.quartz_core.MetalLayer.new();
    defer layer.release();
    n.metal_descriptor.* = .{ .layer = layer };
    core_window.surface_descriptor = .{};
    core_window.surface_descriptor.next_in_chain = .{ .from_metal_layer = n.metal_descriptor };

    // Create the UIWindow bound to the scene.
    n.window = objc.ui_kit.UIWindow.alloc().initWithWindowScene(scene);

    // Use the scene's screen for sizing. UIKit windows always fill their scene's bounds.
    const screen = scene.screen();
    const bounds = screen.bounds();
    const pixel_density: f32 = @floatCast(screen.nativeScale());
    core_window.width = @intFromFloat(bounds.size.width);
    core_window.height = @intFromFloat(bounds.size.height);
    core_window.framebuffer_width = @intFromFloat(bounds.size.width * pixel_density);
    core_window.framebuffer_height = @intFromFloat(bounds.size.height * pixel_density);
    core_window.pixel_density = pixel_density;
    core_window.display_scale = 1.0;

    // Create a UIView that hosts the Metal layer, wrap it in a UIViewController, and make it
    // the window's root view controller.
    n.view = objc.ui_kit.UIView.alloc().initWithFrame(bounds);
    n.view.setContentScaleFactor(@floatCast(pixel_density));
    // Attach the CAMetalLayer as a sublayer of the view's backing layer. UIView doesn't
    // expose a setLayer: equivalent to NSView's; the canonical pattern is a UIView subclass
    // overriding +layerClass to make the backing CALayer a CAMetalLayer directly. We use the
    // sublayer approach here as a placeholder until MACHView is ported.
    objc.objc.msgSend(n.view.layer(), "addSublayer:", void, .{layer});

    n.view_controller = objc.ui_kit.UIViewController.allocInit();
    n.view_controller.setView(n.view);
    n.window.setRootViewController(n.view_controller);

    // Store .native on the Core window object so the rest of mach.Core can find it.
    core_window.native = n;
    core.windows.setValueRaw(window_id, core_window);

    // Shared Core.initWindow logic (creates surface, swap chain, etc.).
    try core.initWindow(window_id);

    // Now that the surface exists, stash it on the NativeState for the render thread to
    // consume via display link callbacks (once the display link is wired up — TODO).
    core_window = core.windows.getValue(window_id);
    n.surface = @ptrCast(@alignCast(core_window.surface));

    // Make the window visible.
    n.window.makeKeyAndVisible();

    core.pushEvent(.{ .open = .{ .window_id = window_id } });
}
