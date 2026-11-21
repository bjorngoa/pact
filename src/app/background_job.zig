//! Picker operations outlive the terminal. The worker inherits an exclusive
//! file lock through stdin, so there is no unlocked handoff or stale PID reuse.
const std = @import("std");
const builtin = @import("builtin");
const store = @import("../adapters/json_store.zig");
const herdr = @import("../adapters/herdr.zig");
const rows_mod = @import("../domain/rows.zig");
const selection = @import("../domain/selection.zig");
const session_mod = @import("session.zig");
const activation = @import("activation.zig");
const service = @import("snapshot_service.zig");
const messages = @import("../present/messages.zig");
const errors = @import("../present/errors.zig");
const arm = @import("../adapters/arm/client.zig");
const request_status = @import("../domain/request_status.zig");

pub const worker_command = "__background-worker";
const file_name = "operation.json";
const lock_name = "operation.lock";
const jobs_dir_name = "operations";
const registry_lock_name = "operations.lock";
const private_file: std.Io.File.Permissions =
    if (@hasDecl(std.Io.File.Permissions, "fromMode")) .fromMode(0o600) else .default_file;
const private_dir: std.Io.Dir.Permissions =
    if (@hasDecl(std.Io.Dir.Permissions, "fromMode")) .fromMode(0o700) else .default_dir;

pub const Job = struct {
    pub const schema_version: u32 = 1;
    version: u32 = schema_version,
    id: []const u8,
    intent: selection.Intent,
    targets: []const rows_mod.Row,
    duration_min: u32,
    started_at: i64,
    done: bool = false,
    lines: []const messages.Line = &.{},
    failure: ?[]const u8 = null,
    authentication_required: bool = false,
    retry_pending: bool = false,
    owner_key: ?[]const u8 = null,
    principal_id: ?[]const u8 = null,
    requests: []TrackedRequest = &.{},
    revision: u32 = 0,
    finished_at: i64 = 0,
    reconciled_at: i64 = 0,
    legacy_resolved: bool = false,
    legacy_unresolved: bool = false,
    /// Cleared by the worker before it contacts Azure.
    justification: ?[]const u8 = null,
};

pub const TrackedRequest = struct {
    id: []const u8,
    row: rows_mod.Row,
    attempted: bool = false,
    state: request_status.State = .unknown,
    azure_status: []const u8 = "",

    fn unresolved(request: TrackedRequest) bool {
        return request.attempted and request.state != .succeeded and request.state != .failed;
    }
};

pub fn blocks(job: Job) bool {
    if (!job.done) return true;
    if (job.legacy_unresolved and !job.legacy_resolved) return true;
    for (job.requests) |request| if (request.unresolved()) return true;
    if (job.requests.len == 0 and !job.legacy_resolved) {
        for (job.lines) |line| if (line.kind == .pending) return true;
    }
    return false;
}

fn createJob(session: *session_mod.Session, arena: std.mem.Allocator, intent: selection.Intent, targets: []const rows_mod.Row, duration_min: u32, justification: []const u8) !Job {
    var diag: session_mod.Diagnostics = .{};
    const owner = try session.identityKey(&diag);
    const principal = try session.principalId(&diag);
    var random: [16]u8 = undefined;
    try session.env.io.randomSecure(&random);
    const requests = try arena.alloc(TrackedRequest, targets.len);
    for (targets, requests) |row, *request| {
        const id = try arm.Client.requestId(session.env.io);
        request.* = .{ .id = try arena.dupe(u8, &id), .row = row };
    }
    return .{
        .id = try arena.dupe(u8, &std.fmt.bytesToHex(random, .lower)),
        .owner_key = owner,
        .principal_id = principal,
        .intent = intent,
        .targets = targets,
        .duration_min = duration_min,
        .started_at = std.Io.Clock.real.now(session.env.io).toSeconds(),
        .justification = justification,
        .requests = requests,
    };
}

