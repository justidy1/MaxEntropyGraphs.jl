##################################################################################
# models.jl
#
# This file contains model types and methods for the MaxEntropyGraphs.jl package
##################################################################################

"""
    AbstractMaxEntropyModel

An abstract type for a MaxEntropyModel. Each model has one or more structural constraints  
that are fixed while the rest of the network is completely random. 
"""
abstract type AbstractMaxEntropyModel end


"""
    UBCM

Maximum entropy model for the Undirected Binary Configuration Model (UBCM). 
    
The object holds the maximum likelihood parameters of the model (θ), the expected adjacency matrix (G), 
and the variance for the elements of the adjacency matrix (σ).
"""
mutable struct UBCM{T,N} <: AbstractMaxEntropyModel where {T<:Union{Graphs.AbstractGraph, Nothing}, N<:Real}
    "Graph type, can be any subtype of AbstractGraph, but will be converted to SimpleGraph for the computation" # can also be empty
    const G::T 
    "Maximum likelihood parameters for reduced model"
    const Θᵣ::Vector{N}
    "Exponentiated maximum likelihood parameters for reduced model ( xᵢ = exp(-θᵢ) )"
    const xᵣ::Vector{N}
    "Degree sequence of the graph" # evaluate usefulness of this field later on
    const d::Vector{Int}
    "Reduced degree sequence of the graph"
    const dᵣ::Vector{Int}
    "Frequency of each degree in the degree sequence"
    const f::Vector{Int}
    "Indices to reconstruct the degree sequence from the reduced degree sequence"
    const d_ind::Vector{Int}
    "Indices to reconstruct the reduced degree sequence from the degree sequence"
    const dᵣ_ind::Vector{Int}
    "Expected adjacency matrix" # not always computed/required
    Ĝ::Union{Nothing, Matrix{N}}
    "Variance of the expected adjacency matrix" # not always computed/required
    σ::Union{Nothing, Matrix{N}}
    "Status indicators: parameters computed, expected adjacency matrix computed, variance computed, etc."
    const status::Dict{Symbol, Any}
    "Function used to computed the log-likelihood of the (reduced) model"
    fun::Union{Nothing, Function}
end

Base.show(io::IO, m::UBCM{T,N}) where {T,N} = print(io, """UBCM{$(T), $(N)} ($(m.status[:d]) vertices, $(m.status[:d_unique]) unique degrees, $(@sprintf("%.2f", m.status[:cᵣ])) compression ratio)""")

"""Return the reduced number of nodes in the UBCM network"""
Base.length(m::UBCM) = length(m.dᵣ)


