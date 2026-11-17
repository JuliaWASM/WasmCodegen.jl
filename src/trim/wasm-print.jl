# Printing with many arguments: a method of a function with varargs is specialized on at most
# `max_args` arguments (juliac's patch raises print's, println's and print_to_string's to 10),
# beyond which the rest is a `Vararg{Any}`, elements of type `Any`: calls juliac's verifier
# cannot resolve (`string(...)` of 14 pieces). 32 for the printing functions, and their
# methods defined again as Base's (the definitions of the Julia installation's Base sources):
# so that what was inferred before the session, under the lower limits, is inferred again.
# Applied with juliac's trim patches (see `patches.jl`).

let file = joinpath(Sys.BINDIR, Base.DATAROOTDIR, "julia", "base", "strings", "io.jl")
    for f in (print, println, Base.print_to_string, string, Base.string_with_env)
        setfield!(typeof(f).name, :max_args, Int32(32), :monotonic)
    end
    # (the definitions of `print(io::IO, xs...)`, `println(io::IO, xs...)`,
    # `print_to_string(xs...)` and `string(xs...)`, by their signatures)
    sigs = (:(print(io::IO, xs...)), :(println(io::IO, xs...)), :(print_to_string(xs...)), :(string(xs...)))
    found = Any[]
    for ex in Meta.parseall(read(file, String); filename=file).args
        # (without its docstring)
        Meta.isexpr(ex, :macrocall) && ex.args[1] == GlobalRef(Core, Symbol("@doc")) && (ex = ex.args[end])
        (Meta.isexpr(ex, :function) || Meta.isexpr(ex, :(=))) && ex.args[1] in sigs && push!(found, ex)
    end
    length(found) == length(sigs) || error("wasm-print.jl: not every printing method found in $file")
    # (the sources are those of the Base that is loaded: each definition is a method of its
    # function at its line)
    for def in found
        line = (def.args[2].args[1]::LineNumberNode).line
        f = getfield(Base, def.args[1].args[1])
        ms = methods(f)
        # (a system image stripped of its metadata has no lines to compare)
        any(m -> m.line == 0, ms) ||
            any(m -> m.line == line && endswith(String(m.file), "io.jl"), ms) ||
            error("wasm-print.jl: `$(def.args[1])` at $file:$line is not a method of the loaded Base " *
                  "(the sources of the Julia installation differ from its system image)")
    end
    foreach(def -> Core.eval(Base, def), found)
end
