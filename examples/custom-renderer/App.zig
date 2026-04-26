const std = @import("std");
const mach = @import("mach");
const math = mach.math;
const Renderer = @import("Renderer.zig");

const vec3 = math.vec3;
const vec2 = math.vec2;
const Vec2 = math.Vec2;
const Vec3 = math.Vec3;

const App = @This();

// The set of Mach modules our application may use.
pub const Modules = mach.Modules(.{
    mach.Core,
    App,
    @import("Renderer.zig"),
});

pub const mach_module = .app;

pub const mach_systems = .{
    .main,
    .init,
    .deinit,
    .deinitApp,
    .appTick,
    .tick,
    .render,
};

// Global state for our app module.
app_thread: mach.Thread,
tick_timer: mach.time.Timer,
player: mach.ObjectID,
window: mach.ObjectID,
direction: Vec2 = vec2(0, 0),
spawning: bool = false,
spawn_timer: mach.time.Timer,

pub const main = mach.schedule(.{
    .{ mach.Core, .init },
    .{ Renderer, .init },
    .{ App, .init },
    .{ mach.Core, .main },
});

pub const deinit = mach.schedule(.{
    .{ App, .deinitApp },
    .{ Renderer, .deinit },
});

pub fn deinitApp(app: *App) void {
    app.app_thread.join();
}

pub fn init(
    core: *mach.Core,
    app: *App,
    app_mod: mach.Mod(App),
    core_mod: mach.Mod(mach.Core),
    renderer: *Renderer,
    io: std.Io,
) !void {
    core.on_exit = app_mod.id.deinit;

    const window = try core.windows.new(.{
        .title = "custom renderer",
        .on_render = app_mod.id.render,
    });

    // Create our player entity.
    const player = try renderer.objects.new(.{
        .position = vec3(0, 0, 0),
        .scale = 1.0,
    });

    app.* = .{
        .app_thread = try mach.startThread(core, app_mod.id.tick, core_mod, .app),
        .tick_timer = mach.time.Timer.start(io),
        .spawn_timer = mach.time.Timer.start(io),
        .player = player,
        .window = window,
    };
}

pub const tick = mach.schedule(.{
    .{ App, .appTick },
    .{ mach.Core, .snapshotStart },
    .{ Renderer, .snapshot },
    .{ mach.Core, .snapshotEnd },
});

pub fn appTick(
    core: *mach.Core,
    renderer: *Renderer,
    app: *App,
) !void {
    var direction = app.direction;
    var spawning = app.spawning;
    var iter = core.events(.default);
    while (iter.next()) |event| {
        switch (event) {
            .key_press => |ev| {
                switch (ev.key) {
                    .left => direction.v[0] -= 1,
                    .right => direction.v[0] += 1,
                    .up => direction.v[1] += 1,
                    .down => direction.v[1] -= 1,
                    .space => spawning = true,
                    else => {},
                }
            },
            .key_release => |ev| {
                switch (ev.key) {
                    .left => direction.v[0] += 1,
                    .right => direction.v[0] -= 1,
                    .up => direction.v[1] -= 1,
                    .down => direction.v[1] += 1,
                    .space => spawning = false,
                    else => {},
                }
            },
            .close => core.exit(),
            else => {},
        }
    }

    // Keep track of which direction we want the player to move based on input, and whether we want
    // to be spawning entities.
    //
    // Note that app. simply returns a pointer to a global singleton of the struct defined
    // by this file, so we can access fields defined at the top of this file.
    app.direction = direction;
    app.spawning = spawning;

    // Get the current player position
    var player = renderer.objects.getValue(app.player);
    defer renderer.objects.setValue(app.player, player);

    // If we want to spawn new entities, then spawn them now. The timer just makes spawning rate
    // independent of frame rate.
    if (spawning and app.spawn_timer.read() > 1.0 / 60.0) {
        _ = app.spawn_timer.lap(); // Reset the timer
        for (0..5) |_| {
            // Spawn a new object at the same position as the player, but smaller in scale.
            const new_obj = try renderer.objects.new(.{
                .position = player.position,
                .scale = 1.0 / 6.0,
            });

            // Parent the object to the player, we'll make children 'follow' the parent below.
            try renderer.objects.addChild(app.player, new_obj);
        }
    }

    // Multiply by delta_time to ensure that movement is the same speed regardless of tick rate.
    const delta_time = app.tick_timer.lap();

    // Calculate the player position, by moving in the direction the player wants to go
    // by the speed amount.
    const speed = 1.0;
    player.position.v[0] += direction.x() * speed * delta_time;
    player.position.v[1] += direction.y() * speed * delta_time;

    // Find the children of the player and make them 'follow' the player position.
    var children = try renderer.objects.getChildren(app.player);
    defer children.deinit();
    for (children.items) |child_id| {
        if (!renderer.objects.is(child_id)) continue;
        var child = renderer.objects.getValue(child_id);
        defer renderer.objects.setValue(child_id, child);

        // Nested query to find all the other follower entities that we should move away from.
        // We will avoid all other follower entities if we're too close to them.
        // This is not very efficient, but it works!
        const close_dist = 1.0 / 15.0;
        var avoidance = Vec3.splat(0);
        var avoidance_div: f32 = 1.0;

        var children2 = try renderer.objects.getChildren(app.player);
        defer children2.deinit();
        for (children2.items) |child2_id| {
            if (!renderer.objects.is(child2_id)) continue;
            if (child_id == child2_id) continue;
            const child2 = renderer.objects.getValue(child2_id);
            if (child.position.dist(&child2.position) < close_dist) {
                avoidance = avoidance.sub(&child.position.dir(&child2.position, 0.0000001));
                avoidance_div += 1.0;
            }
        }

        // Avoid the player if we're too close to it
        var avoid_player_multiplier: f32 = 1.0;
        if (child.position.dist(&player.position) < close_dist * 6.0) {
            avoidance = avoidance.sub(&child.position.dir(&player.position, 0.0000001));
            avoidance_div += 1.0;
            avoid_player_multiplier = 4.0;
        }

        // Determine our new position, taking into account things we want to avoid
        const move_speed = 1.0 * delta_time;
        var new_position = child.position.add(&avoidance.divScalar(avoidance_div).mulScalar(move_speed * avoid_player_multiplier));

        // Try to move towards the center of the world if we don't need to avoid something else
        child.position = new_position.lerp(&vec3(0, 0, 0), move_speed / avoidance_div);
    }

    {
        core.windows.lock();
        defer core.windows.unlock();
        try core.fmtTitle(app.window, "custom-renderer [ {d}fps ] [ Input {d}hz ]", .{
            core.frame.rate, core.input.rate,
        });
    }
}

pub fn render(
    renderer_mod: mach.Mod(Renderer),
) !void {
    renderer_mod.call(.renderFrame);
}