/// Caller must reap the child, but must never kill it when the picker closes.
pub fn start(session: *session_mod.Session, arena: std.mem.Allocator, intent: selection.Intent, targets: []const rows_mod.Row, duration_min: u32, justification: []const u8) !std.process.Child {
    const env = session.env;
    var job = try createJob(session, arena, intent, targets, duration_min, justification);
    const exe = try std.process.executablePathAlloc(env.io, arena);
    // Serialize only the reservation, not the Azure operation.
    const registry = try acquireNamed(env.io, env.state_dir, registry_lock_name, false);
    defer registry.close(env.io);
    const reserved = try reserve(arena, env, job);
    defer reserved.lock.close(env.io);
    return std.process.spawn(env.io, .{
        .argv = &.{ exe, worker_command, job.id },
        .environ_map = env.environ,
        .stdin = .{ .file = reserved.lock },
        .stdout = .ignore,
        .stderr = .ignore,
        .pgid = if (builtin.os.tag == .windows) null else 0,
        .create_no_window = true,
    }) catch |err| {
        job.done = true;
        job.justification = null;
        job.failure = "Could not start the background worker; no requests were submitted.";
        try store.save(Job, env.io, reserved.dir, reserved.file, job);
        return err;
    };
}

const Reservation = struct { lock: std.Io.File, dir: []const u8, file: []const u8 };

/// Caller holds the short-lived registry lock until the worker inherits its lock.
fn reserve(arena: std.mem.Allocator, env: session_mod.Env, job: Job) !Reservation {
    if (job.targets.len == 0) return error.NothingSelected;
    for (job.targets, 0..) |target, i| {
        for (job.targets[0..i]) |earlier|
            if (rows_mod.sameRole(target, earlier)) return error.OperationInProgress;
    }
    const existing = try loadAllUnlocked(arena, env);
    for (existing) |other| {
        if (!blocks(other)) continue;
        if (other.owner_key != null and job.owner_key != null and !std.mem.eql(u8, other.owner_key.?, job.owner_key.?)) continue;
        for (other.targets) |working| {
            for (job.targets) |target|
                if (rows_mod.sameRole(working, target)) return error.OperationInProgress;
        }
    }
    const dir = try std.fs.path.join(arena, &.{ env.state_dir, jobs_dir_name });
    const file = try jobFile(arena, job.id, ".json");
    const lock = try acquireNamed(env.io, dir, try jobFile(arena, job.id, ".lock"), true);
    errdefer lock.close(env.io);
    try store.save(Job, env.io, dir, file, job);
    return .{ .lock = lock, .dir = dir, .file = file };
}

fn jobFile(arena: std.mem.Allocator, id: []const u8, extension: []const u8) ![]const u8 {
    if (id.len == 0 or id.len > 64) return error.InvalidJobId;
    for (id) |c| if (!std.ascii.isAlphanumeric(c) and c != '-') return error.InvalidJobId;
    return std.mem.concat(arena, u8, &.{ id, extension });
}

fn acquireNamed(io: std.Io, state_dir: []const u8, name: []const u8, nonblocking: bool) !std.Io.File {
    var dir = try std.Io.Dir.cwd().createDirPathOpen(io, state_dir, .{ .permissions = private_dir });
    defer dir.close(io);
    return dir.createFile(io, name, .{
        .read = true,
        .truncate = false,
        .lock = .exclusive,
        .lock_nonblocking = nonblocking,
        .permissions = private_file,
    }) catch |err| switch (err) {
        error.WouldBlock => error.OperationInProgress,
        else => err,
    };
}

/// A lost worker is reported, never retried: Azure may have accepted requests.
pub fn load(arena: std.mem.Allocator, env: session_mod.Env) !?Job {
    return loadOne(arena, env.io, env.state_dir, file_name, lock_name);
}

pub fn loadAll(arena: std.mem.Allocator, env: session_mod.Env) ![]const Job {
    const registry = try acquireNamed(env.io, env.state_dir, registry_lock_name, false);
    defer registry.close(env.io);
    const jobs = try loadAllUnlocked(arena, env);
    try prune(env, jobs);
    return jobs;
}

pub fn loadFor(session: *session_mod.Session, arena: std.mem.Allocator) ![]const Job {
    var diag: session_mod.Diagnostics = .{};
    const key = session.account_key orelse try session.identityKey(&diag);
    const all = try loadAll(arena, session.env);
    var matching: std.ArrayList(Job) = .empty;
    for (all) |job| {
        if (job.owner_key) |owner| {
            if (std.mem.eql(u8, owner, key)) try matching.append(arena, job);
        }
    }
    return matching.toOwnedSlice(arena);
}

