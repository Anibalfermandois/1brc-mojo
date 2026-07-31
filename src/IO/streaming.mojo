"""
streaming.mojo — High-performance buffered I/O for 1BRC.

Replaces mmap for large files to avoid page-fault overhead and memory thrashing.
Implements a synchronous double-buffered streaming reader that uses `pread` to
bypass the OS page cache management overhead for bulk sequential reads.
"""

from std.memory import UnsafePointer, alloc, unsafe_memcpy
from std.ffi import CStringSlice, external_call
from std.os.fstat import stat
from misc.metrics import ParserTracker, MapTracker
from engine.perfect_hashmap import PerfectStationMap
from engine.parser import parse_chunk
from std.sys.intrinsics import unlikely

comptime O_RDONLY: Int32 = 0
comptime F_NOCACHE: Int32 = 48


struct FileHandle(Copyable, ImplicitlyCopyable, Movable):
    """A simple thin wrapper around a file descriptor for pread usage."""

    var _fd: Int32
    var size: Int

    def __copyinit__(mut self, other: Self):
        self._fd = other._fd
        self.size = other.size

    def __moveinit__(mut self, mut other: Self):
        self._fd = other._fd
        self.size = other.size

    def __init__(out self, path: String) raises:
        st = stat(path)
        self.size = Int(st.st_size)

        null_terminated_path = path + "\0"
        c_path = CStringSlice(null_terminated_path)
        self._fd = external_call["open", Int32](
            c_path,
            Int32(O_RDONLY),
            Int32(0),
        )
        if unlikely(self._fd < 0):
            raise Error("streaming: open() failed for: " + path)

    def set_nocache(self) raises:
        """Bypass the OS unified buffer cache (UBC). Critical for files > RAM.
        """
        res = external_call["fcntl", Int32](self._fd, F_NOCACHE, 1)
        if res == -1:
            raise Error("streaming: fcntl(F_NOCACHE) failed")

    def pread(
        self,
        buf: UnsafePointer[UInt8, MutUntrackedOrigin],
        count: Int,
        offset: Int,
    ) -> Int:
        """Read count bytes into buf starting at offset in the file."""
        return Int(
            external_call["pread", Int64](
                self._fd, buf.bitcast[NoneType](), Int64(count), Int64(offset)
            )
        )

    def close(mut self):
        if self._fd >= 0:
            _ = external_call["close", Int32](self._fd)
            self._fd = -1


struct DoubleBuffer:
    """A structure that manages two buffers to handle data streaming and tail reconstruction.
    """

    var base_a: UnsafePointer[UInt8, MutUntrackedOrigin]
    var base_b: UnsafePointer[UInt8, MutUntrackedOrigin]
    var buf_a: UnsafePointer[UInt8, MutUntrackedOrigin]
    var buf_b: UnsafePointer[UInt8, MutUntrackedOrigin]
    var capacity: Int
    var tail_len: Int

    def __init__(out self, capacity: Int):
        self.capacity = capacity
        # We manually align to 4096 bytes for F_NOCACHE performance
        self.base_a = alloc[UInt8](capacity + 4096)
        self.base_b = alloc[UInt8](capacity + 4096)

        offset_a = (4096 - (Int(self.base_a) % 4096)) % 4096
        offset_b = (4096 - (Int(self.base_b) % 4096)) % 4096

        self.buf_a = self.base_a + offset_a
        self.buf_b = self.base_b + offset_b
        self.tail_len = 0

    def get_active(self, step: Int) -> UnsafePointer[UInt8, MutUntrackedOrigin]:
        return self.buf_a if (step % 2 == 0) else self.buf_b

    def get_inactive(
        self, step: Int
    ) -> UnsafePointer[UInt8, MutUntrackedOrigin]:
        return self.buf_b if (step % 2 == 0) else self.buf_a

    def close(mut self):
        self.base_a.free()
        self.base_b.free()


@always_inline
def find_last_newline(
    ptr: UnsafePointer[UInt8, MutUntrackedOrigin], length: Int
) -> Int:
    """Find the index of the last newline character in a buffer."""
    for i in range(length - 1, -1, -1):
        if ptr[i] == 10:  # ASCII_LF
            return i
    return -1


@always_inline
def find_first_newline(handle: FileHandle, offset: Int) raises -> Int:
    """Skip to the first newline after the given offset to align chunks."""
    if offset == 0:
        return 0

    buf = alloc[UInt8](1024)
    bytes_read = handle.pread(buf, 1024, offset)

    for i in range(bytes_read):
        if buf[i] == 10:
            res = offset + i + 1
            buf.free()
            return res

    buf.free()
    raise Error("streaming: no newline found while aligning chunk")


struct DoubleBufferedStream[
    BLOCK_SIZE: Int = 4 * 1024 * 1024,  # 4MB
]:
    """Manages streaming processing of a file range using pread and dual buffers.
    This replaces mmap to avoid page fault thrashing on large datasets on macOS.
    """

    var handle: FileHandle
    var buffers: DoubleBuffer

    def __init__(out self, handle: FileHandle):
        self.handle = handle
        self.buffers = DoubleBuffer(
            Self.BLOCK_SIZE + 4096
        )  # Extra padding for tail

    def process_range[
        P: ParserTracker, M: MapTracker
    ](
        self,
        mut map: PerfectStationMap[MAP_TRACKER=M],
        range_start: Int,
        range_end: Int,
        mut metrics: P,
    ) raises:
        """Process an already newline-aligned byte range [start, end)."""
        current_pos = range_start
        step = 0
        tail_len = 0

        # Initial read to prime the pump
        active_buf = self.buffers.get_active(step)
        to_read = min(Self.BLOCK_SIZE, range_end - current_pos)
        if to_read <= 0:
            return
        bytes_read = self.handle.pread(active_buf, to_read, current_pos)
        if bytes_read < 0:
            raise Error("streaming: pread() failed")

        while bytes_read > 0:
            total_len = bytes_read + tail_len

            # Find boundary of last full line in CURRENT block
            last_nl = find_last_newline(active_buf, total_len)

            if unlikely(last_nl == -1):
                raise Error(
                    "streaming: no newline found in "
                    + String(total_len)
                    + " bytes"
                )

            # Parse the full lines
            parse_chunk[P, M](map, active_buf, last_nl + 1, metrics)

            # Prepare NEXT iteration
            next_step = step + 1
            next_buf = self.buffers.get_active(next_step)

            # Handle the tail (partial line)
            tail_len = total_len - (last_nl + 1)
            if tail_len > 0:
                unsafe_memcpy(
                    dest=next_buf,
                    src=active_buf + (last_nl + 1),
                    count=tail_len,
                )

            current_pos += bytes_read
            step = next_step
            active_buf = next_buf

            if current_pos >= range_end:
                if tail_len > 0:
                    raise Error(
                        "streaming: aligned range ended with a partial row"
                    )
                break

            to_read = min(Self.BLOCK_SIZE, range_end - current_pos)

            if to_read <= 0:
                break

            bytes_read = self.handle.pread(
                active_buf + tail_len, to_read, current_pos
            )
            if bytes_read < 0:
                raise Error("streaming: pread() failed")

        # 6. Flush remaining tail if this was the last chunk of the WHOLE file
        if current_pos >= self.handle.size and tail_len > 0:
            # This should not happen if the file ends with \n as specified in 1BRC
            pass

    def close(mut self):
        self.buffers.close()
