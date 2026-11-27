//! Runs the picker: terminal setup, the event loop, and background tasks that
//! talk to Azure without blocking input.
//!
//! Memory: each background task allocates its results in a `Batch` (an arena).
//! The model borrows from batches, so replaced batches are retired and only
//! freed once no form is open and no task that may reference them is running.
const std = @import("std");
const vaxis = @import("vaxis");
const rows_mod = @import("../domain/rows.zig");
const selection = @import("../domain/selection.zig");
const session_mod = @import("../app/session.zig");
const service = @import("../app/snapshot_service.zig");
const activation = @import("../app/activation.zig");
const background_job = @import("../app/background_job.zig");
const azure_login = @import("../adapters/azure_login.zig");
const messages = @import("../present/messages.zig");
const errors = @import("../present/errors.zig");
const log = @import("../platform/log.zig");
const model_mod = @import("model.zig");
const keymap = @import("keymap.zig");
const view = @import("view.zig");
const favorites = @import("../adapters/favorites.zig");

const Row = rows_mod.Row;
const Model = model_mod.Model;
const Session = session_mod.Session;
const Allocator = std.mem.Allocator;

pub const Options = struct {
    default_duration_min: u32,
    initial_filter: []const u8 = "",
    progress_window: bool = false,
    sign_in: bool = false,
};

const Event = union(enum) {
    key_press: vaxis.Key,
    winsize: vaxis.Winsize,
    tick,
    rows_loaded: *Batch,
    policies_loaded: *Batch,
    login_code: struct { generation: u64, code: azure_login.DeviceCode },
    login_refreshing: u64,
    login_done: *Batch,
};

/// Results of one background task, owned by its arena.
const Batch = struct {
    arena: std.heap.ArenaAllocator,
    rows: ?[]Row = null,
    favorites_dir: ?[]const u8 = null,
    fetched_at: i64 = 0,
    plans: []const activation.Plan = &.{},
    failure: ?[]const u8 = null,
    jobs: []const background_job.Job = &.{},
    generation: u64 = 0,
    authentication_required: bool = false,

    fn create(gpa: Allocator) Allocator.Error!*Batch {
        const b = try gpa.create(Batch);
        b.* = .{ .arena = .init(gpa) };
        return b;
    }

    fn allocator(b: *Batch) Allocator {
        return b.arena.allocator();
    }

    fn release(b: *Batch, gpa: Allocator) void {
        b.arena.deinit();
        gpa.destroy(b);
    }
};

