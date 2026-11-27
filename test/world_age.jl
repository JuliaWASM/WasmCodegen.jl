# A module has one world, the one its code was compiled in: a program that checks a build's
# validity (a CodeInstance's `min_world`/`max_world` against `Base.tls_world_age()`, as SynchJulia's
# executables do) finds what it would natively in that world, and `Base.invoke_in_world` in that
# world is a direct call (runtime/jlapi.jl); in another world it is an error, as natively when that
# world has no such method.

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
wa_other(x::Int) = Base.invoke_in_world(UInt(1), wa_callee, x)::Int

@testset "world age: CodeInstance worlds and invoke_in_world" begin
    @test wa_valid() && !wa_stale_valid() && wa_max_finite()
    @wtest wa_valid()
    @wtest wa_stale_valid()
    @wtest wa_max_finite()
    @wtest wa_call(3)
    @wtest wa_call_tls(3)
    @wtest wa_other(3)  # (natively a MethodError: world 1 has no `wa_callee`; the module traps)
end