pub fn acknowledgeRetries(session: *session_mod.Session, arena: std.mem.Allocator) !void {
    const jobs = try loadFor(session, arena);
    for (jobs) |saved| {
        if (!saved.done or !saved.retry_pending) continue;
        const dir = try std.fs.path.join(arena, &.{ session.env.state_dir, jobs_dir_name });
        const lock = acquireNamed(session.env.io, dir, try jobFile(arena, saved.id, ".lock"), true) catch continue;
        defer lock.close(session.env.io);
        const file = try jobFile(arena, saved.id, ".json");
        var job = store.load(Job, arena, session.env.io, dir, file) orelse continue;
        job.retry_pending = false;
        job.revision +%= 1;
        try store.save(Job, session.env.io, dir, file, job);
    }
}

pub fn needsReconcile(jobs: []const Job, now: i64) bool {
    for (jobs) |job|
        if (job.done and blocks(job) and now - job.reconciled_at >= 30) return true;
    return false;
}

pub fn reconcile(session: *session_mod.Session, arena: std.mem.Allocator, diag: *session_mod.Diagnostics) !void {
    try reconcileRequests(session, arena, diag, false);
}

pub fn reconcileNow(session: *session_mod.Session, arena: std.mem.Allocator, diag: *session_mod.Diagnostics) !void {
    try reconcileRequests(session, arena, diag, true);
}

fn reconcileRequests(session: *session_mod.Session, arena: std.mem.Allocator, diag: *session_mod.Diagnostics, force: bool) !void {
    const now = std.Io.Clock.real.now(session.env.io).toSeconds();
    const jobs = try loadFor(session, arena);
    for (jobs) |saved| {
        if (!saved.done or !blocks(saved) or (!force and now - saved.reconciled_at < 30)) continue;
        const dir = try std.fs.path.join(arena, &.{ session.env.state_dir, jobs_dir_name });
        const file = try jobFile(arena, saved.id, ".json");
        const lock = acquireNamed(session.env.io, dir, try jobFile(arena, saved.id, ".lock"), true) catch continue;
        defer lock.close(session.env.io);
        var job = store.load(Job, arena, session.env.io, dir, file) orelse continue;
        if (!job.done) continue;
        const client = try session.client(diag);
        var changed = false;
        for (job.requests) |*request| {
            if (!request.unresolved()) continue;
            const status = client.requestStatus(arena, request.row.eligibility.scope, request.id, &diag.arm) catch |err| {
                if (err == error.Canceled or err == error.OutOfMemory) return err;
                continue;
            };
            const state = request_status.classify(status);
            if (state != request.state or !std.mem.eql(u8, status, request.azure_status)) changed = true;
            request.state = state;
            request.azure_status = status;
        }
        job.reconciled_at = now;
        if (changed) {
            var lines: std.ArrayList(messages.Line) = .empty;
            for (job.requests, 0..) |request, i| {
                if (request.azure_status.len == 0 and i < job.lines.len) {
                    try lines.append(arena, job.lines[i]);
                    continue;
                }
                var final = request.row;
                final.state = if (request.state == .succeeded and job.intent == .activate) .active else .eligible;
                try lines.append(arena, try messages.describeOutcome(arena, .{
                    .row = request.row,
                    .outcome = .{ .accepted = if (request.azure_status.len > 0) request.azure_status else "Unknown" },
                }, job.intent, if (request.state == .succeeded) final else null, now));
            }
            job.lines = lines.items;
            job.revision +%= 1;
        }
        try store.save(Job, session.env.io, dir, file, job);
    }
}

const retained_history = 20;

fn prune(env: session_mod.Env, jobs: []const Job) !void {
    var completed: usize = 0;
    for (jobs) |job| if (job.done and !blocks(job) and !job.retry_pending) {
        completed += 1;
    };
    for (jobs) |job| {
        if (completed <= retained_history) break;
        if (!job.done or blocks(job) or job.retry_pending or job.owner_key == null) continue;
        var arena_state: std.heap.ArenaAllocator = .init(env.gpa);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        const dir_path = try std.fs.path.join(arena, &.{ env.state_dir, jobs_dir_name });
        const lock_file = try jobFile(arena, job.id, ".lock");
        const lock = acquireNamed(env.io, dir_path, lock_file, true) catch continue;
        var dir = try std.Io.Dir.cwd().openDir(env.io, dir_path, .{});
        defer dir.close(env.io);
        dir.deleteFile(env.io, try jobFile(arena, job.id, ".json")) catch {
            lock.close(env.io);
            continue;
        };
        lock.close(env.io);
        try dir.deleteFile(env.io, lock_file);
        completed -= 1;
    }
}

