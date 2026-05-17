"""
Cache directory management for Slocum sensor-list cache files (`.cac`).

Unlike `dbdreader.py` (which mutates global state at module import and creates
directories as a side effect), this module is explicit and side-effect-free
at import time.  Cache directories are created only when actually needed.
"""

"""
    default_cachedir() -> String

Platform-appropriate default cache directory path.  Does NOT create it.

- Linux: `~/.local/share/JLDBDReader/cache`
- macOS: `~/Library/Caches/JLDBDReader`
- Windows: `%LOCALAPPDATA%\\JLDBDReader\\cache`
- Other: `~/.JLDBDReader/cache`
"""
function default_cachedir()::String
    home = homedir()
    if Sys.islinux()
        return joinpath(home, ".local", "share", "JLDBDReader", "cache")
    elseif Sys.isapple()
        return joinpath(home, "Library", "Caches", "JLDBDReader")
    elseif Sys.iswindows()
        appdata = get(ENV, "LOCALAPPDATA", joinpath(home, "AppData", "Local"))
        return joinpath(appdata, "JLDBDReader", "cache")
    else
        return joinpath(home, ".JLDBDReader", "cache")
    end
end

"""
    candidate_cachedirs(user::Union{Nothing,AbstractString}) -> Vector{String}

Build a list of cache directories to search, in priority order:

1. User-provided directory (if any)
2. `./cache` relative to current working directory
3. `cache` next to the data file (added at lookup time)
4. The platform default directory

The first existing directory that contains the requested `.cac` file wins.
"""
function candidate_cachedirs(user::Union{Nothing,AbstractString})::Vector{String}
    dirs = String[]
    if user !== nothing
        push!(dirs, String(user))
    end
    push!(dirs, joinpath(pwd(), "cache"))
    push!(dirs, default_cachedir())
    return dirs
end

"""
    find_cache_file(crc, cachedir, data_filename=nothing) -> Union{String,Nothing}

Search for a cache file `<crc>.cac` (or its compressed form `<crc>.ccc`).
Returns the resolved path or `nothing` if not found anywhere.
"""
function find_cache_file(crc::AbstractString,
                        cachedir::Union{Nothing,AbstractString}=nothing,
                        data_filename::Union{Nothing,AbstractString}=nothing)::Union{String,Nothing}
    candidates = candidate_cachedirs(cachedir)
    # Add cache dir next to data file
    if data_filename !== nothing
        push!(candidates, joinpath(dirname(abspath(data_filename)), "cache"))
        push!(candidates, dirname(abspath(data_filename)))
    end
    for dir in candidates
        for ext in (".cac", ".ccc")
            p = joinpath(dir, lowercase(crc) * ext)
            isfile(p) && return p
        end
    end
    return nothing
end

"""
    ensure_cachedir(path) -> String

Ensure the given cache directory exists, creating it if necessary.  Returns
the absolute path.  Use when you actually intend to write a cache file.
"""
function ensure_cachedir(path::AbstractString)::String
    abs = abspath(path)
    isdir(abs) || mkpath(abs)
    return abs
end
