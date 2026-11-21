//! Minimal Azure Resource Manager client for the PIM APIs.
const std = @import("std");
const role = @import("../../domain/role.zig");
const policy_mod = @import("../../domain/policy.zig");
const dto = @import("dto.zig");
const deadline = @import("../../platform/deadline.zig");

pub const default_base_url = "https://management.azure.com";
pub const user_agent = "herdr-pim";

const pim_api_version = "2020-10-01";

/// Upper bound for one ARM request, so a stalled connection cannot hang a
/// command or a picker task.
pub const request_timeout: std.Io.Duration = .fromSeconds(30);
const subscriptions_api_version = "2022-12-01";

pub const Error = error{
    /// ARM answered with a non-2xx status; see `Diagnostics`.
    HttpFailed,
    InvalidResponse,
    /// A `nextLink` pointed outside `base_url`; refusing to send the token there.
    UntrustedNextLink,
} || deadline.TimedOut || std.Io.Cancelable || std.http.Client.FetchError || std.mem.Allocator.Error;

pub const SubmitError = Error || std.Io.RandomSecureError;

/// Filled when a call fails with `error.HttpFailed`.
pub const Diagnostics = struct {
    status: ?std.http.Status = null,
    code: []const u8 = "",
    message: []const u8 = "",
    retry_after_seconds: ?u32 = null,
    retry_after_present: bool = false,
    claims_challenge: []const u8 = "",
};

