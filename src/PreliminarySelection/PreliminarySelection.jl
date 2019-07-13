module PreliminarySelection

    using GLMNet
    using ..GlobalSearchRegression

    include("const.jl")
    include("utils.jl")
    include("strings.jl")
    include("core.jl")

    export lasso, lassoselection
end