using TandemRNG
using Documenter

DocMeta.setdocmeta!(TandemRNG, :DocTestSetup, :(using TandemRNG); recursive = true)

makedocs(;
    modules = [TandemRNG],
    authors = "Jessica Cox <jmcox@posteo.de>",
    sitename = "TandemRNG.jl",
    format = Documenter.HTML(;
        canonical = "https://BJMCox.github.io/TandemRNG.jl",
        edit_link = "main",
        assets = String[],
    ),
    pages = ["Home" => "index.md"],
)

deploydocs(; repo = "github.com/BJMCox/TandemRNG.jl", devbranch = "main")