"""
    UBCM(G::T; precision::N=Float64, kwargs...) where {T<:Graphs.AbstractGraph, N<:Real}

Constructor function for the `UBCM` type. 
    
By default and dependng on the graph type `T`, the definition of degree from ``Graphs.jl`` is applied. 
If you want to use a different definition of degree, you can pass a vector of degrees as the second argument.
If you want to generate a model directly from a degree sequence without an underlying graph , you can simply pass the degree sequence as an argument.
If you want to work from an adjacency matrix, or edge list, you can use the graph constructors from the ``JuliaGraphs`` ecosystem.

# Examples     
```jldoctest
# generating a model from a graph
julia> G = Graphs.SimpleGraphs.smallgraph(:karate)
{34, 78} undirected simple Int64 graph
julia> model = UBCM(G)
UBCM{SimpleGraph{Int64}, Float64} (34 vertices, 11 unique degrees, 0.32 compression ratio)

# generating a model directly from a degree sequence
julia> model = UBCM([4;3;3;3;2])
UBCM{Nothing, Float64} (5 vertices, 3 unique degrees, 0.60 compression ratio)

# generating a model directly from a degree sequence with a different precision
julia> model = UBCM([4;3;3;3;2], precision=Float16)
UBCM{Nothing, Float16} (5 vertices, 3 unique degrees, 0.60 compression ratio)

# generating a model from an adjacency matrix
julia> A = [0 1 1;1 0 0;1 0 0];
julia> G = Graphs.SimpleGraph(A)
{3, 2} undirected simple Int64 graph
julia> model = UBCM(G)
UBCM{SimpleGraph{Int64}, Float64} (3 vertices, 2 unique degrees, 0.67 compression ratio)

# generating a model from an edge list
julia> E = [(1,2),(1,3),(2,3)];
julia> edgelist = [Graphs.Edge(x,y) for (x,y) in E];
julia> G = Graphs.SimpleGraphFromIterator(edgelist)
{3, 3} undirected simple Int64 graph
julia> model = UBCM(G)
UBCM{SimpleGraph{Int64}, Float64} (3 vertices, 1 unique degrees, 0.33 compression ratio)
```

See also [`Graphs.degree`](@ref), [`SimpleWeightedGraphs.degree`](@ref).
"""
function UBCM(G::T, d::Vector=Graphs.degree(G); precision::Type{<:AbstractFloat}=Float64, kwargs...) where {T}
    T <: Union{Graphs.AbstractGraph, Nothing} ? nothing : throw(TypeError("G must be a subtype of AbstractGraph or Nothing"))
    # coherence checks
    if T <: Graphs.AbstractGraph # Graph specific checks
        if Graphs.is_directed(G)
            @warn "The graph is directed, the UBCM model is undirected, the directional information will be lost"
        end

        if T <: SimpleWeightedGraphs.AbstractSimpleWeightedGraph
            @warn "The graph is weighted, the UBCM model is unweighted, the weight information will be lost"
        end

        if zero(eltype(d)) ∈ d
            @warn "The graph has vertices with zero degree, this may lead to convergence issues."
        end

        Graphs.nv(G) == 0 ? throw(ArgumentError("The graph is empty")) : nothing
        Graphs.nv(G) == 1 ? throw(ArgumentError("The graph has only one vertex")) : nothing

        Graphs.nv(G) != length(d) ? throw(DimensionMismatch("The number of vertices in the graph ($(Graphs.nv(G))) and the length of the degree sequence ($(length(d))) do not match")) : nothing
    end
    # coherence checks specific to the degree sequence
    length(d) == 0 ? throw(ArgumentError("The degree sequence is empty")) : nothing
    length(d) == 1 ? throw(ArgumentError("The degree sequence has only one degree")) : nothing
    maximum(d) >= length(d) ? throw(DomainError("The maximum degree in the graph is greater or equal to the number of vertices, this is not allowed")) : nothing

    # field generation
    dᵣ, d_ind , dᵣ_ind, f = np_unique_clone(d, sorted=true)
    Θᵣ = Vector{precision}(undef, length(dᵣ))
    xᵣ = Vector{precision}(undef, length(dᵣ))
    status = Dict(  :params_computed=>false,        # are the parameters computed?
                    :G_computed=>false,             # is the expected adjacency matrix computed and stored?
                    :σ_computed=>false,             # is the standard deviation computed and stored?
                    :cᵣ => length(dᵣ)/length(d),    # compression ratio of the reduced model
                    :d_unique => length(dᵣ),        # number of unique degrees in the reduced model
                    :d => length(d)                 # number of vertices in the original graph 
                )
    
    return UBCM{T,precision}(G, Θᵣ, xᵣ, d, dᵣ, f, d_ind, dᵣ_ind, nothing, nothing, status, nothing)
end

UBCM(d::Vector{T}; precision::Type{<:AbstractFloat}=Float64, kwargs...) where {T<:Signed} = UBCM(nothing, d; precision=precision, kwargs...)