const App = struct {
    gpa: Allocator,
    io: std.Io,
    session: *Session,
    loop: *vaxis.Loop(Event),
    group: std.Io.Group = .init,
    login_group: std.Io.Group = .init,
    login_generation: u64 = 0,
    generation: u64 = 0,
    /// Background tasks whose result has not been handled yet.
    inflight: usize = 0,

    rows_batch: ?*Batch = null,
    policies_batch: ?*Batch = null,
    job_batch: ?*Batch = null,
    jobs_refresh_pending: bool = false,
    jobs_dirty: bool = false,
    retired: std.ArrayList(*Batch) = .empty,

    fn deinit(app: *App) void {
        app.login_group.cancel(app.io);
        app.group.cancel(app.io);
        while (app.loop.tryEvent() catch null) |event| switch (event) {
            .rows_loaded, .policies_loaded, .login_done => |b| b.release(app.gpa),
            else => {},
        };
        for ([_]?*Batch{ app.rows_batch, app.policies_batch, app.job_batch }) |b| if (b) |batch| batch.release(app.gpa);
        for (app.retired.items) |b| b.release(app.gpa);
        app.retired.deinit(app.gpa);
    }

    fn now(app: *const App) i64 {
        return std.Io.Clock.real.now(app.io).toSeconds();
    }

    /// Hands a finished task's batch to the UI thread, or frees it if the
    /// loop has already stopped.
    fn post(app: *App, event: Event) void {
        app.loop.postEvent(event) catch switch (event) {
            .rows_loaded, .policies_loaded, .login_done => |b| b.release(app.gpa),
            else => {},
        };
    }

    /// Starts a task; returns false (and tells the user) if that failed, in
    /// which case the caller still owns the arguments.
    fn spawn(app: *App, m: *Model, comptime function: anytype, args: anytype) bool {
        const batch = Batch.create(app.gpa) catch {
            m.refreshing = false;
            m.setNotice(.failed, "Not enough memory to start a background task.");
            return false;
        };
        app.group.concurrent(app.io, function, args ++ .{batch}) catch {
            batch.release(app.gpa);
            m.refreshing = false;
            m.setNotice(.failed, "Could not start a background task.");
            return false;
        };
        app.inflight += 1;
        return true;
    }

    /// Performs an effect. Returns true when the UI should exit.
    fn perform(app: *App, m: *Model, effect: model_mod.Effect) bool {
        switch (effect) {
            .none => {},
            .quit => return true,
            .refresh => _ = app.spawn(m, refreshTask, .{ app, app.generation }),
            .toggle_favorite => |row| app.toggleFavorite(m, row) catch
                m.setNotice(.failed, "Could not save favorites. Check the state directory and Azure account."),
            .load_policies => |targets| if (!app.spawn(m, policiesTask, .{ app, targets, m.default_duration_min, app.generation })) app.gpa.free(targets),
            .sign_in => |method| app.startSignIn(m, method),
            .cancel_sign_in => {
                app.login_generation +%= 1;
                app.generation +%= 1;
                app.login_group.cancel(app.io);
                m.refreshing = false;
                m.setNotice(.info, "Sign-in cancelled. No roles were retried.");
                app.acknowledgeRetries();
            },
            .dismiss_sign_in => app.acknowledgeRetries(),
            .activate => |job| {
                app.startOperation(m, .activate, job.targets, job.duration_min, job.justification);
                app.gpa.free(job.targets);
                app.gpa.free(job.justification);
            },
            .deactivate => |targets| {
                app.startOperation(m, .deactivate, targets, 0, "");
                app.gpa.free(targets);
            },
        }
        return false;
    }

    fn handle(app: *App, m: *Model, event: Event) Allocator.Error!void {
        switch (event) {
            .rows_loaded => |b| {
                app.inflight -= 1;
                if (b.generation != app.generation) return app.retire(b);
                if (b.failure) |msg| {
                    m.setRefreshFailed(msg);
                    if (b.authentication_required) try app.offerSignIn(m);
                    try app.retire(b);
                } else try app.adoptRows(m, b);
            },
            .policies_loaded => |b| {
                app.inflight -= 1;
                if (b.generation != app.generation) return app.retire(b);
                if (app.policies_batch) |old| try app.retire(old);
                app.policies_batch = b;
                if (b.failure) |msg| {
                    m.setNotice(.failed, msg);
                    if (b.authentication_required) try app.offerSignIn(m);
                } else m.setPolicies(b.plans);
            },
            .login_code => |update| {
                if (update.generation == app.login_generation and m.sign_in_state == .running)
                    m.sign_in_code = update.code;
            },
            .login_refreshing => |generation| {
                if (generation == app.login_generation) {
                    m.sign_in_state = .refreshing;
                    m.sign_in_code = null;
                    m.refreshing = true;
                }
            },
            .login_done => |b| {
                if (b.generation != app.login_generation) return app.retire(b);
                if (b.failure) |msg| {
                    m.signInFailed(msg);
                    try app.retire(b);
                } else {
                    try app.adoptRows(m, b);
                    app.jobs_refresh_pending = false;
                    m.signInComplete();
                    app.acknowledgeRetries();
                }
            },
            else => unreachable,
        }
    }

    fn startSignIn(app: *App, m: *Model, method: azure_login.Method) void {
        app.login_generation +%= 1;
        app.generation +%= 1;
        app.login_group.cancel(app.io);
        m.refreshing = false;
        const batch = Batch.create(app.gpa) catch {
            m.signInFailed("Not enough memory to start Azure sign-in.");
            return;
        };
        app.login_group.concurrent(app.io, loginTask, .{ app, app.login_generation, method, batch }) catch {
            batch.release(app.gpa);
            m.signInFailed("Could not start Azure sign-in. Press enter to try again.");
        };
    }

    fn acknowledgeRetries(app: *App) void {
        if (app.job_batch == null) return;
        var arena: std.heap.ArenaAllocator = .init(app.gpa);
        defer arena.deinit();
        background_job.acknowledgeRetries(app.session, arena.allocator()) catch {};
    }

    fn startOperation(app: *App, m: *Model, intent: selection.Intent, targets: []const Row, duration_min: u32, justification: []const u8) void {
        var arena: std.heap.ArenaAllocator = .init(app.gpa);
        defer arena.deinit();
        const child = background_job.start(app.session, arena.allocator(), intent, targets, duration_min, justification) catch |err| {
            app.syncJobs(m, true) catch {
                if (app.job_batch) |known| {
                    app.applyJobs(m, known) catch {};
                } else m.endOperation();
            };
            m.setNotice(.failed, if (err == error.OperationInProgress)
                "One of these roles is already being processed. No duplicate requests were submitted."
            else if (err == error.IdentityChanged)
                "Azure identity changed. Reopen the picker before submitting requests."
            else
                "Could not start the background operation; no requests were submitted.");
            if (err == error.AzCliFailed and m.sign_in_enabled) {
                m.rememberRetry(targets, intent, duration_min) catch {};
                m.requireSignIn() catch {};
            }
            return;
        };
        // Cancellation stops waiting, not the independent worker.
        app.group.concurrent(app.io, reapWorker, .{ app.io, child }) catch {};
        m.busy_since = app.now();
        app.syncJob(m) catch m.setNotice(.failed, "Could not read background progress. The operation may still be running.");
    }

    fn syncJob(app: *App, m: *Model) !void {
        try app.syncJobs(m, false);
    }

    fn syncJobs(app: *App, m: *Model, force: bool) !void {
        const b = try Batch.create(app.gpa);
        errdefer if (app.job_batch != b) b.release(app.gpa);
        b.jobs = try background_job.loadFor(app.session, b.allocator());
        if (background_job.needsReconcile(b.jobs, app.now())) app.jobs_refresh_pending = true;
        const previous = if (app.job_batch) |old| old.jobs else &.{};
        if (!force and !app.jobs_dirty and sameJobStates(previous, b.jobs)) {
            b.release(app.gpa);
            app.refreshJobs(m);
            return;
        }
        try app.adoptJobs(m, b);
        app.refreshJobs(m);
    }

    fn adoptJobs(app: *App, m: *Model, b: *Batch) !void {
        try app.retired.ensureUnusedCapacity(app.gpa, 1);
        app.applyJobs(m, b) catch |err| {
            // Model fields may already borrow from b. Retain ownership on error.
            if (app.job_batch) |old| app.retired.appendAssumeCapacity(old);
            app.job_batch = b;
            app.jobs_dirty = true;
            return err;
        };
        app.jobs_dirty = false;
        if (app.job_batch) |old| app.retired.appendAssumeCapacity(old);
        app.job_batch = b;
    }

    fn applyJobs(app: *App, m: *Model, b: *Batch) !void {
        const arena = b.allocator();
        const previous = if (app.job_batch) |old| old.jobs else &.{};
        var working: std.ArrayList(Row) = .empty;
        var lines: std.ArrayList(messages.Line) = .empty;
        var label: ?[]const u8 = null;
        var since: i64 = 0;
        var new_auth_failure = false;
        var workers_running = false;
        const was_running = m.busy != null;
        for (b.jobs) |job| {
            if (!job.done) workers_running = true;
            if (background_job.blocks(job)) {
                if (working.items.len == 0) since = job.started_at;
                const action: []const u8 = if (job.intent == .activate) "Activating" else "Deactivating";
                label = if (label == null or std.mem.eql(u8, label.?, action)) action else "Processing";
                try working.appendSlice(arena, job.targets);
                continue;
            }
            const newly_done = for (previous) |old| {
                if (std.mem.eql(u8, old.id, job.id)) break !old.done;
            } else true;
            if (newly_done) {
                app.jobs_refresh_pending = true;
                if (job.retry_pending) new_auth_failure = true;
            }
            try lines.appendSlice(arena, job.lines);
            if (job.failure) |failure|
                try lines.append(arena, .{ .kind = .failed, .glyph = "!", .text = failure });
        }
        // All running workers remain represented when one finishes or a new one starts.
        try m.setRunning(label orelse "Processing", working.items, since);
        m.workers_running = workers_running;
        m.results = lines.items;
        if (new_auth_failure and m.sign_in_enabled and (was_running or m.authentication_required))
            m.authentication_required = true;
        if (!m.workers_running and m.authentication_required and m.sign_in_enabled)
            try offerSignInForJobs(m, b.jobs);
    }

    fn offerSignIn(app: *App, m: *Model) !void {
        return offerSignInForJobs(m, if (app.job_batch) |b| b.jobs else &.{});
    }

    fn refreshJobs(app: *App, m: *Model) void {
        if (!app.jobs_refresh_pending or m.refreshing or m.sign_in_state == .running or m.sign_in_state == .refreshing) return;
        if (m.sign_in_enabled and m.authentication_required) return;
        m.refreshing = true;
        if (app.spawn(m, refreshTask, .{ app, app.generation }))
            app.jobs_refresh_pending = false;
    }

    fn adoptRows(app: *App, m: *Model, b: *Batch) Allocator.Error!void {
        var scratch: std.heap.ArenaAllocator = .init(app.gpa);
        defer scratch.deinit();
        if (b.favorites_dir) |path| {
            const saved = favorites.load(scratch.allocator(), app.io, path) catch null;
            if (saved) |value| {
                try value.apply(scratch.allocator(), b.rows.?);
            } else m.setNotice(.failed, "Could not read favorites.");
        }
        try m.setRows(b.rows.?, b.fetched_at);
        if (app.rows_batch) |old| try app.retire(old);
        app.rows_batch = b;
    }

    fn toggleFavorite(app: *App, m: *Model, row: Row) !void {
        const batch = app.rows_batch orelse return;
        var scratch: std.heap.ArenaAllocator = .init(app.gpa);
        defer scratch.deinit();
        const arena = scratch.allocator();
        var diag: session_mod.Diagnostics = .{};
        const dir = try app.session.cacheDir(arena, &diag);
        const updated = try favorites.toggle(arena, app.io, dir, row);
        try updated.apply(arena, batch.rows.?);
        try m.favoritesChanged();
    }

    fn retire(app: *App, b: *Batch) Allocator.Error!void {
        try app.retired.append(app.gpa, b);
    }

    /// Frees retired batches once nothing can still point into them.
    fn collect(app: *App, m: *const Model) void {
        if (app.inflight > 0 or m.mode != .browse or app.jobs_dirty or
            (m.busy != null and !m.working_from_jobs)) return;
        if (app.policies_batch) |b| {
            app.policies_batch = null;
            b.release(app.gpa);
        }
        for (app.retired.items) |b| b.release(app.gpa);
        app.retired.clearRetainingCapacity();
    }
};

