#  Copyright 2017, Iain Dunning, Joey Huchette, Miles Lubin, and contributors
#  This Source Code Form is subject to the terms of the Mozilla Public
#  License, v. 2.0. If a copy of the MPL was not distributed with this
#  file, You can obtain one at http://mozilla.org/MPL/2.0/.

using Base.Meta

issum(s::Symbol) = (s == :sum) || (s == :∑) || (s == :Σ)
isprod(s::Symbol) = (s == :prod) || (s == :∏)

function error_curly(x)
    Base.error("The curly syntax (sum{},prod{},norm2{}) is no longer supported. Expression: $x.")
end

include("parseexpr.jl")

function buildrefsets(expr::Expr, cname)
    c = copy(expr)
    idxvars = Any[]
    idxsets = Any[]
    # Creating an indexed set of refs
    refcall = Expr(:ref, cname)
    if isexpr(c, :typed_vcat) || isexpr(c, :ref)
        shift!(c.args)
    end
    condition = :()
    if isexpr(c, :vcat) || isexpr(c, :typed_vcat)
        if isexpr(c.args[1], :parameters)
            @assert length(c.args[1].args) == 1
            condition = shift!(c.args).args[1]
        else
            condition = pop!(c.args)
        end
    end

    for s in c.args
        parse_done = false
        if isa(s, Expr)
            parse_done, idxvar, _idxset = tryParseIdxSet(s::Expr)
            if parse_done
                idxset = esc(_idxset)
            end
        end
        if !parse_done # No index variable specified
            idxvar = gensym()
            idxset = esc(s)
        end
        push!(idxvars, idxvar)
        push!(idxsets, idxset)
        push!(refcall.args, esc(idxvar))
    end
    return refcall, idxvars, idxsets, condition
end

buildrefsets(c, cname)  = (cname, Any[], Any[], :())

"""
    JuMP.buildrefsets(expr::Expr)

Helper function for macros to construct container objects. Takes an `Expr` that specifies the container, e.g. `:(x[i=1:3,[:red,:blue]],k=S; i+k <= 6)`, and returns:

    1. `refcall`: Expr to reference a particular element in the container, e.g. `:(x[i,red,s])`
    2. `idxvars`: Names for the index variables, e.g. `[:i, gensym(), :k]`
    3. `idxsets`: Sets used for indexing, e.g. `[1:3, [:red,:blue], S]`
    4. `condition`: Expr containing any conditional imposed on indexing, or `:()` if none is present
"""
buildrefsets(c) = buildrefsets(c, getname(c))

"""
    JuMP.getloopedcode(varname, code, condition, idxvars, idxsets, sym, requestedcontainer::Symbol; lowertri=false)

Helper function for macros to transform expression objects containing kernel code, index sets, conditionals, etc. to an expression that performs the desired loops that iterate over the kernel code. Arguments to the function are:

    1. `varname`: name and appropriate indexing sets (if any) for container that is assigned to in the kernel code, e.g. `:myvar` or `:(x[i=1:3,[:red,:blue]])`
    2. `code`: `Expr` containing kernel code
    3. `condition`: `Expr` that is evaluated immediately before kernel code in each iteration. If none, pass `:()`.
    4. `idxvars`: Names for the index variables for each loop, e.g. `[:i, gensym(), :k]`
    5. `idxsets`: Sets used to define iteration for each loop, e.g. `[1:3, [:red,:blue], S]`
    6. `sym`: A `Symbol`/`Expr` containing the element type of the container that is being iterated over, e.g. `:AffExpr` or `:VariableRef`
    7. `requestedcontainer`: Argument that is passed through to `generatedcontainer`. Either `:Auto`, `:Array`, `:JuMPArray`, or `:Dict`.
    8. `lowertri`: `Bool` keyword argument that is `true` if the iteration is over a cartesian array and should only iterate over the lower triangular entries, filling upper triangular entries with copies, e.g. `x[1,3] === x[3,1]`, and `false` otherwise.
"""
function getloopedcode(varname, code, condition, idxvars, idxsets, sym, requestedcontainer::Symbol; lowertri=false)

    # if we don't have indexing, just return to avoid allocating stuff
    if isempty(idxsets)
        return code
    end

    hascond = (condition != :())

    requestedcontainer in [:Auto, :Array, :JuMPArray, :Dict] || return :(error("Invalid container type $container. Must be Auto, Array, JuMPArray, or Dict."))

    if hascond
        if requestedcontainer == :Auto
            requestedcontainer = :Dict
        elseif requestedcontainer == :Array || requestedcontainer == :JuMPArray
            return :(error("Requested container type is incompatible with conditional indexing. Use :Dict or :Auto instead."))
        end
    end
    containercode, autoduplicatecheck = generatecontainer(sym, idxvars, idxsets, requestedcontainer)

    if lowertri
        @assert !hascond
        @assert length(idxvars)  == 2
        @assert !hasdependentsets(idxvars, idxsets)

        i, j = esc(idxvars[1]), esc(idxvars[2])
        expr = copy(code)
        vname = expr.args[1].args[1]
        tmp = gensym()
        expr.args[1] = tmp
        code = quote
            let
                $(localvar(i))
                $(localvar(j))
                for $i in $(idxsets[1]), $j in $(idxsets[2])
                    $i <= $j || continue
                    $expr
                    $vname[$i,$j] = $tmp
                    $vname[$j,$i] = $tmp
                end
            end
        end
    else
        if !autoduplicatecheck # we need to check for duplicate keys in the index set
            if length(idxvars) > 1
                keytuple = Expr(:tuple, esc.(idxvars)...)
            else
                keytuple = esc(idxvars[1])
            end
            code = quote
                if haskey($varname, $keytuple)
                    error(string("Repeated index ", $keytuple,". Index sets must have unique elements."))
                end
                $code
            end
        end
        if hascond
            code = quote
                $(esc(condition)) || continue
                $code
            end
        end
        for (idxvar, idxset) in zip(reverse(idxvars),reverse(idxsets))
            code = quote
                let
                    $(localvar(esc(idxvar)))
                    for $(esc(idxvar)) in $idxset
                        $code
                    end
                end
            end
        end
    end


    return quote
        $varname = $containercode
        $code
        nothing
    end
end

# TODO: Remove all localvar calls for Julia 0.7. The scope of loop variables
# has changed to match the behavior we enforce here.
 localvar(x::Symbol) = _localvar(x)
localvar(x::Expr) = Expr(:block, _localvar(x)...)
_localvar(x::Symbol) = :(local $(esc(x)))
function _localvar(x::Expr)
    @assert x.head in (:escape, :tuple)
    args = Any[]
    for t in x.args
        if isa(t, Symbol)
            push!(args, :(local $(esc(t))))
        else
            @assert isa(t, Expr)
            if t.head == :tuple
                append!(args, map(_localvar, t.args))
            else
                error("Internal error defining local variables in macros; please file an issue at https://github.com/JuliaOpt/JuMP.jl/issues/new")
            end
        end
    end
    args
end

"""
    extract_kwargs(args)

Process the arguments to a macro, separating out the keyword arguments.
Return a tuple of (flat_arguments, keyword arguments, and requestedcontainer),
where `requestedcontainer` is a symbol to be passed to `getloopedcode`.
"""
function extract_kwargs(args)
    kwargs = filter(x -> isexpr(x, :(=)) && x.args[1] != :container , collect(args))
    flat_args = filter(x->!isexpr(x, :(=)), collect(args))
    requestedcontainer = :Auto
    for kw in args
        if isexpr(kw, :(=)) && kw.args[1] == :container
            requestedcontainer = kw.args[2]
        end
    end
    return flat_args, kwargs, requestedcontainer
