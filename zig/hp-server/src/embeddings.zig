//! Lightweight in-memory + on-disk embeddings store.
//!
//! We keep one embedding per distinct (ua-prefix, path-pattern) pair, NOT per visit.
//! That bounds the index size (a few hundred at most) so brute-force cosine works fine.
//! No HNSW, no quantization, no fancy structure. Just flat f32 arrays + linear scan.
//!
//! On-disk format: `~/data/embeddings.bin`
//!   header:  [magic 4B="REMB"] [version u32] [dim u32] [count u32]
//!   entries: [key_len u16][key bytes][created_at i64][hits u32][1024 * f32]
//!
//! Threadsafe via mutex. Mutations are append-only and persisted lazily.
const std = @import("std");
const ai = @import("ai.zig");

pub const PATH = "/data/data/com.termux/files/home/data/embeddings.bin";
const MAGIC: [4]u8 = .{ 'R', 'E', 'M', 'B' };
const VERSION: u32 = 1;
const DIM = ai.EMBED_DIM;
const MAX_ENTRIES: usize = 4096; // hard cap so the file cannot grow unbounded

pub const Entry = struct {
    /// Owned key like "curl/8.4|/wp-admin"
    key: []u8,
    created_at: i64,
    hits: u32,
    /// Owned vector, length DIM
    vec: []f32,
};

pub const Cluster = struct {
    /// Representative key (the entry whose vec has the highest avg-similarity to others)
    representative: []const u8,
    /// All keys in this cluster
    members: [][]const u8,
    /// Average pairwise similarity inside the cluster
    cohesion: f32,
};

