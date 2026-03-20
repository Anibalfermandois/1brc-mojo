"""
streaming.mojo — High-performance buffered I/O for 1BRC.

Replaces mmap for large files (>8GB) to avoid page-fault overhead and memory thrashing.
Implements a synchronous double-buffered streaming reader that uses `pread` to
bypass the OS page cache management overhead for bulk sequential reads.
"""

from std.memory import UnsafePointer, memcpy, alloc
from std.ffi import external_call
from std.os.fstat import stat
from metrics import ParserTracker, MapTracker
from perfect_hashmap import PerfectStationMap
from parser import parse_chunk

comptime O_RDONLY: Int32 = 0

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
        var st = stat(path)
        self.size = Int(st.st_size)

        var null_terminated_path = path + "\0"
        self._fd = external_call["open", Int32](
            null_terminated_path.unsafe_ptr().bitcast[NoneType](),
            Int32(O_RDONLY),
            Int32(0),
        )
        if self._fd < 0:
            raise Error("streaming: open() failed for: " + path)

    def pread(self, buf: UnsafePointer[UInt8, MutExternalOrigin], count: Int, offset: Int) -> Int:
        """Read count bytes into buf starting at offset in the file."""
        return Int(external_call["pread", Int64](
            self._fd,
            buf.bitcast[NoneType](),
            Int64(count),
            Int64(offset)
        ))

    def close(mut self):
        if self._fd >= 0:
            _ = external_call["close", Int32](self._fd)
            self._fd = -1

struct DoubleBuffer:
    """A structure that manages two buffers to handle data streaming and tail reconstruction."""
    var buf_a: UnsafePointer[UInt8, MutExternalOrigin]
    var buf_b: UnsafePointer[UInt8, MutExternalOrigin]
    var capacity: Int
    var tail_len: Int

    def __init__(out self, capacity: Int):
        self.capacity = capacity
        self.buf_a = alloc[UInt8](capacity)
        self.buf_b = alloc[UInt8](capacity)
        self.tail_len = 0

    def get_active(self, step: Int) -> UnsafePointer[UInt8, MutExternalOrigin]:
        return self.buf_a if (step % 2 == 0) else self.buf_b

    def get_inactive(self, step: Int) -> UnsafePointer[UInt8, MutExternalOrigin]:
        return self.buf_b if (step % 2 == 0) else self.buf_a

    def close(mut self):
        if self.buf_a: self.buf_a.free()
        if self.buf_b: self.buf_b.free()
        self.buf_a = UnsafePointer[UInt8, MutExternalOrigin]()
        self.buf_b = UnsafePointer[UInt8, MutExternalOrigin]()

@always_inline
def find_last_newline(ptr: UnsafePointer[UInt8, MutExternalOrigin], length: Int) -> Int:
    """Find the index of the last newline character in a buffer."""
    for i in range(length - 1, -1, -1):
        if ptr[i] == 10: # ASCII_LF
            return i
    return -1

@always_inline
def find_first_newline(handle: FileHandle, offset: Int) -> Int:
    """Skip to the first newline after the given offset to align chunks."""
    if offset == 0: return 0
    
    var buf = alloc[UInt8](1024)
    var bytes_read = handle.pread(buf, 1024, offset)
    
    for i in range(bytes_read):
        if buf[i] == 10:
            var res = offset + i + 1
            buf.free()
            return res
    
    buf.free()
    return offset # Fallback

struct DoubleBufferedStream[
    BLOCK_SIZE: Int = 1 * 1024 * 1024, # 1MB
]:
    """Manages streaming processing of a file range using pread and dual buffers.
    This replaces mmap to avoid page fault thrashing on large datasets on macOS.
    """
    var handle: FileHandle
    var buffers: DoubleBuffer

    def __init__(out self, handle: FileHandle):
        self.handle = handle
        self.buffers = DoubleBuffer(Self.BLOCK_SIZE + 4096) # Extra padding for tail

    def process_range[
        P: ParserTracker, M: MapTracker
    ](
        self,
        mut map: PerfectStationMap[MAP_TRACKER=M],
        range_start: Int,
        range_end: Int,
        mut metrics: P
    ) raises:
        """Processes a byte range [range_start, range_end) using buffered pread."""
        # 1. Align to first newline
        var current_pos = find_first_newline(self.handle, range_start)
        var step = 0
        var tail_len = 0
        
        while current_pos < range_end:
            var active_buf = self.buffers.get_active(step)
            
            # 2. Read next block into active buffer (after any existing tail)
            var to_read = Self.BLOCK_SIZE
            if current_pos + to_read > self.handle.size:
                 to_read = self.handle.size - current_pos
            
            var bytes_read = 0
            if to_read > 0:
                bytes_read = self.handle.pread(active_buf + tail_len, to_read, current_pos)
            
            var total_len = bytes_read + tail_len
            if total_len == 0: break
            
            # 3. Find boundary of last full line
            var last_nl = find_last_newline(active_buf, total_len)
            
            if last_nl == -1:
                # Pathological city name > 1MB? Unlikely for 1BRC but handle it.
                # If we don't find a newline, we just read MORE into the SAME buffer.
                # In 1BRC max row is ~100 bytes, so BLOCK_SIZE=1MB is plenty.
                raise Error("streaming: no newline found in " + String(total_len) + " bytes")
                
            # 4. Parse the full lines in the buffer
            parse_chunk[P, M](map, active_buf, last_nl + 1, metrics)
            
            # 5. Handle the tail (partial line)
            tail_len = total_len - (last_nl + 1)
            var inactive_buf = self.buffers.get_inactive(step)
            if tail_len > 0:
                memcpy(dest=inactive_buf, src=active_buf + (last_nl + 1), count=tail_len)
            
            current_pos += bytes_read
            step += 1
            
            # Stop if we crossed the end (the next thread handles its part)
            if current_pos >= range_end:
                 break
        
        # 6. Flush remaining tail if this was the last chunk of the WHOLE file
        if current_pos >= self.handle.size and tail_len > 0:
             # This should not happen if the file ends with \n as specified in 1BRC
             pass
             
    def close(mut self):
        self.buffers.close()