end

function addkwargs!(call, kwargs)
    for kw in kwargs
        @assert isexpr(kw, :(=))
        push!(call.args, esc(Expr(:kw, kw.args...)))
    end
end

getname(c::Symbol) = c
getname(c::Nothing) = ()
getname(c::AbstractString) = c
function getname(c::Expr)
    if c.head == :string
        return c
    else
        return c.args[1]
    end
end

validmodel(m::AbstractModel, name) = nothing
validmodel(m, name) = error("Expected $name to be a JuMP model, but it has type ", typeof(m))

function assert_validmodel(m, macrocode)
    # assumes m is already escaped
    quote
        validmodel($m, $(quot(m.args[1])))
        $macrocode
    end
end

function _check_vectorized(sense::Symbol)
    sense_str = string(sense)
    if sense_str[1] == '.'
        Symbol(sense_str[2:end]), true
    else
        sense, false
    end
end

# two-argument buildconstraint is used for one-sided constraints.
# Right-hand side is zero.
sense_to_set(_error::Function, ::Union{Val{:(<=)}, Val{:(≤)}}) = MOI.LessThan(0.0)
sense_to_set(_error::Function, ::Union{Val{:(>=)}, Val{:(≥)}}) = MOI.GreaterThan(0.0)
sense_to_set(_error::Function, ::Val{:(==)}) = MOI.EqualTo(0.0)
sense_to_set(_error::Function, ::Val{S}) where S = _error("Unrecognized sense $S")

function parse_one_operator_constraint(_error::Function, vectorized::Bool, ::Val{:in}, aff, set)
    newaff, parseaff = parseExprToplevel(aff, :q)
    parsecode = :(q = Val{false}(); $parseaff)
    if vectorized
        buildcall = :(buildconstraint.($_error, $newaff, $(esc(set))))
    else
        buildcall = :(buildconstraint($_error, $newaff, $(esc(set))))
    end
    parsecode, buildcall
end

function parse_one_operator_constraint(_error::Function, vectorized::Bool, sense::Val, lhs, rhs)
    # Simple comparison - move everything to the LHS
    aff = :($lhs - $rhs)
    set = sense_to_set(_error, sense)
    parse_one_operator_constraint(_error, vectorized, Val(:in), aff, set)
end

function parseconstraint(_error::Function, sense::Symbol, lhs, rhs)
    (sense, vectorized) = _check_vectorized(sense)
    vectorized, parse_one_operator_constraint(_error, vectorized, Val(sense), lhs, rhs)...
end

function parseternaryconstraint(_error::Function, vectorized::Bool, lb, ::Union{Val{:(<=)}, Val{:(≤)}}, aff, rsign::Union{Val{:(<=)}, Val{:(≤)}}, ub)
    newaff, parseaff = parseExprToplevel(aff, :aff)
    newlb, parselb = parseExprToplevel(lb, :lb)
    newub, parseub = parseExprToplevel(ub, :ub)
    if vectorized
        buildcall = :(buildconstraint.($_error, $newaff, $newlb, $newub))
    else
        buildcall = :(buildconstraint($_error, $newaff, $newlb, $newub))
    end
    parseaff, parselb, parseub, buildcall
end

function parseternaryconstraint(_error::Function, vectorized::Bool, ub, ::Union{Val{:(>=)}, Val{:(≥)}}, aff, rsign::Union{Val{:(>=)}, Val{:(≥)}}, lb)
    parseternaryconstraint(_error, vectorized, lb, Val(:(<=)), aff, Val(:(<=)), ub)
end

function parseternaryconstraint(_error::Function, args...)
    _error("Only two-sided rows of the form lb <= expr <= ub or ub >= expr >= lb are supported.")
end

function parseconstraint(_error::Function, lb, lsign::Symbol, aff, rsign::Symbol, ub)
    (lsign, lvectorized) = _check_vectorized(lsign)
    (rsign, rvectorized) = _check_vectorized(rsign)
    ((vectorized = lvectorized) == rvectorized) || _error("Signs are inconsistently vectorized")
    parseaff, parselb, parseub, buildcall = parseternaryconstraint(_error, vectorized, lb, Val(lsign), aff, Val(rsign), ub)
    parsecode = quote
        aff = Val{false}()
        $parseaff
        lb = 0.0
        $parselb
        ub = 0.0
        $parseub
    end
    vectorized, parsecode, buildcall
end

function parseconstraint(_error::Function, args...)
    # Unknown
    _error("Constraints must be in one of the following forms:\n" *
          "       expr1 <= expr2\n" * "       expr1 >= expr2\n" *
          "       expr1 == expr2\n" * "       lb <= expr <= ub")
end

const ScalarPolyhedralSets = Union{MOI.LessThan,MOI.GreaterThan,MOI.EqualTo,MOI.Interval}

buildconstraint(_error::Function, v::AbstractVariableRef, set::MOI.AbstractScalarSet) = SingleVariableConstraint(v, set)
buildconstraint(_error::Function, v::Vector{<:AbstractVariableRef}, set::MOI.AbstractVectorSet) = VectorOfVariablesConstraint(v, set)

buildconstraint(_error::Function, α::Number, set::MOI.AbstractScalarSet) = buildconstraint(_error, convert(AffExpr, α), set)
function buildconstraint(_error::Function, aff::GenericAffExpr, set::S) where S <: Union{MOI.LessThan,MOI.GreaterThan,MOI.EqualTo}
    offset = aff.constant
    aff.constant = 0.0
    return AffExprConstraint(aff, S(MOIU.getconstant(set)-offset))
end

buildconstraint(_error::Function, x::AbstractArray, set::MOI.AbstractScalarSet) = _error("Unexpected vector in scalar constraint. Did you mean to use the dot comparison operators like .==, .<=, and .>= instead?")
buildconstraint(_error::Function, x::Vector{<:GenericAffExpr}, set::MOI.AbstractVectorSet) = VectorAffExprConstraint(x, set)

function buildconstraint(_error::Function, quad::GenericQuadExpr, set::S) where S <: Union{MOI.LessThan,MOI.GreaterThan,MOI.EqualTo}
    offset = quad.aff.constant
    quad.aff.constant = 0.0
    return QuadExprConstraint(quad, S(MOIU.getconstant(set)-offset))
end
#buildconstraint(x::Vector{<:GenericQuadExpr}, set::MOI.AbstractVectorSet) = VectorQuadExprConstraint(x, set)


# _vectorize_like(x::Number, y::AbstractArray{AffExpr}) = (ret = similar(y, typeof(x)); fill!(ret, x))
# function _vectorize_like{R<:Number}(x::AbstractArray{R}, y::AbstractArray{AffExpr})
#     for i in 1:max(ndims(x),ndims(y))
#         _size(x,i) == _size(y,i) || error("Unequal sizes for ranged constraint")
#     end
#     x
# end
#
# function buildconstraint(x::AbstractArray{AffExpr}, lb, ub)
#     LB = _vectorize_like(lb,x)
#     UB = _vectorize_like(ub,x)
#     ret = similar(x, AffExprConstraint)
#     map!(ret, eachindex(ret)) do i
#         buildconstraint(x[i], LB[i], UB[i])
#     end
# end

