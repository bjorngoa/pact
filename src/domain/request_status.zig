//! ARM request state is separate from the lifetime of the submitting process.
const std = @import("std");

pub const State = enum { pending, approval, succeeded, failed, unknown };

pub fn classify(value: []const u8) State {
    for ([_][]const u8{ "Provisioned", "Revoked" }) |name|
        if (std.mem.eql(u8, value, name)) return .succeeded;
    for ([_][]const u8{ "Denied", "AdminDenied", "Failed", "FailedAsResourceIsLocked", "Canceled", "TimedOut", "Invalid" }) |name|
        if (std.mem.eql(u8, value, name)) return .failed;
    for ([_][]const u8{ "PendingApproval", "PendingApprovalProvisioning", "PendingAdminDecision" }) |name|
        if (std.mem.eql(u8, value, name)) return .approval;
    for ([_][]const u8{ "Accepted", "Granted", "AdminApproved", "ProvisioningStarted", "ScheduleCreated", "PendingEvaluation", "PendingProvisioning", "PendingRevocation", "PendingScheduleCreation", "PendingExternalProvisioning" }) |name|
        if (std.mem.eql(u8, value, name)) return .pending;
    return .unknown;
}

test "terminal Azure failures are not pending or successful" {
    for ([_][]const u8{ "Denied", "AdminDenied", "Failed", "Canceled", "TimedOut", "Invalid", "FailedAsResourceIsLocked" }) |name|
        try std.testing.expectEqual(State.failed, classify(name));
    try std.testing.expectEqual(State.approval, classify("PendingApproval"));
    try std.testing.expectEqual(State.succeeded, classify("Provisioned"));
    try std.testing.expectEqual(State.unknown, classify("NewAzureStatus"));
}
