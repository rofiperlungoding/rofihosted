//! Bounded worker pool for fire-and-forget background jobs (AI ban annotation
//! and embedding requests).
//!
//! Replaces unbounded per-request `std.Thread.spawn`. Previously a burst of
//! distinct visitors (or a deliberate flood) created unbounded thread churn,
//! each thread also spawning a `curl` subprocess -- a cheap amplification
//! vector on an 8 GB phone. Here a fixed set of worker threads drains a
//! fixed-capacity ring buffer; when the queue is full, `submit` returns false
//! and the caller drops the job (and frees its context) rather than spawning.
//!
//! A job is a type-erased context plus a run function. The run function owns
//! the context and must free it; on a dropped submit the caller frees it.
const std = @import("std");

pub const Job = struct {
    run: *const fn (ctx: *anyopaque) void,
    ctx: *anyopaque,
};

pub const Pool = struct {
    allocator: std.mem.Allocator,
    mutex: std.Thread.Mutex = .{},
    not_empty: std.Thread.Condition = .{},
    ring: []Job,
    head: usize = 0,
    tail: usize = 0,
    len: usize = 0,
    submitted: u64 = 0,
    dropped: u64 = 0,
    completed: u64 = 0,

    pub fn init(allocator: std.mem.Allocator, workers: usize, capacity: usize) !*Pool {
        const self = try allocator.create(Pool);
        self.* = .{
            .allocator = allocator,
            .ring = try allocator.alloc(Job, capacity),
        };
        var i: usize = 0;
        while (i < workers) : (i += 1) {
            const t = try std.Thread.spawn(.{}, workerLoop, .{self});
            t.detach();
        }
        return self;
    }

    /// Enqueue a job. Returns true if enqueued, false if the queue is full
    /// (the caller must then free its own context and drop the work).
    pub fn submit(self: *Pool, job: Job) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.len == self.ring.len) {
            self.dropped += 1;
            return false;
        }
        self.ring[self.tail] = job;
        self.tail = (self.tail + 1) % self.ring.len;
        self.len += 1;
        self.submitted += 1;
        self.not_empty.signal();
        return true;
    }

    fn workerLoop(self: *Pool) void {
        while (true) {
            self.mutex.lock();
            while (self.len == 0) {
                self.not_empty.wait(&self.mutex);
            }
            const job = self.ring[self.head];
            self.head = (self.head + 1) % self.ring.len;
            self.len -= 1;
            self.mutex.unlock();

            job.run(job.ctx);
            _ = @atomicRmw(u64, &self.completed, .Add, 1, .monotonic);
        }
    }
};