# TODO replace these with buildconstraint(_error, fun, ::Interval) for more consistency, quad exprs in Interval should now be supported with MOI anyway
# three-argument buildconstraint is used for two-sided constraints.
buildconstraint(_error::Function, v::AbstractVariableRef, lb::Real, ub::Real) = SingleVariableConstraint(v, MOI.Interval(lb, ub))

function buildconstraint(_error::Function, aff::GenericAffExpr, lb::Real, ub::Real)
    offset = aff.constant
    aff.constant = 0.0
    AffExprConstraint(aff,MOI.Interval(lb-offset,ub-offset))
end

buildconstraint(_error::Function, q::GenericQuadExpr, lb, ub) = _error("Two-sided quadratic constraints not supported. (Try @NLconstraint instead.)")

function buildconstraint(_error::Function, expr, lb, ub)
    lb isa Number || _error(string("Expected $lb to be a number."))
    ub isa Number || _error(string("Expected $ub to be a number."))
    if lb isa Number && ub isa Number
        _error("Range constraint is not supported for $expr.")
    end
end

# TODO: update 3-argument @constraint macro to pass through names like @variable

"""
    constraint_macro(args, macro_name::Symbol, parsefun::Function)

Returns the code for the macro `@constraint_like args...` of syntax
```julia
@constraint_like con     # Single constraint
@constraint_like ref con # group of constraints
```
where `@constraint_like` is either `@constraint` or `@SDconstraint`.
The expression `con` is parsed by `parsefun` which returns a code that, when
executed, returns an `AbstractConstraint`. This `AbstractConstraint` is passed
to `addconstraint` with the macro keyword arguments (except the `container`
keyword argument which is used to determine the container type).
"""
function constraint_macro(args, macro_name::Symbol, parsefun::Function)
    _error(str) = macro_error(macro_name, args, str)

    args, kwargs, requestedcontainer = extract_kwargs(args)

    if length(args) < 2
        if length(kwargs) > 0
            _error("Not enough positional arguments")
        else
            _error("Not enough arguments")
        end
    end
    m = args[1]
    x = args[2]
    extra = args[3:end]

    m = esc(m)
    # Two formats:
    # - @constraint_like(m, a*x <= 5)
    # - @constraint_like(m, myref[a=1:5], a*x <= 5)
    length(extra) > 1 && _error("Too many arguments.")
    # Canonicalize the arguments
    c = length(extra) == 1 ? x        : gensym()
    x = length(extra) == 1 ? extra[1] : x

    anonvar = isexpr(c, :vect) || isexpr(c, :vcat) || length(extra) != 1
    variable = gensym()
    quotvarname = quot(getname(c))
    escvarname  = anonvar ? variable : esc(getname(c))
    basename = anonvar ? "" : string(getname(c))
    # TODO: support the basename keyword argument

    if isa(x, Symbol)
        _error("Incomplete constraint specification $x. Are you missing a comparison (<=, >=, or ==)?")
    end

    (x.head == :block) &&
        _error("Code block passed as constraint. Perhaps you meant to use @constraints instead?")

    # Strategy: build up the code for addconstraint, and if needed
    # we will wrap in loops to assign to the ConstraintRefs
    refcall, idxvars, idxsets, condition = buildrefsets(c, variable)

    vectorized, parsecode, buildcall = parsefun(_error, x.args...)
    if vectorized
        # TODO: Pass through names here.
        constraintcall = :(addconstraint.($m, $buildcall))
    else
        constraintcall = :(addconstraint($m, $buildcall, $(namecall(basename, idxvars))))
    end
    addkwargs!(constraintcall, kwargs)
    code = quote
        $parsecode
        $(refcall) = $constraintcall
    end

    # Determine the return type of addconstraint. This is needed for JuMP extensions for which this is different than ConstraintRef
    if vectorized
        contype = :( AbstractArray{constrainttype($m)} ) # TODO use a concrete type instead of AbstractArray, see #525, #1310
    else
        contype = :( constrainttype($m) )
    end
    creationcode = getloopedcode(variable, code, condition, idxvars, idxsets, contype, requestedcontainer)

    if anonvar
        # Anonymous constraint, no need to register it in the model-level
        # dictionary nor to assign it to a variable in the user scope.
        # We simply return the constraint reference
        assignmentcode = variable
    else
        # We register the constraint reference to its name and
        # we assign it to a variable in the local scope of this name
        assignmentcode = quote
            registercon($m, $quotvarname, $variable)
            $escvarname = $variable
        end
    end

    return assert_validmodel(m, quote
        $creationcode
        $assignmentcode
    end)
end

# This function needs to be implemented by all `AbstractModel`s
constrainttype(m::Model) = ConstraintRef{typeof(m)}

"""
    @constraint(m::Model, expr)

Add a constraint described by the expression `expr`.

    @constraint(m::Model, ref[i=..., j=..., ...], expr)

Add a group of constraints described by the expression `expr` parametrized by
`i`, `j`, ...

The expression `expr` can either be

* of the form `func in set` constraining the function `func` to belong to the
  set `set`, e.g. `@constraint(m, [1, x-1, y-2] in MOI.SecondOrderCone(3))`
  constrains the norm of `[x-1, y-2]` be less than 1;
* of the form `a sign b`, where `sign` is one of `==`, `≥`, `>=`, `≤` and
  `<=` building the single constraint enforcing the comparison to hold for the
  expression `a` and `b`, e.g. `@constraint(m, x^2 + y^2 == 1)` constrains `x`
  and `y` to lie on the unit circle;
* of the form `a ≤ b ≤ c` or `a ≥ b ≥ c` (where `≤` and `<=` (resp. `≥` and
  `>=`) can be used interchangeably) constraining the paired the expression
  `b` to lie between `a` and `c`;
* of the forms `@constraint(m, a .sign b)` or
  `@constraint(m, a .sign b .sign c)` which broadcast the constraint creation to
  each element of the vectors.

## Note for extending the constraint macro

Each constraint will be created using
`addconstraint(m, buildconstraint(_error, func, set))` where
* `_error` is an error function showing the constraint call in addition to the
  error message given as argument,
* `func` is the expression that is constrained
* and `set` is the set in which it is constrained to belong.

For `expr` of the first type (i.e. `@constraint(m, func in set)`), `func` and
`set` are passed unchanged to `buildconstraint` but for the other types, they
are determined from the expressions and signs. For instance,
`@constraint(m, x^2 + y^2 == 1)` is transformed into
`addconstraint(m, buildconstraint(_error, x^2 + y^2, MOI.EqualTo(1.0)))`.

To extend JuMP to accept new constraints of this form, it is necessary to add
the corresponding methods to `buildconstraint`. Note that this will likely mean
that either `func` or `set` will be some custom type, rather than e.g. a
`Symbol`, since we will likely want to dispatch on the type of the function or
set appearing in the constraint.
"""
macro constraint(args...)
    constraint_macro(args, :constraint, parseconstraint)
end

function parseSDconstraint(_error::Function, sense::Symbol, lhs, rhs)
    # Simple comparison - move everything to the LHS
    aff = :()
    if sense == :⪰ || sense == :(≥) || sense == :(>=)
        aff = :($lhs - $rhs)
    elseif sense == :⪯ || sense == :(≤) || sense == :(<=)
        aff = :($rhs - $lhs)
    else
        _error("Invalid sense $sense in SDP constraint")
    end
    vectorized = false
    parsecode, buildcall = parse_one_operator_constraint(_error, false, Val(:in), aff, :(PSDCone()))
    vectorized, parsecode, buildcall
end

function parseSDconstraint(_error::Function, args...)
    _error("Constraints must be in one of the following forms:\n" *
           "       expr1 <= expr2\n" *
           "       expr1 >= expr2")
end

"""
    @SDconstraint(m::Model, expr)

Add a semidefinite constraint described by the expression `expr`.

    @SDconstraint(m::Model, ref[i=..., j=..., ...], expr)

Add a group of semidefinite constraints described by the expression `expr`
parametrized by `i`, `j`, ...

The expression `expr` needs to be of the form `a sign b` where `sign` is `⪰`,
`≥`, `>=`, `⪯`, `≤` or `<=` and `a` and `b` are `square` matrices. It
constrains that `a - b` (or `b - a` if the sign is `⪯`, `≤` or `<=`) is
positive semidefinite.
"""
macro SDconstraint(args...)
    constraint_macro(args, :SDconstraint, parseSDconstraint)
end


# """
#     @LinearConstraint(x)
#
# Constructs a `LinearConstraint` instance efficiently by parsing the `x`. The same as `@constraint`, except it does not attach the constraint to any model.
# """
# macro LinearConstraint(x)
#     (x.head == :block) &&
#         error("Code block passed as constraint. Perhaps you meant to use @LinearConstraints instead?")
#
#     if isexpr(x, :call) && length(x.args) == 3
#         (sense,vectorized) = _canonicalize_sense(x.args[1])
#         # Simple comparison - move everything to the LHS
#         vectorized &&
#             error("in @LinearConstraint ($(string(x))): Cannot add vectorized constraints")
#         lhs = :($(x.args[2]) - $(x.args[3]))
#         return quote
#             newaff = @Expression($(esc(lhs)))
#             c = buildconstraint(newaff,$(quot(sense)))
#             isa(c, LinearConstraint) ||
#                 error("Constraint in @LinearConstraint is really a $(typeof(c))")
#             c
#         end
#     elseif isexpr(x, :comparison)
#         # Ranged row
#         (lsense,lvectorized) = _canonicalize_sense(x.args[2])
#         (rsense,rvectorized) = _canonicalize_sense(x.args[4])
#         if (lsense != :<=) || (rsense != :<=)
#             error("in @constraint ($(string(x))): only ranged rows of the form lb <= expr <= ub are supported.")
#         end
#         (lvectorized || rvectorized) &&
#             error("in @LinearConstraint ($(string(x))): Cannot add vectorized constraints")
#         lb = x.args[1]
#         ub = x.args[5]
#         return quote
#             if !isa($(esc(lb)),Number)
#                 error(string("in @LinearConstraint (",$(string(x)),"): expected ",$(string(lb))," to be a number."))
#             elseif !isa($(esc(ub)),Number)
#                 error(string("in @LinearConstraint (",$(string(x)),"): expected ",$(string(ub))," to be a number."))
#             end
#             newaff = @Expression($(esc(x.args[3])))
#             offset = newaff.constant
#             newaff.constant = 0.0
#             isa(newaff,AffExpr) || error("Ranged quadratic constraints are not allowed")
#             LinearConstraint(newaff,$(esc(lb))-offset,$(esc(ub))-offset)
#         end
#     else
#         # Unknown
#         error("in @LinearConstraint ($(string(x))): constraints must be in one of the following forms:\n" *
#               "       expr1 <= expr2\n" * "       expr1 >= expr2\n" *
#               "       expr1 == expr2\n" * "       lb <= expr <= ub")
#     end
# end

# """
#     @QuadConstraint(x)
#
# Constructs a `QuadConstraint` instance efficiently by parsing the `x`. The same as `@constraint`, except it does not attach the constraint to any model.
# """
# macro QuadConstraint(x)
#     (x.head == :block) &&
#         error("Code block passed as constraint. Perhaps you meant to use @QuadConstraints instead?")
#
#     if isexpr(x, :call) && length(x.args) == 3
#         (sense,vectorized) = _canonicalize_sense(x.args[1])
#         # Simple comparison - move everything to the LHS
#         vectorized &&
#             error("in @QuadConstraint ($(string(x))): Cannot add vectorized constraints")
#         lhs = :($(x.args[2]) - $(x.args[3]))
#         return quote
#             newaff = @Expression($(esc(lhs)))
#             q = buildconstraint(newaff,$(quot(sense)))
#             isa(q, QuadConstraint) || error("Constraint in @QuadConstraint is really a $(typeof(q))")
#             q
#         end
#     elseif isexpr(x, :comparison)
#         error("Ranged quadratic constraints are not allowed")
#     else
#         # Unknown
#         error("in @QuadConstraint ($(string(x))): constraints must be in one of the following forms:\n" *
#               "       expr1 <= expr2\n" * "       expr1 >= expr2\n" *
#               "       expr1 == expr2")
#     end
# end

# macro SOCConstraint(x)
#     (x.head == :block) &&
#         error("Code block passed as constraint. Perhaps you meant to use @SOCConstraints instead?")
#
#     if isexpr(x, :call) && length(x.args) == 3
#         (sense,vectorized) = _canonicalize_sense(x.args[1])
#         # Simple comparison - move everything to the LHS
#         vectorized &&
#             error("in @SOCConstraint ($(string(x))): Cannot add vectorized constraints")
#         lhs = :($(x.args[2]) - $(x.args[3]))
#         return quote
#             newaff = @Expression($(esc(lhs)))
#             q = buildconstraint(newaff,$(quot(sense)))
#             isa(q, SOCConstraint) || error("Constraint in @SOCConstraint is really a $(typeof(q))")
#             q
#         end
#     elseif isexpr(x, :comparison)
#         error("Ranged second-order cone constraints are not allowed")
#     else
#         # Unknown
#         error("in @SOCConstraint ($(string(x))): constraints must be in one of the following forms:\n" *
#               "       expr1 <= expr2\n" * "       expr1 >= expr2")
#     end
# end

# for (mac,sym) in [(:LinearConstraints, Symbol("@LinearConstraint")),
#                   (:QuadConstraints,   Symbol("@QuadConstraint")),
#                   (:SOCConstraints,    Symbol("@SOCConstraint"))]
#     @eval begin
#         macro $mac(x)
#             x.head == :block || error(string("Invalid syntax for @", $(string(mac))))
#             @assert x.args[1].head == :line
#             code = Expr(:vect)
#             for it in x.args
#                 if it.head == :line
#                     # do nothing
#                 elseif it.head == :comparison || (it.head == :call && it.args[1] in (:<=,:≤,:>=,:≥,:(==))) # regular constraint
#                     push!(code.args, Expr(:macrocall, $sym, esc(it)))
#                 elseif it.head == :tuple # constraint ref
#                     if all([isexpr(arg,:comparison) for arg in it.args]...)
#                         # the user probably had trailing commas at end of lines, e.g.
#                         # @LinearConstraints(m, begin
#                         #     x <= 1,
#                         #     x >= 1
#                         # end)
#                         error(string("Invalid syntax in @", $(string(mac)), ". Do you have commas at the end of a line specifying a constraint?"))
#                     end
#                     error("@", string($(string(mac)), " does not currently support the two argument syntax for specifying groups of constraints in one line."))
#                 else
#                     error("Unexpected constraint expression $it")
#                 end
#             end
#             return code
#         end
#     end
# end

for (mac,sym) in [(:constraints,  Symbol("@constraint")),
                  (:NLconstraints,Symbol("@NLconstraint")),
                  (:SDconstraints,Symbol("@SDconstraint")),
                  (:variables,Symbol("@variable")),
                  (:expressions, Symbol("@expression")),
                  (:NLexpressions, Symbol("@NLexpression"))]
    @eval begin
        macro $mac(m, x)
            x.head == :block || error("Invalid syntax for @",$(string(mac)))
            @assert x.args[1].head == :line
            code = quote end
            for it in x.args
                if isexpr(it, :line)
                    # do nothing
                elseif isexpr(it, :tuple) # line with commas
                    args = []
                    for ex in it.args
                        if isexpr(ex, :tuple) # embedded tuple
                            append!(args, ex.args)
                        else
                            push!(args, ex)
                        end
                    end
                    args_esc = []
                    for ex in args
                        if isexpr(ex, :(=)) && VERSION < v"0.6.0-dev.1934"
                            push!(args_esc,Expr(:kw, ex.args[1], esc(ex.args[2])))
                        else
                            push!(args_esc, esc(ex))
                        end
                    end
                    mac = Expr(:macrocall,$(quot(sym)), esc(m), args_esc...)
                    push!(code.args, mac)
                else # stand-alone symbol or expression
                    push!(code.args,Expr(:macrocall,$(quot(sym)), esc(m), esc(it)))
                end
            end
            push!(code.args, :(nothing))
            return code
        end
    end
end


# Doc strings for the auto-generated macro pluralizations
@doc """
    @constraints(m, args...)

adds groups of constraints at once, in the same fashion as @constraint. The model must be the first argument, and multiple constraints can be added on multiple lines wrapped in a `begin ... end` block. For example:

    @constraints(m, begin
      x >= 1
      y - w <= 2
      sum_to_one[i=1:3], z[i] + y == 1
    end)
""" :(@constraints)

@doc """
    @LinearConstraints(m, args...)

Constructs a vector of `LinearConstraint` objects. Similar to `@LinearConstraint`, except it accepts multiple constraints as input as long as they are separated by newlines.
""" :(@LinearConstraints)

@doc """
    @QuadConstraints(m, args...)

Constructs a vector of `QuadConstraint` objects. Similar to `@QuadConstraint`, except it accepts multiple constraints as input as long as they are separated by newlines.
""" :(@QuadConstraints)






macro objective(m, args...)
    m = esc(m)
    if length(args) != 2
        # Either just an objective sene, or just an expression.
        error("in @objective: needs three arguments: model, objective sense (Max or Min) and expression.")
    end
    sense, x = args
    if sense == :Min || sense == :Max
        sense = Expr(:quote,sense)
    end
    newaff, parsecode = parseExprToplevel(x, :q)
    code = quote
        q = Val{false}()
        $parsecode
        setobjective($m, $(esc(sense)), $newaff)
    end
    return assert_validmodel(m, code)
end

# Return a standalone, unnamed expression
# ex = @Expression(2x + 3y)
# Currently for internal use only.
macro Expression(x)
    newaff, parsecode = parseExprToplevel(x, :q)
    return quote
        q = Val{false}()
        $parsecode
        $newaff
    end
end


"""
    @expression(args...)

efficiently builds a linear, quadratic, or second-order cone expression but does not add to model immediately. Instead, returns the expression which can then be inserted in other constraints. For example:

```julia
@expression(m, shared, sum(i*x[i] for i=1:5))
@constraint(m, shared + y >= 5)
@constraint(m, shared + z <= 10)
```

The `ref` accepts index sets in the same way as `@variable`, and those indices can be used in the construction of the expressions:

```julia
@expression(m, expr[i=1:3], i*sum(x[j] for j=1:3))
```

Anonymous syntax is also supported:

```julia
expr = @expression(m, [i=1:3], i*sum(x[j] for j=1:3))
```
"""
macro expression(args...)

    args, kwargs, requestedcontainer = extract_kwargs(args)
    if length(args) == 3
        m = esc(args[1])
        c = args[2]
        x = args[3]
    elseif length(args) == 2
        m = esc(args[1])
        c = gensym()
        x = args[2]
    else
        error("@expression: needs at least two arguments.")
    end
    length(kwargs) == 0 || error("@expression: unrecognized keyword argument")

    anonvar = isexpr(c, :vect) || isexpr(c, :vcat)
    variable = gensym()
    escvarname  = anonvar ? variable : esc(getname(c))

    refcall, idxvars, idxsets, condition = buildrefsets(c, variable)
    newaff, parsecode = parseExprToplevel(x, :q)
    code = quote
        q = Val{false}()
        $parsecode
    end
    if isa(c,Expr)
        code = quote
            $code
            (isa($newaff,AffExpr) || isa($newaff,Number) || isa($newaff,VariableRef)) || error("Collection of expressions with @expression must be linear. For quadratic expressions, use your own array.")
        end
    end
    code = quote
        $code
        $(refcall) = $newaff
    end
    code = getloopedcode(variable, code, condition, idxvars, idxsets, :AffExpr, requestedcontainer)
    # don't do anything with the model, but check that it's valid anyway
    return assert_validmodel(m, quote
        $code
        $(anonvar ? variable : :($escvarname = $variable))
    end)
end

function hasdependentsets(idxvars, idxsets)
    # check if any index set depends on a previous index var
    for i in 2:length(idxsets)
        for v in idxvars[1:(i-1)]
            if dependson(idxsets[i],v)
                return true
            end
        end
    end
    return false
end

dependson(ex::Expr,s::Symbol) = any(a->dependson(a,s), ex.args)
dependson(ex::Symbol,s::Symbol) = (ex == s)
dependson(ex,s::Symbol) = false
function dependson(ex1,ex2)
    @assert isa(ex2, Expr)
    @assert ex2.head == :tuple
    any(s->dependson(ex1,s), ex2.args)
end

function isdependent(idxvars,idxset,i)
    for (it,idx) in enumerate(idxvars)
        it == i && continue
        dependson(idxset, idx) && return true
    end
    return false
end

esc_nonconstant(x::Number) = x
esc_nonconstant(x::Expr) = isexpr(x,:quote) ? x : esc(x)
esc_nonconstant(x) = esc(x)

# Returns the type of what `addvariable(::Model, buildvariable(...))` would return where `...` represents the positional arguments.
# Example: `@variable m [1:3] foo` will allocate an vector of element type `variabletype(m, foo)`
# Note: it needs to be implemented by all `AbstractModel`s
variabletype(m::Model) = VariableRef
# Returns a new variable. Additional positional arguments can be used to dispatch the call to a different method.
# The return type should only depends on the positional arguments for `variabletype` to make sense. See the @variable macro doc for more details.
# Example: `@variable m x` foo will call `buildvariable(_error, info, foo)`
function buildvariable(_error::Function, info::VariableInfo; extra_kwargs...)
    for (kwarg, _) in extra_kwargs
        _error("Unrecognized keyword argument $kwarg")
    end
    return ScalarVariable(info)
end

const EMPTYSTRING = ""

macro_error(macroname, args, str) = error("In @$macroname($(join(args,","))): ", str)

# Given a basename and idxvars, returns an expression that constructs the name
# of the object. For use within macros only.
function namecall(basename, idxvars)
    if length(idxvars) == 0 || basename == ""
        return basename
    end
    ex = Expr(:call,:string,basename,"[")
    for i in 1:length(idxvars)
        push!(ex.args, esc(idxvars[i]))
        i < length(idxvars) && push!(ex.args,",")
    end
    push!(ex.args,"]")
    return ex
end

reverse_sense(::Val{:<=})   = :>=
reverse_sense(::Val{:≤})    = :≥
reverse_sense(::Val{:>=})   = :<=
reverse_sense(::Val{:≥})    = :≤
reverse_sense(::Val{:(==)}) = :(==)

"""
    parse_one_operator_variable(_error::Function, infoexpr::VariableInfoExpr, sense::Val{S}, value) where S

Update `infoexr` for a variable expression in the `@variable` macro of the form `variable name S value`.
"""
parse_one_operator_variable(_error::Function, infoexpr::VariableInfoExpr, ::Union{Val{:<=}, Val{:≤}}, upper) = setupperbound_or_error(_error, infoexpr, upper)
parse_one_operator_variable(_error::Function, infoexpr::VariableInfoExpr, ::Union{Val{:>=}, Val{:≥}}, lower) = setlowerbound_or_error(_error, infoexpr, lower)
parse_one_operator_variable(_error::Function, infoexpr::VariableInfoExpr, ::Val{:(==)}, value) = fix_or_error(_error, infoexpr, value)
parse_one_operator_variable(_error::Function, infoexpr::VariableInfoExpr, ::Val{S}, value) where S = _error("Unknown sense $S.")
function parsevariable(_error::Function, infoexpr::VariableInfoExpr, sense::Symbol, var, value)
    # Variable declaration of the form: var sense value

    # There is not way to determine at parsing time which of lhs or rhs is the
    # variable name and which is the value. For instance, lhs could be the
    # Symbol `:x` and rhs could be the Symbol `:a` where a variable `a` is
    # assigned to 1 in the local scope. Knowing this, we know that `x` is the
    # variable name but at parse time there is now way to know that `a` has
    # a value.
    # Therefore, we always assume that the variable is the `lhs` and throw
    # an helpful error in the the case were we can easily determine that the
    # user placed the variable in the rhs, i.e. the case where the rhs is a
    # constant number.
    var isa Number && _error("Variable declaration of the form `$var $S $value` is not supported. Use `$value $(reverse_sense(sense)) $var` instead.")
    parse_one_operator_variable(_error, infoexpr, Val(sense), esc_nonconstant(value))
    var
end

function parseternaryvariable(_error::Function, infoexpr::VariableInfoExpr,
                              ::Union{Val{:<=}, Val{:≤}}, lower,
                              ::Union{Val{:<=}, Val{:≤}}, upper)
    setlowerbound_or_error(_error, infoexpr, lower)
    setupperbound_or_error(_error, infoexpr, upper)
end
function parseternaryvariable(_error::Function, infoexpr::VariableInfoExpr,
                              ::Union{Val{:>=}, Val{:≥}}, upper,
                              ::Union{Val{:>=}, Val{:≥}}, lower)
    parseternaryvariable(_error, infoexpr, Val(:≤), lower, Val(:≤), upper)
end
function parseternaryvariable(_error::Function, infoexpr::VariableInfoExpr,
                              ::Val, lvalue,
                              ::Val, rvalue)
    _error("Use the form lb <= ... <= ub.")
end
function parsevariable(_error::Function, infoexpr::VariableInfoExpr, lvalue, lsign::Symbol, var, rsign::Symbol, rvalue)
    # lvalue lsign var rsign rvalue
    parseternaryvariable(_error, infoexpr, Val(lsign), esc_nonconstant(lvalue), Val(rsign), esc_nonconstant(rvalue))
    var
end

"""
    @variable(m; kwargs...)

Add an *anonymous* (see [Names](@ref)) variable to the model `m`
described by the keyword arguments `kwargs`.

    @variable(m, expr, args...; kwargs...)

Add a variable to the model `m` described by the expression `expr`, the
positional arguments `args` and the keyword arguments `kwargs`. The expression
`expr` can either be (note that in the following the symbol `<=` can be used
instead of `≤` and the symbol `>=`can be used instead of `≥`)

* of the form `varexpr` creating variables described by `varexpr`;
* of the form `varexpr ≤ ub` (resp. `varexpr ≥ lb`) creating variables described by
  `varexpr` with upper bounds given by `ub` (resp. lower bounds given by `lb`);
* of the form `varexpr == value` creating variables described by `varexpr` with
  fixed values given by `value`; or
* of the form `lb ≤ varexpr ≤ ub` or `ub ≥ varexpr ≥ lb` creating variables
  described by `varexpr` with lower bounds given by `lb` and upper bounds given
  by `ub`.

The expression `varexpr` can either be

* of the form `varname` creating a scalar real variable of name `varname`;
* of the form `varname[...]` or `[...]` creating a container of variables (see
  [Containers in macro](@ref).

The recognized positional arguments in `args` are the following:

* `Bin`: Sets the variable to be binary, i.e. either 0 or 1.
* `Int`: Sets the variable to be integer, i.e. one of ..., -2, -1, 0, 1, 2, ...
* `Symmetric`: Only available when creating a square matrix of variables, i.e.
  when `varexpr` is of the form `varname[1:n,1:n]` or `varname[i=1:n,j=1:n]`.
  It creates a symmetric matrix of variable, that is, it only creates a
  new variable for `varname[i,j]` with `i ≤ j` and sets `varname[j,i]` to the
  same variable as `varname[i,j]`.
* `PSD`: Same as `Symmetric` but also constrains the matrix to be positive
  semidefinite.

The recognized keyword arguments in `kwargs` are the following:

* `basename`: Sets the base name used to generate variable names. It
  corresponds to the variable name for scalar variable, otherwise, the
  variable names are `basename[...]` for each indices `...` of the axes `axes`.
* `lowerbound`: Sets the value of the variable lower bound.
* `upperbound`: Sets the value of the variable upper bound.
* `start`: Sets the variable starting value used as initial guess in optimization.
* `binary`: Sets whether the variable is binary or not.
* `integer`: Sets whether the variable is integer or not.
* `variabletype`: See the "Note for extending the variable macro" section below.
* `container`: Specify the container type, see [Containers in macro](@ref).

## Note for extending the variable macro

The single scalar variable or each scalar variable of the container are created
using `addvariable(m, buildvariable(_error, info, extra_args...;
extra_kwargs...))` where

* `m` is the model passed to the `@variable` macro;
* `_error` is an error function with a single `String` argument showing the
  `@variable` call in addition to the error message given as argument;
* `info` is the `VariableInfo` struct containing the information gathered in
  `expr`, the recognized keyword arguments (except `basename` and
  `variabletype`) and the recognized positional arguments (except `Symmetric`
  and `PSD`);
* `extra_args` are the unrecognized positional arguments of `args` plus the
  value of the `variabletype` keyword argument if present. The `variabletype`
  keyword argument allows the user to pass a position argument to
  `buildvariable` without the need to give a positional argument to
  `@variable`. In particular, this allows the user to give a positional
  argument to the `buildvariable` call when using the anonymous single variable
  syntax `@variable(m; kwargs...)`; and
* `extra_kwargs` are the unrecognized keyword argument of `kwargs`.

## Examples

The following are equivalent ways of creating a variable `x` of name `x` with
lowerbound 0:
```julia
# Specify everything in `expr`
@variable(m, x >= 0)
# Specify the lower bound using a keyword argument
@variable(m, x, lowerbound=0)
# Specify everything in `kwargs`
x = @variable(m, basename="x", lowerbound=0)
# Without the `@variable` macro
info = VariableInfo(true, 0, false, NaN, false, NaN, false, NaN, false, false)
JuMP.addvariable(m, JuMP.buildvariable(error, info), "x")
```

The following are equivalent ways of creating a `JuMPArray` of index set
`[:a, :b]` and with respective upper bounds 2 and 3 and names `x[a]` and `x[b].
```julia
ub = Dict(:a => 2, :b => 3)
# Specify everything in `expr`
@variable(m, x[i=keys(ub)] <= ub[i])
# Specify the upper bound using a keyword argument
@variable(m, x[i=keys(ub)], upperbound=ub[i])
# Without the `@variable` macro
data = Vector{JuMP.variabletype(m)}(undef, length(keys(ub)))
x = JuMPArray(data, keys(ub))
for i in keys(ub)
    info = VariableInfo(false, NaN, true, ub[i], false, NaN, false, NaN, false, false)
    x[i] = JuMP.addvariable(m, JuMP.buildvariable(error, info), "x[\$i]")
end
```

The following are equivalent ways of creating a `Matrix` of size
`N x N` with variables custom variables created with a JuMP extension using
the `Poly(X)` positional argument to specify its variables:
```julia
# Using the `@variable` macro
@variable(m, x[1:N,1:N], Symmetric, Poly(X))
# Without the `@variable` macro
x = Matrix{JuMP.variabletype(m, Poly(X))}(N, N)
info = VariableInfo(false, NaN, false, NaN, false, NaN, false, NaN, false, false)
for i in 1:N, j in i:N
    x[i,j] = x[j,i] = JuMP.addvariable(m, buildvariable(error, info, Poly(X)), "x[\$i,\$j]")
end
```
"""
macro variable(args...)
    _error(str) = macro_error(:variable, args, str)

    m = esc(args[1])

    extra, kwargs, requestedcontainer = extract_kwargs(args[2:end])

    # if there is only a single non-keyword argument, this is an anonymous
    # variable spec and the one non-kwarg is the model
    if length(extra) == 0
        x = gensym()
        anon_singleton = true
    else
        x = shift!(extra)
        if x in [:Int,:Bin,:PSD]
            _error("Ambiguous variable name $x detected. Use the \"category\" keyword argument to specify a category for an anonymous variable.")
        end
        anon_singleton = false
    end

    info_kwargs = filter(isinfokeyword, kwargs)
    extra_kwargs = filter(kw -> kw.args[1] != :basename && kw.args[1] != :variabletype && !isinfokeyword(kw), kwargs)
    basename_kwargs = filter(kw -> kw.args[1] == :basename, kwargs)
    variabletype_kwargs = filter(kw -> kw.args[1] == :variabletype, kwargs)
    infoexpr = VariableInfoExpr(; keywordify.(info_kwargs)...)

    # There are four cases to consider:
    # x                                       | type of x | x.head
    # ----------------------------------------+-----------+------------
    # var                                     | Symbol    | NA
    # var[1:2]                                | Expr      | :ref
    # var <= ub or var[1:2] <= ub             | Expr      | :call
    # lb <= var <= ub or lb <= var[1:2] <= ub | Expr      | :comparison
    # In the two last cases, we call parsevariable
    explicit_comparison = isexpr(x, :comparison) || isexpr(x, :call)
    if explicit_comparison
        var = parsevariable(_error, infoexpr, x.args...)
    else
        var = x
    end

    anonvar = isexpr(var, :vect) || isexpr(var, :vcat) || anon_singleton
    anonvar && explicit_comparison && error("Cannot use explicit bounds via >=, <= with an anonymous variable")
    variable = gensym()
    quotvarname = anonvar ? :(:__anon__) : quot(getname(var))
    escvarname  = anonvar ? variable     : esc(getname(var))
    # TODO: Should we generate non-empty default names for variables?
    if isempty(basename_kwargs)
        basename = anonvar ? "" : string(getname(var))
    else
        basename = esc(basename_kwargs[1].args[2])
    end

    if !isa(getname(var),Symbol) && !anonvar
        Base.error("Expression $(getname(var)) should not be used as a variable name. Use the \"anonymous\" syntax $(getname(var)) = @variable(m, ...) instead.")
    end

    # process keyword arguments
    obj = nothing

    sdp = any(t -> (t == :PSD), extra)
    symmetric = (sdp || any(t -> (t == :Symmetric), extra))
    extra = filter(x -> (x != :PSD && x != :Symmetric), extra) # filter out PSD and sym tag
    for ex in extra
        if ex == :Int
            setinteger_or_error(_error, infoexpr)
        elseif ex == :Bin
            setbinary_or_error(_error, infoexpr)
        end
    end
    extra = esc.(filter(ex -> !(ex in [:Int,:Bin]), extra))
    if !isempty(variabletype_kwargs)
        push!(extra, esc(variabletype_kwargs[1].args[2]))
    end

    info = constructor_expr(infoexpr)
    if isa(var,Symbol)
        # Easy case - a single variable
        sdp && _error("Cannot add a semidefinite scalar variable")
        buildcall = :( buildvariable($_error, $info, $(extra...)) )
        addkwargs!(buildcall, extra_kwargs)
        variablecall = :( addvariable($m, $buildcall, $basename) )
        # The looped code is trivial here since there is a single variable
        creationcode = :($variable = $variablecall)
        finalvariable = variable
    else
        isa(var,Expr) || _error("Expected $var to be a variable name")

        # We now build the code to generate the variables (and possibly the JuMPDict
        # to contain them)
        refcall, idxvars, idxsets, condition = buildrefsets(var, variable)
        clear_dependencies(i) = (isdependent(idxvars,idxsets[i],i) ? () : idxsets[i])

        # Code to be used to create each variable of the container.
        buildcall = :( buildvariable($_error, $info, $(extra...)) )
        addkwargs!(buildcall, extra_kwargs)
        variablecall = :( addvariable($m, $buildcall, $(namecall(basename, idxvars))) )
        code = :( $(refcall) = $variablecall )
        # Determine the return type of addvariable. This is needed to create the container holding them.
        vartype = :( variabletype($m, $(extra...)) )

        if symmetric
            # Sanity checks on PSD input stuff
            condition == :() ||
                _error("Cannot have conditional indexing for PSD variables")
            length(idxvars) == length(idxsets) == 2 ||
                _error("PSD variables must be 2-dimensional")
            !symmetric || (length(idxvars) == length(idxsets) == 2) ||
                _error("Symmetric variables must be 2-dimensional")
            hasdependentsets(idxvars, idxsets) &&
                _error("Cannot have index dependencies in symmetric variables")
            for _rng in idxsets
                isexpr(_rng, :escape) ||
                    _error("Internal error 1")
                rng = _rng.args[1] # undo escaping
                if VERSION >= v"0.7-"
                    (isexpr(rng,:call) && length(rng.args) == 3 && rng.args[1] == :(:) && rng.args[2] == 1) ||
                        _error("Index sets for SDP variables must be ranges of the form 1:N")
                else
                    (isexpr(rng,:(:)) && rng.args[1] == 1 && length(rng.args) == 2) ||
                        _error("Index sets for SDP variables must be ranges of the form 1:N")
                end
            end

            if infoexpr.haslb || infoexpr.hasub
                _error("Semidefinite or symmetric variables cannot be provided bounds")
            end
            creationcode = quote
                $(esc(idxsets[1].args[1].args[2])) == $(esc(idxsets[2].args[1].args[2])) || error("Cannot construct symmetric variables with nonsquare dimensions")
                $(getloopedcode(variable, code, condition, idxvars, idxsets, vartype, requestedcontainer; lowertri=symmetric))
                $(if sdp
                    quote
                        JuMP.addconstraint($m, JuMP.buildconstraint($_error, Symmetric($variable), JuMP.PSDCone()))
                    end
                end)
            end
            finalvariable = :(Symmetric($variable))
        else
            creationcode = getloopedcode(variable, code, condition, idxvars, idxsets, vartype, requestedcontainer)
            finalvariable = variable
        end
    end
    if anonvar
        # Anonymous variable, no need to register it in the model-level
        # dictionary nor to assign it to a variable in the user scope.
        # We simply return the variable
        assignmentcode = finalvariable
    else
        # We register the variable reference to its name and
        # we assign it to a variable in the local scope of this name
        assignmentcode = quote
            registervar($m, $quotvarname, $variable)
            $escvarname = $finalvariable
        end
    end
    return assert_validmodel(m, quote
        $creationcode
        $assignmentcode
    end)