fn loadAllUnlocked(arena: std.mem.Allocator, env: session_mod.Env) ![]const Job {
    var jobs: std.ArrayList(Job) = .empty;
    // Keep an operation started by an older installed binary visible and protected.
    if (try load(arena, env)) |legacy| try jobs.append(arena, legacy);
    const dir_path = try std.fs.path.join(arena, &.{ env.state_dir, jobs_dir_name });
    var dir = std.Io.Dir.cwd().openDir(env.io, dir_path, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return jobs.toOwnedSlice(arena),
        else => return err,
    };
    defer dir.close(env.io);
    var iterator = dir.iterate();
    while (try iterator.next(env.io)) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.name, ".json")) continue;
        const id = entry.name[0 .. entry.name.len - ".json".len];
        const lock_file = try jobFile(arena, id, ".lock");
        const job = try loadOne(arena, env.io, dir_path, entry.name, lock_file) orelse return error.InvalidJobState;
        try jobs.append(arena, job);
    }
    std.mem.sort(Job, jobs.items, {}, struct {
        fn less(_: void, a: Job, b: Job) bool {
            if (a.started_at != b.started_at) return a.started_at < b.started_at;
            return std.mem.lessThan(u8, a.id, b.id);
        }
    }.less);
    return jobs.toOwnedSlice(arena);
}

fn loadOne(arena: std.mem.Allocator, io: std.Io, dir: []const u8, file: []const u8, lock_file: []const u8) !?Job {
    const path = try std.fs.path.join(arena, &.{ dir, lock_file });
    const lock = std.Io.Dir.cwd().openFile(io, path, .{
        .mode = .read_write,
        .lock = .exclusive,
        .lock_nonblocking = true,
    }) catch |err| switch (err) {
        error.FileNotFound => return null,
        error.WouldBlock => return store.load(Job, arena, io, dir, file) orelse error.InvalidJobState,
        else => return err,
    };
    defer lock.close(io);
    var job = store.load(Job, arena, io, dir, file) orelse return null;
    if (!job.done) {
        job.done = true;
        job.legacy_unresolved = job.requests.len == 0;
        job.justification = null;
        job.failure = "The background worker stopped. Some requests may have reached Azure; refresh roles before retrying.";
        job.revision +%= 1;
        try store.save(Job, io, dir, file, job);
    }
    return job;
}

pub fn run(session: *session_mod.Session, id: []const u8) !void {
    const env = session.env;
    const new_dir = try std.fs.path.join(session.arena, &.{ env.state_dir, jobs_dir_name });
    const new_file = try jobFile(session.arena, id, ".json");
    const new_job = store.load(Job, session.arena, env.io, new_dir, new_file);
    const dir = if (new_job != null) new_dir else env.state_dir;
    const file = if (new_job != null) new_file else file_name;
    var job = new_job orelse store.load(Job, session.arena, env.io, dir, file) orelse return error.NoJob;
    if (job.done or !std.mem.eql(u8, job.id, id)) return error.NoJob;
    // Legacy jobs have no trustworthy account binding and must not be replayed.
    session.expected_account_key = job.owner_key orelse {
        job.done = true;
        job.failure = "This legacy job has no Azure identity binding. Refresh roles and submit it again.";
        job.justification = null;
        try store.save(Job, env.io, dir, file, job);
        return;
    };
    session.expected_principal_id = job.principal_id orelse return error.IdentityChanged;
    try runJob(session, &job, dir, file, true);
    const notification = try describeNotification(session.arena, job);
    herdr.Notifier.fromEnv(env.environ).show(session.arena, env.io, notification.title, notification.body) catch |err|
        std.log.warn("cannot notify about background operation: {t}", .{err});
}

/// Foreground and popup operations share reservations, persistence and execution.
pub fn foreground(session: *session_mod.Session, arena: std.mem.Allocator, intent: selection.Intent, targets: []const rows_mod.Row, duration_min: u32, justification: []const u8, wait: bool) !Job {
    var job = try createJob(session, arena, intent, targets, duration_min, justification);
    const registry = try acquireNamed(session.env.io, session.env.state_dir, registry_lock_name, false);
    const reserved = reserve(arena, session.env, job) catch |err| {
        registry.close(session.env.io);
        return err;
    };
    registry.close(session.env.io);
    defer reserved.lock.close(session.env.io);
    try runJob(session, &job, reserved.dir, reserved.file, wait);
    return job;
}