"""
    L_UBCM_reduced(θ::Vector, K::Vector, F::Vector)

Compute the log-likelihood of the reduced UBCM model using the exponential formulation in order to maintain convexity.

The arguments of the function are:
- `θ`: the maximum likelihood parameters of the model
- `K`: the reduced degree sequence
- `F`: the frequency of each degree in the degree sequence

The function returns the log-likelihood of the reduced model. For the optimisation, this function will be used to
generate an anonymous function associated with a specific model.

# Examples
```jldoctest
# Generic use:
julia> θ = [1.0, 2.0, 3.0, 4.0, 5.0];
julia> K = [1, 2, 3, 4, 5];
julia> F = [1, 2, 3, 4, 5];
julia> L_UBCM_reduced(θ, K, F)

# Use with UBCM model:
julia> G = Graphs.SimpleGraphs.smallgraph(:karate);
julia> model = UBCM(G);
julia> model_fun = θ -> L_UBCM_reduced(θ, model.dᵣ, model.f)
julia> model_fun(model.Θᵣ)
```
"""
function L_UBCM_reduced(θ::Vector, K::Vector, F::Vector)
    res = - sum(θ .* K .* F)
    for k in eachindex(K)
        @simd for k′ in eachindex(K)
            if k′ ≤ k
                if k == k′
                    @inbounds res -= F[k] * (F[k] - 1) * log(1 + exp(- θ[k] - θ[k′]) ) * .5 # to avoid counting it twice
                else
                    @inbounds res -= F[k] * F[k′]      * log(1 + exp(- θ[k] - θ[k′]) )
                end
                #@inbounds res -= F[k] * (F[k′] - (k==k′ ? 1. : 0.)) * log(1 + exp(- θ[k] - θ[k′]) ) * (k==k′ ? .5 : 1.) 
            end
        end
    end
    return res
end


"""
    ∇L_UBCM_reduced()

Compute the gradient of the log-likelihood of the reduced UBCM model using the exponential formulation in order to maintain convexity.

For the optimisation, this function will be used togenerate an anonymous function associated with a specific model.
"""
∇L_UBCM_reduced() = throw(MethodError("The gradient of the log-likelihood of the reduced UBCM model has not been implemented yet"))

"""
    set_xᵣ!(m::UBCM)

Set the value of xᵣ to exp(-θᵣ) for the UBCM model `m`
"""
function set_x!(m::UBCM)
    if m.status[:params_computed]
        m.xᵣ .= exp.(-m.Θᵣ)
    else
        throw(UndefRefError("The parameters have not been computed yet"))
    end
end

"""
    set_Ĝ!(m::UBCM)

Set the expected adjacency matrix for the UBCM model `m`
"""
function set_Ĝ!(m::UBCM)
    m.Ĝ .= Ĝ(m)
end

"""
    Ĝ(m::UBCM)

Compute the expected adjacency matrix for the UBCM model `m`
"""
function Ĝ(m::UBCM{T,N}) where {T,N}
    # check if possible
    m.status[:params_computed] ? nothing : throw(UndefRefError("The parameters have not been computed yet"))
    # check network size
    n = length(m.status[:d])
    # initiate G
    G = zeros(N, n, n)
    # initiate x
    x = m.xᵣ[m.dᵣ_ind]
    # compute G
    for i = 1:n
        @simd for j = i+1:n
            @inbounds xij = x[i]*x[j]
            @inbounds G[i,j] = xij/(1 + xij)
            @inbounds G[j,i] = xij/(1 + xij)
        end
    end

    return G    
end


"""
    set_σ!(m::UBCM)

Set the standard deviation for the elements of the adjacency matrix for the UBCM model `m`
"""
function set_σ!(m::UBCM)
    m.σ .= σˣ(m)
end

"""
    σˣ(m::UBCM{T,N}) where {T,N}

Compute the standard deviation for the elements of the adjacency matrix for the UBCM model `m`.

**Note:** read as "sigma star"
"""
function σˣ(m::UBCM{T,N}) where {T,N}
    # check if possible
    m.status[:params_computed] ? nothing : throw(UndefRefError("The parameters have not been computed yet"))
    # check network size
    n = length(m.status[:d])
    # initiate G
    σ = zeros(N, n, n)
    # initiate x
    x = m.xᵣ[m.dᵣ_ind]
    # compute σ
    for i = 1:n
        @simd for j = i+1:n
            @inbounds xij =  x[i]*x[j]
            @inbounds res[i,j] = sqrt(xij)/(1 + xij)
            @inbounds res[j,i] = sqrt(xij)/(1 + xij)
        end
    end

    return σ
