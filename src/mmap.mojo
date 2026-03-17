"""
mmap.mojo — POSIX memory-mapped file helper

Provides a thin wrapper around the POSIX mmap/munmap/open/close/fstat
syscalls so Mojo code can memory-map files without copying bytes.

Usage:
    var m = MappedFile("measurements.txt")
    var ptr  = m.ptr    # UnsafePointer[UInt8] into the mapped region
    var size = m.size   # Int, total bytes
    m.close()           # unmaps and closes; always call this!

The mapped region is read-only (PROT_READ) and uses MAP_SHARED.
On macOS/Linux the OS will satisfy page faults on demand (lazy I/O),
so effectively only the bytes the parser actually touches are ever
loaded from disk — no upfront copy, minimal RSS peak.
"""

from std.memory import UnsafePointer
from std.ffi import external_call
from std.os.fstat import stat


comptime O_RDONLY: Int32 = 0
comptime PROT_READ: Int32 = 1
comptime MAP_PRIVATE: Int32 = 2
comptime MAP_FAILED_SENTINEL: Int = -1  # mmap returns (void*)-1 on failure

# madvise constants
comptime MADV_NORMAL: Int32 = 0
comptime MADV_RANDOM: Int32 = 1
comptime MADV_SEQUENTIAL: Int32 = 2
comptime MADV_WILLNEED: Int32 = 3
comptime MADV_DONTNEED: Int32 = 4


struct MappedFile:
    """Memory-mapped read-only view of a file."""

    var ptr: UnsafePointer[UInt8, MutExternalOrigin]
    var size: Int
    var _fd: Int32

    def __init__(out self, path: String) raises:
        # Get file size via stat (available in os.fstat)
        var st = stat(path)
        self.size = Int(st.st_size)

        # open(2) - must match stdlib's registered signature: (pointer, si32, si32) -> si32
        # Ensure path is null-terminated for C
        var null_terminated_path = path + "\0"
        self._fd = external_call["open", Int32](
            null_terminated_path.unsafe_ptr().bitcast[NoneType](),
            Int32(O_RDONLY),
            Int32(0),  # mode
        )
        if self._fd < 0:
            raise Error("mmap: open() failed for: " + path)

        # mmap(2)  — addr=NULL, prot=PROT_READ, flags=MAP_SHARED, offset=0
        var raw = external_call[
            "mmap", UnsafePointer[UInt8, MutExternalOrigin]
        ](
            UnsafePointer[
                UInt8, MutExternalOrigin
            ](),  # addr  = NULL  (kernel chooses)
            self.size,  # length
            PROT_READ,  # prot
            MAP_PRIVATE,  # flags
            self._fd,  # fd
            Int64(0),  # offset
        )

        # mmap returns MAP_FAILED = (void*)-1 on error
        if Int(raw) == MAP_FAILED_SENTINEL:
            _ = external_call["close", Int32](self._fd)
            raise Error("mmap: mmap() failed for: " + path)

        self.ptr = raw

    def advise(self, advice: Int32):
        """Advise the kernel about the intended memory access pattern."""
        if self.size > 0 and Int(self.ptr) != 0:
            _ = external_call["madvise", Int32](
                self.ptr.bitcast[NoneType](), self.size, advice
            )

    def close(mut self):
        """Unmap and close the file descriptor. Always call this."""
        if self.size > 0 and Int(self.ptr) != 0:
            _ = external_call["munmap", Int32](
                self.ptr.bitcast[NoneType](), self.size
            )
            self.ptr = UnsafePointer[UInt8, MutExternalOrigin]()
        if self._fd >= 0:
            _ = external_call["close", Int32](self._fd)
            self._fd = -1


def madvise_range(
    ptr: UnsafePointer[UInt8, MutExternalOrigin], length: Int, advice: Int32
):
    """Advise the kernel about a specific sub-range of a mapped region.
    Call with MADV_DONTNEED after a thread finishes its chunk to release
    physical pages back to the OS, freeing RAM for upcoming chunks."""
    if length > 0:
        _ = external_call["madvise", Int32](
            ptr.bitcast[NoneType](), length, advice
        )
