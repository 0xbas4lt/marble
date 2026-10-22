const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;
const testing = std.testing;
const builtin = @import("builtin");

const pmm_types = @import("PhysicalMemoryManager.zig");
const PmmAllocError = pmm_types.AllocError;
const PmmFreeError = pmm_types.FreeError;
const FrameSpan = pmm_types.FrameSpan;
const types = @import("types.zig");
const PhysAddr = types.PhysAddr;
const VirtAddr = types.VirtAddr;

pub fn PhysicalFreeListAllocator(PhysicalMemoryManager: type) type {
    return struct {
        const Self = @This();

        const AllocError = error{OutOfMemory};

        /// Allocated header + chunk
        /// |-----------------|--------\------------------------------------------------|
        /// |                 |        \                                                |
        /// | other memory    | header \ allocated chunk                                |
        /// |                 |        \   (aligned)                                    |
        /// |-----------------|--------\------------------------------------------------|
        ///
        /// Free header + chunk
        /// |-----------------|--------\------------------\-----------------------------|
        /// |                 |        \                  \                             |
        /// | other memory    | header \ free list header \ rest of chunk               |
        /// |                 |        \                  \                             |
        /// |-----------------|--------\------------------\-----------------------------|
        ///
        /// Entire memory region
        /// |-----------------|----------\-----------------\----------|-----------------|
        /// |                 |          \                 \          |                 |
        /// | other memory    | sentinel \ region's chunks \ sentinel | other memory    |
        /// |                 |          \                 \          |                 |
        /// |-----------------|----------\-----------------\----------|-----------------|
        ///
        /// Sentinel chunk's `prev_chunk_size` is undefined, and must not ever be used.
        const Header = extern struct {
            const Tag = enum(u8) {
                allocated,
                free,
                sentinel,
            };

            /// Size of the chunk without its header.
            /// Includes the FreeListHeader, if applicable.
            payload_size: usize,
            /// Size of the previous chunk in the region including its header(s).
            prev_chunk_size: usize,
            /// Specifies what header and its chunk represent.
            tag: Tag,

            pub inline fn initAtAddr(address: VirtAddr, prev_chunk_size: usize, payload_size: usize, tag: Tag) *Header {
                assert(payload_size >= min_payload_size);
                const header: *Header = @ptrFromInt(address);
                header.prev_chunk_size = prev_chunk_size;
                header.payload_size = payload_size;
                header.tag = tag;
                return header;
            }

            pub inline fn initSentinelAtAddr(address: VirtAddr) void {
                _ = initAtAddr(address, undefined, min_payload_size, .sentinel);
            }

            /// Size of this chunk including the header(s).
            pub inline fn chunkSize(self: *const Header) usize {
                return @sizeOf(Header) + self.payload_size;
            }

            /// Return this chunk's free list header.
            /// Applicable only if this chunk is free.
            pub inline fn freeListHeader(self: *Header) *FreeListHeader {
                assert(self.tag == .free);
                const base = @intFromPtr(self) + @sizeOf(Header);
                return @ptrFromInt(base);
            }

            /// Returns the previous chunk in the current region.
            /// Not applicable for sentinel chunks.
            pub inline fn prevChunk(self: *Header) *Header {
                assert(self.tag != .sentinel);
                const base = @intFromPtr(self) - self.prev_chunk_size;
                return @ptrFromInt(base);
            }

            /// Return the next chunk in the current region.
            /// Not applicable for sentinel chunks.
            pub inline fn nextChunk(self: *Header) *Header {
                assert(self.tag != .sentinel);
                const base = @intFromPtr(self) + self.chunkSize();
                return @ptrFromInt(base);
            }
        };

        const FreeListHeader = extern struct {
            prev_free: *FreeListHeader,
            next_free: *FreeListHeader,

            pub fn header(self: *const FreeListHeader) *Header {
                const base = @intFromPtr(self) - @sizeOf(Header);
                return @ptrFromInt(base);
            }
        };

        const min_payload_size: usize = @sizeOf(FreeListHeader);
        const min_chunk_size: usize = @sizeOf(Header) + min_payload_size;
        const min_region_size: usize = min_chunk_size * 3;
        const sentinel_chunk_size: usize = min_chunk_size;

        pmm: *PhysicalMemoryManager,

        min_alloc_framesize: usize,
        page_size: usize,
        hhdm_offset: VirtAddr,

        free_list_head: FreeListHeader,

        chunk_alloc_count: usize,
        chunk_free_count: usize,
        region_count: usize,

        /// `min_alloc_framesize` specifies the minimum amount of frames
        /// that can be allocated at ones.
        ///
        /// Will allocate the smallest possible memory region during initialization.
        pub fn init(self: *Self, pmm: *PhysicalMemoryManager, hhdm_offset: VirtAddr, min_alloc_framesize: usize, page_size: usize) AllocError!void {
            self.* = .{
                .pmm = pmm,
                .min_alloc_framesize = min_alloc_framesize,
                .page_size = page_size,
                .free_list_head = undefined,
                .chunk_alloc_count = 0,
                .chunk_free_count = 0,
                .region_count = 0,
                .hhdm_offset = hhdm_offset,
            };

            // Also sets self.free_list_head's initial values.
            _ = try self.reserveRegion(
                0,
                &self.free_list_head,
                &self.free_list_head,
            );
        }

        /// Returns error on memory leaks.
        pub fn deinit(self: *Self) !void {
            if (self.chunk_alloc_count > 0)
                return error.MemoryLeak;
        }

        /// Allocates a new region from raw frames. Returns the free chunk's header.
        /// |--------------------|----------------------------------|-------------------|
        /// |                    |                                  |                   |
        /// |  sentinel          | free chunk                       | sentinel          |
        /// |                    |                                  |                   |
        /// |--------------------|----------------------------------|-------------------|
        ///
        /// `min_free_size` is the minimum size of the entire free chunk with its payload.
        /// `prev_free` and `next_free` link it to the other free regions.
        /// If either of them is not null, those headers will be changed accordingly, to
        /// point to the newly-created free chunk.
        /// If one of them is null, the newly created chunk will point to undefined memory.
        fn reserveRegion(self: *Self, min_free_size: usize, prev_free: ?*FreeListHeader, next_free: ?*FreeListHeader) AllocError!*Header {
            const req_min_region_size = min_free_size + sentinel_chunk_size * 2;
            const min_alloc_size = self.min_alloc_framesize * self.page_size;
            const region_size_unaligned = @max(min_alloc_size, req_min_region_size, min_region_size);

            const region_framesize = @divCeil(region_size_unaligned, self.page_size);
            const region_size = region_framesize * self.page_size;
            const region_frame_span: FrameSpan = try self.pmm.allocate(region_framesize);

            const sentinel_first_physbase: PhysAddr = self.pmm.frameSpanPhysbase(region_frame_span);
            const sentinel_first_base = physToVirt(sentinel_first_physbase, self.hhdm_offset);
            Header.initSentinelAtAddr(sentinel_first_base);

            const chunk_size = region_size - sentinel_chunk_size * 2;
            const chunk_payload_size = chunk_size - @sizeOf(Header);
            const chunk_base = sentinel_first_base + sentinel_chunk_size;
            const chunk = Header.initAtAddr(chunk_base, sentinel_chunk_size, chunk_payload_size, .free);

            if (prev_free) |p| {
                p.next_free = chunk.freeListHeader();
                chunk.freeListHeader().prev_free = p;
            }

            if (next_free) |n| {
                n.prev_free = chunk.freeListHeader();
                chunk.freeListHeader().next_free = n;
            }

            const sentinel_last_base = chunk_base + chunk_size;
            Header.initSentinelAtAddr(sentinel_last_base);

            self.region_count += 1;
            self.chunk_free_count += 1;

            return chunk;
        }

        fn physToVirt(addr: PhysAddr, hhdm_offset: VirtAddr) VirtAddr {
            return addr + hhdm_offset;
        }

        fn virtToPhys(addr: VirtAddr, hhdm_offset: VirtAddr) PhysAddr {
            return addr - hhdm_offset;
        }
    };
}

// -----------------------------------------------------------------------------
//
//   Testing
//
// -----------------------------------------------------------------------------
test "physical allocator reserve region" {}