fn runJob(session: *session_mod.Session, job: *Job, dir: []const u8, file: []const u8, wait: bool) !void {
    const env = session.env;
    const justification = job.justification orelse "";
    job.justification = null;
    try store.save(Job, env.io, dir, file, job.*);

    var diag: session_mod.Diagnostics = .{};
    execute(session, job, justification, dir, file, wait, &diag) catch |err| {
        job.authentication_required = errors.needsSignIn(err, diag);
        job.failure = try errors.summaryAlloc(session.arena, err, diag);
    };
    job.done = true;
    job.retry_pending = job.authentication_required and !blocks(job.*);
    job.finished_at = std.Io.Clock.real.now(env.io).toSeconds();
    job.revision +%= 1;
    if (job.retry_pending) {
        const registry = try acquireNamed(env.io, env.state_dir, registry_lock_name, false);
        defer registry.close(env.io);
        const previous = try loadAllUnlocked(session.arena, env);
        for (previous) |old| {
            if (!old.done or !old.retry_pending or old.owner_key == null or job.owner_key == null or
                !std.mem.eql(u8, old.owner_key.?, job.owner_key.?) or std.mem.eql(u8, old.id, job.id)) continue;
            var superseded = old;
            superseded.retry_pending = false;
            superseded.revision +%= 1;
            const old_dir = try std.fs.path.join(session.arena, &.{ env.state_dir, jobs_dir_name });
            try store.save(Job, env.io, old_dir, try jobFile(session.arena, old.id, ".json"), superseded);
        }
        try store.save(Job, env.io, dir, file, job.*);
        return;
    }
    try store.save(Job, env.io, dir, file, job.*);
}

fn execute(session: *session_mod.Session, job: *Job, justification: []const u8, dir: []const u8, file: []const u8, wait: bool, diag: *session_mod.Diagnostics) errors.Error!void {
    const arena = session.arena;
    const io = session.env.io;
    const plans = if (job.intent == .activate) try activation.plan(session, arena, job.targets, job.duration_min, diag) else &.{};
    _ = try session.client(diag);
    const ids = try arena.alloc([]const u8, job.requests.len);
    for (job.requests, ids) |*request, *id| {
        request.attempted = true;
        id.* = request.id;
    }
    store.save(Job, io, dir, file, job.*) catch return error.JobStorageFailed;
    const submissions = switch (job.intent) {
        .activate => try activation.activateWithIds(session, arena, plans, justification, std.Io.Clock.real.now(io).toSeconds(), ids, diag),
        .deactivate => try activation.deactivateWithIds(session, arena, job.targets, ids, diag),
    };
    for (submissions, job.requests) |submission, *request| switch (submission.outcome) {
        .accepted => |status| {
            request.azure_status = status;
            request.state = request_status.classify(status);
        },
        .failed => |failure| {
            request.state = failureState(failure);
        },
    };
    store.save(Job, io, dir, file, job.*) catch return error.JobStorageFailed;
    const settling = for (submissions) |s| {
        if (s.settlesAutomatically()) break true;
    } else false;

    var lines: std.ArrayList(messages.Line) = .empty;
    var problems: std.ArrayList(messages.Line) = .empty;
    var still_applying = false;
    if (settling and wait) {
        if (activation.awaitSettled(session, arena, submissions, job.intent, 120, diag)) |settled| {
            still_applying = !settled;
        } else |err| {
            job.authentication_required = job.authentication_required or errors.needsSignIn(err, diag.*);
            try problems.append(arena, try problemLine(arena, "Could not confirm the change", err, diag.*));
        }
    }
    const now = std.Io.Clock.real.now(io).toSeconds();
    const rows: []const rows_mod.Row = if (service.refresh(session, arena, now, diag)) |snapshot|
        try rows_mod.build(arena, snapshot, now)
    else |err| blk: {
        job.authentication_required = job.authentication_required or errors.needsSignIn(err, diag.*);
        try problems.append(arena, try problemLine(arena, "Could not refresh roles", err, diag.*));
        break :blk &.{};
    };
    for (submissions) |s| {
        if (s.outcome == .failed and s.outcome.failed.reason == .rejected)
            job.authentication_required = job.authentication_required or errors.needsSignIn(error.HttpFailed, .{ .arm = s.outcome.failed.arm });
        try lines.append(arena, try messages.describeOutcome(arena, s, job.intent, messages.findRow(rows, s.row), now));
    }
    try lines.appendSlice(arena, problems.items);
    if (still_applying) try lines.append(arena, .{ .kind = .info, .glyph = "...", .text = "Azure is still applying some changes; press ^r to refresh." });
    job.lines = lines.items;
}