fn offerSignInForJobs(m: *Model, jobs: []const background_job.Job) !void {
    // Keep an actively edited form's retry selection, otherwise recover failed batches.
    if (m.sign_in_enabled and !m.workers_running and m.mode == .browse and !m.authentication_prompted) {
        var latest: ?background_job.Job = null;
        for (jobs) |job| {
            if (job.done and job.retry_pending) latest = job;
        }
        if (latest) |job| {
            // Independent batches can have different durations and user intent.
            try m.rememberRetry(job.targets, job.intent, job.duration_min);
        }
    }
    try m.requireSignIn();
}

fn sameJobStates(a: []const background_job.Job, b: []const background_job.Job) bool {
    if (a.len != b.len) return false;
    for (a, b) |left, right|
        if (!std.mem.eql(u8, left.id, right.id) or left.done != right.done or left.revision != right.revision) return false;
    return true;
}

// ---- background tasks --------------------------------------------------------

fn refreshTask(app: *App, generation: u64, b: *Batch) void {
    b.generation = generation;
    var diag: session_mod.Diagnostics = .{};
    loadRows(app, b, &diag) catch |err| {
        b.authentication_required = errors.needsSignIn(err, diag);
        b.failure = errors.summaryAlloc(b.allocator(), err, diag) catch "Refresh failed";
    };
    if (b.failure == null) background_job.reconcile(app.session, b.allocator(), &diag) catch |err| {
        if (err == error.Canceled) {
            b.failure = "Refresh cancelled.";
        } else std.log.warn("could not reconcile Azure requests: {t}", .{err});
    };
    app.post(.{ .rows_loaded = b });
}

