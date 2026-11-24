# Reflection the module answers at run time without the C runtime: modules (parentmodule,
# PkgId, moduleloc, show), fieldtype of a field known only at run time, the
# parser's operator tables (show of Symbols and Modules).

module ReflectionRT

using Test
import Random, TOML
using ..Main: wcompile, wasm_run, @wtest, WasmCodegen

module Outer
module Inner
struct T; x::Int; end
end
end

const MODS = Module[Base, Core, Main, Random, TOML, Outer, Outer.Inner, Base.Iterators, Base.Filesystem, Random.DSFMT]
mod_at(i::Int) = MODS[i]
mod_parent(i::Int) = something(findfirst(m -> m === parentmodule(mod_at(i)), MODS), 0)
function mod_query(i::Int)
    m = mod_at(i)
    p = parentmodule(m)
    id = Base.PkgId(m)
    u = id.uuid === nothing ? UInt128(0) : UInt128(id.uuid)
    loc = Base.moduleloc(m)
    return (something(findfirst(x -> x === p, MODS), 0), u, hash(id.name), loc.line,
            hash(String(loc.file)), hash(sprint(show, m)), hash(string(nameof(m))))
end
# `jl_module_getloc` with no line pointer (chosen at run time): only the file
mod_file(i::Int, null::Bool) = (line = Ref{Int32}(0);
    f = GC.@preserve line ccall(:jl_module_getloc, Ref{Symbol}, (Any, Ptr{Int32}), mod_at(i),
                                null ? Ptr{Int32}(C_NULL) : Base.unsafe_convert(Ptr{Int32}, line));
    (hash(String(f)), line[]))

# the operator ccalls in Wasm, of names chosen at run time
const OPNAMES = ["+", "+₁", ".+", "->", "&&", "a", "", "′+", "in", "√", "..."]
function op_queries(i::Int)
    s = OPNAMES[i]
    GC.@preserve s begin
        p = Base.unsafe_convert(Cstring, s)
        (ccall(:jl_is_operator, Cint, (Cstring,), p), ccall(:jl_is_unary_operator, Cint, (Cstring,), p),
         ccall(:jl_is_unary_and_binary_operator, Cint, (Cstring,), p),
         ccall(:jl_is_syntactic_operator, Cint, (Cstring,), p), ccall(:jl_operator_precedence, Cint, (Cstring,), p),
         ccall(:jl_op_suffix_char, Cint, (UInt32,), UInt32(i == 2 ? '₁' : i == 8 ? '′' : 'x')))
    end
end

# fieldtype and setproperty! with a field known only at run time
mutable struct Mixed; a::Int; b::String; c::Union{Nothing,Float64}; end
fieldname_at(k::Int) = (:a, :b, :c, :zz)[k]
ft(k::Int) = (T = fieldtype(Mixed, fieldname_at(k)); (T === Int, T === String, T === Union{Nothing,Float64}))
ft_index(k::Int) = (T = fieldtype(Mixed, k); (T === Int, T === String))
# (as Base's setproperty! of a Ref{Bool} to nothing: the conversion to the field's type fails)
function setprop(k::Int)
    r = Ref(true)
    try
        setproperty!(r, (:x, :zz)[k], nothing)
        return (r[], 0)
    catch e
        return (r[], e isa MethodError ? 1 : e isa FieldError ? 2 : 3)
    end
end
# setfield! of a field known only at run time: of a name or an index; a value its type does not
# admit a TypeError, a name of none a FieldError, an index out of range a BoundsError, a const
# field an error, as natively
mutable struct Point3; x::Float64; y::Float64; n::Int; const id::Int; end
const KEYS = [:x, :y, :n, :id, :zz]
const NAMES = [:x, :value]
code(e) = e isa TypeError ? (e.func === :setfield! ? 1 : 2) : e isa FieldError ? 3 :
          e isa BoundsError ? 4 : e isa InexactError ? 5 : e isa ErrorException ? 6 : 7
fields(p::Point3) = (p.x, p.y, p.n, p.id)
setkey(i::Int, v::Float64) = (p = Point3(1.0, 2.0, 3, 4);
    try setproperty!(p, KEYS[i], v); (fields(p), 0) catch e; (fields(p), code(e)) end)
setkey_any(i::Int, k::Int) = (p = Point3(1.0, 2.0, 3, 4); v = Any[5.0, 6, "s"][k];
    try setfield!(p, KEYS[i], v); (fields(p), 0) catch e; (fields(p), code(e)) end)
setindex_field(i::Int, v::Int) = (p = Point3(1.0, 2.0, 3, 4);
    try setfield!(p, i, v); (fields(p), 0) catch e; (fields(p), code(e)) end)