pub const Client = struct {
    http: *std.http.Client,
    /// Complete `Authorization` header value, e.g. `Bearer eyJ...`.
    authorization: []const u8,
    base_url: []const u8 = default_base_url,

    pub fn listEligibilities(self: *const Client, arena: std.mem.Allocator, diag: *Diagnostics) Error![]role.Eligibility {
        return self.listAll(role.Eligibility, arena, pimPath("roleEligibilityScheduleInstances"), dto.parseEligibilities, diag);
    }

    pub fn listAssignments(self: *const Client, arena: std.mem.Allocator, diag: *Diagnostics) Error![]role.Assignment {
        return self.listAll(role.Assignment, arena, pimPath("roleAssignmentScheduleInstances"), dto.parseAssignments, diag);
    }

    pub fn listRequests(self: *const Client, arena: std.mem.Allocator, diag: *Diagnostics) Error![]role.Request {
        return self.listAll(role.Request, arena, pimPath("roleAssignmentScheduleRequests"), dto.parseRequests, diag);
    }

    pub fn listSubscriptions(self: *const Client, arena: std.mem.Allocator, diag: *Diagnostics) Error![]role.Subscription {
        const path = "/subscriptions?api-version=" ++ subscriptions_api_version;
        return self.listAll(role.Subscription, arena, path, dto.parseSubscriptions, diag);
    }

    /// The activation policy for `role_definition_id` at `scope`, or null if none is assigned.
    pub fn getPolicy(
        self: *const Client,
        arena: std.mem.Allocator,
        scope: []const u8,
        role_definition_id: []const u8,
        diag: *Diagnostics,
    ) Error!?policy_mod.Policy {
        var url: std.Io.Writer.Allocating = .init(arena);
        const w = &url.writer;
        writeUrl(w, self.base_url, scope, "roleManagementPolicyAssignments") catch return error.OutOfMemory;
        w.writeAll("?api-version=" ++ pim_api_version ++ "&$filter=") catch return error.OutOfMemory;
        writeQueryEncoded(w, "roleDefinitionId eq '") catch return error.OutOfMemory;
        writeQueryEncoded(w, role_definition_id) catch return error.OutOfMemory;
        writeQueryEncoded(w, "'") catch return error.OutOfMemory;
        const body = try self.send(arena, .GET, url.written(), null, diag);
        return dto.parsePolicy(arena, body);
    }

    /// Creates a role assignment schedule request (activate or deactivate) and
    /// returns Azure's status for it, e.g. `Provisioned` or `PendingApproval`.
    pub fn submitRequest(
        self: *const Client,
        arena: std.mem.Allocator,
        io: std.Io,
        scope: []const u8,
        request: dto.ScheduleRequest,
        diag: *Diagnostics,
    ) SubmitError![]const u8 {
        var id: [36]u8 = undefined;
        const request_id = request.request_id orelse blk: {
            try newUuid(io, &id);
            break :blk &id;
        };

        var url: std.Io.Writer.Allocating = .init(arena);
        writeUrl(&url.writer, self.base_url, scope, "roleAssignmentScheduleRequests/") catch return error.OutOfMemory;
        url.writer.print("{s}?api-version=" ++ pim_api_version, .{request_id}) catch return error.OutOfMemory;

        var payload: std.Io.Writer.Allocating = .init(arena);
        dto.writeScheduleRequest(&payload.writer, request) catch return error.OutOfMemory;

        const body = try self.send(arena, .PUT, url.written(), payload.written(), diag);
        return dto.parseRequestStatus(arena, body);
    }

    pub fn requestStatus(self: *const Client, arena: std.mem.Allocator, scope: []const u8, id: []const u8, diag: *Diagnostics) Error![]const u8 {
        var url: std.Io.Writer.Allocating = .init(arena);
        writeUrl(&url.writer, self.base_url, scope, "roleAssignmentScheduleRequests/") catch return error.OutOfMemory;
        url.writer.print("{s}?api-version=" ++ pim_api_version, .{id}) catch return error.OutOfMemory;
        return dto.parseRequestStatus(arena, try self.send(arena, .GET, url.written(), null, diag));
    }

    pub fn requestId(io: std.Io) std.Io.RandomSecureError![36]u8 {
        var id: [36]u8 = undefined;
        try newUuid(io, &id);
        return id;
    }

    fn listAll(
        self: *const Client,
        comptime T: type,
        arena: std.mem.Allocator,
        comptime path: []const u8,
        comptime parsePage: fn (std.mem.Allocator, []const u8) dto.ParseError!dto.Page(T),
        diag: *Diagnostics,
    ) Error![]T {
        var items: std.ArrayList(T) = .empty;
        var url: []const u8 = try std.mem.concat(arena, u8, &.{ self.base_url, path });
        while (true) {
            const body = try self.send(arena, .GET, url, null, diag);
            const page = try parsePage(arena, body);
            try items.appendSlice(arena, page.items);
            const next = page.next_link orelse break;
            if (!isTrustedLink(self.base_url, next)) return error.UntrustedNextLink;
            url = next;
        }
        return items.toOwnedSlice(arena);
    }

    fn send(
        self: *const Client,
        arena: std.mem.Allocator,
        method: std.http.Method,
        url: []const u8,
        payload: ?[]const u8,
        diag: *Diagnostics,
    ) Error![]const u8 {
        var attempt: u32 = 0;
        while (true) : (attempt += 1) {
            diag.* = .{};
            return deadline.call(self.http.io, request_timeout, sendNow, .{ self, arena, method, url, payload, diag }) catch |err| {
                if (err != error.HttpFailed) return err;
                const delay = retryDelay(method, diag.*, attempt) orelse return err;
                var jitter: [1]u8 = undefined;
                self.http.io.random(&jitter);
                try self.http.io.sleep(.fromMilliseconds(@as(i64, delay) * 1000 + jitter[0]), .awake);
                continue;
            };
        }
    }

    /// Redirects are never followed, so the token cannot leak to another host.
    fn sendNow(
        self: *const Client,
        arena: std.mem.Allocator,
        method: std.http.Method,
        url: []const u8,
        payload: ?[]const u8,
        diag: *Diagnostics,
    ) Error![]const u8 {
        var req = try self.http.request(method, try std.Uri.parse(url), .{
            .redirect_behavior = .unhandled,
            .headers = .{
                .authorization = .{ .override = self.authorization },
                .user_agent = .{ .override = user_agent },
                .content_type = if (payload != null) .{ .override = "application/json" } else .default,
            },
            .extra_headers = &.{.{ .name = "accept", .value = "application/json" }},
        });
        defer req.deinit();
        if (payload) |data| {
            req.transfer_encoding = .{ .content_length = data.len };
            var body = try req.sendBodyUnflushed(&.{});
            try body.writer.writeAll(data);
            try body.end();
            try req.connection.?.flush();
        } else try req.sendBodiless();
        var response = try req.receiveHead(&.{});
        const status = response.head.status;
        var headers = response.head.iterateHeaders();
        var retry_after: ?u32 = null;
        var retry_after_present = false;
        var claims: []const u8 = "";
        while (headers.next()) |header| {
            if (std.ascii.eqlIgnoreCase(header.name, "retry-after")) {
                retry_after_present = true;
                retry_after = std.fmt.parseInt(u32, header.value, 10) catch null;
            }
            if (std.ascii.eqlIgnoreCase(header.name, "www-authenticate"))
                claims = try arena.dupe(u8, header.value);
        }
        var transfer: [4096]u8 = undefined;
        const decompress_buffer: []u8 = switch (response.head.content_encoding) {
            .identity => &.{},
            .gzip, .deflate => try arena.alloc(u8, std.compress.flate.max_window_len),
            .zstd => try arena.alloc(u8, std.compress.zstd.default_window_len),
            .compress => return error.UnsupportedCompressionMethod,
        };
        var decompress: std.http.Decompress = undefined;
        const bytes = response.readerDecompressing(&transfer, &decompress, decompress_buffer).allocRemaining(arena, .limited(8 * 1024 * 1024)) catch |err| switch (err) {
            error.ReadFailed => return response.bodyErr().?,
            error.StreamTooLong, error.OutOfMemory => return err,
        };
        if (status.class() != .success) {
            const err = dto.parseError(arena, bytes);
            diag.* = .{ .status = status, .code = err.code, .message = err.message, .retry_after_seconds = retry_after, .retry_after_present = retry_after_present, .claims_challenge = claims };
            return error.HttpFailed;
        }
        return bytes;
    }
};