fn loadRows(app: *App, b: *Batch, diag: *session_mod.Diagnostics) errors.Error!void {
    const now = app.now();
    const snapshot = try service.refresh(app.session, b.allocator(), now, diag);
    b.rows = try rows_mod.build(b.allocator(), snapshot, now);
    b.favorites_dir = try app.session.cacheDir(b.allocator(), diag);
    b.fetched_at = snapshot.fetched_at;
}

fn policiesTask(app: *App, targets: []Row, requested_min: u32, generation: u64, b: *Batch) void {
    defer app.gpa.free(targets);
    b.generation = generation;
    var diag: session_mod.Diagnostics = .{};
    b.plans = activation.plan(app.session, b.allocator(), targets, requested_min, &diag) catch |err| blk: {
        b.authentication_required = errors.needsSignIn(err, diag);
        b.failure = errors.summaryAlloc(b.allocator(), err, diag) catch "Could not read policies";
        break :blk &.{};
    };
    app.post(.{ .policies_loaded = b });
}

const LoginProgress = struct {
    app: *App,
    generation: u64,

    fn update(context: *anyopaque, code: azure_login.DeviceCode) void {
        const progress: *LoginProgress = @ptrCast(@alignCast(context));
        progress.app.post(.{ .login_code = .{ .generation = progress.generation, .code = code } });
    }
};

