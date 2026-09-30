const std = @import("std");

pub const url = "https://paneflow.dev/agent/feedback";

test "feedback URL stays on the paneflow.dev/agent domain" {
    try std.testing.expectEqualStrings("https://paneflow.dev/agent/feedback", url);
}
