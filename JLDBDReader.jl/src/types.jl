"""
Core types for JLDBDReader.jl.

Design principle: a sensor's CYCLE POSITION (its position in the state-byte
encoding of one cycle) is implicit in its position in `Vector{SensorInfo}`.
We do not store the cycle index in the struct itself — this keeps the data
flow obvious and avoids the bug class where `index` could disagree with
the storage order.
"""

# ── State of one sensor in one cycle (2-bit value) ────────────────────────────

const NOTSET  = UInt8(0)
const SAME    = UInt8(1)
const UPDATED = UInt8(2)

# ── File type classification ──────────────────────────────────────────────────

"""
    is_science_extension(ext) -> Bool

True for science-computer file extensions (the `.ebd`/`.tbd`/`.nbd`/`.ecd`/`.tcd`/`.ncd`
companions of the engineering files).  Used for grouping in `MultiDBD`.
"""
function is_science_extension(ext::AbstractString)::Bool
    e = lowercase(ext)
    startswith(e, ".") && (e = e[2:end])
    e in ("ebd","tbd","nbd","ecd","tcd","ncd")
end

is_science_file(filename::AbstractString) =
    is_science_extension(splitext(filename)[2])

"""
    is_compressed_extension(ext) -> Bool

True for LZ4-compressed glider extensions (`.dcd`, `.ecd`, ..., `.dcg`, ...).
"""
function is_compressed_extension(ext::AbstractString)::Bool
    e = lowercase(ext)
    startswith(e, ".") && (e = e[2:end])
    length(e) == 3 || return false
    e[1] in ('d','e','m','n','s','t') && e[2] == 'c' && e[3] in ('d','g','c')
end

is_compressed(filename::AbstractString) =
    is_compressed_extension(splitext(filename)[2])

# ── Sensor metadata ───────────────────────────────────────────────────────────

"""
    SensorInfo(name, unit, bytesize)

Metadata for a single active sensor in a DBD cycle.

The cycle position of the sensor is determined by its index in the
`DBDFile.sensors` vector — there is no explicit index field, to prevent
representation/order drift.
"""
struct SensorInfo
    name::String
    unit::String
    bytesize::Int
end

# ── ASCII file header ─────────────────────────────────────────────────────────

"""
    FileHeader

Parsed ASCII header of a DBD-family file.  All fields preserve the original
text encoding except the integer-typed ones.
"""
struct FileHeader
    dbd_label::String
    encoding_ver::Int
    num_ascii_tags::Int
    all_sensors::String                 # "F" or "T"
    the8x3_filename::String
    full_filename::String
    filename_extension::String
    mission_name::String
    fileopen_time::String               # e.g., "Sun_Jul_21_23:00:36_2024"
    total_num_sensors::Int
    sensors_per_cycle::Int
    state_bytes_per_cycle::Int
    sensor_list_crc::String             # 8-char hex
    sensor_list_factored::Int           # 0 = inline, 1 = in external cache file
end

# ── DBD file handle ───────────────────────────────────────────────────────────

"""
    DBDFile

Represents an opened Slocum glider binary data file.  Construct via [`open_dbd`](@ref).

# Fields
- `filename`       : path on disk
- `header`         : parsed ASCII header
- `sensors`        : `Vector{SensorInfo}` of length `sensors_per_cycle`, indexed by cycle position
- `name_to_pos`    : map from sensor name → 1-based cycle position
- `bytesizes`      : `Vector{Int}` of byte sizes, indexed by cycle position
- `binary_offset`  : byte offset where the binary section begins
- `time_var_name`  : `"m_present_time"` or `"sci_m_present_time"`
- `time_pos`       : 1-based cycle position of the time variable
- `decompressed`   : `Vector{UInt8}` if the file was compressed, else `nothing`
"""
struct DBDFile
    filename::String
    header::FileHeader
    sensors::Vector{SensorInfo}
    name_to_pos::Dict{String,Int}
    bytesizes::Vector{Int}
    binary_offset::Int64
    time_var_name::String
    time_pos::Int
    decompressed::Union{Nothing,Vector{UInt8}}
end

# ── Time-series result ────────────────────────────────────────────────────────

"""
    TimeSeries(time, value)

A pair of `Vector{Float64}` for time (epoch seconds, UTC) and the corresponding
sensor values.  Time is always Float64 because Slocum stores it as IEEE-754
double precision.
"""
struct TimeSeries
    time::Vector{Float64}
    value::Vector{Float64}
end

TimeSeries() = TimeSeries(Float64[], Float64[])

Base.length(ts::TimeSeries) = length(ts.time)
Base.isempty(ts::TimeSeries) = isempty(ts.time)
Base.size(ts::TimeSeries) = (length(ts),)
Base.firstindex(ts::TimeSeries) = 1
Base.lastindex(ts::TimeSeries) = length(ts)

# Iteration: yields (t, v) pairs
function Base.iterate(ts::TimeSeries, state::Int=1)
    state > length(ts) && return nothing
    return ((ts.time[state], ts.value[state]), state + 1)
end

# Allow destructuring: t, v = ts
Base.iterate(ts::TimeSeries, ::Val{:tv}) = (ts.time, Val(:v))
Base.iterate(ts::TimeSeries, ::Val{:v}) = (ts.value, Val(:done))
Base.iterate(ts::TimeSeries, ::Val{:done}) = nothing