fn failureState(failure: activation.Failure) request_status.State {
    if (failure.reason == .transport) return .unknown;
    if (failure.reason != .rejected) return .failed;
    const status = failure.arm.status orelse return .unknown;
    return if (status.class() == .client_error and status != .request_timeout) .failed else .unknown;
}

test "ambiguous server failures remain unresolved while definitive policy rejections do not" {
    try testing.expectEqual(request_status.State.unknown, failureState(.{ .reason = .transport }));
    try testing.expectEqual(request_status.State.unknown, failureState(.{ .reason = .rejected, .arm = .{ .status = .service_unavailable } }));
    try testing.expectEqual(request_status.State.failed, failureState(.{ .reason = .rejected, .arm = .{ .status = .forbidden } }));
    try testing.expectEqual(request_status.State.failed, failureState(.{ .reason = .ticket_required }));
}

fn problemLine(arena: std.mem.Allocator, what: []const u8, err: errors.Error, diag: session_mod.Diagnostics) std.mem.Allocator.Error!messages.Line {
    return .{
        .kind = .info,
        .glyph = "!",
        .text = try std.fmt.allocPrint(arena, "{s}: {s}. Press ^r to refresh.", .{ what, try errors.summaryAlloc(arena, err, diag) }),
    };
}

fn describeNotification(arena: std.mem.Allocator, job: Job) !messages.Notification {
    const action = if (job.intent == .activate) "activation" else "deactivation";
    if (job.failure) |failure| return .{
        .title = try std.fmt.allocPrint(arena, "PIM {s} failed", .{action}),
        .body = failure,
    };
    var failed: usize = 0;
    var pending: usize = 0;
    var uncertain = false;
    for (job.lines) |line| switch (line.kind) {
        .failed => failed += 1,
        .pending => pending += 1,
        .info => uncertain = true,
        .ok => {},
    };
    return .{
        .title = try std.fmt.allocPrint(arena, "PIM {s} {s}", .{ action, if (failed > 0) "had failures" else if (pending > 0 or uncertain) "needs attention" else "complete" }),
        .body = if (job.lines.len == 1) job.lines[0].text else try std.fmt.allocPrint(arena, "{d} roles: {d} failed, {d} pending. Open the PIM picker for details.", .{ job.targets.len, failed, pending }),
    };
}

const testing = std.testing;

fn acquire(io: std.Io, state_dir: []const u8) !std.Io.File {
    return acquireNamed(io, state_dir, lock_name, true);
}

fn testJob() Job {
    return .{ .id = "test", .intent = .activate, .targets = &.{}, .duration_min = 60, .started_at = 1 };
}

test "job lock excludes duplicate operations and detects a lost worker" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const io = testing.io;
    const dir = try tmp.dir.realPathFileAlloc(io, ".", arena);
    var environ: std.process.Environ.Map = .init(arena);
    const env: session_mod.Env = .{ .io = io, .gpa = testing.allocator, .environ = &environ, .state_dir = dir };
    const lock = try acquire(io, dir);
    var closed = false;
    defer if (!closed) lock.close(io);
    var job = testJob();
    job.justification = "private reason";
    try store.save(Job, io, dir, file_name, job);
    try testing.expectError(error.OperationInProgress, acquire(io, dir));
    try testing.expect(!(try load(arena, env)).?.done);
    lock.close(io);
    closed = true;
    const lost = (try load(arena, env)).?;
    try testing.expect(lost.done and lost.failure != null and lost.justification == null);
    try testing.expect((store.load(Job, arena, io, dir, file_name) orelse return error.TestExpectedJob).done);
}

