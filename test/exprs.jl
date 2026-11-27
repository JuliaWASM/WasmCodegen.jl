# Building an `Expr` (`Core._expr`): as natively, its errors included. Splatting into `Expr` is
# a call of a function that is not a builtin through `Core._apply_iterate`, which juliac's
# verifier reports ("unresolved call to function"): so is it here.

module ExprPrograms
built(n::Int) = (e = Expr(:call, :f, n, 2n); 1000 * (e.head === :call) + 100 * length(e.args) + e.args[2]::Int + e.args[3]::Int)
# no arguments, and an argument of a type of the program's
struct Item
    k::Int
end
bare(n::Int) = (e = Expr(:block); length(e.args) + n)
held(n::Int) = (Expr(:quote, Item(n)).args[1]::Item).k
const HEAD = Ref{Any}(1)
bad_head(n::Int) = try Core._expr(HEAD[], n); 0 catch e; e isa TypeError && e.func === :Expr && e.expected === Symbol ? 1 : 2 end
no_head(n::Int) = try Core._expr(); 0 catch e; e isa ArgumentError ? 1 : 2 end
splat(n::Int) = Expr(:block, Any[n, n + 1]...).args[1]::Int
end

@testset "Expr construction" begin
    P = ExprPrograms
    @wtest P.built(3)
    @wtest P.bare(3)
    @wtest P.held(3)
    @wtest P.bad_head(3)
    @wtest P.no_head(3)
    @test_throws WasmCodegen.UnsupportedConstructs WasmCodegen.compile(P.splat, (Int,); config = WasmCodegen.Config(verify = :off))
end

# The parser at run time (`Meta.parse`, `Meta.parseall`, `runtime/parse.jl`): JuliaSyntax's steps,
# called directly instead of `Core._parse`'s hook. JuliaSyntax's `Expr` builder still splats into
# `Expr` and reads fields of `Any` values (reported with `trim = :safe`), so these modules are
# compiled with `trim = :unsafe`, where those constructs are traps: the inputs that reach none of
# them parse as natively, parse errors included.
module ParsePrograms
    const STRS = ["1 + 2", "f(x) = x^2", "a.b[1]", "x = 1\ny = 2", "[1, 2.5, :s]", "1.0.2", "f(", "  ",
                  "for i in 1:3; s += i; end"]
    shape(@nospecialize(ex)) = ex isa Expr ? (hash(string(ex.head)), length(ex.args)) :
                               ex isa Int ? (UInt(0), -ex) : (UInt(1), 0)
    parse_shape(i::Int) = shape(Meta.parse(STRS[i]; raise = false))
    parse_error(i::Int) = (try Meta.parse(STRS[i]); 0 catch e; e isa Meta.ParseError ? 1 : 2 end)
    parseall_length(i::Int) = length(Meta.parseall(STRS[i]).args)
end
@testset "Meta.parse at run time (trim = :unsafe)" begin
    P = ParsePrograms
    cfg = WasmCodegen.Config(trim = :unsafe)
    c = WasmCodegen.compile(P.parse_shape, (Int,); config = cfg)
    # (Julia 1.12's JuliaSyntax builds the `Expr`s of these statements, 1 to 5, through one of the
    # constructs that are traps here: broken there; errors and whitespace parse as natively)
    ok = VERSION >= v"1.13-"
    for i in 1:8
        @test wasm_run(c, "parse_shape", i; rettype = Tuple{UInt,Int}) == P.parse_shape(i) broken = !ok && i <= 5
    end
    # (a `for` loop: JuliaSyntax splats its iteration spec into an `Expr`)
    @test_broken wasm_run(c, "parse_shape", 9; rettype = Tuple{UInt,Int}) == P.parse_shape(9)
    e = WasmCodegen.compile(P.parse_error, (Int,); config = cfg)
    for i in (1, 6, 7)
        @test wasm_run(e, "parse_error", i; rettype = Int) == P.parse_error(i) broken = !ok && i == 1
    end
    # (a toplevel block: the same splats)
    a = WasmCodegen.compile(P.parseall_length, (Int,); config = cfg)
    @test_broken wasm_run(a, "parseall_length", 1; rettype = Int) == P.parseall_length(1)
end
