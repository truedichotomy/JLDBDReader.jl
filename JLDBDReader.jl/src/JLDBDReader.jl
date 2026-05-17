"""
    JLDBDReader

A pure-Julia reader for Slocum ocean glider binary data files
(`.dbd`, `.sbd`, `.mbd`, `.ebd`, `.tbd`, `.nbd`) and their LZ4-compressed
variants (`.dcd`, `.scd`, `.mcd`, `.ecd`, `.tcd`, `.ncd`).

This is a ground-up Julia translation of the Python `dbdreader` package
(https://github.com/smerckel/dbdreader) by Lucas Merckelbach, addressing
architectural issues identified in a critical evaluation of that codebase.

# Quick start

```julia
using JLDBDReader

# Single file
dbd = open_dbd("00010010.dbd", cachedir="/path/to/cac")
ts = get_data(dbd, "m_depth")          # TimeSeries with .time and .value
t, hdg, pitch, roll = get_sync(dbd, "m_heading", "m_pitch", "m_roll")

# Multi-file
m = MultiDBD(pattern="data/*.dbd", cachedir="/path/to/cac")
ts = get_data(m, "m_depth")
```

# Key correctness properties (validated byte-for-byte against `dbdreader`)
- Cycle structure: state bytes + chunk + 1-byte separator.
- `chunk_size` accumulated over ALL UPDATED sensors, not just requested ones.
- SensorInfo position in `Vector{SensorInfo}` IS the cycle position
  (no separate index field that could drift).
- IEEE NaN throughout (no `1e9` sentinels).
- Strict NMEA validation (rejects minutes ≥ 60).

# Improvements over `dbdreader`
- Pure Julia: no C extension to compile or fail at runtime.
- Thread-safe: no static variables or global locale mutation.
- Side-effect-free at import: no `mkdir`, no `setlocale`.
- Clear errors: never `exit(1)` on malformed input.

See [`open_dbd`](@ref), [`MultiDBD`](@ref), [`get_data`](@ref), [`get_sync`](@ref).
"""
module JLDBDReader

using Dates
using Printf

# ── Submodules (order matters: types → utils → reader → multi → show) ────────

include("types.jl")
include("nmea.jl")
include("decompress.jl")
include("cache.jl")
include("header.jl")
include("reader.jl")
include("interpolation.jl")
include("multi.jl")
include("show.jl")

# ── Public API ────────────────────────────────────────────────────────────────

export
    # Types
    DBDFile, MultiDBD, TimeSeries, SensorInfo, FileHeader,
    # Constants
    NOTSET, SAME, UPDATED,
    # Opening
    open_dbd,
    # Reading
    get_data, get_sync, read_binary,
    has_parameter, parameter_names, nfiles,
    # NMEA
    nmea_to_decimal, is_latlon_param, is_valid_nmea,
    # Interpolation
    linear_interp, heading_interp,
    # File type helpers
    is_science_file, is_compressed,
    # Cache
    default_cachedir,
    # LZ4
    lz4_decompress_block, decompress_glider_file,
    # Time
    parse_fileopen_time

# ── Single-file opener ────────────────────────────────────────────────────────

"""
    open_dbd(filename; cachedir=nothing) -> DBDFile

Open a Slocum DBD-family file and parse its header.  Locates the matching
sensor-list cache (`.cac`) file if the header indicates `sensor_list_factored=1`.

Supports compressed files (`.dcd`, `.ecd`, etc.) transparently — they are
decompressed in-memory at open time.

# Cache resolution order
1. `cachedir` (if provided)
2. `./cache` relative to current working directory
3. `<datafile_dir>/cache`
4. `<datafile_dir>` itself
5. Platform default ([`default_cachedir`](@ref))

# Errors
- Throws `SystemError` if `filename` is missing.
- Throws `ErrorException` with the searched paths if no matching `.cac` is found.
- Throws if the header is malformed or the encoding version is incompatible.

# Example
```julia
dbd = open_dbd("electa-2024-202-1-0.dbd", cachedir="/home/me/glider/cache")
```
"""
function open_dbd(filename::AbstractString;
                  cachedir::Union{Nothing,AbstractString}=nothing)::DBDFile
    isfile(filename) ||
        throw(SystemError("open_dbd: file not found: $filename", 2))

    # Handle compressed file: decompress to memory, then parse from buffer
    local raw::Union{Nothing,Vector{UInt8}} = nothing
    if is_compressed(filename)
        raw = decompress_glider_file(String(filename))
    end

    # Read header (and inline sensor list if applicable)
    local header::FileHeader, inline_sensor_text::String, binary_offset::Int64
    if raw === nothing
        open(filename, "r") do io
            header, inline_sensor_text = read_file_header(io)
            binary_offset = position(io)
        end
    else
        io = IOBuffer(raw)
        header, inline_sensor_text = read_file_header(io)
        binary_offset = position(io)
    end

    # Build sensor list (from inline or external cache)
    local sensors::Vector{SensorInfo}, all_names::Vector{String}
    if header.sensor_list_factored == 1
        cac_path = find_cache_file(header.sensor_list_crc, cachedir, String(filename))
        cac_path === nothing && error(
            "Cache file $(header.sensor_list_crc).cac not found in any of: " *
            join(candidate_cachedirs(cachedir), ", ")
        )
        sensors, all_names = parse_sensor_list(read_cache_file(cac_path),
                                                header.total_num_sensors)
    else
        sensors, all_names = parse_sensor_list(inline_sensor_text,
                                                header.total_num_sensors)
    end

    length(sensors) == header.sensors_per_cycle ||
        @warn "Cache active-sensor count ($(length(sensors))) ≠ header sensors_per_cycle ($(header.sensors_per_cycle)); using cache."

    # Build name→position map and bytesizes lookup
    name_to_pos = Dict{String,Int}()
    bytesizes = Vector{Int}(undef, length(sensors))
    for (i, s) in pairs(sensors)
        name_to_pos[s.name] = i
        bytesizes[i] = s.bytesize
    end

    # Find time variable (m_present_time for engineering, sci_m_present_time for science)
    time_pos = 0
    time_var = ""
    for candidate in ("m_present_time", "sci_m_present_time")
        p = get(name_to_pos, candidate, 0)
        if p != 0
            time_pos = p
            time_var = candidate
            break
        end
    end
    time_pos == 0 && error("No time variable (m_present_time or sci_m_present_time) found in $filename")

    return DBDFile(
        String(filename), header, sensors, name_to_pos, bytesizes,
        binary_offset, time_var, time_pos, raw,
    )