end




solve_model(::T, method::Symbol) where {T<:AbstractMaxEntropyModel} = throw(MethodError("The model type $(T) is not implemented yet"))





"""
    Ĝ(m::UBCM)


# G = MODELS.Graphs.SimpleGraphs.smallgraph(:karate)
# model = MODELS.UBCM(G,)

# G = Graphs.SimpleDiGraph(5)
# nv(G)
# res = MODELS.UBCM(G, precision=Float16)
# res = MODELS.UBCM(G, [4;3;3;3;2])
# res.Θᵣ, res.dᵣ

# res.dᵣ[res.dᵣ_ind] == res.d
# res.Θᵣ[res.dᵣ_ind]
# res.Θᵣ
# """
# Idea: starting from models with known parameters:
# - obtain expected values and variances for adjacency/weight matrix elements
# - sample networks, returning 
#     1. Adjacency matrix (dense/ sparse (ULT)) 
#     2. Graph 
#     3. Adjacency List & node number
# - compute z-scores of different metrics by 
#     1. "exact" method 
#     2. sampling method
# """
# #= run this once at startup
# if Sys.islinux()
#     ENV["GRDIR"] = "" # for headless plotting
#     using Pkg; Pkg.build("GR")
#     # sudo apt install xvfb
#     # https://gr-framework.org/julia.html#installation
#     import GR:inline
#     GR.inline("pdf")
#     GR.inline("png")
# end
# =#


# # ----------------------------------------------------------------------------------------------------------------------
# #
# #                                               General model
# #
# # ----------------------------------------------------------------------------------------------------------------------



# """
#     σ(::AbstractMaxEntropyModel)

# Compute variance for elements of the adjacency matrix for the specific `AbstractMaxEntropyModel` based on the ML parameters.
# """
# σ(::AbstractMaxEntropyModel) = nothing


# """
#     Ĝ(::AbstractMaxEntropyModel)

# Compute expected adjacency and/or weight matrix for a given `AbstractMaxEntropyModel`
# """
# Ĝ(::AbstractMaxEntropyModel) = nothing


# """
#     rand(::AbstractMaxEntropyModel)

# Sample a random network from the `AbstractMaxEntropyModel`
# """
# Base.rand(::AbstractMaxEntropyModel) = nothing

# """
#     ∇X(X::Function, M::T)

# Compute the gradient of a property `X` with respect to the expected adjacency matrix associated with the model `M`.
# """
# ∇X(X::Function, M::T) where T <: AbstractMaxEntropyModel = ReverseDiff.gradient(X, M.G)


# """
#     σˣ(X::Function, M::T)

# Compute the standard deviation of a property `X` with respect to the expected adjacency matrix associated with the model `M`.
# """
# σˣ(X::Function, M::T) where T <: AbstractMaxEntropyModel = nothing

# # ----------------------------------------------------------------------------------------------------------------------
# #
# #                                               UBCM model
# #
# # ----------------------------------------------------------------------------------------------------------------------

# """
#     UBCM

# Maximum entropy model for the Undirected Binary Configuration Model (UBCM). 
    
# The object holds the maximum likelihood parameters of the model (x), the expected adjacency matrix (G), 
# and the variance for the elements of the adjacency matrix (σ).

# """
# struct UBCM{T} <: AbstractMaxEntropyModel where {T<:Real}
#     x::Vector{T}
#     G::Matrix{T}
#     σ::Matrix{T}
# end



# """
#     UBCM(x::Vector{T}; compute::Bool=true) where {T<:Real}

# Constructor for the `UBCM` type.
# """
# function UBCM(x::Vector{T}) where {T<:Real}
#     G = Ĝ(x, UBCM{T})  # expected adjacency matrix
#     σ = σˣ(x, UBCM{T}) # expected standard deviation matrix

