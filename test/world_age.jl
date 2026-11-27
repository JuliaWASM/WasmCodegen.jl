# A module has one world, the one its code was compiled in: a program that checks a build's
# validity (a CodeInstance's `min_world`/`max_world` against `Base.tls_world_age()`, as SynchJulia's
# executables do) finds what it would natively in that world, and `Base.invoke_in_world` in that
# world, or in a later one (natively the latest), is a direct call (runtime/jlapi.jl); in an earlier
# world it is an error, as natively when that world has no such method.

wa_callee(x::Int) = x + 1
wa_callee(0)
const WA_CI = Ref{Core.CodeInstance}(WasmCodegen.entry_instance(wa_callee, (Int,)).cache)

wa_dep(x::Int) = x + 2
@noinline wa_stale(x::Int) = wa_dep(x) * 2
wa_stale(0)
const WA_STALE_CI = Ref{Core.CodeInstance}(WasmCodegen.entry_instance(wa_stale, (Int,)).cache)
wa_dep(x::Int) = x + 3  # (`wa_stale`'s code above is no longer valid in later worlds: its callee changed)

function wa_valid(r::Base.RefValue{Core.CodeInstance})
    w = Base.tls_world_age()
    ci = r[]
    return (@atomic ci.min_world) <= w <= (@atomic ci.max_world)
end
wa_valid() = wa_valid(WA_CI)
wa_stale_valid() = wa_valid(WA_STALE_CI)
wa_max_finite() = (@atomic WA_STALE_CI[].max_world) < typemax(UInt)

wa_call(x::Int) = Base.invoke_in_world(Base.get_world_counter(), wa_callee, x)::Int
wa_call_tls(x::Int) = Base.invoke_in_world(Base.tls_world_age(), wa_callee, x)::Int * 2
wa_call_later(x::Int) = Base.invoke_in_world(typemax(UInt), wa_callee, x)::Int
wa_other(x::Int) = Base.invoke_in_world(UInt(1), wa_callee, x)::Int
wa_kw(x::Int; a::Int=1) = x + a
wa_call_kw(x::Int) = Base.invoke_in_world(Base.get_world_counter(), wa_kw, x; a=5)::Int
wa_splat(t::Tuple) = Base.invoke_in_world(t...)::Int
wa_call_splat(x::Int) = wa_splat((Base.get_world_counter(), wa_callee, x))

# the builtin's own argument checks, and the builtin as a value
function wa_error(f, args...)
    try
        f(args...)
    catch e
        return e isa TypeError ? 1 : e isa ArgumentError ? 2 : e isa MethodError ? 3 : 4
    end
    return 0
end
wa_world_type(x::Int) = wa_error(Base.invoke_in_world, x, wa_callee, x)
wa_too_few() = wa_error(Base.invoke_in_world, Base.get_world_counter())
wa_not_callable(x::Int) = wa_error(Base.invoke_in_world, Base.get_world_counter(), x, x)
wa_pick(::typeof(Core.invoke_in_world)) = 1
wa_pick(@nospecialize(x)) = 2
wa_builtin() = (Base.invoke_in_world isa Core.Builtin, wa_pick(Base.invoke_in_world), wa_pick(Base.inferencebarrier(Base.invoke_in_world)))

@testset "world age: CodeInstance worlds and invoke_in_world" begin
    @test wa_valid() && !wa_stale_valid() && wa_max_finite()
    @wtest wa_valid()
    @wtest wa_stale_valid()
    @wtest wa_max_finite()
    @wtest wa_call(3)
    @wtest wa_call_tls(3)
    @wtest wa_call_later(3)
    @wtest wa_call_kw(3)
    @wtest wa_call_splat(3)
    @wtest wa_other(3)  # (natively a MethodError: world 1 has no `wa_callee`; the module's error is its own)
    @test wa_world_type(3) == 1 && wa_too_few() == 2 && wa_not_callable(3) == 3
    @wtest wa_world_type(3)
    @wtest wa_too_few()
    @wtest wa_not_callable(3)
    @wtest wa_builtin()
end