fn retryDelay(method: std.http.Method, diag: Diagnostics, attempt: u32) ?u32 {
    if (attempt >= 2) return null;
    const status = diag.status orelse return null;
    const retryable = status == .too_many_requests or status == .service_unavailable or
        (method == .GET and (status == .internal_server_error or status == .bad_gateway or status == .gateway_timeout));
    if (!retryable) return null;
    if (diag.retry_after_present and diag.retry_after_seconds == null) return null;
    // A longer server-directed wait is surfaced to the caller, never shortened.
    const delay = diag.retry_after_seconds orelse (@as(u32, 1) << @intCast(attempt));
    return if (delay <= 20) delay else null;
}

test "throttling honors Retry-After and retries are bounded" {
    try std.testing.expectEqual(@as(?u32, 7), retryDelay(.PUT, .{ .status = .too_many_requests, .retry_after_seconds = 7 }, 0));
    try std.testing.expect(retryDelay(.PUT, .{ .status = .too_many_requests, .retry_after_seconds = 60 }, 0) == null);
    try std.testing.expect(retryDelay(.GET, .{ .status = .too_many_requests }, 2) == null);
    try std.testing.expect(retryDelay(.PUT, .{ .status = .bad_gateway }, 0) == null);
    try std.testing.expectEqual(@as(?u32, 1), retryDelay(.GET, .{ .status = .bad_gateway }, 0));
    try std.testing.expect(retryDelay(.GET, .{ .status = .unauthorized }, 0) == null);
    try std.testing.expect(retryDelay(.GET, .{ .status = .too_many_requests, .retry_after_present = true }, 0) == null);
}
fn pimPath(comptime collection: []const u8) []const u8 {
    return "/providers/Microsoft.Authorization/" ++ collection ++
        "?api-version=" ++ pim_api_version ++ "&$filter=asTarget()";
}

/// Writes `{base}{scope}/providers/Microsoft.Authorization/{collection}` with
/// the scope percent-encoded segment by segment.
fn writeUrl(w: *std.Io.Writer, base_url: []const u8, scope: []const u8, collection: []const u8) std.Io.Writer.Error!void {
    try w.writeAll(base_url);
    var it = std.mem.tokenizeScalar(u8, scope, '/');
    while (it.next()) |segment| {
        try w.writeByte('/');
        try writeEncoded(w, segment, isPathSafe);
    }
    try w.print("/providers/Microsoft.Authorization/{s}", .{collection});
}

