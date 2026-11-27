//! Account-scoped favorites, keyed by the canonical scope/role identity.
const std = @import("std");
const store = @import("json_store.zig");
const rows_mod = @import("../domain/rows.zig");

const file_name = "favorites.json";
const max_bytes = 8 * 1024 * 1024;
const private_file: std.Io.File.Permissions =
    if (@hasDecl(std.Io.File.Permissions, "fromMode")) .fromMode(0o600) else .default_file;
const private_dir: std.Io.File.Permissions =
    if (@hasDecl(std.Io.File.Permissions, "fromMode")) .fromMode(0o700) else .default_dir;

pub const Favorites = struct {
    pub const schema_version: u32 = 1;
    version: u32 = schema_version,
    keys: []const []const u8 = &.{},

    pub fn apply(self: Favorites, arena: std.mem.Allocator, rows: []rows_mod.Row) std.mem.Allocator.Error!void {
        var keys: std.StringHashMapUnmanaged(void) = .empty;
        defer keys.deinit(arena);
        for (self.keys) |key| try keys.put(arena, key, {});
        for (rows) |*row| {
            const key = try rows_mod.roleKey(arena, row.eligibility.scope, row.eligibility.role_definition_id);
            defer arena.free(key);
            row.favorite = keys.contains(key);
        }
    }
};

pub fn load(arena: std.mem.Allocator, io: std.Io, dir: []const u8) !Favorites {
    const path = try std.fs.path.join(arena, &.{ dir, file_name });
    const bytes = std.Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(max_bytes)) catch |err| switch (err) {
        error.FileNotFound => return .{},
        else => return err,
    };
    return store.decode(Favorites, arena, bytes);
}

/// Reload under a lock so separate pickers cannot overwrite each other's edits.
pub fn toggle(arena: std.mem.Allocator, io: std.Io, dir_path: []const u8, row: rows_mod.Row) !Favorites {
    var dir = try std.Io.Dir.cwd().createDirPathOpen(io, dir_path, .{ .permissions = private_dir });
    defer dir.close(io);
    const lock = try dir.createFile(io, "favorites.lock", .{
        .read = true,
        .truncate = false,
        .lock = .exclusive,
        .permissions = private_file,
    });
    defer lock.close(io);

    const saved = try load(arena, io, dir_path);
    const key = try rows_mod.roleKey(arena, row.eligibility.scope, row.eligibility.role_definition_id);
    var keys: std.ArrayList([]const u8) = .empty;
    var found = false;
    for (saved.keys) |existing| {
        if (std.mem.eql(u8, existing, key)) {
            found = true;
        } else try keys.append(arena, existing);
    }
    if (!found) try keys.append(arena, key);
    const updated: Favorites = .{ .keys = keys.items };
    try store.save(Favorites, io, dir_path, file_name, updated);
    return updated;
}

const testing = std.testing;

fn testRow(scope: []const u8, role: []const u8) rows_mod.Row {
    return .{
        .eligibility = .{ .schedule_id = "schedule", .scope = scope, .scope_name = scope, .role_definition_id = role, .role_name = role },
        .subscription_name = "Sub",
        .state = .eligible,
    };
}

test "favorites persist by canonical scope and role, remain account scoped, and toggle off" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const root = try tmp.dir.realPathFileAlloc(testing.io, ".", arena);
    const account_a = try std.fs.path.join(arena, &.{ root, "a" });
    const account_b = try std.fs.path.join(arena, &.{ root, "b" });
    const row = testRow("/subscriptions/S/resourceGroups/App/", "/providers/Microsoft.Authorization/roleDefinitions/R");
    _ = try toggle(arena, testing.io, account_a, row);
    const saved = try load(arena, testing.io, account_a);
    var rows = [_]rows_mod.Row{
        testRow("/subscriptions/s/resourcegroups/app", "r"),
        testRow("/subscriptions/s/resourcegroups/app", "other"),
        testRow("/subscriptions/s/resourcegroups/other", "r"),
    };
    try saved.apply(arena, &rows);
    try testing.expect(rows[0].favorite);
    try testing.expect(!rows[1].favorite);
    try testing.expect(!rows[2].favorite);
    try testing.expectEqual(@as(usize, 0), (try load(arena, testing.io, account_b)).keys.len);
    const removed = try toggle(arena, testing.io, account_a, rows[0]);
    try removed.apply(arena, &rows);
    try testing.expect(!rows[0].favorite);
    try testing.expectEqual(@as(usize, 0), (try load(arena, testing.io, account_a)).keys.len);
}

test "toggling reloads existing favorites instead of losing another picker's change" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const root = try tmp.dir.realPathFileAlloc(testing.io, ".", arena);
    _ = try toggle(arena, testing.io, root, testRow("/a", "r"));
    const updated = try toggle(arena, testing.io, root, testRow("/b", "r"));
    try testing.expectEqual(@as(usize, 2), updated.keys.len);
}

test "invalid favorites are not overwritten by a toggle" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const root = try tmp.dir.realPathFileAlloc(testing.io, ".", arena);
    const invalid = "{\"version\":99,\"keys\":[\"/a|r\"]}";
    try tmp.dir.writeFile(testing.io, .{ .sub_path = file_name, .data = invalid });
    try testing.expectError(error.IncompatibleVersion, toggle(arena, testing.io, root, testRow("/b", "r")));
    const bytes = try tmp.dir.readFileAlloc(testing.io, file_name, arena, .limited(max_bytes));
    try testing.expectEqualStrings(invalid, bytes);
}