pub const Store = struct {
    mutex: std.Thread.Mutex,
    entries: std.ArrayList(Entry),
    /// Backing index: key -> entry index. Fast dedup on insert.
    index: std.StringHashMap(usize),
    allocator: std.mem.Allocator,
    dirty: bool,

    pub fn init(allocator: std.mem.Allocator) !*Store {
        const self = try allocator.create(Store);
        self.* = .{
            .mutex = .{},
            .entries = std.ArrayList(Entry).init(allocator),
            .index = std.StringHashMap(usize).init(allocator),
            .allocator = allocator,
            .dirty = false,
        };
        self.loadFromFile() catch {};
        return self;
    }

    pub fn count(self: *Store) usize {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.entries.items.len;
    }

    /// Returns true if a new entry was added; false if key already existed (we just bumped hits).
    pub fn upsert(self: *Store, key: []const u8, vec: []const f32) !bool {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (vec.len != DIM) return error.WrongDimension;

        if (self.index.get(key)) |idx| {
            self.entries.items[idx].hits +%= 1;
            self.dirty = true;
            return false;
        }

        if (self.entries.items.len >= MAX_ENTRIES) {
            // Evict the least-hit, oldest entry
            var worst: usize = 0;
            var worst_score: i64 = std.math.maxInt(i64);
            for (self.entries.items, 0..) |e, i| {
                const score = @as(i64, e.hits) * 1000 + @divFloor(e.created_at, 60);
                if (score < worst_score) {
                    worst_score = score;
                    worst = i;
                }
            }
            self.removeAtLocked(worst);
        }

        const key_dup = try self.allocator.dupe(u8, key);
        errdefer self.allocator.free(key_dup);
        const vec_dup = try self.allocator.dupe(f32, vec);
        errdefer self.allocator.free(vec_dup);

        try self.entries.append(.{
            .key = key_dup,
            .created_at = std.time.timestamp(),
            .hits = 1,
            .vec = vec_dup,
        });
        try self.index.put(key_dup, self.entries.items.len - 1);
        self.dirty = true;
        return true;
    }

    fn removeAtLocked(self: *Store, idx: usize) void {
        const e = self.entries.items[idx];
        _ = self.index.remove(e.key);
        self.allocator.free(e.key);
        self.allocator.free(e.vec);
        _ = self.entries.swapRemove(idx);
        // Repair index for the entry that was swapped in
        if (idx < self.entries.items.len) {
            const moved = self.entries.items[idx];
            self.index.put(moved.key, idx) catch {};
        }
    }

    /// Cosine similarity between two same-length vectors. Assumes vectors are non-zero.
    pub fn cosine(a: []const f32, b: []const f32) f32 {
        var dot: f32 = 0;
        var na: f32 = 0;
        var nb: f32 = 0;
        var i: usize = 0;
        while (i < a.len) : (i += 1) {
            dot += a[i] * b[i];
            na += a[i] * a[i];
            nb += b[i] * b[i];
        }
        if (na == 0 or nb == 0) return 0;
        return dot / (std.math.sqrt(na) * std.math.sqrt(nb));
    }

    pub const Neighbor = struct {
        key: []const u8,
        similarity: f32,
        hits: u32,
    };

    /// k-nearest neighbours by cosine similarity. Caller must hold store via lock from outside,
    /// or use the public `topK` wrapper.
    pub fn topK(self: *Store, allocator: std.mem.Allocator, query: []const f32, k: usize) ![]Neighbor {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (query.len != DIM) return error.WrongDimension;

        const n = self.entries.items.len;
        const take = @min(k, n);
        var out = try allocator.alloc(Neighbor, take);
        for (0..take) |i| out[i] = .{ .key = "", .similarity = -2.0, .hits = 0 };

        for (self.entries.items) |e| {
            const sim = cosine(query, e.vec);
            // Insertion sort into out (small k, so O(k) per insert)
            var i: usize = 0;
            while (i < take) : (i += 1) {
                if (sim > out[i].similarity) break;
            }
            if (i < take) {
                var j: usize = take - 1;
                while (j > i) : (j -= 1) out[j] = out[j - 1];
                out[i] = .{
                    .key = try allocator.dupe(u8, e.key),
                    .similarity = sim,
                    .hits = e.hits,
                };
            }
        }
        // Trim trailing empties (in case n < k+1 weirdness)
        var real: usize = 0;
        while (real < take and out[real].similarity > -1.5) real += 1;
        return out[0..real];
    }

    /// Single-pass agglomerative-ish clustering by similarity threshold.
    /// Returns groups where every member is within `threshold` cosine of the representative.
    /// Cheap and good enough for our scale.
    pub fn cluster(self: *Store, allocator: std.mem.Allocator, threshold: f32) ![]Cluster {
        self.mutex.lock();
        defer self.mutex.unlock();

        const n = self.entries.items.len;
        if (n == 0) return allocator.alloc(Cluster, 0);

        const assigned = try allocator.alloc(?usize, n);
        defer allocator.free(assigned);
        for (assigned) |*a| a.* = null;

        var groups = std.ArrayList(std.ArrayList(usize)).init(allocator);
        defer {
            for (groups.items) |*g| g.deinit();
            groups.deinit();
        }

        for (0..n) |i| {
            if (assigned[i] != null) continue;
            // New group seeded by entry i
            var g = std.ArrayList(usize).init(allocator);
            try g.append(i);
            assigned[i] = groups.items.len;
            for (i + 1..n) |j| {
                if (assigned[j] != null) continue;
                const sim = cosine(self.entries.items[i].vec, self.entries.items[j].vec);
                if (sim >= threshold) {
                    try g.append(j);
                    assigned[j] = groups.items.len;
                }
            }
            try groups.append(g);
        }

        // Build result, keeping only groups with >= 2 members (singletons are noise)
        var out = std.ArrayList(Cluster).init(allocator);
        defer out.deinit();
        for (groups.items) |g| {
            if (g.items.len < 2) continue;
            const members = try allocator.alloc([]const u8, g.items.len);
            for (g.items, 0..) |entry_idx, k| {
                members[k] = try allocator.dupe(u8, self.entries.items[entry_idx].key);
            }
            // Compute mean cohesion (avg pairwise sim within group)
            var sum: f32 = 0;
            var pairs: f32 = 0;
            for (g.items, 0..) |a_idx, ai_idx| {
                for (g.items[ai_idx + 1 ..]) |b_idx| {
                    sum += cosine(self.entries.items[a_idx].vec, self.entries.items[b_idx].vec);
                    pairs += 1;
                }
            }
            const cohesion: f32 = if (pairs == 0) 1.0 else sum / pairs;
            try out.append(.{
                .representative = try allocator.dupe(u8, self.entries.items[g.items[0]].key),
                .members = members,
                .cohesion = cohesion,
            });
        }
        return out.toOwnedSlice();
    }

    pub fn persist(self: *Store) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (!self.dirty) return;

        const tmp = PATH ++ ".tmp";
        {
            const file = try std.fs.createFileAbsolute(tmp, .{ .truncate = true, .mode = 0o600 });
            defer file.close();
            const w = file.writer();
            try w.writeAll(&MAGIC);
            try w.writeInt(u32, VERSION, .little);
            try w.writeInt(u32, @intCast(DIM), .little);
            try w.writeInt(u32, @intCast(self.entries.items.len), .little);
            for (self.entries.items) |e| {
                if (e.key.len > std.math.maxInt(u16)) continue;
                try w.writeInt(u16, @intCast(e.key.len), .little);
                try w.writeAll(e.key);
                try w.writeInt(i64, e.created_at, .little);
                try w.writeInt(u32, e.hits, .little);
                for (e.vec) |v| {
                    const bits: u32 = @bitCast(v);
                    try w.writeInt(u32, bits, .little);
                }
            }
        }
        try std.fs.renameAbsolute(tmp, PATH);
        self.dirty = false;
    }

    fn loadFromFile(self: *Store) !void {
        const file = std.fs.openFileAbsolute(PATH, .{}) catch |e| switch (e) {
            error.FileNotFound => return,
            else => return e,
        };
        defer file.close();
        var reader = file.reader();

        var magic: [4]u8 = undefined;
        const n = try reader.readAll(&magic);
        if (n < 4 or !std.mem.eql(u8, &magic, &MAGIC)) return;
        const ver = try reader.readInt(u32, .little);
        if (ver != VERSION) return;
        const dim = try reader.readInt(u32, .little);
        if (dim != DIM) return;
        const cnt = try reader.readInt(u32, .little);

        self.mutex.lock();
        defer self.mutex.unlock();

        var i: usize = 0;
        while (i < cnt) : (i += 1) {
            const klen = try reader.readInt(u16, .little);
            const key = try self.allocator.alloc(u8, klen);
            errdefer self.allocator.free(key);
            _ = try reader.readAll(key);
            const created_at = try reader.readInt(i64, .little);
            const hits = try reader.readInt(u32, .little);
            const vec = try self.allocator.alloc(f32, DIM);
            errdefer self.allocator.free(vec);
            for (vec) |*v| {
                const bits = try reader.readInt(u32, .little);
                v.* = @bitCast(bits);
            }
            try self.entries.append(.{
                .key = key,
                .created_at = created_at,
                .hits = hits,
                .vec = vec,
            });
            try self.index.put(key, self.entries.items.len - 1);
        }
    }

    /// Background loop: persist every 5 minutes if dirty.
    pub fn persistLoop(self: *Store) void {
        while (true) {
            std.Thread.sleep(5 * 60 * std.time.ns_per_s);
            self.persist() catch {};
        }
    }
};

/// Build a stable embedding key from request signals.
/// Lowercase the UA prefix and the path so trivial variants do not duplicate.
pub fn keyForRequest(allocator: std.mem.Allocator, ua: []const u8, path: []const u8) ![]u8 {
    const ua_max = @min(ua.len, 64);
    var key = try std.ArrayList(u8).initCapacity(allocator, ua_max + path.len + 1);
    for (ua[0..ua_max]) |c| try key.append(std.ascii.toLower(c));
    try key.append('|');
    for (path) |c| try key.append(std.ascii.toLower(c));
    return key.toOwnedSlice();
}