test "worker inherits the lock after its parent releases its handle" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const io = testing.io;
    const dir = try tmp.dir.realPathFileAlloc(io, ".", arena);
    const lock = try acquire(io, dir);
    var child = std.process.spawn(io, .{
        .argv = &.{ "/bin/sleep", "30" },
        .stdin = .{ .file = lock },
        .stdout = .ignore,
        .stderr = .ignore,
        .pgid = 0,
    }) catch |err| {
        lock.close(io);
        return err;
    };
    lock.close(io);
    defer child.kill(io);
    try testing.expectError(error.OperationInProgress, acquire(io, dir));
    child.kill(io);
    const available = try acquire(io, dir);
    available.close(io);
}

test "completed results survive an unlocked worker without being marked interrupted" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const io = testing.io;
    const dir = try tmp.dir.realPathFileAlloc(io, ".", arena);
    var environ: std.process.Environ.Map = .init(arena);
    const env: session_mod.Env = .{ .io = io, .gpa = testing.allocator, .environ = &environ, .state_dir = dir };
    const lock = try acquire(io, dir);
    lock.close(io);
    var job = testJob();
    job.done = true;
    job.lines = &.{.{ .kind = .ok, .glyph = "*", .text = "Owner: active" }};
    try store.save(Job, io, dir, file_name, job);
    const completed = (try load(arena, env)).?;
    try testing.expect(completed.done and completed.failure == null);
    try testing.expectEqualStrings("Owner: active", completed.lines[0].text);
}

fn testTarget(scope: []const u8, role: []const u8, schedule: []const u8) rows_mod.Row {
    return .{
        .eligibility = .{ .schedule_id = schedule, .scope = scope, .scope_name = scope, .role_definition_id = role, .role_name = role },
        .subscription_name = "Sub",
        .state = .eligible,
    };
}

test "separate jobs run together while conflicting scope-role requests are rejected" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const io = testing.io;
    const dir = try tmp.dir.realPathFileAlloc(io, ".", arena);
    var environ: std.process.Environ.Map = .init(arena);
    const env: session_mod.Env = .{ .io = io, .gpa = testing.allocator, .environ = &environ, .state_dir = dir };
    const registry = try acquireNamed(io, dir, registry_lock_name, false);
    defer registry.close(io);
    var first = testJob();
    first.id = "first";
    first.targets = &.{testTarget("/subscriptions/a/resourceGroups/rg", "/roles/owner", "eligibility-one")};
    const a = try reserve(arena, env, first);
    var a_closed = false;
    defer if (!a_closed) a.lock.close(io);

    var duplicate = first;
    duplicate.id = "duplicate";
    duplicate.intent = .deactivate;
    duplicate.targets = &.{testTarget("/SUBSCRIPTIONS/A/resourceGroups/RG/", "OWNER", "another-eligibility")};
    try testing.expectError(error.OperationInProgress, reserve(arena, env, duplicate));

    var second = first;
    second.id = "second";
    second.targets = &.{testTarget("/subscriptions/a/resourceGroups/other", "owner", "eligibility-two")};
    const b = try reserve(arena, env, second);
    defer b.lock.close(io);
    var third = first;
    third.id = "third";
    third.targets = &.{testTarget("/subscriptions/a/resourceGroups/rg", "reader", "eligibility-three")};
    const c = try reserve(arena, env, third);
    defer c.lock.close(io);
    const all = try loadAllUnlocked(arena, env);
    try testing.expectEqual(@as(usize, 3), all.len);
    for (all) |job| try testing.expect(!job.done);

    // Completing one job neither overwrites nor cancels another job.
    first.done = true;
    first.lines = &.{.{ .kind = .ok, .glyph = "*", .text = "first active" }};
    try store.save(Job, io, a.dir, a.file, first);
    a.lock.close(io);
    a_closed = true;
    const after = try loadAllUnlocked(arena, env);
    var active_count: usize = 0;
    for (after) |job| {
        if (!job.done) active_count += 1;
    }
    try testing.expectEqual(@as(usize, 2), active_count);
    const retry = try reserve(arena, env, duplicate);
    retry.lock.close(io);
}

