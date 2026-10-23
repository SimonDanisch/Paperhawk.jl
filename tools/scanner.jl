# julia --project=. dev/Paperhawk/tools/scanner.jl [--gpu NAME] [--classify] [--no-torch] [draft-dir] [archive-dir]
#
# Opens the scanner and returns when its window is closed. `--gpu` names the
# GPU by a part of its name, as `--gpu "RTX 4000"`; without it the best one is
# taken. `--classify` lets the local LLM summarise archived documents.
using Paperhawk

function main(args = ARGS)
    i = findfirst(==("--gpu"), args)
    select = i === nothing ? Paperhawk.anygpu : args[i + 1]
    rest = i === nothing ? args : args[setdiff(eachindex(args), (i, i + 1))]
    paths = filter(!startswith("--"), rest)
    scanner(; select, classify = "--classify" in rest, camera_torch = !("--no-torch" in rest),
        dir = isempty(paths) ? nothing : paths[1],
        archive = length(paths) >= 2 ? paths[2] : Paperhawk.data_dir("archiv"))
end

main()
