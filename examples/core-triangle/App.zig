const std = @import("std");
const mach = @import("mach");
const gpu = mach.gpu;

const App = @This();

// The set of Mach modules our application may use.
pub const Modules = mach.Modules(.{
    mach.Core,
    App,
});

pub const mach_module = .app;

pub const mach_systems = .{
    .main,
    .init,
    .appTick,
    .tick,
    .render,
    .deinit,
};

pub const main = mach.schedule(.{
    .{ mach.Core, .init },
    .{ App, .init },
    .{ mach.Core, .main },
});

title_timer: mach.time.Timer,
pipeline: ?*gpu.RenderPipeline = null,
app_thread: mach.Thread,

pub fn init(
    core: *mach.Core,
    app: *App,
    app_mod: mach.Mod(App),
    core_mod: mach.Mod(mach.Core),
    io: std.Io,
) !void {
    core.on_exit = app_mod.id.deinit;

    _ = try core.windows.new(.{
        .title = "core-triangle",
        .on_render = app_mod.id.render,
    });

    // Store our render pipeline in our module's state, so we can access it later on.
    app.* = .{
        .title_timer = mach.time.Timer.start(io),
        .app_thread = try mach.startThread(core, app_mod.id.tick, core_mod, .app),
    };
}

fn setupPipeline(core: *mach.Core, app: *App) !void {
    var window = core.windows.getValue(core.window);
    defer core.windows.setValueRaw(core.window, window);

    // Create our shader module
    const shader_module = window.device.createShaderModuleWGSL("shader.wgsl", @embedFile("shader.wgsl"));
    defer shader_module.release();

    // Blend state describes how rendered colors get blended
    const blend = gpu.BlendState{};

    // Color target describes e.g. the pixel format of the window we are rendering to.
    const color_target = gpu.ColorTargetState{
        .format = window.framebuffer_format,
        .blend = &blend,
    };

    // Fragment state describes which shader and entrypoint to use for rendering fragments.
    const fragment = gpu.FragmentState.init(.{
        .module = shader_module,
        .entry_point = "frag_main",
        .targets = &.{color_target},
    });

    // Create our render pipeline that will ultimately get pixels onto the screen.
    const label = @tagName(mach_module) ++ ".init";
    const pipeline_descriptor = gpu.RenderPipeline.Descriptor{
        .label = label,
        .fragment = &fragment,
        .vertex = gpu.VertexState{
            .module = shader_module,
            .entry_point = "vertex_main",
        },
    };
    app.pipeline = window.device.createRenderPipeline(&pipeline_descriptor);
}

// TODO(object): window-title
// try updateWindowTitle(core);

pub const tick = mach.schedule(.{
    .{ App, .appTick },
    .{ mach.Core, .snapshotStart },
    .{ mach.Core, .snapshotEnd },
});

pub fn appTick(core: *mach.Core) void {
    var iter = core.events(core.suggestEventPacing());
    while (iter.next()) |event| {
        switch (event) {
            .close => core.exit(),
            else => {},
        }
    }
}

pub fn render(app: *App, core: *mach.Core) !void {
    const pipeline = app.pipeline orelse {
        try setupPipeline(core, app);
        return;
    };
    const label = @tagName(mach_module) ++ ".render";
    const window = core.windows.getValue(core.window);

    // Grab the back buffer of the swapchain
    // TODO(core): this wouldn't exist in browser
    const back_buffer_view = window.swap_chain.getCurrentTextureView() orelse return;
    defer back_buffer_view.release();

    // Create a command encoder
    const encoder = window.device.createCommandEncoder(&.{ .label = label });
    defer encoder.release();

    // Begin render pass
    const sky_blue_background = gpu.Color{ .r = 0.776, .g = 0.988, .b = 1, .a = 1 };
    const color_attachments = [_]gpu.RenderPassColorAttachment{.{
        .view = back_buffer_view,
        .clear_value = sky_blue_background,
        .load_op = .clear,
        .store_op = .store,
    }};
    const render_pass = encoder.beginRenderPass(&gpu.RenderPassDescriptor.init(.{
        .label = label,
        .color_attachments = &color_attachments,
    }));
    defer render_pass.release();

    // Draw
    render_pass.setPipeline(pipeline);
    render_pass.draw(3, 1, 0, 0);

    // Finish render pass
    render_pass.end();

    // Submit our commands to the queue
    var command = encoder.finish(&.{ .label = label });
    defer command.release();
    window.queue.submit(&[_]*gpu.CommandBuffer{command});

    // update the window title every second
    // if (app.title_timer.read() >= 1.0) {
    //     app.title_timer.reset();
    //     // TODO(object): window-title
    //     // try updateWindowTitle(core);
    // }
}

pub fn deinit(app: *App) void {
    app.app_thread.join();
    if (app.pipeline) |p| p.release();
}

// TODO(object): window-title
// fn updateWindowTitle(core: *mach.Core) !void {
//     try core.printTitle(
//         core.main_window,
//         "core-custom-entrypoint [ {d}fps ] [ Input {d}hz ]",
//         .{
//             core.frameRate(),
//             core.inputRate(),
//         },
//     );
//     core.schedule(.update);
// }
