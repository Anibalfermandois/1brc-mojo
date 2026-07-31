trait Tag: pass
struct TagA(Tag): pass
struct TagB(Tag): pass

struct Handle[tag: Tag](ImplicitlyCopyable, Movable):
    var _index: Int

    def __init__(out self, index: Int):
        self._index = index

struct BrandedArena[T: Tag]:
    var data: List[Int]

    def __init__(out self, var data: List[Int] = []):
        self.data = data^

    def alloc(mut self, value: Int) -> Handle[Self.T]:
        self.data.append(value)
        return Handle[Self.T](len(self.data) - 1)

    def get(self, handle: Handle[Self.T]) -> Int:
        return self.data[handle._index]

def main():
    var arena_a = BrandedArena[TagA]()
    var arena_b = BrandedArena[TagB]()
    # User tracks the indices
    var obj_a1: Handle[TagA] = arena_a.alloc(1)
    var obj_a2: Handle[TagA] = arena_a.alloc(2)
    var obj_b1: Handle[TagB] = arena_b.alloc(1)
    arena_a.get(obj_a1)
    arena_b.get(obj_b1)
    arena_a.get(obj_b1) # COMPILER ERROR:
