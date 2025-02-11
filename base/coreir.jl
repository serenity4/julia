# This file is a part of Julia. License is MIT: https://julialang.org/license

Core.PhiNode() = Core.PhiNode(Int32[], Any[])

"""
    struct Const
        val
    end

The type representing a constant value.
"""
Core.Const

"""
    struct PartialStruct
        typ
        undef::BitVector # indicates which fields may be undefined
        fields::Vector{Any} # i-th element holds the lattice element corresponding to the i-th field
    end

This extended lattice element is introduced when we have information about an object's
fields beyond what can be obtained from the object type. E.g. it represents a tuple where
some elements are known to be constants or a struct whose `Any`-typed field is initialized
with `Int` values.

- `typ` indicates the type of the object
- `undef` records which fields are possibly undefined (`true`) or guaranteed to be defined (`false`), if `typ` is a struct
- `fields` holds the lattice elements corresponding to each defined field of the object

If `typ` is a tuple, the last element of `fields` may be `Vararg`. In this case, it is
guaranteed that the number of elements in the tuple is at least `length(fields)-1`, but the
exact number of elements is unknown.

To represent that a field is guaranteed to be undefined, the corresponding entry in `fields` should be `Union{}`.
"""
Core.PartialStruct

function Core.PartialStruct(@nospecialize(typ), undef::BitVector, fields::Vector{Any})
    validate_partial_struct(typ, undef, fields)
    Core._PartialStruct(typ, undef, fields)
end

function validate_partial_struct(@nospecialize(typ), undef, fields)
    @assert length(undef) ≥ length(fields)
    @assert isa(typ, DataType)
    if isdefined(@__MODULE__(), :datatype_min_ninitialized)
        @assert all(!undef[i] for i in 1:datatype_min_ninitialized(t))
    end
end

function Core.PartialStruct(@nospecialize(typ), fields::Vector{Any})
    nf = length(fields)
    fields[end] === Vararg && (nf -= 1)
    if isa(typ, DataType)
        fldcount = datatype_fieldcount(typ)
        undef = trues(fldcount)
        # if fldcount > nf
        #     fields = Any[get(fields, i, Any) for i in 1:fldcount]
        # end
        if isdefined(@__MODULE__(), :datatype_min_ninitialized)
            for i in 1:datatype_min_ninitialized(t)
                undef[i] = false
            end
        end
    else
        undef = trues(nf)
    end
    # if nfields === nothing || nfields == ndef
    #     undef = trues(ndef)
    # else
    #     @assert nfields > ndef
    #     undef = trues(nfields)
    #     for i in 1:ndef undef[i] = true end
    # end
    Core.PartialStruct(typ, undef, fields)
end

(==)(a::PartialStruct, b::PartialStruct) = a.typ === b.typ && a.undef == b.undef && a.fields == b.fields

function Base.getproperty(pstruct::Core.PartialStruct, name::Symbol)
    name === :undef && return getfield(pstruct, :undef)::BitVector
    getfield(pstruct, name)
end

"""
    struct InterConditional
        slot::Int
        thentype
        elsetype
    end

Similar to `Conditional`, but conveys inter-procedural constraints imposed on call arguments.
This is separate from `Conditional` to catch logic errors: the lattice element name is `InterConditional`
while processing a call, then `Conditional` everywhere else.
"""
Core.InterConditional

Core.InterConditional(var::SlotNumber, @nospecialize(thentype), @nospecialize(elsetype)) =
    InterConditional(slot_id(var), thentype, elsetype)
