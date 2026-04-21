const std = @import("std");
const zigimg = @import("zigimg");
const assets = @import("assets");
const mach = @import("mach");
const gpu = mach.gpu;
const gfx = mach.gfx;
const math = mach.math;

const vec2 = math.vec2;
const vec3 = math.vec3;
const Vec2 = math.Vec2;
const Mat3x3 = math.Mat3x3;
const Mat4x4 = math.Mat4x4;

const App = @This();

// The set of Mach modules our application may use.
pub const Modules = mach.Modules(.{
    mach.Core,
    mach.gfx.Sprite,
    mach.gfx.Text,
    mach.Audio,
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
    .deinit2,
    .audioStateChange,
};

pub const main = mach.schedule(.{
    .{ mach.Core, .init },
    .{ mach.Audio, .init },
    .{ gfx.Text, .init },
    .{ gfx.Sprite, .init },
    .{ App, .init },
    .{ mach.Core, .main },
});

pub const deinit = mach.schedule(.{
    .{ mach.Audio, .deinit },
    .{ App, .deinit2 },
});

app_thread: mach.Thread,
allocator: std.mem.Allocator,
window: mach.ObjectID,
tick_timer: mach.time.Timer,
spawn_timer: mach.time.Timer,
rand: std.Random.DefaultPrng,

vsync_mode: mach.Core.VSyncMode = .double,
score: usize = 0,
num_sprites_spawned: usize = 0,
direction: Vec2 = vec2(0, 0),
spawning: bool = false,
gotta_go_fast: bool = false,

info_text_buf: [128]u8 = undefined,
info_text: []u8 = &.{},
info_text_id: mach.ObjectID = undefined,
info_text_style_id: mach.ObjectID = undefined,
sprite_pipeline_id: ?mach.ObjectID = null,
text_pipeline_id: mach.ObjectID = undefined,
sfx: mach.Audio.Opus = undefined,

pub fn init(
    core: *mach.Core,
    audio: *mach.Audio,
    app: *App,
    app_mod: mach.Mod(App),
    core_mod: mach.Mod(mach.Core),
    io: std.Io,
) !void {
    core.on_exit = app_mod.id.deinit;

    // Configure the audio module to call our App.audioStateChange function when a sound buffer
    // finishes playing.
    audio.on_state_change = app_mod.id.audioStateChange;

    const window = try core.windows.new(.{
        .title = "hardware check",
        .on_render = app_mod.id.render,
        .vsync_mode = .double,
    });

    // TODO(allocator): find a better way to get an allocator here
    const allocator = std.heap.c_allocator;

    app.* = .{
        .app_thread = try mach.startThread(core, app_mod.id.tick, core_mod, .app),
        .allocator = allocator,
        .window = window,
        .tick_timer = mach.time.Timer.start(io),
        .spawn_timer = mach.time.Timer.start(io),
        .rand = std.Random.DefaultPrng.init(1337),
    };
}

pub fn deinit2(
    app: *App,
    text: *gfx.Text,
) void {
    app.app_thread.join();
    // Cleanup here, if desired.
    text.objects.delete(app.info_text_id);
}

/// Called on the high-priority audio OS thread when the audio driver needs more audio samples, so
/// this callback should be fast to respond.
pub fn audioStateChange(audio: *mach.Audio, app: *App) !void {
    audio.buffers.lock();
    defer audio.buffers.unlock();

    // Find audio objects that are no longer playing
    var buffers = audio.buffers.slice();
    while (buffers.next()) |buf_id| {
        if (audio.buffers.get(buf_id, .playing)) continue;

        // Remove the audio buffer that is no longer playing
        const samples = audio.buffers.get(buf_id, .samples);
        audio.buffers.delete(buf_id);
        app.allocator.free(samples);
    }
}

fn setupPipeline(
    core: *mach.Core,
    app: *App,
    sprite: *gfx.Sprite,
    text: *gfx.Text,
) !void {
    const window = core.windows.getValue(core.window);

    // Load sfx
    app.sfx = try mach.Audio.Opus.decodeStream(app.allocator, .{ .data = assets.sfx.scifi_gun });

    // Create a sprite rendering pipeline
    app.sprite_pipeline_id = try sprite.pipelines.new(.{
        .window = core.window,
        .render_pass = undefined,
        .texture = try loadTexture(window.device, window.queue, app.allocator),
    });

    // Create a text rendering pipeline
    app.text_pipeline_id = try text.pipelines.new(.{
        .window = core.window,
        .render_pass = undefined,
    });

    // Create a text style
    app.info_text_style_id = try text.styles.new(.{
        .font_size = 48 * gfx.px_per_pt, // 48pt
    });

    // Create documentation text
    {
        // TODO(text): release this memory somewhere
        const text_value =
            \\ Mach is probably working if you:
            \\ * See this text
            \\ * See sprites to the left
            \\ * Hear sounds when sprites disappear
            \\ * Hold space and things go faster
        ;
        const text_buf = try app.allocator.alloc(u8, text_value.len);
        @memcpy(text_buf, text_value);
        const segments = try app.allocator.alloc(gfx.Text.Segment, 1);
        segments[0] = .{
            .text = text_buf,
            .style = app.info_text_style_id,
        };

        // Create our player text
        const text_id = try text.objects.new(.{
            .transform = Mat4x4.translate(vec3(-0.02, 0, 0)),
            .segments = segments,
        });
        // Attach the text object to our text rendering pipeline.
        try text.pipelines.setParent(text_id, app.text_pipeline_id);
    }

    // Create info text to be updated dynamically later
    {
        const text_value = "[info]";
        @memcpy(app.info_text_buf[0..text_value.len], text_value);
        app.info_text = app.info_text_buf[0..text_value.len];
        const segments = try app.allocator.alloc(gfx.Text.Segment, 1);
        segments[0] = .{
            .text = app.info_text,
            .style = app.info_text_style_id,
        };

        // Create our player text
        app.info_text_id = try text.objects.new(.{
            .transform = Mat4x4.translate(vec3(0, (@as(f32, @floatFromInt(window.height)) / 2.0) - 50.0, 0)),
            .segments = segments,
        });
        // Attach the text object to our text rendering pipeline.
        try text.pipelines.setParent(app.info_text_id, app.text_pipeline_id);
    }
}

pub const tick = mach.schedule(.{
    .{ App, .appTick },
    .{ mach.Core, .snapshotStart },
    .{ gfx.Sprite, .snapshot },
    .{ gfx.Text, .snapshot },
    .{ mach.Core, .snapshotEnd },
});

pub fn appTick(
    core: *mach.Core,
    app: *App,
    sprite: *gfx.Sprite,
    text: *gfx.Text,
    audio: *mach.Audio,
) !void {
    const window = core.windows.getValue(app.window);

    var iter = core.events(.adaptive);
    while (iter.next()) |event| {
        switch (event) {
            .key_press => |ev| {
                switch (ev.key) {
                    .space => app.gotta_go_fast = true,
                    .v => {
                        app.vsync_mode = switch (app.vsync_mode) {
                            .none => .double,
                            .double => .triple,
                            .triple => .none,
                        };
                        core.windows.set(app.window, .vsync_mode, app.vsync_mode);
                    },
                    else => {},
                }
            },
            .key_release => |ev| {
                switch (ev.key) {
                    .space => app.gotta_go_fast = false,
                    else => {},
                }
            },

            .close => core.exit(),
            else => {},
        }
    }

    if (app.sprite_pipeline_id == null) return;

    // TODO(text): make updating text easier
    app.info_text = std.fmt.bufPrint(
        &app.info_text_buf,
        "[ render: {d}hz | input: {d}hz ]\n[ Sprites spawned: {d} ]\n(v) vsync: {s}",
        .{ core.frame.rate, core.input.rate, app.num_sprites_spawned, @tagName(app.vsync_mode) },
    ) catch &.{};
    var segments: []gfx.Text.Segment = @constCast(text.objects.get(app.info_text_id, .segments));
    segments[0] = .{
        .text = app.info_text,
        .style = segments[0].style,
    };
    text.objects.set(app.info_text_id, .segments, segments);

    const entities_per_second: f32 = @floatFromInt(
        app.rand.random().intRangeAtMost(usize, 0, if (app.gotta_go_fast) 50 else 10),
    );
    if (app.spawn_timer.read() > 1.0 / entities_per_second) {
        // Spawn new entities
        _ = app.spawn_timer.lap();

        var new_pos = vec3(-(@as(f32, @floatFromInt(window.width)) / 2), 0, 0);
        new_pos.v[1] += app.rand.random().floatNorm(f32) * 50;

        const new_sprite_id = try sprite.objects.new(.{
            .transform = Mat4x4.translate(new_pos),
            .size = vec2(32, 32),
            .uv_transform = Mat3x3.translate(vec2(0, 0)),
        });
        try sprite.pipelines.setParent(new_sprite_id, app.sprite_pipeline_id.?);
        app.num_sprites_spawned += 1;
    }

    // Multiply by delta_time to ensure that movement is the same speed regardless of tick rate.
    const delta_time = app.tick_timer.lap();

    // Move sprites to the right, and make them smaller the further they travel
    var pipeline_children = try sprite.pipelines.getChildren(app.sprite_pipeline_id.?);
    defer pipeline_children.deinit();
    for (pipeline_children.items) |sprite_id| {
        if (!sprite.objects.is(sprite_id)) continue;
        var s = sprite.objects.getValue(sprite_id);

        const location = s.transform.translation();
        const speed: f32 = if (app.gotta_go_fast) 2000 else 100;
        const progression = std.math.clamp((location.v[0] + (@as(f32, @floatFromInt(window.height)) / 2.0)) / @as(f32, @floatFromInt(window.height)), 0, 1);
        const scale = mach.math.lerp(2, 0, progression);
        if (progression >= 0.6) {
            try sprite.pipelines.removeChild(app.sprite_pipeline_id.?, sprite_id);
            sprite.objects.delete(sprite_id);

            // Play a new sound
            const samples = try app.allocator.alignedAlloc(f32, std.mem.Alignment.fromByteUnits(mach.Audio.alignment), app.sfx.samples.len);
            @memcpy(samples, app.sfx.samples);
            audio.buffers.lock();
            defer audio.buffers.unlock();
            const sound_id = try audio.buffers.new(.{
                .samples = samples,
                .channels = app.sfx.channels,
            });
            _ = sound_id;
            app.score += 1;
        } else {
            var transform = Mat4x4.ident;
            transform = transform.mul(&Mat4x4.translate(location.add(&vec3(speed * delta_time, (speed / 2.0) * delta_time * progression, 0))));
            transform = transform.mul(&Mat4x4.scaleScalar(scale));
            sprite.objects.set(sprite_id, .transform, transform);
        }
    }

}

pub fn render(
    core: *mach.Core,
    app: *App,
    sprite: *gfx.Sprite,
    sprite_mod: mach.Mod(gfx.Sprite),
    text: *gfx.Text,
    text_mod: mach.Mod(gfx.Text),
) !void {
    if (app.sprite_pipeline_id == null) {
        try setupPipeline(core, app, sprite, text);
        return;
    }

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
    const sky_blue = gpu.Color{ .r = 0.776, .g = 0.988, .b = 1, .a = 1 };
    const color_attachments = [_]gpu.RenderPassColorAttachment{.{
        .view = back_buffer_view,
        .clear_value = sky_blue,
        .load_op = .clear,
        .store_op = .store,
    }};
    const render_pass = encoder.beginRenderPass(&gpu.RenderPassDescriptor.init(.{
        .label = label,
        .color_attachments = &color_attachments,
    }));

    // Render sprites
    sprite.pipelines.set(app.sprite_pipeline_id.?, .render_pass, render_pass);
    sprite_mod.call(.render);

    // Render text
    text.pipelines.set(app.text_pipeline_id, .render_pass, render_pass);
    text_mod.call(.render);

    // Finish render pass
    render_pass.end();
    var command = encoder.finish(&.{ .label = label });
    window.queue.submit(&[_]*gpu.CommandBuffer{command});
    command.release();
    render_pass.release();

}

// TODO(sprite): don't require users to copy / write this helper themselves
fn loadTexture(device: *gpu.Device, queue: *gpu.Queue, allocator: std.mem.Allocator) !*gpu.Texture {
    // Load the image from memory
    var img = try zigimg.Image.fromMemory(allocator, assets.sprites_sheet_png);
    defer img.deinit(allocator);
    const img_size = gpu.Extent3D{ .width = @as(u32, @intCast(img.width)), .height = @as(u32, @intCast(img.height)) };

    // Create a GPU texture
    const label = @tagName(mach_module) ++ ".loadTexture";
    const texture = device.createTexture(&.{
        .label = label,
        .size = img_size,
        .format = .rgba8_unorm,
        .usage = .{
            .texture_binding = true,
            .copy_dst = true,
        },
    });
    const data_layout = gpu.Texture.DataLayout{
        .bytes_per_row = @as(u32, @intCast(img.width * 4)),
        .rows_per_image = @as(u32, @intCast(img.height)),
    };
    switch (img.pixels) {
        .rgba32 => |pixels| queue.writeTexture(&.{ .texture = texture }, &data_layout, &img_size, pixels),
        .rgb24 => |pixels| {
            const data = try rgb24ToRgba32(allocator, pixels);
            defer data.deinit(allocator);
            queue.writeTexture(&.{ .texture = texture }, &data_layout, &img_size, data.rgba32);
        },
        else => @panic("unsupported image color format"),
    }
    return texture;
}

fn rgb24ToRgba32(allocator: std.mem.Allocator, in: []zigimg.color.Rgb24) !zigimg.color.PixelStorage {
    const out = try zigimg.color.PixelStorage.init(allocator, .rgba32, in.len);
    var i: usize = 0;
    while (i < in.len) : (i += 1) {
        out.rgba32[i] = zigimg.color.Rgba32{ .r = in[i].r, .g = in[i].g, .b = in[i].b, .a = 255 };
    }
    return out;
}
