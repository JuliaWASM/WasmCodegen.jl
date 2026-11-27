# The parser at run time: `Meta.parse`, `Meta.parseall` (`Meta._parse_string`) with JuliaSyntax
# (Base's parser), called directly. Natively they call `Core._parse`, which Base sets to
# JuliaSyntax's `core_parser_hook` when it starts: a closure that calls the hook in the world Base
# was loaded in (`invoke_in_world` of a fixed, older world: not the module's), and whose hook
# writes a debug log, falls back to the flisp parser (a C function) and logs an error when
# JuliaSyntax throws, and prints parse errors with StyledStrings. A module compiles the hook's
# steps: parse the stream, build the `Expr`; a parse error is the same `Expr(:error)` /
# `Expr(:incomplete)` with a `Meta.ParseError`, whose message has the place and the first
# diagnostic but not the highlighted source line native Julia prints.

module Parse

using ..Runtime: @wasm_method

const JS = Base.JuliaSyntax

@wasm_method function Base.Meta._parse_string(text::AbstractString, filename::AbstractString,
                                              lineno::Integer, index::Integer, options)
    if index < 1 || index > ncodeunits(text) + 1
        throw(BoundsError(text, index))
    end
    ex, offset = parse_code(String(text), String(filename), Int(lineno), Int(index) - 1, options::Symbol)
    return ex, offset + 1
end

"""
    parse_code(code, filename, lineno, offset, options) -> (ex, last_offset)

`JuliaSyntax.core_parser_hook`'s parse of `code` from the 0-based `offset`, with `options` one of
`:statement`, `:atom`, `:all`: the expression and the 0-based offset of the last byte consumed.
"""
function parse_code(code::String, filename::String, lineno::Int, offset::Int, options::Symbol)
    stream = JS.ParseStream(code, offset + 1)
    if options === :statement || options === :atom
        # (as the hook, after flisp: atoms consume leading trivia, statements leading and
        # trailing; at the end of the input, `nothing`)
        JS.bump_trivia(stream)
        JS.peek(stream) == JS.K"EndMarker" && return nothing, JS.last_byte(stream)
    end
    JS.parse!(stream; rule = options)
    if options === :statement
        JS.bump_trivia(stream; skip_newlines = false)
        JS.peek(stream) == JS.K"NewlineWs" && JS.bump(stream)
    end
    ex = JS.any_error(stream) ? error_expr(stream, code, filename, lineno, options) :
         JS.build_tree(Expr, stream; filename = filename, first_line = lineno)
    return ex, JS.last_byte(stream)
end

"The `Expr` of a parse with errors, as `core_parser_hook` makes it (see `error_message`)."
function error_expr(stream::JS.ParseStream, code::String, filename::String, lineno::Int, options::Symbol)
    pos_before_comments = JS.last_non_whitespace_byte(stream)
    @static if isdefined(JS, :first_tree_error)
        # (JuliaSyntax of Julia 1.13: the errors from the stream)
        errspec = JS.first_tree_error(stream)
        tag = JS._incomplete_tag(errspec, pos_before_comments)
    else
        # (of Julia 1.12: from a tree of the stream)
        tree = JS.build_tree(JS.SyntaxNode, stream; first_line = lineno, filename = filename)
        tag = JS._incomplete_tag(tree, pos_before_comments)
    end
    exc = JS.ParseError(stream; filename = filename, first_line = lineno, incomplete_tag = tag)
    error_ex = Expr(tag === :none ? :error : :incomplete, Base.Meta.ParseError(error_message(exc), exc))
    options === :all || return error_ex
    # (a toplevel error: the expressions before it, the line number, the error)
    @static if isdefined(JS, :first_tree_error)
        source = JS.SourceFile(stream; filename = filename, first_line = lineno)
        topex = JS.build_tree(Expr, stream, source)
        errline = JS.source_line(source, JS.first_byte(errspec.node))
    else
        topex = Expr(tree)
        _, errort = JS._first_error(tree)
        errline = JS.source_line(errort)
    end
    i = findfirst(JS._has_nested_error, topex.args)
    i === nothing && (i = length(topex.args) + 1)
    if i > 1 && topex.args[i-1] isa LineNumberNode
        i -= 1
    end
    resize!(topex.args, i - 1)
    push!(topex.args, LineNumberNode(errline, filename))
    push!(topex.args, error_ex)
    return topex
end

"""
The message of a `JuliaSyntax.ParseError`: its first error diagnostic and where it is, in the
words of the native message (`ParseError:\\n# Error @ file:line:column\\nmessage`), without the
source line it highlights.
"""
function error_message(exc::JS.ParseError)
    io = IOBuffer()
    print(io, "ParseError:")
    for d in exc.diagnostics
        d.level === :error || continue
        line, column = JS.source_location(exc.source, JS.first_byte(d))
        print(io, "\n# Error @ ", exc.source.filename === nothing ? "none" : exc.source.filename,
              ":", line, ":", column, "\n", d.message)
        break
    end
    return String(take!(io))
end

end