fn loginTask(app: *App, generation: u64, method: azure_login.Method, b: *Batch) void {
    b.generation = generation;
    var progress: LoginProgress = .{ .app = app, .generation = generation };
    const env = app.session.env;
    azure_login.login(b.allocator(), app.io, env.environ, method, .{ .context = &progress, .update = LoginProgress.update }) catch |err| {
        b.failure = switch (err) {
            error.AzCliNotFound => "Azure CLI was not found. Install az, then try again.",
            error.TimedOut => "Azure sign-in timed out. Press enter to retry or d for a device code.",
            else => "Azure sign-in failed or was cancelled. Press enter to retry or d for a device code.",
        };
        app.post(.{ .login_done = b });
        return;
    };
    app.post(.{ .login_refreshing = generation });
    var diag: session_mod.Diagnostics = .{};
    app.session.invalidateToken() catch {
        b.failure = "Sign-in was cancelled before roles could be refreshed.";
        app.post(.{ .login_done = b });
        return;
    };
    loadRows(app, b, &diag) catch |err| {
        b.failure = std.fmt.allocPrint(b.allocator(), "Signed in, but role refresh failed: {s}", .{
            errors.summaryAlloc(b.allocator(), err, diag) catch "could not contact Azure",
        }) catch "Signed in, but role refresh failed. Dismiss and press Ctrl-R to refresh.";
    };
    app.post(.{ .login_done = b });
}

fn reapWorker(io: std.Io, process: std.process.Child) void {
    var child = process;
    _ = child.wait(io) catch {};
}

fn tickTask(app: *App) std.Io.Cancelable!void {
    while (true) {
        try app.io.sleep(.fromMilliseconds(model_mod.tick_ms), .awake);
        app.loop.postEvent(.tick) catch return;
    }
}

// ---- entry point -------------------------------------------------------------

pub fn run(gpa: Allocator, io: std.Io, environ: *std.process.Environ.Map, session: *Session, opts: Options) !void {
    var tty_buffer: [4096]u8 = undefined;
    var tty = try vaxis.Tty.init(io, &tty_buffer);
    defer tty.deinit();
    const out = tty.writer();

    var vx = try vaxis.init(io, gpa, environ, .{});
    defer vx.deinit(gpa, out);

    var loop: vaxis.Loop(Event) = .init(io, &tty, &vx);
    try loop.installResizeHandler();
    defer loop.uninstallResizeHandler();
    try loop.start();
    defer loop.stop();

    log.setMuted(true);
    defer log.setMuted(false);
    try vx.enterAltScreen(out);
    defer vx.exitAltScreen(out) catch {};
    try vx.queryTerminal(out, .fromSeconds(1));

    var model: Model = .init(gpa, opts.default_duration_min);
    defer model.deinit();
    model.filter.set(opts.initial_filter);
    model.progress_window = opts.progress_window;
    model.sign_in_enabled = opts.sign_in;

    var app: App = .{ .gpa = gpa, .io = io, .session = session, .loop = &loop };
    defer app.deinit();

    if (try loadCachedRows(&app)) |b| {
        try app.adoptRows(&model, b);
    } else {
        try model.setRows(&.{}, 0);
        model.fetched_at = null;
    }
    model.refreshing = true;
    _ = app.spawn(&model, refreshTask, .{ &app, app.generation });
    app.syncJob(&model) catch model.setNotice(.info, "Job history unavailable until Azure sign-in is restored.");
    app.group.concurrent(io, tickTask, .{&app}) catch {};

    var frame: std.heap.ArenaAllocator = .init(gpa);
    defer frame.deinit();

    while (true) {
        const event = try loop.nextEvent();
        switch (event) {
            .key_press => |key| if (keymap.translate(key)) |input| {
                if (app.perform(&model, try model.update(input))) break;
            },
            .winsize => |ws| try vx.resize(gpa, out, ws),
            .tick => {
                if (!model.tick()) continue;
                if (model.ticks % model_mod.ticks_per_second == 0)
                    app.syncJob(&model) catch model.setNotice(.failed, "Could not read background progress.");
            },
            else => try app.handle(&model, event),
        }
        app.collect(&model);

        _ = frame.reset(.retain_capacity);
        try view.draw(frame.allocator(), vx.window(), &model, app.now());
        try vx.render(out);
        try out.flush();
    }
}

