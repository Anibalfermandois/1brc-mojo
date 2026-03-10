Mojo struct

SIMD
@register_passable(trivial)
struct SIMD[dtype: DType, size: Int]

Represents a vector type that leverages hardware acceleration to process multiple data elements with a single operation.

SIMD (Single Instruction, Multiple Data) is a fundamental parallel computing paradigm where a single CPU instruction operates on multiple data elements at once. Modern CPUs can perform 4, 8, 16, or even 32 operations in parallel using SIMD, delivering substantial performance improvements over scalar operations. Instead of processing one value at a time, SIMD processes entire vectors of values with each instruction.

For example, when adding two vectors of four values, a scalar operation adds each value in the vector one by one, while a SIMD operation adds all four values at once using vector registers:

Scalar operation:                SIMD operation:
┌─────────────────────────┐      ┌───────────────────────────┐
│ 4 instructions          │      │ 1 instruction             │
│ 4 clock cycles          │      │ 1 clock cycle             │
│                         │      │                           │
│ ADD  a[0], b[0] → c[0]  │      │ Vector register A         │
│ ADD  a[1], b[1] → c[1]  │      │ ┌─────┬─────┬─────┬─────┐ │
│ ADD  a[2], b[2] → c[2]  │      │ │a[0] │a[1] │a[2] │a[3] │ │
│ ADD  a[3], b[3] → c[3]  │      │ └─────┴─────┴─────┴─────┘ │
└─────────────────────────┘      │           +               │
                                 │ Vector register B         │
                                 │ ┌─────┬─────┬─────┬─────┐ │
                                 │ │b[0] │b[1] │b[2] │b[3] │ │
                                 │ └─────┴─────┴─────┴─────┘ │
                                 │           ↓               │
                                 │        SIMD_ADD           │
                                 │           ↓               │
                                 │ Vector register C         │
                                 │ ┌─────┬─────┬─────┬─────┐ │
                                 │ │c[0] │c[1] │c[2] │c[3] │ │
                                 │ └─────┴─────┴─────┴─────┘ │
                                 └───────────────────────────┘

The SIMD type maps directly to hardware vector registers and instructions. Mojo automatically generates optimal SIMD code that leverages CPU-specific instruction sets (such as AVX and NEON) without requiring manual intrinsics or assembly programming.

This type is the foundation of high-performance CPU computing in Mojo, enabling you to write code that automatically leverages modern CPU vector capabilities while maintaining code clarity and portability.

Caution: If you declare a SIMD vector size larger than the vector registers of the target hardware, the compiler will break up the SIMD into multiple vector registers for compatibility. However, you should avoid using a vector that's more than 2x the hardware's vector register size because the resulting code will perform poorly.

Key properties:

Hardware-mapped: Directly maps to CPU vector registers
Type-safe: Data types and vector sizes are checked at compile time
Zero-cost: No runtime overhead compared to hand-optimized intrinsics
Portable: Same code works across different CPU architectures (x86, ARM, etc.)
Composable: Seamlessly integrates with Mojo's parallelization features
Key APIs:

Construction:

Broadcast single value to all elements: SIMD[dtype, size](value)
Initialize with specific values: SIMD[dtype, size](v1, v2, ...)
Zero-initialized vector: SIMD[dtype, size]()
Element operations:

Arithmetic: +, -, *, /, %, //
Comparison: ==, !=, <, <=, >, >=
Math functions: sqrt(), sin(), cos(), fma(), etc.
Bit operations: &, |, ^, ~, <<, >>
Vector operations:

Horizontal reductions: reduce_add(), reduce_mul(), reduce_min(), reduce_max()
Element-wise conditional selection: select(condition, true_case, false_case)
Vector manipulation: shuffle(), slice(), join(), split()
Type conversion: cast[target_dtype]()
Examples:

Vectorized math operations:

# Process 8 floating-point numbers simultaneously
var a = SIMD[DType.float32, 8](1.0, 2.0, 3.0, 4.0, 5.0, 6.0, 7.0, 8.0)
var b = SIMD[DType.float32, 8](2.0)  # Broadcast 2.0 to all elements
var result = a * b + 1.0
print(result)  # => [3.0, 5.0, 7.0, 9.0, 11.0, 13.0, 15.0, 17.0]

Conditional operations with masking:

# Double the positive values and negate the negative values
var values = SIMD[DType.int32, 4](1, -2, 3, -4)
var is_positive = values.gt(0)  # greater-than: gets SIMD of booleans
var result = is_positive.select(values * 2, values * -1)
print(result)  # => [2, 2, 6, 4]

Horizontal reductions:

# Sum all elements in a vector
var data = SIMD[DType.float64, 4](10.5, 20.3, 30.1, 40.7)
var total = data.reduce_add()
var maximum = data.reduce_max()
print(total, maximum)  # => 101.6 40.7

Constraints:

The size of the SIMD vector must be positive and a power of 2.

Parameters
​dtype (DType): The data type of SIMD vector elements.
​size (Int): The size of the SIMD vector (number of elements).
Implemented traits
Absable, AnyType, Boolable, CeilDivable, Ceilable, Comparable, Copyable, Defaultable, DevicePassable, DivModable, Equatable, Floorable, Hashable, ImplicitlyCopyable, ImplicitlyDestructible, Indexer, Intable, Movable, Powable, Representable, Roundable, Sized, Stringable, Truncable, Writable

comptime members
__copyinit__is_trivial
comptime __copyinit__is_trivial = True

__del__is_trivial
comptime __del__is_trivial = True

__moveinit__is_trivial
comptime __moveinit__is_trivial = True

device_type
comptime device_type = SIMD[dtype, size]

SIMD types are remapped to the same type when passed to accelerator devices.

MAX
comptime MAX = SIMD[dtype, size](max_or_inf[dtype]())

Gets the maximum value for the SIMD value, potentially +inf.