fn writeQueryEncoded(w: *std.Io.Writer, value: []const u8) std.Io.Writer.Error!void {
    try writeEncoded(w, value, isQuerySafe);
}

fn writeEncoded(w: *std.Io.Writer, value: []const u8, comptime isSafe: fn (u8) bool) std.Io.Writer.Error!void {
    for (value) |c| {
        if (isSafe(c)) try w.writeByte(c) else try w.print("%{X:0>2}", .{c});
    }
}

fn isUnreserved(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '-' or c == '.' or c == '_' or c == '~';
}

fn isPathSafe(c: u8) bool {
    return isUnreserved(c) or c == '(' or c == ')';
}

fn isQuerySafe(c: u8) bool {
    return isUnreserved(c) or c == '/';
}

/// Random (version 4) UUID, lowercase.
fn newUuid(io: std.Io, out: *[36]u8) std.Io.RandomSecureError!void {
    var bytes: [16]u8 = undefined;
    try io.randomSecure(&bytes);
    formatUuid(&bytes, out);
}

fn formatUuid(bytes: *[16]u8, out: *[36]u8) void {
    bytes[6] = (bytes[6] & 0x0f) | 0x40;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;
    const hex = std.fmt.bytesToHex(bytes.*, .lower);
    _ = std.fmt.bufPrint(out, "{s}-{s}-{s}-{s}-{s}", .{ hex[0..8], hex[8..12], hex[12..16], hex[16..20], hex[20..32] }) catch unreachable;
}

/// True when `link` is an https URL on exactly the same host as `base_url`.
fn isTrustedLink(base_url: []const u8, link: []const u8) bool {
    if (!std.ascii.startsWithIgnoreCase(link, base_url)) return false;
    if (link.len == base_url.len) return true;
    return switch (link[base_url.len]) {
        '/', '?' => true,
        else => false,
    };
}

const testing = std.testing;

test "isTrustedLink only allows the configured host" {
    const base = default_base_url;
    try testing.expect(isTrustedLink(base, "https://management.azure.com/subscriptions?page=2"));
    try testing.expect(isTrustedLink(base, "HTTPS://MANAGEMENT.AZURE.COM/providers/x"));
    try testing.expect(!isTrustedLink(base, "https://management.azure.com.evil.example/x"));
    try testing.expect(!isTrustedLink(base, "https://management.azure.com@evil.example/x"));
    try testing.expect(!isTrustedLink(base, "http://management.azure.com/x"));
    try testing.expect(!isTrustedLink(base, "https://evil.example/https://management.azure.com/"));
}

test "pimPath targets the caller's own schedules" {
    try testing.expectEqualStrings(
        "/providers/Microsoft.Authorization/roleEligibilityScheduleInstances?api-version=2020-10-01&$filter=asTarget()",
        pimPath("roleEligibilityScheduleInstances"),
    );
}

test "writeUrl encodes scope segments" {
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try writeUrl(&out.writer, "https://h", "/subscriptions/s/resourceGroups/rg (prod)?x#y/", "roleAssignmentScheduleRequests/");
    try testing.expectEqualStrings(
        "https://h/subscriptions/s/resourceGroups/rg%20(prod)%3Fx%23y/providers/Microsoft.Authorization/roleAssignmentScheduleRequests/",
        out.written(),
    );
}

test "query encoding keeps slashes and escapes quotes and spaces" {
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try writeQueryEncoded(&out.writer, "roleDefinitionId eq '/a/b'");
    try testing.expectEqualStrings("roleDefinitionId%20eq%20%27/a/b%27", out.written());
}

test "formatUuid sets version and variant bits" {
    var bytes: [16]u8 = @splat(0xff);
    var out: [36]u8 = undefined;
    formatUuid(&bytes, &out);
    try testing.expectEqualStrings("ffffffff-ffff-4fff-bfff-ffffffffffff", &out);
}