#     return UBCM(x, G, σ)
# end

# """
#     UBCM(G::T) where T<:SimpleGraph

# Constructor for the `UBCM` type based on a `SimpleGraph`. 
# """
# function UBCM(G::T; method="fixed-point", initial_guess="degrees", max_steps=5000, tol=1e-12, kwargs...) where T<:Graphs.SimpleGraph
#     NP = PyCall.pyimport("NEMtropy")
#     G_nem = NP.UndirectedGraph(degree_sequence=Graphs.degree(G))
#     G_nem.solve_tool(model="cm_exp", method=method, initial_guess=initial_guess, max_steps=max_steps, tol=tol, kwargs...);
#     if G_nem.error > 1e-7
#         @warn "The model did not converge, maybe try some other options (solution error $(G_nem.error))"
#     end
#     return UBCM(G_nem.x)
# end

# """
#     Ĝ(::UBCM, x::Vector{T}) where {T<:Real}

# Compute the expected adjacency matrix for the UBCM model with maximum likelihood parameters `x`.
# """
# function Ĝ(x::Vector{T}, ::Type{UBCM{T}}) where T
#     n = length(x)
#     G = zeros(T, n, n)
#     for i = 1:n
#         @simd for j = i+1:n
#             @inbounds xij = x[i]*x[j]
#             @inbounds G[i,j] = xij/(1 + xij)
#             @inbounds G[j,i] = xij/(1 + xij)
#         end
#     end
    
#     return G
# end

# """
#     σˣ(x::Vector{T}, ::Type{UBCM{T}}) where T

# Compute the standard deviation for the elements of the adjacency matrix for the UBCM model using the maximum likelihood parameters `x`.

# **Note:** read as "sigma star"
# """
# function σˣ(x::Vector{T}, ::Type{UBCM{T}}) where T
#     n = length(x)
#     res = zeros(T, n, n)
#     for i = 1:n
#         @simd for j = i+1:n
#             @inbounds xij =  x[i]*x[j]
#             @inbounds res[i,j] = sqrt(xij)/(1 + xij)
#             @inbounds res[j,i] = sqrt(xij)/(1 + xij)
#         end
#     end

#     return res
# end

# """
#     rand(m::UBCM)

# Generate a random graph from the UBCM model. The function returns a `Graphs.AbstractGraph` object.
# """
# function Base.rand(m::UBCM)
#     n = length(m)
#     g = Graphs.SimpleGraph(n)
#     for i = 1:n
#         for j = i+1:n
#             if rand() < m.G[i,j]
#                 Graphs.add_edge!(g, i, j)
#             end
#         end
#     end

#     return g
# end


# """
#     σˣ(X::Function, M::UBCM{T})

# Compute the standard deviation of a property `X` with respect to the expected adjacency matrix associated with the UBCM model `M`.
# """
# σˣ(X::Function, M::UBCM{T}) where T = sqrt( sum((M.σ .* ∇X(X, M)) .^ 2) )



# # ----------------------------------------------------------------------------------------------------------------------
# #
# #                                               DBCM model
# #
# # ----------------------------------------------------------------------------------------------------------------------

# """
#     DBCM

# Maximum entropy model for the Directed Binary Configuration Model (DBCM). 
    
# The object holds the maximum likelihood parameters of the model (x, y), the expected adjacency matrix (G), 
# and the variance for the elements of the adjacency matrix (σ).

# """
# struct DBCM{T} <: AbstractMaxEntropyModel where {T<:Real}
#     x::Vector{T}
#     y::Vector{T}
#     G::Matrix{T}
#     σ::Matrix{T}
# end

# Base.show(io::IO, m::DBCM{T}) where T = print(io, "$(T) DBCM model ($(length(m)) vertices)")

# """Return the number of nodes in the DBCM network"""
# Base.length(m::DBCM) = length(m.x)

# """
#     DBCM(x::Vector{T}, y::Vector{T}; compute::Bool=true) where {T<:Real}