end

# ── Single-file high-level API ────────────────────────────────────────────────

"""
    get_data(dbd::DBDFile, params...; kwargs...) -> TimeSeries or Vector{TimeSeries}

Read one or more parameters from a single DBD file.  Returns a `TimeSeries`
for a single parameter, a `Vector{TimeSeries}` for multiple.

# Keywords
- `decimal_latlon=true`     : convert NMEA lat/lon to decimal degrees.
- `discard_bad_latlon=true` : drop invalid NMEA values (incl. minutes ≥ 60).
- `return_nans=false`       : emit NaN for NOTSET cycles.
- `max_values=-1`           : limit emitted rows.
- `skip_initial_line=true`  : drop the first (initialisation) cycle.

# Example
```julia
ts = get_data(dbd, "m_depth")
plot(ts.time, ts.value, yflip=true, xlabel="Unix time", ylabel="m_depth (m)")
```
"""
function get_data(dbd::DBDFile, params::AbstractString...;
                  decimal_latlon::Bool=true,
                  discard_bad_latlon::Bool=true,
                  return_nans::Bool=false,
                  max_values::Int=-1,
                  skip_initial_line::Bool=true)
    params_vec = collect(String, params)
    isempty(params_vec) && error("get_data: need at least one parameter name")
    results = read_binary(dbd, params_vec;
                          skip_initial_line, return_nans, max_values)
    @inbounds for (i, p) in pairs(params_vec)
        if is_latlon_param(p) && !isempty(results[i])
            ts = results[i]
            if discard_bad_latlon && !return_nans
                lat = is_lat_param(p)
                mask = [is_valid_nmea(v, lat) for v in ts.value]
                ts = TimeSeries(ts.time[mask], ts.value[mask])
            end
            if decimal_latlon
                ts = TimeSeries(ts.time, nmea_to_decimal.(ts.value))
            end
            results[i] = ts
        end
    end
    return length(results) == 1 ? results[1] : results
end

"""
    get_sync(dbd::DBDFile, params...; interp_fn=linear_interp, kwargs...) -> Tuple

Read multiple parameters from a single DBD file and synchronise them onto
the time base of the first parameter.

Returns `(t, v1, v2, ..., vN)` where `t == series[1].time` and each `v_i`
is the corresponding parameter interpolated onto `t`.

`interp_fn` may be a function (e.g., [`linear_interp`](@ref) or
[`heading_interp`](@ref)) or a `Dict{Int,Function}` mapping 1-based series
index (starting from 2 for the first interpolated series) to a custom
interpolator.

# Example
```julia
t, depth, hdg, pitch = get_sync(dbd, "m_depth", "m_heading", "m_pitch";
                                interp_fn = Dict(3 => heading_interp))
```
"""
function get_sync(dbd::DBDFile, params::AbstractString...;
                  interp_fn = linear_interp,
                  decimal_latlon::Bool=true,
                  discard_bad_latlon::Bool=true)
    length(params) >= 2 || error("get_sync requires at least 2 parameters")
    series = get_data(dbd, params...; decimal_latlon, discard_bad_latlon)
    series isa TimeSeries && (series = [series])
    return get_sync(series; interp_fn)
end

# ── parameter_names / nfiles single-file shims ────────────────────────────────

parameter_names(dbd::DBDFile) = [s.name for s in dbd.sensors]
has_parameter(dbd::DBDFile, name::AbstractString) = haskey(dbd.name_to_pos, String(name))
nfiles(::DBDFile) = 1

end # module
