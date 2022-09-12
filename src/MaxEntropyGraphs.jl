"""
    MaxEntropyGraphs

Julia module for working with maximum entropy graphs
"""
module MaxEntropyGraphs
    import Base: show, rand
    import Dates: now, Day, Minute  # for logmessages
    
    import Distributions
    import Graphs
    import PyCall                   # for calling NEMtropy package in Python, dependency should be removed in a future version
    import ReverseDiff              # for gradient
    import StatsBase: mean, std     # for mean and standard deviation
    import JLD                      # for saving and loading models
    
    include("models.jl")
    include("metrics.jl")
    include("utils.jl")
    
    # models
    export AbstractMaxEntropyModel, UBCM, DBCM
    export rand
    export σˣ

    # metrics
    export degree, indegree, outdegree, indegree_dist, outdegree_dist
    export ANND, ANND_in, ANND_out
    for foo in DBCM_motif_function_names
        @eval begin
        export $(foo)
        end
    end
    export motifs

    # utils
    export DBCM_analysis

end


    #import Statistics: std, mean    # for statistics
    #import Printf: @sprintf         # for specific printing
#using Plots                     # for plotting
#using Measures                  # for margin settings
#using LaTeXStrings              # for LaTeX printing

#using GraphIO                   # to read and write external graphs
#using JLD2                      # for data storage
#using Distributions, HypothesisTests
#import Graphs: degree
#import LinearAlgebra: diagind
#import StatsBase: countmap


# using SimpleWeightedGraphs

#using NLsolve
#using IndirectArrays
#using LoopVectorization
# MODELS

# METRICS
#export degree



#include("metrics.jl")
#end # module