/// Shows cached data instantly; a background refresh replaces it.
fn loadCachedRows(app: *App) Allocator.Error!?*Batch {
    const b = try Batch.create(app.gpa);
    const snapshot = service.loadCached(app.session, b.allocator()) orelse {
        b.release(app.gpa);
        return null;
    };
    b.rows = try rows_mod.build(b.allocator(), snapshot, app.now());
    var diag: session_mod.Diagnostics = .{};
    b.favorites_dir = app.session.cacheDir(b.allocator(), &diag) catch null;
    b.fetched_at = snapshot.fetched_at;
    return b;
}

test "adopting refreshed rows reloads the latest persisted favorites" {
    const testing = std.testing;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var scratch: std.heap.ArenaAllocator = .init(testing.allocator);
    defer scratch.deinit();
    const arena = scratch.allocator();
    const root = try tmp.dir.realPathFileAlloc(testing.io, ".", arena);
    var model: Model = .init(testing.allocator, 480);
    defer model.deinit();
    var app: App = .{ .gpa = testing.allocator, .io = testing.io, .session = undefined, .loop = undefined };
    defer {
        if (app.rows_batch) |b| b.release(testing.allocator);
        for (app.retired.items) |b| b.release(testing.allocator);
        app.retired.deinit(testing.allocator);
    }
    const a: Row = .{
        .eligibility = .{ .schedule_id = "a", .scope = "/a", .scope_name = "a", .role_definition_id = "r", .role_name = "Role" },
        .subscription_name = "Sub",
        .state = .active,
    };
    var b = a;
    b.eligibility.schedule_id = "b";
    b.eligibility.scope = "/b";
    b.state = .eligible;
    _ = try favorites.toggle(arena, testing.io, root, b);
    const first = try Batch.create(testing.allocator);
    first.rows = try first.allocator().dupe(Row, &.{ a, b });
    first.favorites_dir = root;
    try app.adoptRows(&model, first);
    try testing.expectEqualStrings("b", model.currentRow().?.eligibility.schedule_id);
    _ = try favorites.toggle(arena, testing.io, root, b);
    const refreshed = try Batch.create(testing.allocator);
    refreshed.rows = try refreshed.allocator().dupe(Row, &.{ a, b });
    refreshed.favorites_dir = root;
    try app.adoptRows(&model, refreshed);
    try testing.expect(!model.currentRow().?.favorite);
    try testing.expectEqualStrings("b", model.currentRow().?.eligibility.schedule_id);
    try testing.expectEqual(@as(u32, 0), model.visible.items[0]);
}