# (with an ordering: not atomic, as the fields)
setkey_order(i::Int, v::Float64) = (p = Point3(1.0, 2.0, 3, 4);
    try setfield!(p, KEYS[i], v, :not_atomic); (fields(p), 0) catch e; (fields(p), code(e)) end)
# (of a Ref, as Makie's ComputePipeline: `setproperty!(::RefValue, name, v)`)
setref(k::Int, v::Float64) = (r = Ref(0.0);
    try setproperty!(r, NAMES[k], v); (r[], 0) catch e; (r[], code(e)) end)
# (an index of a type known only at run time: an Int, a name, or neither, a TypeError)
const INDICES = Any[1, :x, :y, 2, 1.5, Int32(1)]
setref_any(k::Int) = (r = Ref(0);
    try setfield!(r, INDICES[k], 7); (r[], 0) catch e; (r[], code(e)) end)
setref_ints(b::Bool) = (r = Ref(0);
    try setfield!(r, b ? 1 : Int32(1), 7); (r[], 0) catch e; (r[], code(e)) end)
getref_any(k::Int) = (r = Ref(5); i = INDICES[k]; i isa Union{Int,Symbol,Int32} || return -9;
    try getfield(r, i) catch e; -code(e) end)
# an ordering: a ConcurrencyViolationError where it is none of a store, or its atomicity is
# not the field's; the errors in the builtin's order for a field known at run time (a const
# field, the ordering, the value's type), in compiled code's for one known (the value's type,
# the ordering, a const field); too many arguments an ArgumentError
mutable struct Counters; n::Int; @atomic a::Int; const c::Int; end
const ORDERS = [:not_atomic, :release, :acquire, :none, :sequentially_consistent, :acquire_release]
const COUNTER_KEYS = [:n, :a, :c]
const COUNTS = Any[7, "s"]
order_code(e) = e isa ConcurrencyViolationError ? 8 : e isa ArgumentError ? 9 : code(e)
counts(s::Counters) = (s.n, @atomic(s.a), s.c)
set_ordered(i::Int, o::Int, k::Int) = (s = Counters(0, 0, 0);
    try setfield!(s, COUNTER_KEYS[i], COUNTS[k], ORDERS[o]); (counts(s), 0) catch e; (counts(s), order_code(e)) end)
set_unordered(i::Int, k::Int) = (s = Counters(0, 0, 0);
    try setfield!(s, i, COUNTS[k]); (counts(s), 0) catch e; (counts(s), order_code(e)) end)
set_known(o::Int, k::Int) = (s = Counters(0, 0, 0); v = COUNTS[k];
    try
        o == 1 ? setfield!(s, :a, v) : o == 2 ? setfield!(s, :n, v, :release) : o == 3 ? setfield!(s, :a, v, :acquire) :
        o == 4 ? setfield!(s, :a, v, :release) : o == 5 ? setfield!(s, :c, v, :release) : o == 6 ? setfield!(s, :c, v, :none) :
        o == 7 ? setfield!(s, :n, "s", :release) : setfield!(s, :c, v)
        (counts(s), 0)
    catch e
        (counts(s), order_code(e))
    end)
# (a field known and an ordering that is not: the builtin's order; an ordering of a type known
# only at run time, a TypeError where it is no Symbol, before any other error)
const ANY_ORDERS = Any[:not_atomic, :release, 1]
set_known_field(i::Int, o::Int, k::Int) = (s = Counters(0, 0, 0); v = COUNTS[k];
    try
        i == 1 ? setfield!(s, :n, v, ORDERS[o]) : i == 2 ? setfield!(s, :a, v, ORDERS[o]) :
        i == 3 ? setfield!(s, :c, v, ORDERS[o]) : setfield!(s, :n, v, ANY_ORDERS[min(o, 3)])
        (counts(s), 0)
    catch e
        (counts(s), order_code(e))
    end)
set_acquire_release(v::Int) = (s = Counters(0, 0, 0);
    try setfield!(s, :a, v, :acquire_release); (counts(s), 0) catch e; (counts(s), order_code(e)) end)
# (an index that is no field's, known at compile time: a BoundsError at run time)
set_out_of_bounds(b::Bool) = (r = Ref(0);
    try b ? setfield!(r, 2, 7) : setfield!(r, 0, "s", :release); (r[], 0) catch e; (r[], order_code(e)) end)
# of an immutable value: the error of a field and an ordering known comes after those of the
# value's type and of the ordering, as in the code Julia compiles; before them otherwise
struct Fixed; x::Int; end
set_fixed(o::Int, k::Int) = (s = Fixed(1); v = COUNTS[k];
    try
        o == 1 ? setfield!(s, :x, v) : o == 2 ? setfield!(s, :x, v, :release) : o == 3 ? setfield!(s, :x, v, :none) :
        o == 4 ? setfield!(s, :y, v) : o == 5 ? setfield!(s, 2, v) : o == 6 ? setfield!(s, COUNTER_KEYS[k], v) :
        setfield!(s, :x, v, ORDERS[k + 1])
        0
    catch e
        e isa ErrorException ? 10 + ((e.msg::String) == "setfield!: immutable struct of type Fixed cannot be changed") : order_code(e)
    end)
