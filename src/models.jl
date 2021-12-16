"""
    AbstractMaxEntropyModel

An abstract type for a MaxEntropyModel. Each model has one or more structural constraints  
that are fixed while the rest of the network is completely random.
"""
abstract type AbstractMaxEntropyModel end

"""
    UBCM{T,N} <: AbstractMaxEntropyModel where {T<:Real, N<:UInt}

# Undirected Binary Configuration Model (UBCM)
Maximum entropy model with a fixed degree sequence. Uses the model where ``x_i = e^{-\\theta_i}```

See also: [AbstractMaxEntropyModel](@ref)
"""
mutable struct UBCM{T,N} <: AbstractMaxEntropyModel where {T<:Real, N<:UInt}
    idx::Vector{N}
    κ::Vector{T}
    f::Vector{T} #Dict{T,T}
    method::Symbol
    x0::Vector{T} # initial guess
    F::Vector{T}  # buffer for solution
    f!::Function  # function that will need to be solved
    xs::Vector{T} # solution vector
    x::IndirectArray{T,1, N, Vector{N}, Vector{T}}  # solution vector expanded
end

	Base.show(io::IO, model::UBCM{T,N}) where {T,N} = print(io, """UBCM{$(T)} model ($(length(model.κ) < length(model.idx)  ? "$(round((1- length(model.κ)/length(model.idx)) * 100,digits=2))% compression in $(N)" : "uncompressed"))""")
	
	function UBCM(k::Vector{T}; compact::Bool=true, 
	                            P::DataType=Float64,
								method::Symbol=:newton,
								initial::Union{Symbol, Vector{T}}=:nodes, kwargs...) where {T<:Int}
		# check input
		method ∈ [:newton, :fixedpoint] ? nothing : throw(ArgumentError("'$(method)' is not a valid solution method"))
		
		
	    # convert datatypes
		k = convert.(P, k) 
		
		# compress or not
		if compact
			idxtype = length(unique(k)) < typemax(UInt8) ? UInt8 : length(unique(k)) < typemax(UInt16) ? UInt16 : UInt32 # limited to 4.29e9 nodes
			idx, κ = IndirectArray{idxtype}(k).index, IndirectArray{idxtype}(k).values
			f = countmap(k, ones(P, size(k))) # using weight vector for proper type inference
            f = [f[v] for v in κ] # addition
		else
			κ = k
			idxtype = length(κ) < typemax(UInt8) ? UInt8 : length(κ) < typemax(UInt16) ? UInt16 : UInt32 # limited to 4.29e9 nodes
			idx = collect(one(idxtype):idxtype(length(κ)))
			f = ones(P,length(κ)) #     Dict(v => one(P) for v in κ)
		end

		# initial vector
		if isa(initial, Vector)
			length(initial) == length(κ) ? nothing : throw(DimensionMismatch("Length of initial vector $(length(initial)) does not match the length of κ $(length(κ))"))
			x0 = P.(initial)
		
		elseif isa(initial, Symbol)
			initial ∈ [:links, :nodes,:random] ? nothing : throw(ArgumentError("'$(initial)' is not a valid initial argument method"))
			if isequal(initial, :nodes)
				x0 = κ ./ P(sqrt(length(κ)))
			elseif isequal(initial, :links)
				x0 = κ ./ P(sqrt(2 * get(kwargs, :L, length(κ))))
			elseif isequal(initial, :random)
				x0 = rand(P, length(κ))
			end
		end

		# functions to compute
		if isequal(method, :newton)
			f! = (F::Vector, x::Vector) -> ∂UBCM_∂x!(F, x, κ, f)
		elseif isequal(method, :fixedpoint)
			f! = (F::Vector, x::Vector) -> ∂UBCM_∂x_it!(F, x, κ, f)
		end

		# buffers (required?)
		F = similar(x0) # modify in place method
		xs = similar(x0) # solution value

		# outresult with indirect indexing for further use
		x = IndirectArray(idx, xs)
		
	
		return UBCM(idx, κ, f, method, x0, F, f!, xs, x)
	end
	
"""
	∂UBCM_∂x!(F::Vector, x::Vector, κ::Vector, f::Vector)

Gradient of likelihood function of the UBCM model using the `x_i` formulation. 

F value of gradients
x value of parameters
κ value of (reduced degree vector)
f frequency associated with each value in κ 

## see also [`UBCM``](@ref)
"""
function ∂UBCM_∂x!(F::Vector, x::Vector, κ::Vector, f::Vector)
    @tturbo for i in eachindex(x)
        fx = -x[i] / (1 + x[i] * x[i])
        for j in eachindex(x)
                fx += f[j] * x[j] / (1 + x[j] * x[i])
        end
        
        F[i] = κ[i] / fx
    end
    
    return F
end

function iterative_cm!(F::Vector{T}, x::Vector{T}, κ::Vector{T}, f::Vector{T}) where {T}
    @tturbo for i in eachindex(x)
        fx = -x[i] / (1 + x[i] * x[i])
        for j in eachindex(x)
                fx += f[j] * x[j] / (1 + x[j] * x[i])
        end
        
        F[i] = κ[i] / fx
    end
    
    return F
end

function solve(model::T; kwargs...) where T <: AbstractMaxEntropyModel
	if isequal(model.method, :newton)
		df = OnceDifferentiable(model.f!, model.x0, model.F)
		res = nlsolve(df, model.x0; kwargs...)
	elseif isequal(model.method, :fixedpoint)
		res = fixedpoint(model.f!, model.x0; kwargs...)
	end
		
	return res
end



"""
    DBCM{T,N} <: AbstractMaxEntropyModel where {T<:Real, N<:UInt}

# Directed Binary Configuration Model (DBCM)
Maximum entropy model with a fixed in- and outdegree sequence. 
"""
mutable struct DBCM{T,N} <: AbstractMaxEntropyModel where {T<:Real, N<:UInt} end