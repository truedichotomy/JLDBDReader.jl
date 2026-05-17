"""
Multi-file Slocum glider data reader.

`MultiDBD` opens and manages a set of related glider files (engineering and
science computer outputs from the same deployment) and provides unified
access by parameter name.  Data is concatenated across files in chronological
order.

Key differences from `dbdreader.MultiDBD`:
- No global state mutation.
- File pairing (eng↔sci) is explicit and lazy.
- Time-limit filtering is applied at read time, not on metadata-only.
- Missing files do not exit the process; they are skipped with a warning.
"""

# ── Filename sorting (handles Slocum's `name-YYYY-DDD-S-FFFF.ext` format) ────

const _DBD_FILENAME_RE = r"-(\d+)-(\d+)-(\d+)-(\d+)\.[a-zA-Z]{3}$"

"""
Compute a sort key for Slocum filenames such that chronological order is
preserved.  Handles both `name-YYYY-DDD-S-FFFF.ext` and 8x3 `NNNNNNNN.ext`
forms; the latter sorts lexicographically.
"""
function _slocum_sort_key(filename::AbstractString)
    m = match(_DBD_FILENAME_RE, filename)
    if m !== nothing
        nums = parse.(Int, m.captures)
        base = filename[1:m.offset-1]
        ext = lowercase(splitext(filename)[2])
        return (base, nums[1]*10^8 + nums[2]*10^5 + nums[3]*10^3 + nums[4], ext)
    else
        return (lowercase(filename), 0, "")
    end
end

sort_slocum!(filenames::AbstractVector) = sort!(filenames; by=_slocum_sort_key)

# ── Glob helper ───────────────────────────────────────────────────────────────

"""
Expand a glob-like pattern (`*`, `?`, character classes) into a sorted list
of matching paths.  Uses Julia's stdlib only; no Glob.jl dependency.
"""
function glob_files(pattern::AbstractString)::Vector{String}
    dir = dirname(pattern)
    base = basename(pattern)
    isempty(dir) && (dir = ".")
    isdir(dir) || return String[]
    # Translate glob to regex
    re_buf = IOBuffer()
    for c in base
        if c == '*'
            write(re_buf, ".*")
        elseif c == '?'
            write(re_buf, '.')
        elseif c == '.'
            write(re_buf, "\\.")
        elseif c == '[' || c == ']'
            write(re_buf, c)
        else
            write(re_buf, c)
        end
    end
    re = Regex("^" * String(take!(re_buf)) * "\$")
    files = [joinpath(dir, f) for f in readdir(dir) if occursin(re, f)]
    return sort_slocum!(files)
end

# ── Eng/Sci file pairing ──────────────────────────────────────────────────────

"""
Given an extension like `.dbd`, return the matching science-computer
extension `.ebd` (or vice versa).  Encoding-wise this is a simple +1/-1 on
the first letter (`d`↔`e`, `s`↔`t`, `m`↔`n`).
"""
function paired_extension(ext::AbstractString)::String
    e = lowercase(ext)
    startswith(e, ".") || (e = "." * e)
    chars = collect(e)
    sci = is_science_extension(e)
    chars[2] = sci ? Char(UInt32(chars[2]) - 1) : Char(UInt32(chars[2]) + 1)
    return String(chars)
end

paired_filename(fn::AbstractString) =
    splitext(fn)[1] * paired_extension(splitext(fn)[2])

# ── MultiDBD type ─────────────────────────────────────────────────────────────

"""
    MultiDBD

A collection of opened DBD files, partitioned by data source (engineering vs
science computer), supporting unified parameter access across all of them.

Construct via:
```julia
m = MultiDBD(filenames=["a.dbd", "b.dbd", ...], cachedir="./cache")
m = MultiDBD(pattern="data/*.dbd",              cachedir="./cache")
```
"""
struct MultiDBD
    files_eng::Vector{DBDFile}
    files_sci::Vector{DBDFile}
    cachedir::Union{Nothing,String}
    mission_names::Vector{String}
    all_param_names_eng::Set{String}
    all_param_names_sci::Set{String}
    time_range::Tuple{Float64,Float64}    # (t_min, t_max) from headers
    skip_initial_line::Bool
end