end

# TODO: replace with a general macro that can construct any container type
# macro constraintref(var)
#     if isa(var,Symbol)
#         # easy case
#         return esc(:(local $var))
#     else
#         if !isexpr(var,:ref)
#             error("Syntax error: Expected $var to be of form var[...]")
#         end
#
#         varname = var.args[1]
#         idxsets = var.args[2:end]
#
#         code = quote
#             $(esc(gendict(varname, :ConstraintRef, idxsets...)))
#             nothing
#         end
#         return code
#     end
# end

macro NLobjective(m, sense, x)
    m = esc(m)
    if sense == :Min || sense == :Max
        sense = Expr(:quote,sense)
    end
    return assert_validmodel(m, quote
        ex = @processNLExpr($m, $(esc(x)))
        setobjective($m, $(esc(sense)), ex)
    end)
end

macro NLconstraint(m, x, extra...)
    m = esc(m)
    # Two formats:
    # - @NLconstraint(m, a*x <= 5)
    # - @NLconstraint(m, myref[a=1:5], sin(x^a) <= 5)
    extra, kwargs, requestedcontainer = extract_kwargs(extra)
    (length(extra) > 1 || length(kwargs) > 0) && error("in @NLconstraint: too many arguments.")
    # Canonicalize the arguments
    c = length(extra) == 1 ? x        : gensym()
    x = length(extra) == 1 ? extra[1] : x

    anonvar = isexpr(c, :vect) || isexpr(c, :vcat) || length(extra) != 1
    variable = gensym()
    quotvarname = anonvar ? :(:__anon__) : quot(getname(c))
    escvarname  = anonvar ? variable : esc(getname(c))

    # Strategy: build up the code for non-macro addconstraint, and if needed
    # we will wrap in loops to assign to the ConstraintRefs
    refcall, idxvars, idxsets, condition = buildrefsets(c, variable)
    # Build the constraint
    if isexpr(x, :call) # one-sided constraint
        # Simple comparison - move everything to the LHS
        op = x.args[1]
        if op == :(==)
            lb = 0.0
            ub = 0.0
        elseif op == :(<=) || op == :(≤)
            lb = -Inf
            ub = 0.0
        elseif op == :(>=) || op == :(≥)
            lb = 0.0
            ub = Inf
        else
            error("in @NLconstraint ($(string(x))): expected comparison operator (<=, >=, or ==).")
        end
        lhs = :($(x.args[2]) - $(x.args[3]))
        code = quote
            c = NonlinearConstraint(@processNLExpr($m, $(esc(lhs))), $lb, $ub)
            push!($m.nlpdata.nlconstr, c)
            $(refcall) = ConstraintRef($m, NonlinearConstraintIndex(length($m.nlpdata.nlconstr)))
        end
    elseif isexpr(x, :comparison)
        # ranged row
        if (x.args[2] != :<= && x.args[2] != :≤) || (x.args[4] != :<= && x.args[4] != :≤)
            error("in @NLconstraint ($(string(x))): only ranged rows of the form lb <= expr <= ub are supported.")
        end
        lb = x.args[1]
        ub = x.args[5]
        code = quote
            if !isa($(esc(lb)),Number)
                error(string("in @NLconstraint (",$(string(x)),"): expected ",$(string(lb))," to be a number."))
            elseif !isa($(esc(ub)),Number)
                error(string("in @NLconstraint (",$(string(x)),"): expected ",$(string(ub))," to be a number."))
            end
            c = NonlinearConstraint(@processNLExpr($m, $(esc(x.args[3]))), $(esc(lb)), $(esc(ub)))
            push!($m.nlpdata.nlconstr, c)
            $(refcall) = ConstraintRef($m, NonlinearConstraintIndex(length($m.nlpdata.nlconstr)))
        end
    else
        # Unknown
        error("in @NLconstraint ($(string(x))): constraints must be in one of the following forms:\n" *
              "       expr1 <= expr2\n" * "       expr1 >= expr2\n" *
              "       expr1 == expr2")
    end
    looped = getloopedcode(variable, code, condition, idxvars, idxsets, :(ConstraintRef{Model,NonlinearConstraintIndex}), requestedcontainer)
    return assert_validmodel(m, quote
        initNLP($m)
        $looped
        $(if anonvar
            variable
        else
            quote
                registercon($m, $quotvarname, $variable)
                $escvarname = $variable
            end
        end)
    end)
end

macro NLexpression(args...)
    args, kwargs, requestedcontainer = extract_kwargs(args)
    if length(args) <= 1
        error("in @NLexpression: To few arguments ($(length(args))); must pass the model and nonlinear expression as arguments.")
    elseif length(args) == 2
        m, x = args
        m = esc(m)
        c = gensym()
    elseif length(args) == 3
        m, c, x = args
        m = esc(m)
    end
    if length(args) > 3 || length(kwargs) > 0
        error("in @NLexpression: To many arguments ($(length(args))).")
    end

    anonvar = isexpr(c, :vect) || isexpr(c, :vcat)
    variable = gensym()
    escvarname  = anonvar ? variable : esc(getname(c))

    refcall, idxvars, idxsets, condition = buildrefsets(c, variable)
    code = quote
        $(refcall) = NonlinearExpression($m, @processNLExpr($m, $(esc(x))))
    end
    return assert_validmodel(m, quote
        $(getloopedcode(variable, code, condition, idxvars, idxsets, :NonlinearExpression, requestedcontainer))
        $(anonvar ? variable : :($escvarname = $variable))
    end)
end

# syntax is @NLparameter(m, p[i=1] == 2i)
macro NLparameter(m, ex, extra...)

    extra, kwargs, requestedcontainer = extract_kwargs(extra)
    (length(extra) == 0 && length(kwargs) == 0) || error("in @NLperameter: too many arguments.")
    m = esc(m)
    @assert isexpr(ex, :call)
    @assert length(ex.args) == 3
    @assert ex.args[1] == :(==)
    c = ex.args[2]
    x = ex.args[3]

    anonvar = isexpr(c, :vect) || isexpr(c, :vcat)
    if anonvar
        error("In @NLparameter($m, $ex): Anonymous nonlinear parameter syntax is not currently supported")
    end
    variable = gensym()
    escvarname  = anonvar ? variable : esc(getname(c))

    refcall, idxvars, idxsets, condition = buildrefsets(c, variable)
    code = quote
        $(refcall) = newparameter($m, $(esc(x)))
    end
    return assert_validmodel(m, quote
        $(getloopedcode(variable, code, condition, idxvars, idxsets, :NonlinearParameter, :Auto))
        $(anonvar ? variable : :($escvarname = $variable))
    end)
end