# Constructor for the `DBCM` type. If `compute` is true, the expected adjacency matrix and variance are computed. 
# Otherwise the memory is allocated but not initialized. (TBC)
# """
# function DBCM(x::Vector{T}, y::Vector{T}; compute::Bool=true) where {T<:Real}
#     G = Ĝ( x, y, DBCM{T}) # expected adjacency matrix
#     σ = σˣ(x, y, DBCM{T}) # expected standard deviation matrix

#     return DBCM(x, y, G, σ)
# end

# """
#     DBCM(G::T) where T<:SimpleDiGraph

# Constructor for the `DBCM` type based on a `SimpleDiGraph`. 
# """
# function DBCM(G::T; method="fixed-point", initial_guess="degrees", max_steps=5000, tol=1e-12, kwargs...) where T<:Graphs.SimpleDiGraph
#     NP = PyCall.pyimport("NEMtropy")
#     G_nem =  NP.DirectedGraph(degree_sequence=vcat(Graphs.outdegree(G), Graphs.indegree(G)))
#     G_nem.solve_tool(model="dcm_exp"; method=method, initial_guess=initial_guess, max_steps=max_steps, tol=tol, kwargs...);
#     if G_nem.error > 1e-7
#         @warn "The model did not converge, maybe try some other options (solution error $(G_nem.error))"
#     end
#     return DBCM(G_nem.x, G_nem.y)
# end

# """
#     Ĝ(x::Vector{T}, y::Vector{T}, ::Type{DBCM{T}}) where {T<:Real}

# Compute the expected adjacency matrix for the `DBCM` model with maximum likelihood parameters `x` and `y`.
# """
# function Ĝ(x::Vector{T}, y::Vector{T}, ::Type{DBCM{T}}) where T
#     n = length(x)
#     G = zeros(T, n, n)
#     for i = 1:n
#         @simd for j = i+1:n
#             @inbounds xiyj = x[i]*y[j]
#             @inbounds xjyi = x[j]*y[i]
#             @inbounds G[i,j] = xiyj/(1 + xiyj)
#             @inbounds G[j,i] = xjyi/(1 + xjyi)
#         end
#     end
    
#     return G
# end

# """
#     σˣ(x::Vector{T}, y::Vector{T}, ::Type{DBCM{T}}) where T

# Compute the standard deviation for the elements of the adjacency matrix for the `DBCM` model using the maximum likelihood parameters `x` and `y`.

# **Note:** read as "sigma star"
# """
# function σˣ(x::Vector{T}, y::Vector{T}, ::Type{DBCM{T}}) where T
#     n = length(x)
#     res = zeros(T, n, n)
#     for i = 1:n
#         @simd for j = i+1:n
#             @inbounds xiyj =  x[i]*y[j]
#             @inbounds xjyi =  x[j]*y[i]
#             @inbounds res[i,j] = sqrt(xiyj)/(1 + xiyj)
#             @inbounds res[j,i] = sqrt(xjyi)/(1 + xjyi)
#         end
#     end

#     return res
# end

# """
#     rand(m::DBCM)

# Generate a random graph from the `DBCM` model. The function returns a `Graphs.AbstractGraph` object.
# """
# function Base.rand(m::DBCM)
#     n = length(m)
#     g = Graphs.SimpleDiGraph(n)
#     for i = 1:n
#         for j = i+1:n
#             if rand() < m.G[i,j]
#                 Graphs.add_edge!(g, i, j)
#             end
#             if rand() < m.G[j,i]
#                 Graphs.add_edge!(g, j, i)
#             end
#         end
#     end

#     return g
# end

# """
#     σˣ(X::Function, M::DBCM{T})

# Compute the standard deviation of a property `X` with respect to the expected adjacency matrix associated with the `DBCM` model `M`.
# """
# σˣ(X::Function, M::DBCM{T}) where T = sqrt( sum((M.σ .* ∇X(X, M)) .^ 2) )