"""
    MultiDBD(; filenames=nothing, pattern=nothing, cachedir=nothing,
              complement_files=false, complemented_files_only=false,
              banned_missions=String[], missions=String[],
              max_files=nothing, skip_initial_line=true) -> MultiDBD

Build a multi-file reader.

# Keyword arguments
- `filenames` : explicit list of paths.
- `pattern`   : glob pattern (e.g., `"data/*.[dDsS][bB][dD]"`).
- `cachedir`  : cache directory (or `nothing` to use defaults).
- `complement_files`         : auto-add matching eng↔sci pairs.
- `complemented_files_only`  : keep only files that have a matching pair.
- `banned_missions`          : skip files whose `mission_name` is in this list.
- `missions`                 : keep only files whose `mission_name` is in this list.
- `max_files`                : limit number of files (positive = first N, negative = last N).
- `skip_initial_line`        : pass through to per-file reader (default `true`).
"""
function MultiDBD(; filenames::Union{Nothing,Vector{<:AbstractString}}=nothing,
                    pattern::Union{Nothing,AbstractString}=nothing,
                    cachedir::Union{Nothing,AbstractString}=nothing,
                    complement_files::Bool=false,
                    complemented_files_only::Bool=false,
                    banned_missions::Vector{String}=String[],
                    missions::Vector{String}=String[],
                    max_files::Union{Nothing,Int}=nothing,
                    skip_initial_line::Bool=true)

    filenames === nothing && pattern === nothing &&
        error("MultiDBD: provide `filenames` or `pattern`.")

    # Gather initial file list
    fns = String[]
    filenames === nothing || append!(fns, String.(filenames))
    pattern === nothing   || append!(fns, glob_files(String(pattern)))
    unique!(fns)
    isempty(fns) && error("MultiDBD: no files found.")
    sort_slocum!(fns)

    # max_files trimming
    if max_files !== nothing
        n = length(fns)
        if max_files > 0
            fns = fns[1:min(max_files, n)]
        elseif max_files < 0
            fns = fns[max(1, n + max_files + 1):end]
        end
    end

    # File complementing
    if complement_files
        extras = String[]
        for f in fns
            mf = paired_filename(f)
            if isfile(mf) && !(mf in fns)
                push!(extras, mf)
            end
        end
        append!(fns, extras)
        sort_slocum!(fns)
    end
    if complemented_files_only
        filter!(f -> isfile(paired_filename(f)), fns)
    end

    # Open each file
    eng = DBDFile[]
    sci = DBDFile[]
    miss = String[]
    names_eng = Set{String}()
    names_sci = Set{String}()
    tmin = Inf
    tmax = -Inf

    for f in fns
        local dbd::DBDFile
        try
            dbd = open_dbd(f; cachedir=cachedir)
        catch e
            @warn "Skipping $(basename(f)): $(sprint(showerror, e))"
            continue
        end
        mname = lowercase(dbd.header.mission_name)
        mname in banned_missions && (continue)
        !isempty(missions) && !(mname in missions) && (continue)
        mname in miss || push!(miss, mname)
        if is_science_file(f)
            push!(sci, dbd)
            for s in dbd.sensors
                push!(names_sci, s.name)
            end
        else
            push!(eng, dbd)
            for s in dbd.sensors
                push!(names_eng, s.name)
            end
        end
        t = parse_fileopen_time(dbd.header.fileopen_time)
        if isfinite(t)
            t < tmin && (tmin = t)
            t > tmax && (tmax = t)
        end
    end

    isempty(eng) && isempty(sci) && error("MultiDBD: no files could be opened.")

    return MultiDBD(eng, sci, cachedir === nothing ? nothing : String(cachedir),
                    miss, names_eng, names_sci,
                    (tmin, tmax), skip_initial_line)
end

"""
    nfiles(m) -> Int

Total number of opened files across both data sources.
"""
nfiles(m::MultiDBD) = length(m.files_eng) + length(m.files_sci)

"""
    parameter_names(m, source=:both) -> Vector{String}

Sorted list of all parameter names available.  `source` is `:eng`, `:sci`,
or `:both`.
"""
function parameter_names(m::MultiDBD, source::Symbol=:both)::Vector{String}
    if source == :eng
        return sort!(collect(m.all_param_names_eng))
    elseif source == :sci
        return sort!(collect(m.all_param_names_sci))
    elseif source == :both
        return sort!(collect(union(m.all_param_names_eng, m.all_param_names_sci)))
    else
        error("source must be :eng, :sci, or :both")
    end
end

