//! Streaming ZIP archive reader.
//!
//! Walks the central directory once and exposes each member as an on-demand
//! streaming reader over its *decompressed* bytes — no whole-archive or
//! whole-entry materialisation. A consumer's memory ceiling is therefore
//! O(one decompression window) regardless of archive or entry size.
//!
//! Shared primitive: `xlsx.zig` parses a workbook's XML parts through it, and
//! bxp-cli's parallel `zipPrePass` streams each zipped `.csv` member out the
//! same way — neither consumer needs to touch ZIP internals.
//!
//! Reads the LOCAL file header directly for its own filename/extra lengths to
//! locate the compressed data, so the central-vs-local `version_needed`
//! mismatch some writers emit (XTB: 45 local / 20 central) is irrelevant — no
//! header patching is needed. Store + Deflate only (the two methods Excel and
//! ordinary zip tools emit); any other method is
//! `error.UnsupportedCompressionMethod`.
//!
//! Lifetime contract: both `Archive` and `EntryReader` hold internal
//! self-pointers (the file reader's `interface`, the inflate stream's input
//! handle), so both are initialised in place via a `*Self` and must not be
//! moved after `init`. One `Archive` drives one file cursor — stream an
//! `EntryReader` to completion (or abandon it) before opening the next entry.

const std = @import("std");
const Allocator = std.mem.Allocator;

/// Buffer the file reader uses for compressed bytes pulled from disk.
const READER_BUF_SIZE = 64 * 1024;

pub const Error = error{
    UnsupportedCompressionMethod,
    ZipNameTooLong,
    ZipBadFileOffset,
};

/// One archive member. `name` is owned by the parent `Archive` (its name
/// arena) and stays valid until `Archive.deinit`. Backslashes in the stored
/// path are normalised to '/'.
pub const Entry = struct {
    name: []const u8,
    compression: std.zip.CompressionMethod,
    compressed_size: u64,
    uncompressed_size: u64,
    /// Offset of this entry's local file header within the archive.
    file_offset: u64,
};

/// A central-directory-parsed ZIP archive. Borrows an already-open `File` (does
/// not close it); owns the reader buffer, the entry list and the entries' name
/// storage. Initialise in place — see the lifetime contract above.
pub const Archive = struct {
    file: std.fs.File,
    reader_buf: []u8,
    file_reader: std.fs.File.Reader,
    entries: std.ArrayList(Entry),
    name_arena: std.heap.ArenaAllocator,
    alloc: Allocator,

    /// Walks the central directory and records every entry (name + location +
    /// sizes). Does not read any entry's data. The `file` must outlive the
    /// archive; it is not closed by `deinit`.
    pub fn init(self: *Archive, alloc: Allocator, file: std.fs.File) !void {
        self.* = .{
            .file = file,
            .reader_buf = try alloc.alloc(u8, READER_BUF_SIZE),
            .file_reader = undefined,
            .entries = .empty,
            .name_arena = std.heap.ArenaAllocator.init(alloc),
            .alloc = alloc,
        };
        errdefer {
            self.entries.deinit(alloc);
            self.name_arena.deinit();
            alloc.free(self.reader_buf);
        }

        self.file_reader = file.reader(self.reader_buf);
        const name_alloc = self.name_arena.allocator();

        var iter = try std.zip.Iterator.init(&self.file_reader);
        var name_buf: [std.fs.max_path_bytes]u8 = undefined;
        while (try iter.next()) |e| {
            switch (e.compression_method) {
                .store, .deflate => {},
                else => return Error.UnsupportedCompressionMethod,
            }
            if (e.filename_len > name_buf.len) return Error.ZipNameTooLong;

            // Read the filename out of the central-directory header.
            try self.file_reader.seekTo(e.header_zip_offset + @sizeOf(std.zip.CentralDirectoryFileHeader));
            const raw = name_buf[0..e.filename_len];
            try self.file_reader.interface.readSliceAll(raw);
            std.mem.replaceScalar(u8, raw, '\\', '/'); // some writers emit Windows paths

            // Directory entries carry no content.
            if (raw.len == 0 or raw[raw.len - 1] == '/') continue;

            try self.entries.append(self.alloc, .{
                .name = try name_alloc.dupe(u8, raw),
                .compression = e.compression_method,
                .compressed_size = e.compressed_size,
                .uncompressed_size = e.uncompressed_size,
                .file_offset = e.file_offset,
            });
        }
    }

    pub fn deinit(self: *Archive) void {
        self.entries.deinit(self.alloc);
        self.name_arena.deinit();
        self.alloc.free(self.reader_buf);
    }

    /// First entry whose name exactly equals `name`, else null.
    pub fn find(self: *const Archive, name: []const u8) ?*const Entry {
        for (self.entries.items) |*e| {
            if (std.mem.eql(u8, e.name, name)) return e;
        }
        return null;
    }

    /// First entry whose name ends with `suffix` (e.g. a known basename), else
    /// null. Handy when the member sits under a directory prefix.
    pub fn findSuffix(self: *const Archive, suffix: []const u8) ?*const Entry {
        for (self.entries.items) |*e| {
            if (std.mem.endsWith(u8, e.name, suffix)) return e;
        }
        return null;
    }
};