# (an index of two types of integers, of a tuple that is an array)
const LONG = ntuple(identity, 65)
get_long(b::Bool) = try getfield(LONG, b ? 2 : Int32(2)) catch e; -code(e) end
get_long_name(b::Bool) = try getfield(LONG, b ? 2 : :missing) catch e; -code(e) end
# (a name or an index known not to be a field's, of a type whose fields cannot be set here)
struct Named; x::Int; end
set_missing(b::Bool) = try b ? setfield!(Named.name, :missing, 1) : setfield!(Named.name, 400, 1); 0 catch e; code(e) end
set_many(i::Int) = (r = Ref(0);
    try setfield!(r, i, 7, :not_atomic, :extra); (r[], 0) catch e; (r[], order_code(e)) end)

@testset "run-time reflection without the C runtime" begin
    @testset "modules" begin
        for i in 1:length(MODS)
            @wtest mod_parent(i)
            @wtest mod_query(i)
            @wtest mod_file(i, true)
            @wtest mod_file(i, false)
        end
    end
    @testset "fieldtype" begin
        for k in 1:4
            @wtest ft(k)
        end
        for k in 0:4
            @wtest ft_index(k)
        end
        @wtest setprop(1)
        @wtest setprop(2)
    end
    @testset "setfield! of a field known only at run time" begin
        for i in 1:length(KEYS)
            @wtest setkey(i, 7.5)
            @wtest setkey(i, 7.0)
            @wtest setkey_order(i, 7.5)
            for k in 1:3
                @wtest setkey_any(i, k)
            end
        end
        for i in 0:5
            @wtest setindex_field(i, 9)
        end
        for k in 1:2
            @wtest setref(k, 3.0)
        end
        for k in 1:length(INDICES)
            @wtest setref_any(k)
            @wtest getref_any(k)
        end
        @wtest setref_ints(true)
        @wtest setref_ints(false)
        for k in 1:2
            for i in 1:3
                @wtest set_unordered(i, k)
                for o in 1:length(ORDERS)
                    @wtest set_ordered(i, o, k)
                end
            end
            for o in 1:8
                @wtest set_known(o, k)
            end
        end
        @wtest set_many(1)
        for k in 1:2, o in 1:length(ORDERS), i in 1:4
            @wtest set_known_field(i, o, k)
        end
        @wtest set_acquire_release(7)
        @wtest set_out_of_bounds(true); @wtest set_out_of_bounds(false)
        for k in 1:2, o in 1:7
            @wtest set_fixed(o, k)
        end
        @wtest get_long(true); @wtest get_long(false)
        @wtest get_long_name(true); @wtest get_long_name(false)
        @wtest set_missing(true); @wtest set_missing(false)
    end
    @testset "operator ccalls in Wasm" begin
        for i in 1:length(OPNAMES)
            @wtest op_queries(i)
        end
    end
    @testset "operator tables against the native parser" begin
        O = WasmCodegen.Runtime.Operators
        natives = (s -> ccall(:jl_is_operator, Cint, (Cstring,), s), s -> ccall(:jl_is_unary_operator, Cint, (Cstring,), s),
                   s -> ccall(:jl_is_unary_and_binary_operator, Cint, (Cstring,), s),
                   s -> ccall(:jl_is_syntactic_operator, Cint, (Cstring,), s), s -> ccall(:jl_operator_precedence, Cint, (Cstring,), s))
        ports = (O.is_operator, O.is_unary_operator, O.is_unary_and_binary_operator, O.is_syntactic_operator, O.operator_precedence)
        cands = String[O.OPERATOR_LIST; first.(O.PRECEDENCE_LIST); ["", "a", "₁", "′+", "in", "isa", "x+", "++", "..", "....", "&&&"]]
        for op in O.OPERATOR_LIST, suf in ("₁", "′", "\u0301", "ᵀ", "x")
            push!(cands, op * suf)
        end
        for c in 0x21:0x7e
            push!(cands, string(Char(c)), "." * Char(c))
        end
        bad = 0
        for s in cands, (n, p) in zip(natives, ports)
            bad += GC.@preserve(s, p(Base.unsafe_convert(Cstring, s))) != n(s)
        end
        @test bad == 0
        @test all(c -> ccall(:jl_op_suffix_char, Cint, (UInt32,), c) == O.op_suffix_char(c),
                  UInt32[c for c in 0x0:0x10ffff if !(0xd800 <= c <= 0xdfff)])
    end
end

end