MAX_FINITE
comptime MAX_FINITE = SIMD[dtype, size](max_finite[dtype]())

Returns the maximum finite value of SIMD value.

MIN
comptime MIN = SIMD[dtype, size](min_or_neg_inf[dtype]())

Gets the minimum value for the SIMD value, potentially -inf.

MIN_FINITE
comptime MIN_FINITE = SIMD[dtype, size](min_finite[dtype]())

Returns the minimum (lowest) finite value of SIMD value.

Methods
__init__
__init__() -> Self

Default initializer of the SIMD vector.

By default the SIMD vectors are initialized to all zeros.

__init__[other_dtype: DType, //](value: SIMD[other_dtype, size], /) -> Self

Initialize from another SIMD of the same size. If the value passed is a scalar, you can initialize a SIMD vector with more elements.

Example:

print(UInt64(UInt8(42))) # 42
print(SIMD[DType.uint64, 4](UInt8(42))) # [42, 42, 42, 42]

Casting behavior:

# Basic casting preserves value within range
Int8(UInt8(127)) == Int8(127)

# Numbers above signed max wrap to negative using two's complement
Int8(UInt8(128)) == Int8(-128)
Int8(UInt8(129)) == Int8(-127)
Int8(UInt8(256)) == Int8(0)

# Negative signed cast to unsigned using two's complement
UInt8(Int8(-128)) == UInt8(128)
UInt8(Int8(-127)) == UInt8(129)
UInt8(Int8(-1)) == UInt8(255)

# Truncate precision after downcast and upcast
Float64(Float32(Float64(123456789.123456789))) == Float64(123456792.0)

# Rightmost bits of significand become 0's on upcast
Float64(Float32(0.3)) == Float64(0.30000001192092896)

# Numbers equal after truncation of float literal and cast truncation
Float32(Float64(123456789.123456789)) == Float32(123456789.123456789)

# Float to int/uint floors
Int64(Float64(42.2)) == Int64(42)

Parameters:

​other_dtype (DType): The type of the value that is being cast from.
Args:

​value (SIMD): The value to cast from.
@implicit
__init__(value: Int, /) -> Self

Initializes the SIMD vector with a signed integer.

The signed integer value is splatted across all the elements of the SIMD vector.

Args:

​value (Int): The input value.
__init__[T: Floatable, //](value: T, /) -> Float64

Initialize a Float64 from a type conforming to Floatable.

Parameters:

​T (Floatable): The Floatable type.
Args:

​value (T): The object to get the float point representation of.
Returns:

Float64

__init__[T: FloatableRaising, //](out self: Float64, value: T, /)

Initialize a Float64 from a type conforming to FloatableRaising.

Parameters:

​T (FloatableRaising): The FloatableRaising type.
Args:

​value (T): The object to get the float point representation of.
Returns:

Float64 Raises:

If the type does not have a float point representation.

@implicit
__init__(value: IntLiteral[value], /) -> Self

Initializes the SIMD vector with an integer.

The integer value is splatted across all the elements of the SIMD vector.

Args:

​value (IntLiteral): The input value.
@implicit
__init__(value: Bool, /) -> SIMD[DType.bool, size]

Initializes a Scalar with a bool value.

Since this constructor does not splat, it can be implicit.

Args:

​value (Bool): The bool value to initialize the Scalar with.
Returns:

SIMD

__init__(*, fill: Bool) -> SIMD[DType.bool, size]

Initializes the SIMD vector with a bool value.

The bool value is splatted across all elements of the SIMD vector.

Args:

​fill (Bool): The bool value to fill each element of the SIMD vector with.
Returns:

SIMD

@implicit
__init__(value: Scalar[dtype], /) -> Self

Constructs a SIMD vector by splatting a scalar value.

The input value is splatted across all elements of the SIMD vector.

Args:

​value (Scalar): The value to splat to the elements of the vector.
__init__(*elems: Scalar[dtype], *, __list_literal__: Tuple[] = Tuple[]()) -> Self

Constructs a SIMD vector via a variadic list of elements.

The input values are assigned to the corresponding elements of the SIMD vector.

Constraints:

The number of input values is equal to size of the SIMD vector.

Args:

​*elems (Scalar): The variadic list of elements from which the SIMD vector is constructed.
​list_literal (Tuple): Tell Mojo to use this method for list literals.
@implicit
__init__(value: FloatLiteral[value], /) -> Self

Initializes the SIMD vector with a float.

The value is splatted across all the elements of the SIMD vector.

Args:

​value (FloatLiteral): The input value.
__init__[int_dtype: DType, //](*, from_bits: SIMD[int_dtype, size]) -> Self

Initializes the SIMD vector from the bits of an integral SIMD vector.

Parameters:

​int_dtype (DType): The integral type of the input SIMD vector.
Args:

​from_bits (SIMD): The SIMD vector to copy the bits from.
__bool__
__bool__(self) -> Bool

Converts the SIMD scalar into a boolean value.

Returns:

Bool: True if the SIMD scalar is non-zero and False otherwise.

__getitem__
__getitem__(self, idx: Int) -> Scalar[dtype]

Gets an element from the vector.

Args:

​idx (Int): The element index.
Returns:

Scalar: The value at position idx.

__setitem__
__setitem__(mut self, idx: Int, val: Scalar[dtype])

Sets an element in the vector.

Args:

​idx (Int): The index to set.
​val (Scalar): The value to set.
__neg__
__neg__(self) -> Self

Defines the unary - operation.

Returns:

Self: The negation of this SIMD vector.

__pos__
__pos__(self) -> Self

Defines the unary + operation.

Returns:

Self: This SIMD vector.

__invert__
__invert__(self) -> Self

Returns ~self.

Constraints:

The element type of the SIMD vector must be boolean or integral.

Returns:

Self: The ~self value.

__lt__
__lt__(self, rhs: Self) -> Bool

Compares two Scalars using less-than comparison.

Args:

​rhs (Self): The Scalar to compare with.
Returns:

Bool: True if self is less than rhs, False otherwise.

__le__
__le__(self, rhs: Self) -> Bool

Compares two Scalars using less-than-or-equal comparison.

Args:

​rhs (Self): The Scalar to compare with.
Returns:

Bool: True if self is less than or equal to rhs, False otherwise.

__eq__
__eq__(self, rhs: Self) -> Bool

Compares two SIMD vectors for equality.

Args:

​rhs (Self): The SIMD vector to compare with.
Returns:

Bool: True if all elements of the SIMD vectors are equal, False otherwise.

__ne__
__ne__(self, rhs: Self) -> Bool

Compares two SIMD vectors for inequality.

Args:

​rhs (Self): The SIMD vector to compare with.
Returns:

Bool: True if any elements of the SIMD vectors are not equal, False otherwise.

__gt__
__gt__(self, rhs: Self) -> Bool

Compares two Scalars using greater-than comparison.

Args:

​rhs (Self): The Scalar to compare with.
Returns:

Bool: True if self is greater than rhs, False otherwise.

__ge__
__ge__(self, rhs: Self) -> Bool

Compares two Scalars using greater-than-or-equal comparison.

Args:

​rhs (Self): The Scalar to compare with.
Returns:

Bool: True if self is greater than or equal to rhs, False otherwise.

__contains__
__contains__(self, value: Scalar[dtype]) -> Bool

Whether the vector contains the value.

Args:

​value (Scalar): The value.
Returns:

Bool: Whether the vector contains the value.

__add__
__add__(self, rhs: Self) -> Self

Computes self + rhs.

Args:

​rhs (Self): The rhs value.
Returns:

Self: A new vector whose element at position i is computed as self[i] + rhs[i].

__sub__
__sub__(self, rhs: Self) -> Self

Computes self - rhs.

Args:

​rhs (Self): The rhs value.
Returns:

Self: A new vector whose element at position i is computed as self[i] - rhs[i].

__mul__
__mul__(self, rhs: Self) -> Self

Computes self * rhs.

Args:

​rhs (Self): The rhs value.
Returns:

Self: A new vector whose element at position i is computed as self[i] * rhs[i].

__truediv__
__truediv__(self, rhs: Self) -> Self

Computes self / rhs.

Args:

​rhs (Self): The rhs value.
Returns:

Self: A new vector whose element at position i is computed as self[i] / rhs[i].

__floordiv__
__floordiv__(self, rhs: Self) -> Self

Returns the division of self and rhs rounded down to the nearest integer.

Constraints:

The element type of the SIMD vector must be numeric.

Args:

​rhs (Self): The value to divide with.
Returns:

Self: floor(self / rhs) value.

__mod__
__mod__(self, rhs: Self) -> Self

Returns the remainder of self divided by rhs.

Args:

​rhs (Self): The value to divide with.
Returns:

Self: The remainder of dividing self by rhs.

__pow__
__pow__(self, exp: Int) -> Self

Computes the vector raised to the power of the input integer value.

Args:

​exp (Int): The exponent value.
Returns:

Self: A SIMD vector where each element is raised to the power of the specified exponent value.

__pow__(self, exp: Self) -> Self

Computes the vector raised elementwise to the right hand side power.

Args:

​exp (Self): The exponent value.
Returns:

Self: A SIMD vector where each element is raised to the power of the specified exponent value.

__lshift__
__lshift__(self, rhs: Self) -> Self

Returns self << rhs.

Constraints:

The element type of the SIMD vector must be integral.

Args:

​rhs (Self): The RHS value.
Returns:

Self: self << rhs.

__rshift__
__rshift__(self, rhs: Self) -> Self

Returns self >> rhs.

Constraints:

The element type of the SIMD vector must be integral.

Args:

​rhs (Self): The RHS value.
Returns:

Self: self >> rhs.

__and__
__and__(self, rhs: Self) -> Self

Returns self & rhs.

Constraints:

The element type of the SIMD vector must be bool or integral.

Args:

​rhs (Self): The RHS value.
Returns:

Self: self & rhs.

__or__
__or__(self, rhs: Self) -> Self

Returns self | rhs.

Constraints:

The element type of the SIMD vector must be bool or integral.

Args:

​rhs (Self): The RHS value.
Returns:

Self: self | rhs.

__xor__
__xor__(self, rhs: Self) -> Self

Returns self ^ rhs.

Constraints:

The element type of the SIMD vector must be bool or integral.

Args:

​rhs (Self): The RHS value.
Returns:

Self: self ^ rhs.

__radd__
__radd__(self, value: Self) -> Self

Returns value + self.

Args:

​value (Self): The other value.
Returns:

Self: value + self.

__rsub__
__rsub__(self, value: Self) -> Self

Returns value - self.

Args:

​value (Self): The other value.
Returns:

Self: value - self.

__rmul__
__rmul__(self, value: Self) -> Self

Returns value * self.

Args:

​value (Self): The other value.
Returns:

Self: value * self.

__rtruediv__
__rtruediv__(self, value: Self) -> Self

Returns value / self.

Args:

​value (Self): The other value.
Returns:

Self: value / self.

__rfloordiv__
__rfloordiv__(self, rhs: Self) -> Self

Returns the division of rhs and self rounded down to the nearest integer.

Constraints:

The element type of the SIMD vector must be numeric.

Args:

​rhs (Self): The value to divide by self.
Returns:

Self: floor(rhs / self) value.

__rmod__
__rmod__(self, value: Self) -> Self

Returns value mod self.

Args:

​value (Self): The other value.
Returns:

Self: value mod self.

__rpow__
__rpow__(self, base: Self) -> Self

Returns base ** self.

Args:

​base (Self): The base value.
Returns:

Self: base ** self.

__rlshift__
__rlshift__(self, value: Self) -> Self

Returns value << self.

Constraints:

The element type of the SIMD vector must be integral.

Args:

​value (Self): The other value.
Returns:

Self: value << self.

__rrshift__
__rrshift__(self, value: Self) -> Self

Returns value >> self.

Constraints:

The element type of the SIMD vector must be integral.

Args:

​value (Self): The other value.
Returns:

Self: value >> self.

__rand__
__rand__(self, value: Self) -> Self

Returns value & self.

Constraints:

The element type of the SIMD vector must be bool or integral.

Args:

​value (Self): The other value.
Returns:

Self: value & self.

__ror__
__ror__(self, value: Self) -> Self

Returns value | self.

Constraints:

The element type of the SIMD vector must be bool or integral.

Args:

​value (Self): The other value.
Returns:

Self: value | self.

__rxor__
__rxor__(self, value: Self) -> Self

Returns value ^ self.

Constraints:

The element type of the SIMD vector must be bool or integral.

Args:

​value (Self): The other value.
Returns:

Self: value ^ self.

__iadd__
__iadd__(mut self, rhs: Self)

Performs in-place addition.

The vector is mutated where each element at position i is computed as self[i] + rhs[i].

Args:

​rhs (Self): The rhs of the addition operation.
__isub__
__isub__(mut self, rhs: Self)

Performs in-place subtraction.

The vector is mutated where each element at position i is computed as self[i] - rhs[i].

Args:

​rhs (Self): The rhs of the operation.
__imul__
__imul__(mut self, rhs: Self)

Performs in-place multiplication.

The vector is mutated where each element at position i is computed as self[i] * rhs[i].

Args:

​rhs (Self): The rhs of the operation.
__itruediv__
__itruediv__(mut self, rhs: Self)

In-place true divide operator.

The vector is mutated where each element at position i is computed as self[i] / rhs[i].

Args:

​rhs (Self): The rhs of the operation.
__ifloordiv__
__ifloordiv__(mut self, rhs: Self)

In-place flood div operator.

The vector is mutated where each element at position i is computed as self[i] // rhs[i].

Args:

​rhs (Self): The rhs of the operation.
__imod__
__imod__(mut self, rhs: Self)

In-place mod operator.

The vector is mutated where each element at position i is computed as self[i] % rhs[i].

Args:

​rhs (Self): The rhs of the operation.
__ipow__
__ipow__(mut self, rhs: Int)

In-place pow operator.

The vector is mutated where each element at position i is computed as pow(self[i], rhs).

Args:

​rhs (Int): The rhs of the operation.
__ilshift__
__ilshift__(mut self, rhs: Self)

Computes self << rhs and save the result in self.

Constraints:

The element type of the SIMD vector must be integral.

Args:

​rhs (Self): The RHS value.
__irshift__
__irshift__(mut self, rhs: Self)

Computes self >> rhs and save the result in self.

Constraints:

The element type of the SIMD vector must be integral.

Args:

​rhs (Self): The RHS value.
__iand__
__iand__(mut self, rhs: Self)

Computes self & rhs and save the result in self.

Constraints:

The element type of the SIMD vector must be bool or integral.

Args:

​rhs (Self): The RHS value.
__ixor__
__ixor__(mut self, rhs: Self)

Computes self ^ rhs and save the result in self.

Constraints:

The element type of the SIMD vector must be bool or integral.

Args:

​rhs (Self): The RHS value.
__ior__
__ior__(mut self, rhs: Self)

Computes self | rhs and save the result in self.

Constraints:

The element type of the SIMD vector must be bool or integral.

Args:

​rhs (Self): The RHS value.
get_type_name
static get_type_name() -> String

Gets this type's name, for use in error messages when handing arguments to kernels. TODO: This will go away soon, when we get better error messages for kernel calls.

Returns:

String: This type's name.

get_device_type_name
static get_device_type_name() -> String

Gets device_type's name, for use in error messages when handing arguments to kernels. TODO: This will go away soon, when we get better error messages for kernel calls.

Returns:

String: This type's name.

__divmod__
__divmod__(self, denominator: Self) -> Tuple[SIMD[dtype, size], SIMD[dtype, size]]

Computes both the quotient and remainder using floor division.

Args:

​denominator (Self): The value to divide on.
Returns:

Tuple: The quotient and remainder as a Tuple(self // denominator, self % denominator).

eq
eq(self, rhs: Self) -> SIMD[DType.bool, size]

Compares two SIMD vectors using elementwise equality.

Args:

​rhs (Self): The SIMD vector to compare with.
Returns:

SIMD: A new bool SIMD vector of the same size whose element at position i is the value of self[i] == rhs[i].

ne
ne(self, rhs: Self) -> SIMD[DType.bool, size]

Compares two SIMD vectors using elementwise inequality.

Args:

​rhs (Self): The SIMD vector to compare with.
Returns:

SIMD: A new bool SIMD vector of the same size whose element at position i is the value of self[i] != rhs[i].

gt
gt(self, rhs: Self) -> SIMD[DType.bool, size]

Compares two SIMD vectors using elementwise greater-than comparison.

Args:

​rhs (Self): The SIMD vector to compare with.
Returns:

SIMD: A new bool SIMD vector of the same size whose element at position i is the value of self[i] > rhs[i].

ge
ge(self, rhs: Self) -> SIMD[DType.bool, size]

Compares two SIMD vectors using elementwise greater-than-or-equal comparison.

Args:

​rhs (Self): The SIMD vector to compare with.
Returns:

SIMD: A new bool SIMD vector of the same size whose element at position i is the value of self[i] >= rhs[i].

lt
lt(self, rhs: Self) -> SIMD[DType.bool, size]

Compares two SIMD vectors using elementwise less-than comparison.

Args:

​rhs (Self): The SIMD vector to compare with.
Returns:

SIMD: A new bool SIMD vector of the same size whose element at position i is the value of self[i] < rhs[i].

le
le(self, rhs: Self) -> SIMD[DType.bool, size]

Compares two SIMD vectors using elementwise less-than-or-equal comparison.

Args:

​rhs (Self): The SIMD vector to compare with.
Returns:

SIMD: A new bool SIMD vector of the same size whose element at position i is the value of self[i] <= rhs[i].

__len__
__len__(self) -> Int

Gets the length of the SIMD vector.

Returns:

Int: The length of the SIMD vector.

__int__
__int__(self) -> Int

Casts to the value to an Int. If there is a fractional component, then the fractional part is truncated.

Constraints:

The size of the SIMD vector must be 1.

Returns:

Int: The value as an integer.

__mlir_index__
__mlir_index__(self) -> __mlir_type.index

Convert to index.

Returns:

__mlir_type.index: The corresponding __mlir_type.index value.

__float__
__float__(self) -> Float64

Casts the value to a float.

Constraints:

The size of the SIMD vector must be 1.

Returns:

Float64: The value as a float.

__str__
__str__(self) -> String

Get the SIMD as a string.

Returns:

String: A string representation.

__repr__
__repr__(self) -> String

Get the representation of the SIMD value e.g. "SIMD[DType.int8, 2](1, 2)".

Returns:

String: The representation of the SIMD value.

__floor__
__floor__(self) -> Self

Performs elementwise floor on the elements of a SIMD vector.

Returns:

Self: The elementwise floor of this SIMD vector.

__ceil__
__ceil__(self) -> Self

Performs elementwise ceiling on the elements of a SIMD vector.

Returns:

Self: The elementwise ceiling of this SIMD vector.

__trunc__
__trunc__(self) -> Self

Performs elementwise truncation on the elements of a SIMD vector.

Returns:

Self: The elementwise truncated values of this SIMD vector.

__abs__
__abs__(self) -> Self

Defines the absolute value operation.

Returns:

Self: The absolute value of this SIMD vector.

__round__
__round__(self) -> Self

Performs elementwise rounding on the elements of a SIMD vector.

This rounding goes to the nearest integer with ties away from zero.

Returns:

Self: The elementwise rounded value of this SIMD vector.

__round__(self, ndigits: Int) -> Self

Performs elementwise rounding on the elements of a SIMD vector.

This rounding goes to the nearest integer with ties away from zero.

Args:

​ndigits (Int): The number of digits to round to.
Returns:

Self: The elementwise rounded value of this SIMD vector.

__hash__
__hash__[H: Hasher](self, mut hasher: H)

Updates hasher with this SIMD value.

Parameters:

​H (Hasher): The hasher type.
Args:

​hasher (H): The hasher instance.
__ceildiv__
__ceildiv__(self, denominator: Self) -> Self

Return the rounded-up result of dividing self by denominator.

Args:

​denominator (Self): The denominator.
Returns:

Self: The ceiling of dividing numerator by denominator.

cast
cast[target: DType](self) -> SIMD[target, size]

Casts the elements of the SIMD vector to the target element type.

Casting behavior:

# Basic casting preserves value within range
Int8(UInt8(127)) == Int8(127)

# Numbers above signed max wrap to negative using two's complement
Int8(UInt8(128)) == Int8(-128)
Int8(UInt8(129)) == Int8(-127)
Int8(UInt8(256)) == Int8(0)

# Negative signed cast to unsigned using two's complement
UInt8(Int8(-128)) == UInt8(128)
UInt8(Int8(-127)) == UInt8(129)
UInt8(Int8(-1)) == UInt8(255)

# Truncate precision after downcast and upcast
Float64(Float32(Float64(123456789.123456789))) == Float64(123456792.0)

# Rightmost bits of significand become 0's on upcast
Float64(Float32(0.3)) == Float64(0.30000001192092896)

# Numbers equal after truncation of float literal and cast truncation
Float32(Float64(123456789.123456789)) == Float32(123456789.123456789)

# Float to int/uint floors
Int64(Float64(42.2)) == Int64(42)

Parameters:

​target (DType): The target DType.
Returns:

SIMD: A new SIMD vector whose elements have been casted to the target element type.

is_power_of_two
is_power_of_two(self) -> SIMD[DType.bool, size]

Checks if the input value is a power of 2 for each element of a SIMD vector.

Constraints:

The element type of the input vector must be integral.

Returns:

SIMD: A SIMD value where the element at position i is True if the integer at position i of the input value is a power of 2, False otherwise.

write_to
write_to(self, mut writer: T)

Formats this SIMD value to the provided Writer.

Args:

​writer (T): The object to write to.
write_repr_to
write_repr_to(self, mut writer: T)

Write the string representation of the SIMD value".

Args:

​writer (T): The value to write to.
to_bits
to_bits[_dtype: DType = _uint_type_of_width[bit_width_of[dtype]()]()](self) -> SIMD[_dtype, size]

Bitcasts the SIMD vector to an integer SIMD vector.

Parameters:

​_dtype (DType): The integer type to cast to.
Returns:

SIMD: An integer representation of the floating-point value.

from_bytes
static from_bytes[*, big_endian: Bool = is_big_endian()](bytes: InlineArray[Byte, size_of[SIMD[dtype, size]]()]) -> Self

Converts a byte array to a vector.

Parameters:

​big_endian (Bool): Whether the byte array is big-endian.
Args:

​bytes (InlineArray): The byte array to convert.
Returns:

Self: The integer value.

as_bytes
as_bytes[*, big_endian: Bool = is_big_endian()](self) -> InlineArray[Byte, size_of[SIMD[dtype, size]]()]

Convert the vector to a byte array.

Parameters:

​big_endian (Bool): Whether the byte array should be big-endian.
Returns:

InlineArray: The byte array.

clamp
clamp(self, lower_bound: Self, upper_bound: Self) -> Self

Clamps the values in a SIMD vector to be in a certain range.

Clamp cuts values in the input SIMD vector off at the upper bound and lower bound values. For example, SIMD vector [0, 1, 2, 3] clamped to a lower bound of 1 and an upper bound of 2 would return [1, 1, 2, 2].

Args:

​lower_bound (Self): Minimum of the range to clamp to.
​upper_bound (Self): Maximum of the range to clamp to.
Returns:

Self: A new SIMD vector containing x clamped to be within lower_bound and upper_bound.

fma
fma[flag: FastMathFlag = FastMathFlag.CONTRACT](self, multiplier: Self, accumulator: Self) -> Self

Performs a fused multiply-add operation, i.e. self*multiplier + accumulator.

Parameters:

​flag (FastMathFlag): Fast-math optimization flags to apply (default: CONTRACT).
Args:

​multiplier (Self): The value to multiply.
​accumulator (Self): The value to accumulate.
Returns:

Self: A new vector whose element at position i is computed as self[i]*multiplier[i] + accumulator[i].

shuffle
shuffle[*mask: Int](self) -> Self

Shuffles (also called blend) the values of the current vector with the other value using the specified mask (permutation). The mask values must be within 2 * len(self).

Parameters:

​*mask (Int): The permutation to use in the shuffle.
Returns:

Self: A new vector with the same length as the mask where the value at position i is (self)[permutation[i]].

shuffle[*mask: Int](self, other: Self) -> Self

Shuffles (also called blend) the values of the current vector with the other value using the specified mask (permutation). The mask values must be within 2 * len(self).

Parameters:

​*mask (Int): The permutation to use in the shuffle.
Args:

​other (Self): The other vector to shuffle with.
Returns:

Self: A new vector with the same length as the mask where the value at position i is (self + other)[permutation[i]].

shuffle[mask: IndexList[size, element_type=element_type]](self) -> Self

Shuffles (also called blend) the values of the current vector with the other value using the specified mask (permutation). The mask values must be within 2 * len(self).

Parameters:

​mask (IndexList): The permutation to use in the shuffle.
Returns:

Self: A new vector with the same length as the mask where the value at position i is (self)[permutation[i]].

shuffle[mask: IndexList[size, element_type=element_type]](self, other: Self) -> Self

Shuffles (also called blend) the values of the current vector with the other value using the specified mask (permutation). The mask values must be within 2 * len(self).

Parameters:

​mask (IndexList): The permutation to use in the shuffle.
Args:

​other (Self): The other vector to shuffle with.
Returns:

Self: A new vector with the same length as the mask where the value at position i is (self + other)[permutation[i]].

slice
slice[output_width: Int, /, *, offset: Int = 0](self) -> SIMD[dtype, output_width]

Returns a slice of the vector of the specified width with the given offset.

Constraints:

output_width + offset must not exceed the size of this SIMD vector.

Parameters:

​output_width (Int): The output SIMD vector size.
​offset (Int): The given offset for the slice.
Returns:

SIMD: A new vector whose elements map to self[offset:offset+output_width].

insert
insert[*, offset: Int = 0](self, value: SIMD[dtype, size]) -> Self

Returns a new vector where the elements between offset and offset + input_width have been replaced with the elements in value.

Parameters:

​offset (Int): The offset to insert at. This must be a multiple of value's size.
Args:

​value (SIMD): The value to be inserted.
Returns:

Self: A new vector whose elements at self[offset:offset+input_width] contain the values of value.

join
join(self, other: Self) -> SIMD[dtype, (2 * size)]

Concatenates the two vectors together.

Args:

​other (Self): The other SIMD vector.
Returns:

SIMD: A new vector self_0, self_1, ..., self_n, other_0, ..., other_n.

interleave
interleave(self, other: Self) -> SIMD[dtype, (2 * size)]

Constructs a vector by interleaving two input vectors.

Args:

​other (Self): The other SIMD vector.
Returns:

SIMD: A new vector self_0, other_0, ..., self_n, other_n.

split
split(self) -> Tuple[SIMD[dtype, (size // 2)], SIMD[dtype, (size // 2)]]

Splits the SIMD vector into 2 subvectors.

Returns:

Tuple: A new vector self_0:N/2, self_N/2:N.

deinterleave
deinterleave(self) -> Tuple[SIMD[dtype, (size // 2)], SIMD[dtype, (size // 2)]]

Constructs two vectors by deinterleaving the even and odd lanes of the vector.

Constraints:

The vector size must be greater than 1.

Returns:

Tuple: Two vectors the first of the form self_0, self_2, ..., self_{n-2} and the other being self_1, self_3, ..., self_{n-1}.

reduce
reduce[func: fn[width: Int](SIMD[dtype, width], SIMD[dtype, width]) -> SIMD[dtype, width], size_out: Int = 1](self) -> SIMD[dtype, size_out]

Reduces the vector using a provided reduce operator.

Constraints:

size_out must not exceed width of the vector.

Parameters:

​func (fn[width: Int](SIMD[dtype, width], SIMD[dtype, width]) -> SIMD[dtype, width]): The reduce function to apply to elements in this SIMD.
​size_out (Int): The width of the reduction.
Returns:

SIMD: A new scalar which is the reduction of all vector elements.

reduce[func: fn[width: Int](SIMD[dtype, width], SIMD[dtype, width]) capturing -> SIMD[dtype, width], size_out: Int = 1](self) -> SIMD[dtype, size_out]

Reduces the vector using a provided reduce operator.

Constraints:

size_out must not exceed width of the vector.

Parameters:

​func (fn[width: Int](SIMD[dtype, width], SIMD[dtype, width]) capturing -> SIMD[dtype, width]): The reduce function to apply to elements in this SIMD.
​size_out (Int): The width of the reduction.
Returns:

SIMD: A new scalar which is the reduction of all vector elements.

reduce_max
reduce_max[size_out: Int = 1](self) -> SIMD[dtype, size_out]

Reduces the vector using the max operator.

Constraints:

size_out must not exceed width of the vector. The element type of the vector must be integer or FP.

Parameters:

​size_out (Int): The width of the reduction.
Returns:

SIMD: The maximum element of the vector.

reduce_min
reduce_min[size_out: Int = 1](self) -> SIMD[dtype, size_out]

Reduces the vector using the min operator.

Constraints:

size_out must not exceed width of the vector. The element type of the vector must be integer or FP.

Parameters:

​size_out (Int): The width of the reduction.
Returns:

SIMD: The minimum element of the vector.

reduce_add
reduce_add[size_out: Int = 1](self) -> SIMD[dtype, size_out]

Reduces the vector using the add operator.

Constraints:

size_out must not exceed width of the vector.

Parameters:

​size_out (Int): The width of the reduction.
Returns:

SIMD: The sum of all vector elements.

reduce_mul
reduce_mul[size_out: Int = 1](self) -> SIMD[dtype, size_out]

Reduces the vector using the mul operator.

Constraints:

size_out must not exceed width of the vector. The element type of the vector must be integer or FP.

Parameters:

​size_out (Int): The width of the reduction.
Returns:

SIMD: The product of all vector elements.

reduce_and
reduce_and[size_out: Int = 1](self) -> SIMD[dtype, size_out]

Reduces the vector using the bitwise & operator.

Constraints:

size_out must not exceed width of the vector. The element type of the vector must be integer or boolean.

Parameters:

​size_out (Int): The width of the reduction.
Returns:

SIMD: The reduced vector.

reduce_or
reduce_or[size_out: Int = 1](self) -> SIMD[dtype, size_out]

Reduces the vector using the bitwise | operator.

Constraints:

size_out must not exceed width of the vector. The element type of the vector must be integer or boolean.

Parameters:

​size_out (Int): The width of the reduction.
Returns:

SIMD: The reduced vector.

reduce_bit_count
reduce_bit_count(self) -> Int

Returns the total number of bits set in the SIMD vector.

Constraints:

Must be either an integral or a boolean type.

Returns:

Int: Count of set bits across all elements of the vector.

select
select[_dtype: DType](self, true_case: SIMD[_dtype, size], false_case: SIMD[_dtype, size]) -> SIMD[_dtype, size]

Selects the values of the true_case or the false_case based on the current boolean values of the SIMD vector.

Constraints:

The element type of the vector must be boolean.

Parameters:

​_dtype (DType): The element type of the input and output SIMD vectors.
Args:

​true_case (SIMD): The values selected if the positional value is True.
​false_case (SIMD): The values selected if the positional value is False.
Returns:

SIMD: A new vector of the form [true_case[i] if elem else false_case[i] for i, elem in enumerate(self)].

rotate_left
rotate_left[shift: Int](self) -> Self

Shifts the elements of a SIMD vector to the left by shift elements (with wrap-around).

Constraints:

-size <= shift < size

Parameters:

​shift (Int): The number of positions by which to rotate the elements of SIMD vector to the left (with wrap-around).
Returns:

Self: The SIMD vector rotated to the left by shift elements (with wrap-around).

rotate_right
rotate_right[shift: Int](self) -> Self

Shifts the elements of a SIMD vector to the right by shift elements (with wrap-around).

Constraints:

-size < shift <= size

Parameters:

​shift (Int): The number of positions by which to rotate the elements of SIMD vector to the right (with wrap-around).
Returns:

Self: The SIMD vector rotated to the right by shift elements (with wrap-around).

shift_left
shift_left[shift: Int](self) -> Self

Shifts the elements of a SIMD vector to the left by shift elements (no wrap-around, fill with zero).

Constraints:

0 <= shift <= size

Parameters:

​shift (Int): The number of positions by which to rotate the elements of SIMD vector to the left (no wrap-around, fill with zero).
Returns:

Self: The SIMD vector rotated to the left by shift elements (no wrap-around, fill with zero).

shift_right
shift_right[shift: Int](self) -> Self

Shifts the elements of a SIMD vector to the right by shift elements (no wrap-around, fill with zero).

Constraints:

0 <= shift <= size

Parameters:

​shift (Int): The number of positions by which to rotate the elements of SIMD vector to the right (no wrap-around, fill with zero).
Returns:

Self: The SIMD vector rotated to the right by shift elements (no wrap-around, fill with zero).

reversed
reversed(self) -> Self

Reverses the SIMD vector by indexes.

Examples:

print(SIMD[DType.uint8, 4](1, 2, 3, 4).reversed()) # [4, 3, 2, 1]

Returns:

Self: The by index reversed vector.



# simd

<section class='mojo-docs'>

Implements SIMD primitives and abstractions.

Provides high-performance SIMD primitives and abstractions for
vectorized computation in Mojo. It enables efficient data-parallel operations
by leveraging hardware vector processing units across different architectures.

Key Features:

1. Architecture-agnostic SIMD abstractions with automatic hardware detection
2. Optimized vector operations for common numerical computations
3. Explicit control over vectorization strategies and memory layouts
4. Zero-cost abstractions that compile to efficient machine code
5. Support for different vector widths and element types

Primary Components:

* Vector types: Strongly-typed vector containers with element-wise operations
* SIMD intrinsics: Low-level access to hardware SIMD instructions
* Vectorized algorithms: Common algorithms optimized for SIMD execution
* Memory utilities: Aligned memory allocation and vector load/store operations

Performance Considerations:

* Vector width selection should match target hardware capabilities
* Memory alignment affects load/store performance
* Data layout transformations may be necessary for optimal vectorization

Integration:
This module is designed to work seamlessly with other Mojo numerical computing
components, including tensor operations, linear algebra routines, and
domain-specific libraries for machine learning and scientific computing.

## `comptime` values

### `BFloat16`

`comptime BFloat16 = BFloat16`

Represents a 16-bit brain floating point value.

### `Byte`

`comptime Byte = UInt8`

Represents a byte (backed by an 8-bit unsigned integer).

### `Float16`

`comptime Float16 = Float16`

Represents a 16-bit floating point value.

### `Float32`

`comptime Float32 = Float32`

Represents a 32-bit floating point value.

### `Float4_e2m1fn`

`comptime Float4_e2m1fn = Float4_e2m1fn`

Represents a 4-bit `e2m1` floating point format.

This type is encoded as `s.ee.m` and defined by the
[Open Compute MX Format Specification](https://www.opencompute.org/documents/ocp-microscaling-formats-mx-v1-0-spec-final-pdf):

* (s)ign: 1 bit
* (e)xponent: 2 bits
* (m)antissa: 1 bits
* exponent\_bias: 1

### `Float64`

`comptime Float64 = Float64`

Represents a 64-bit floating point value.

### `Float8_e4m3fn`

`comptime Float8_e4m3fn = Float8_e4m3fn`

Represents the E4M3 floating point format defined in the [OFP8 standard](https://www.opencompute.org/documents/ocp-8-bit-floating-point-specification-ofp8-revision-1-0-2023-12-01-pdf-1).

This type is named differently across libraries and vendors, for example:

* Mojo, PyTorch, JAX, and LLVM refer to it as `e4m3fn`.
* OCP, NVIDIA CUDA, and AMD ROCm refer to it as `e4m3`.

In these contexts, they are all referring to the same finite type specified
in the OFP8 standard above, encoded as `seeeemmm`:

* (s)ign: 1 bit
* (e)xponent: 4 bits
* (m)antissa: 3 bits
* exponent bias: 7
* nan: 01111111, 11111111
* -0: 10000000
* fn: finite (no inf or -inf encodings)

### `Float8_e4m3fnuz`

`comptime Float8_e4m3fnuz = Float8_e4m3fnuz`

Represents an 8-bit e4m3fnuz floating point format.

This type is encoded as `seeeemmm`:

* (s)ign: 1 bit
* (e)xponent: 4 bits
* (m)antissa: 3 bits
* exponent bias: 8
* nan: 10000000
* fn: finite (no inf or -inf encodings)
* uz: unsigned zero (no -0 encoding)

### `Float8_e5m2`

`comptime Float8_e5m2 = Float8_e5m2`

Represents the 8-bit E5M2 floating point format.

This type is from the [OFP8
standard](https://www.opencompute.org/documents/ocp-8-bit-floating-point-specification-ofp8-revision-1-0-2023-12-01-pdf-1),
encoded as `seeeeemm`:

* (s)ign: 1 bit
* (e)xponent: 5 bits
* (m)antissa: 2 bits
* exponent bias: 15
* nan: {0,1}11111{01,10,11}
* inf: 01111100
* -inf: 11111100
* -0: 10000000

### `Float8_e5m2fnuz`

`comptime Float8_e5m2fnuz = Float8_e5m2fnuz`

Represents an 8-bit floating point format.

This type is encoded as `seeeeemm`:

* (s)ign: 1 bit
* (e)xponent: 5 bits
* (m)antissa: 2 bits
* exponent bias: 16
* nan: 10000000
* fn: finite (no inf or -inf encodings)
* uz: unsigned zero (no -0 encoding)

### `Float8_e8m0fnu`

`comptime Float8_e8m0fnu = Float8_e8m0fnu`

Represents the 8-bit E8M0FNU floating point format.

This type is defined in the [OCP MX
spec](https://www.opencompute.org/documents/ocp-microscaling-formats-mx-v1-0-spec-final-pdf),
encoded as `eeeeeeee`:

* (e)xponent: 8 bits
* (m)antissa: 0 bits
* exponent bias: 127
* nan: 11111111
* fn: finite (no inf or -inf encodings)
* u: unsigned (no sign bit or zero value)

### `Int128`

`comptime Int128 = Int128`

Represents a 128-bit signed scalar integer.

### `Int16`

`comptime Int16 = Int16`

Represents a 16-bit signed scalar integer.

### `Int256`

`comptime Int256 = Int256`

Represents a 256-bit signed scalar integer.

### `Int32`

`comptime Int32 = Int32`

Represents a 32-bit signed scalar integer.

### `Int64`

`comptime Int64 = Int64`

Represents a 64-bit signed scalar integer.

### `Int8`

`comptime Int8 = Int8`

Represents an 8-bit signed scalar integer.

### `Scalar`

`comptime Scalar = Scalar[?]`

Represents a scalar dtype.

### `U8x16`

`comptime U8x16 = SIMD[DType.uint8, 16]`

A 16-element vector of unsigned 8-bit integers.

### `UInt`

`comptime UInt = UInt`

Represents an unsigned integer of platform-dependent bit-width.

### `UInt128`

`comptime UInt128 = UInt128`

Represents a 128-bit unsigned scalar integer.

### `UInt16`

`comptime UInt16 = UInt16`

Represents a 16-bit unsigned scalar integer.

### `UInt256`

`comptime UInt256 = UInt256`

Represents a 256-bit unsigned scalar integer.

### `UInt32`

`comptime UInt32 = UInt32`

Represents a 32-bit unsigned scalar integer.

### `UInt64`

`comptime UInt64 = UInt64`

Represents a 64-bit unsigned scalar integer.

### `UInt8`

`comptime UInt8 = UInt8`

Represents an 8-bit unsigned scalar integer.

## Structs

* [​`FastMathFlag`](./FastMathFlag): Flags for controlling fast-math optimizations in floating-point operations.
* [​`SIMD`](./SIMD): Represents a vector type that leverages hardware acceleration to process multiple data elements with a single operation.

</section>