test "login refresh replaces roles but stale pre-login results cannot reopen authentication" {
    const testing = std.testing;
    var model: Model = .init(testing.allocator, 480);
    defer model.deinit();
    model.sign_in_enabled = true;
    model.mode = .sign_in;
    model.sign_in_state = .running;
    const target: Row = .{
        .eligibility = .{ .schedule_id = "one", .scope = "", .scope_name = "rg", .role_definition_id = "owner", .role_name = "Owner" },
        .subscription_name = "Sub",
        .state = .eligible,
    };
    try model.setRows(&.{target}, 1);
    try model.rememberRetry(&.{target}, .activate, 60);
    var app: App = .{
        .gpa = testing.allocator,
        .io = testing.io,
        .session = undefined,
        .loop = undefined,
        .generation = 2,
        .login_generation = 3,
        .inflight = 1,
    };
    defer {
        if (app.rows_batch) |b| b.release(testing.allocator);
        for (app.retired.items) |b| b.release(testing.allocator);
        app.retired.deinit(testing.allocator);
    }
    const stale = try Batch.create(testing.allocator);
    stale.generation = 1;
    stale.failure = "Expired login";
    stale.authentication_required = true;
    try app.handle(&model, .{ .rows_loaded = stale });
    try testing.expect(!model.authentication_required);
    try testing.expectEqual(model_mod.SignInState.running, model.sign_in_state);

    try app.handle(&model, .{ .login_refreshing = 2 });
    try testing.expectEqual(model_mod.SignInState.running, model.sign_in_state);
    try app.handle(&model, .{ .login_refreshing = 3 });
    try testing.expectEqual(model_mod.SignInState.refreshing, model.sign_in_state);
    const done = try Batch.create(testing.allocator);
    done.generation = 3;
    var active = target;
    active.state = .active;
    done.rows = try done.allocator().dupe(Row, &.{active});
    done.fetched_at = 100;
    try app.handle(&model, .{ .login_done = done });
    try testing.expectEqual(model_mod.SignInState.ready, model.sign_in_state);
    try testing.expectEqual(rows_mod.State.active, model.rows[0].state);
    try testing.expectEqual(@as(usize, 0), model.selected.count());
    try testing.expect(model.busy == null);
}

test "parallel jobs restore all running roles and one completion preserves an open form" {
    const testing = std.testing;
    var model: Model = .init(testing.allocator, 480);
    defer model.deinit();
    const a: Row = .{
        .eligibility = .{ .schedule_id = "a", .scope = "/a", .scope_name = "a", .role_definition_id = "owner", .role_name = "Owner" },
        .subscription_name = "Sub",
        .state = .eligible,
    };
    var b = a;
    b.eligibility.schedule_id = "b";
    b.eligibility.scope = "/b";
    var c = a;
    c.eligibility.schedule_id = "c";
    c.eligibility.scope = "/c";
    try model.setRows(&.{ a, b, c }, 1);
    var app: App = .{ .gpa = testing.allocator, .io = testing.io, .session = undefined, .loop = undefined };
    const first = try Batch.create(testing.allocator);
    defer first.release(testing.allocator);
    first.jobs = &.{
        .{ .id = "one", .intent = .activate, .targets = &.{a}, .duration_min = 60, .started_at = 10 },
        .{ .id = "two", .intent = .activate, .targets = &.{b}, .duration_min = 60, .started_at = 11 },
    };
    try app.applyJobs(&model, first);
    app.job_batch = first;
    try testing.expectEqual(@as(usize, 2), model.working.len);
    try testing.expectEqual(@as(i64, 10), model.busy_since);
    _ = try model.update(.end);
    const effect = try model.update(.enter);
    defer testing.allocator.free(effect.load_policies);
    model.justification.set("third role");

    const second = try Batch.create(testing.allocator);
    defer second.release(testing.allocator);
    var completed = first.jobs[1];
    completed.done = true;
    completed.lines = &.{.{ .kind = .ok, .glyph = "*", .text = "b active" }};
    second.jobs = &.{ first.jobs[0], completed };
    try app.applyJobs(&model, second);
    try testing.expectEqual(@as(usize, 1), model.working.len);
    try testing.expect(model.isWorking(a) and !model.isWorking(b));
    try testing.expectEqual(model_mod.Mode.form, model.mode);
    try testing.expectEqualStrings("third role", model.justification.text());
    try testing.expectEqualStrings("b active", model.results[0].text);
    try testing.expect(app.jobs_refresh_pending);
    app.job_batch = second;
    const final = try Batch.create(testing.allocator);
    defer final.release(testing.allocator);
    var done = first.jobs[0];
    done.done = true;
    done.failure = "a failed";
    final.jobs = &.{ done, completed };
    try app.applyJobs(&model, final);
    try testing.expect(model.busy == null);
    try testing.expectEqual(@as(usize, 2), model.results.len);
    try testing.expectEqual(model_mod.Mode.form, model.mode);
}