"""
    has_parameter(m, param) -> Bool

True if any opened file contains the named parameter.
"""
has_parameter(m::MultiDBD, param::AbstractString) =
    param in m.all_param_names_eng || param in m.all_param_names_sci

# ── Multi-file get ────────────────────────────────────────────────────────────

"""
    get_data(m, params...; kwargs...) -> TimeSeries or Vector{TimeSeries}

Read one or more parameters across all files in chronological order.

Each parameter is read individually (different parameters may have different
time bases).  Returns a single `TimeSeries` for one parameter, or a
`Vector{TimeSeries}` for multiple.

# Keywords
- `decimal_latlon::Bool=true`        — convert NMEA coords to decimal degrees.
- `discard_bad_latlon::Bool=true`    — drop invalid NMEA values (incl. minutes ≥ 60).
- `return_nans::Bool=false`          — emit NaN for NOTSET cycles.
- `max_values::Int=-1`               — limit emitted rows per parameter.
"""
function get_data(m::MultiDBD, params::AbstractString...;
                  decimal_latlon::Bool=true,
                  discard_bad_latlon::Bool=true,
                  return_nans::Bool=false,
                  max_values::Int=-1)
    params_vec = collect(String, params)
    isempty(params_vec) && error("get_data: at least one parameter required")

    # Read from eng files
    eng_results = _read_param_set(m.files_eng, params_vec;
                                  skip_initial_line=m.skip_initial_line,
                                  return_nans, max_values)
    # Read from sci files
    sci_results = _read_param_set(m.files_sci, params_vec;
                                  skip_initial_line=m.skip_initial_line,
                                  return_nans, max_values)

    # Merge: for each param, concat eng + sci (a param is in only one set typically)
    results = Vector{TimeSeries}(undef, length(params_vec))
    @inbounds for i in eachindex(params_vec)
        e = eng_results[i]
        s = sci_results[i]
        if isempty(e)
            ts = s
        elseif isempty(s)
            ts = e
        else
            ts = TimeSeries(vcat(e.time, s.time), vcat(e.value, s.value))
        end
        # NMEA handling
        if is_latlon_param(params_vec[i]) && !isempty(ts)
            if discard_bad_latlon && !return_nans
                lat = is_lat_param(params_vec[i])
                mask = [is_valid_nmea(v, lat) for v in ts.value]
                ts = TimeSeries(ts.time[mask], ts.value[mask])
            end
            if decimal_latlon
                ts = TimeSeries(ts.time, nmea_to_decimal.(ts.value))
            end
        end
        results[i] = ts
    end
    return length(results) == 1 ? results[1] : results
end

"""
    get_sync(m, params...; interp_fn=linear_interp, kwargs...) -> Tuple

Read multiple parameters and interpolate onto the time base of the first.
Returns `(t, v1, v2, ..., vN)`.

`interp_fn` can be `linear_interp` (default), `heading_interp`, or a
`Dict{Int,Function}` mapping series index (2-based) to a custom interpolator.
"""
function get_sync(m::MultiDBD, params::AbstractString...;
                  interp_fn = linear_interp,
                  decimal_latlon::Bool=true,
                  discard_bad_latlon::Bool=true)
    length(params) >= 2 || error("get_sync requires at least 2 parameters")
    series = get_data(m, params...; decimal_latlon, discard_bad_latlon)
    series isa TimeSeries && (series = [series])
    return get_sync(series; interp_fn)
end

# ── Internal helper ───────────────────────────────────────────────────────────

function _read_param_set(files::Vector{DBDFile}, params::Vector{String};
                         skip_initial_line::Bool, return_nans::Bool,
                         max_values::Int)::Vector{TimeSeries}
    nv = length(params)
    times = [Float64[] for _ in 1:nv]
    values = [Float64[] for _ in 1:nv]
    for dbd in files
        available_mask = [haskey(dbd.name_to_pos, p) for p in params]
        any(available_mask) || continue
        available = [params[i] for i in 1:nv if available_mask[i]]
        local results
        try
            results = read_binary(dbd, available;
                                  skip_initial_line, return_nans, max_values)
        catch e
            @warn "Read failed for $(basename(dbd.filename)): $(sprint(showerror, e))"
            continue
        end
        j = 0
        for i in 1:nv
            available_mask[i] || continue
            j += 1
            append!(times[i],  results[j].time)
            append!(values[i], results[j].value)
        end
    end
    return [TimeSeries(times[i], values[i]) for i in 1:nv]
end