/// A streaming reader over one entry's decompressed bytes. Initialise in place
/// against an `Archive` and a caller-provided decompression `window` buffer
/// (≥ `std.compress.flate.max_window_len` for deflate). The window must outlive
/// the `EntryReader`. Opening a new `EntryReader` reseeks the shared file
/// cursor, so a previous one must be finished first.
pub const EntryReader = struct {
    decompress: std.compress.flate.Decompress,
    limited: std.Io.Reader.Limited,
    is_deflate: bool,

    pub fn init(self: *EntryReader, archive: *Archive, entry: *const Entry, window: []u8) !void {
        const fr = &archive.file_reader;

        // Locate the compressed data: the local header carries its own
        // filename/extra lengths (which can differ from the central header).
        // version_needed is deliberately ignored — see the module note.
        try fr.seekTo(entry.file_offset);
        const local = try fr.interface.takeStruct(std.zip.LocalFileHeader, .little);
        if (!std.mem.eql(u8, &local.signature, &std.zip.local_file_header_sig))
            return Error.ZipBadFileOffset;
        const data_off = entry.file_offset + @sizeOf(std.zip.LocalFileHeader) +
            @as(u64, local.filename_len) + @as(u64, local.extra_len);
        try fr.seekTo(data_off);

        switch (entry.compression) {
            .deflate => {
                self.is_deflate = true;
                self.decompress = .init(&fr.interface, .raw, window);
            },
            .store => {
                self.is_deflate = false;
                self.limited = fr.interface.limited(.limited64(entry.uncompressed_size), window);
            },
            else => return Error.UnsupportedCompressionMethod,
        }
    }

    /// The decompressed-byte reader. Valid until the next `EntryReader.init`
    /// against the same archive (which reseeks the file cursor).
    pub fn reader(self: *EntryReader) *std.Io.Reader {
        return if (self.is_deflate) &self.decompress.reader else &self.limited.interface;
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------
const testing = std.testing;

// These unit tests stay deliberately small and functional: they build tiny
// STORE-method zips by hand (no compressor) to exercise the central-directory
// walk, name handling and the streaming read path. The deflate path + the real
// XTB central-vs-local version_needed mismatch are covered end-to-end, on real
// workbooks, by the `xtb*` datasets in test-02 (xlsx.zig consumes this module) —
// same split the former `extractZipToMemory` test used.

/// One member for the store-only test-zip builder.
const TestMember = struct { name: []const u8, data: []const u8 };

/// Builds a minimal but real STORE-method ZIP byte stream from `members`, using
/// the same std.zip structs the production walk parses (so the byte layout
/// can't drift). No compression — keeps the test a pure structural check.
fn buildStoreZip(a: Allocator, members: []const TestMember) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(a);

    var offs: std.ArrayList(u32) = .empty;
    defer offs.deinit(a);

    for (members) |m| {
        try offs.append(a, @intCast(buf.items.len));
        const lfh = std.zip.LocalFileHeader{
            .signature = std.zip.local_file_header_sig,
            .version_needed_to_extract = 20,
            .flags = @bitCast(@as(u16, 0)),
            .compression_method = .store,
            .last_modification_time = 0,
            .last_modification_date = 0,
            .crc32 = 0,
            .compressed_size = @intCast(m.data.len),
            .uncompressed_size = @intCast(m.data.len),
            .filename_len = @intCast(m.name.len),
            .extra_len = 0,
        };
        try buf.appendSlice(a, std.mem.asBytes(&lfh));
        try buf.appendSlice(a, m.name);
        try buf.appendSlice(a, m.data);
    }

    const cd_offset: u32 = @intCast(buf.items.len);
    for (members, offs.items) |m, off| {
        const cdh = std.zip.CentralDirectoryFileHeader{
            .signature = std.zip.central_file_header_sig,
            .version_made_by = 20,
            .version_needed_to_extract = 20,
            .flags = @bitCast(@as(u16, 0)),
            .compression_method = .store,
            .last_modification_time = 0,
            .last_modification_date = 0,
            .crc32 = 0,
            .compressed_size = @intCast(m.data.len),
            .uncompressed_size = @intCast(m.data.len),
            .filename_len = @intCast(m.name.len),
            .extra_len = 0,
            .comment_len = 0,
            .disk_number = 0,
            .internal_file_attributes = 0,
            .external_file_attributes = 0,
            .local_file_header_offset = off,
        };
        try buf.appendSlice(a, std.mem.asBytes(&cdh));
        try buf.appendSlice(a, m.name);
    }
    const cd_size: u32 = @intCast(buf.items.len - cd_offset);

    const eocd = std.zip.EndRecord{
        .signature = std.zip.end_record_sig,
        .disk_number = 0,
        .central_directory_disk_number = 0,
        .record_count_disk = @intCast(members.len),
        .record_count_total = @intCast(members.len),
        .central_directory_size = cd_size,
        .central_directory_offset = cd_offset,
        .comment_len = 0,
    };
    try buf.appendSlice(a, std.mem.asBytes(&eocd));

    return buf.toOwnedSlice(a);
}

fn openZip(tmp: *std.testing.TmpDir, bytes: []const u8) !std.fs.File {
    try tmp.dir.writeFile(.{ .sub_path = "t.zip", .data = bytes });
    return tmp.dir.openFile("t.zip", .{});
}

test "Archive: enumerates members, skips dir entries, find + findSuffix" {
    const a = testing.allocator;
    const zip = try buildStoreZip(a, &.{
        .{ .name = "dir/", .data = "" },
        .{ .name = "a.csv", .data = "x" },
        .{ .name = "sub/b.csv", .data = "y" },
    });
    defer a.free(zip);

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var f = try openZip(&tmp, zip);
    defer f.close();

    var archive: Archive = undefined;
    try archive.init(a, f);
    defer archive.deinit();

    // The trailing-slash directory entry is skipped.
    try testing.expectEqual(@as(usize, 2), archive.entries.items.len);
    try testing.expect(archive.find("a.csv") != null);
    try testing.expect(archive.find("missing") == null);
    try testing.expect(archive.findSuffix("b.csv") != null);
    try testing.expectEqualStrings("sub/b.csv", archive.findSuffix("b.csv").?.name);
}

test "EntryReader: streams a stored entry, then a second one (shared cursor)" {
    const a = testing.allocator;
    const zip = try buildStoreZip(a, &.{
        .{ .name = "one.csv", .data = "hello,world" },
        .{ .name = "two.csv", .data = "a,b,c\n1,2,3" },
    });
    defer a.free(zip);

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var f = try openZip(&tmp, zip);
    defer f.close();

    var archive: Archive = undefined;
    try archive.init(a, f);
    defer archive.deinit();

    var window: [std.compress.flate.max_window_len]u8 = undefined;

    var er1: EntryReader = undefined;
    try er1.init(&archive, archive.find("one.csv").?, &window);
    var out1: std.ArrayList(u8) = .empty;
    defer out1.deinit(a);
    try er1.reader().appendRemaining(a, &out1, .unlimited);
    try testing.expectEqualStrings("hello,world", out1.items);

    // Opening a second entry reseeks the shared file cursor.
    var er2: EntryReader = undefined;
    try er2.init(&archive, archive.find("two.csv").?, &window);
    var out2: std.ArrayList(u8) = .empty;
    defer out2.deinit(a);
    try er2.reader().appendRemaining(a, &out2, .unlimited);
    try testing.expectEqualStrings("a,b,c\n1,2,3", out2.items);
}