test "a lost job is reported individually while a legacy worker remains protected" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const io = testing.io;
    const dir = try tmp.dir.realPathFileAlloc(io, ".", arena);
    var environ: std.process.Environ.Map = .init(arena);
    const env: session_mod.Env = .{ .io = io, .gpa = testing.allocator, .environ = &environ, .state_dir = dir };
    var legacy = testJob();
    legacy.targets = &.{testTarget("/subscriptions/one", "owner", "legacy")};
    const old_lock = try acquire(io, dir);
    defer old_lock.close(io);
    try store.save(Job, io, dir, file_name, legacy);
    var new = legacy;
    new.id = "new";
    try testing.expectError(error.OperationInProgress, reserve(arena, env, new));
    new.targets = &.{testTarget("/subscriptions/two", "owner", "new")};
    new.justification = "private reason";
    const reserved = try reserve(arena, env, new);
    reserved.lock.close(io);
    const jobs = try loadAll(arena, env);
    try testing.expectEqual(@as(usize, 2), jobs.len);
    for (jobs) |job| {
        if (std.mem.eql(u8, job.id, new.id)) {
            try testing.expect(job.done and job.failure != null and job.justification == null);
        } else try testing.expect(!job.done);
    }
}

test "completion notifications distinguish failures, pending and success" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var job = testJob();
    job.lines = &.{.{ .kind = .ok, .glyph = "", .text = "active" }};
    try testing.expectEqualStrings("PIM activation complete", (try describeNotification(arena, job)).title);
    job.lines = &.{.{ .kind = .pending, .glyph = "", .text = "awaiting approval" }};
    try testing.expectEqualStrings("PIM activation needs attention", (try describeNotification(arena, job)).title);
    job.lines = &.{.{ .kind = .failed, .glyph = "", .text = "rejected" }};
    try testing.expectEqualStrings("PIM activation had failures", (try describeNotification(arena, job)).title);
    job.failure = "not signed in";
    try testing.expectEqualStrings("not signed in", (try describeNotification(arena, job)).body);
}

test "pending approvals and ambiguous writes retain conflicts after a worker exits" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const io = testing.io;
    const dir = try tmp.dir.realPathFileAlloc(io, ".", arena);
    var environ: std.process.Environ.Map = .init(arena);
    const env: session_mod.Env = .{ .io = io, .gpa = testing.allocator, .environ = &environ, .state_dir = dir };
    var job = testJob();
    job.id = "pending";
    job.owner_key = "account";
    job.targets = &.{testTarget("/subscriptions/a", "owner", "schedule")};
    var requests = [_]TrackedRequest{.{ .id = "request", .row = job.targets[0], .attempted = true, .state = .approval }};
    job.requests = &requests;
    job.done = true;
    const saved = try reserve(arena, env, job);
    saved.lock.close(io);
    var duplicate = job;
    duplicate.id = "duplicate";
    duplicate.intent = .deactivate;
    try testing.expectError(error.OperationInProgress, reserve(arena, env, duplicate));
    requests[0].state = .unknown;
    try store.save(Job, io, saved.dir, saved.file, job);
    try testing.expectError(error.OperationInProgress, reserve(arena, env, duplicate));
    requests[0].state = .failed;
    try store.save(Job, io, saved.dir, saved.file, job);
    const retry = try reserve(arena, env, duplicate);
    retry.lock.close(io);
}

test "history retention keeps unresolved jobs and bounds resolved files" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const io = testing.io;
    const dir = try tmp.dir.realPathFileAlloc(io, ".", arena);
    var environ: std.process.Environ.Map = .init(arena);
    const env: session_mod.Env = .{ .io = io, .gpa = testing.allocator, .environ = &environ, .state_dir = dir };
    for (0..retained_history + 3) |i| {
        var job = testJob();
        job.id = try std.fmt.allocPrint(arena, "history-{d}", .{i});
        job.owner_key = "account";
        job.targets = &.{testTarget("/subscriptions/a", "owner", "schedule")};
        job.done = true;
        const reserved = try reserve(arena, env, job);
        reserved.lock.close(io);
    }
    var unknown = testJob();
    unknown.id = "unresolved";
    unknown.owner_key = "account";
    unknown.targets = &.{testTarget("/subscriptions/a", "owner", "schedule")};
    unknown.done = true;
    unknown.requests = &.{};
    unknown.legacy_unresolved = true;
    const reserved = try reserve(arena, env, unknown);
    reserved.lock.close(io);
    _ = try loadAll(arena, env);
    const after = try loadAll(arena, env);
    try testing.expectEqual(@as(usize, retained_history + 1), after.len);
    var found = false;
    for (after) |job| if (std.mem.eql(u8, job.id, unknown.id)) {
        found = true;
        try testing.expect(blocks(job));
    };
    try testing.expect(found);
}
