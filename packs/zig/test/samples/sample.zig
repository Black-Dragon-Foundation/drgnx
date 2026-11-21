const std = @import("std");

/// A small queue.
const Queue = struct {
    items: [8]u32 = undefined,
    len: usize = 0,

    pub fn push(self: *Queue, item: u32) bool {
        if (self.len >= self.items.len) return false;
        self.items[self.len] = item;
        self.len += 1;
        return true;
    }
};

pub fn main() void {
    var q = Queue{};
    _ = q.push(42); // greeting
    std.debug.print("size {d}\n", .{q.len});
}