test "parallel authentication failures wait for workers then preserve all failed activation targets" {
    const testing = std.testing;
    var model: Model = .init(testing.allocator, 480);
    defer model.deinit();
    model.sign_in_enabled = true;
    const a: Row = .{
        .eligibility = .{ .schedule_id = "a", .scope = "/a", .scope_name = "a", .role_definition_id = "owner", .role_name = "Owner" },
        .subscription_name = "Sub",
        .state = .eligible,
    };
    var b = a;
    b.eligibility.schedule_id = "b";
    b.eligibility.scope = "/b";
    try model.setRows(&.{ a, b }, 1);
    var app: App = .{ .gpa = testing.allocator, .io = testing.io, .session = undefined, .loop = undefined };
    const first = try Batch.create(testing.allocator);
    defer first.release(testing.allocator);
    first.jobs = &.{
        .{ .id = "one", .intent = .activate, .targets = &.{a}, .duration_min = 60, .started_at = 10 },
        .{ .id = "two", .intent = .activate, .targets = &.{b}, .duration_min = 90, .started_at = 11 },
    };
    try app.applyJobs(&model, first);
    app.job_batch = first;
    var failed_a = first.jobs[0];
    failed_a.done = true;
    failed_a.failure = "sign in";
    failed_a.authentication_required = true;
    failed_a.retry_pending = true;
    const second = try Batch.create(testing.allocator);
    defer second.release(testing.allocator);
    second.jobs = &.{ failed_a, first.jobs[1] };
    try app.applyJobs(&model, second);
    try testing.expect(model.authentication_required);
    try testing.expectEqual(model_mod.Mode.browse, model.mode);
    try testing.expect(model.isWorking(b));
    app.job_batch = second;
    var failed_b = first.jobs[1];
    failed_b.done = true;
    failed_b.failure = "sign in";
    failed_b.authentication_required = true;
    failed_b.retry_pending = true;
    const final = try Batch.create(testing.allocator);
    defer final.release(testing.allocator);
    final.jobs = &.{ failed_a, failed_b };
    try app.applyJobs(&model, final);
    try testing.expectEqual(model_mod.Mode.sign_in, model.mode);
    try testing.expectEqual(@as(usize, 1), model.selected.count());
    try testing.expect(model.busy == null);
    try testing.expectEqual(@as(?u32, 90), model.retry_duration_min);
}

test "allocation failure after publishing job results retains the backing batch" {
    const testing = std.testing;
    var failing = testing.FailingAllocator.init(testing.allocator, .{ .fail_index = 1 });
    const gpa = failing.allocator();
    var model: Model = .init(gpa, 480);
    defer model.deinit();
    model.sign_in_enabled = true;
    model.authentication_required = true;
    var app: App = .{ .gpa = gpa, .io = testing.io, .session = undefined, .loop = undefined };
    const batch = try Batch.create(testing.allocator);
    defer {
        batch.release(gpa);
        app.retired.deinit(gpa);
    }
    batch.jobs = &.{.{
        .id = "failed",
        .intent = .activate,
        .targets = &.{.{
            .eligibility = .{ .schedule_id = "one", .scope = "/s", .scope_name = "s", .role_definition_id = "owner", .role_name = "Owner" },
            .subscription_name = "Sub",
            .state = .eligible,
        }},
        .duration_min = 60,
        .started_at = 1,
        .done = true,
        .authentication_required = true,
        .retry_pending = true,
        .failure = "sign in",
    }};
    try testing.expectError(error.OutOfMemory, app.adoptJobs(&model, batch));
    try testing.expect(app.job_batch == batch and app.jobs_dirty);
    try testing.expectEqual(messages.Kind.failed, model.results[0].kind);
    try testing.expectEqualStrings("sign in", model.results[0].text);
}

test "historical authentication failures are excluded and retry keeps one batch duration" {
    const testing = std.testing;
    var model: Model = .init(testing.allocator, 480);
    defer model.deinit();
    model.sign_in_enabled = true;
    const old: Row = .{
        .eligibility = .{ .schedule_id = "old", .scope = "/old", .scope_name = "old", .role_definition_id = "owner", .role_name = "Owner" },
        .subscription_name = "Sub",
        .state = .eligible,
    };
    var current = old;
    current.eligibility.schedule_id = "current";
    current.eligibility.scope = "/current";
    const jobs: []const background_job.Job = &.{
        .{ .id = "historical", .intent = .activate, .targets = &.{old}, .duration_min = 480, .started_at = 1, .done = true, .authentication_required = true },
        .{ .id = "current", .intent = .activate, .targets = &.{current}, .duration_min = 60, .started_at = 2, .done = true, .authentication_required = true, .retry_pending = true },
    };
    try offerSignInForJobs(&model, jobs);
    try testing.expect(!model.isSelected(old) and model.isSelected(current));
    try testing.expectEqual(@as(?u32, 60), model.retry_duration_min);
}
