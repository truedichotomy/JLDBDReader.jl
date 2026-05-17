"""
Header and cache-file parsing for Slocum glider files.

Two related parsers:

- `read_file_header(io)` reads the ASCII key-value lines at the top of a DBD
  file, returning a typed `FileHeader`.

- `read_cache_file(path, total_num_sensors)` parses an external `.cac` cache
  file into a `Vector{SensorInfo}` indexed by cycle position.

Both parsers are tolerant of trailing whitespace and locale-independent (we
never call `setlocale`).
"""

# ── ASCII header reader ───────────────────────────────────────────────────────

"""
Parse a single `key:    value\\n` header line.  Returns `(key, value)` with
the value stripped of leading/trailing whitespace.
"""
function _parse_header_line(line::AbstractString)
    colon = findfirst(==(':'), line)
    colon === nothing && error("Malformed header line (no colon): $(repr(line))")
    key = strip(line[1:colon-1])
    val = strip(line[colon+1:end])
    return String(key), String(val)
end

"""
    read_file_header(io) -> (header::FileHeader, sensor_list_text::String)

Read the ASCII header.  After this call, `io` is positioned at either
the start of the binary section (factored=1) or the start of the sensor list
(factored=0).  For factored=0, the sensor list lines are read and returned
as a single string; for factored=1, the returned string is empty.

The number of header lines is determined by the `num_ascii_tags` field.
"""
function read_file_header(io::IO)::Tuple{FileHeader,String}
    # Required keys with their expected types
    info = Dict{String,Any}()
    # First line must be dbd_label
    line = readline(io)
    k, v = _parse_header_line(line)
    k == "dbd_label" || error("Not a Slocum DBD file: first key is $(repr(k))")
    info["dbd_label"] = v
    n_read = 1

    # Header fields are listed before num_ascii_tags so we don't know how
    # many lines to read until we hit that key.  We read up to a sane
    # ceiling and check.
    while n_read < 64
        line = readline(io)
        k, v = _parse_header_line(line)
        info[k] = v
        n_read += 1
        if haskey(info, "num_ascii_tags")
            n_tags = parse(Int, info["num_ascii_tags"])
            n_read == n_tags && break
        end
    end
    haskey(info, "num_ascii_tags") || error("num_ascii_tags missing from header")

    # Build typed header
    header = FileHeader(
        get(info, "dbd_label", ""),
        parse(Int, get(info, "encoding_ver", "0")),
        parse(Int, get(info, "num_ascii_tags", "0")),
        get(info, "all_sensors", ""),
        get(info, "the8x3_filename", ""),
        get(info, "full_filename", ""),
        get(info, "filename_extension", ""),
        get(info, "mission_name", ""),
        get(info, "fileopen_time", ""),
        parse(Int, get(info, "total_num_sensors", "0")),
        parse(Int, get(info, "sensors_per_cycle", "0")),
        parse(Int, get(info, "state_bytes_per_cycle", "0")),
        get(info, "sensor_list_crc", ""),
        parse(Int, get(info, "sensor_list_factored", "0")),
    )

    # Validate encoding version
    header.encoding_ver == 5 ||
        @warn "Encoding version $(header.encoding_ver) not validated; only v5 has been tested."

    # If sensor list is inline, read it now
    sensor_list_text = ""
    if header.sensor_list_factored == 0
        buf = IOBuffer()
        for _ in 1:header.total_num_sensors
            line = readline(io)
            println(buf, line)
        end
        sensor_list_text = String(take!(buf))
    end

    return header, sensor_list_text
end

# ── Cache file (or inline sensor list) parser ─────────────────────────────────

"""
    parse_sensor_list(text, total_num_sensors) -> Vector{SensorInfo}

Parse the cache-style sensor list (one line per sensor in the full sensor
namespace) and return a dense `Vector{SensorInfo}` indexed by **cycle
position** (1-based in Julia).  Inactive sensors are omitted; the returned
vector has length equal to the number of active sensors in the cycle.

Line format (whitespace-separated):

```
s:  F|T   full_idx   active_pos   bytesize   name   unit
```

- Columns 1-2: literal `s:` and the factored flag (`F` or `T`).
- Column 3: 0-based position in the full sensor namespace.
- Column 4: 0-based cycle position, or `-1` if not active in this cycle.
- Column 5: byte size (1, 4, or 8 typically).
- Column 6: sensor name.
- Column 7: unit string (may be empty).

The function also returns `all_names`, a vector of every sensor name in the
file's namespace (active or not), in `full_idx` order, useful for `has_parameter`.
"""
function parse_sensor_list(text::AbstractString, total_num_sensors::Int)::Tuple{Vector{SensorInfo},Vector{String}}
    # First pass: gather all (active_pos, SensorInfo) pairs and all_names
    by_pos = Dict{Int,SensorInfo}()
    all_names = Vector{String}(undef, total_num_sensors)
    lines = split(text, '\n'; keepempty=false)
    length(lines) >= total_num_sensors ||
        error("Sensor list has $(length(lines)) lines, expected ≥ $total_num_sensors")

    for i in 1:total_num_sensors
        line = lines[i]
        words = split(strip(line))
        length(words) >= 6 ||
            error("Malformed sensor-list line $i: $(repr(line))")
        # Defensive parsing — column 1 should be "s:"
        startswith(words[1], "s") || error("Sensor list line $i lacks 's:' marker")
        active_pos = parse(Int, words[4])
        bytesize = parse(Int, words[5])
        name = String(words[6])
        unit = length(words) >= 7 ? String(words[7]) : ""
        all_names[i] = name
        if active_pos != -1
            haskey(by_pos, active_pos) &&
                error("Duplicate active_pos=$active_pos in sensor list")
            by_pos[active_pos] = SensorInfo(name, unit, bytesize)
        end
    end

    isempty(by_pos) && return SensorInfo[], all_names

    # Build dense vector indexed by cycle position (1-based in Julia)
    n_cycle = maximum(keys(by_pos)) + 1
    sensors = Vector{SensorInfo}(undef, n_cycle)
    for pos in 0:n_cycle-1
        haskey(by_pos, pos) ||
            error("Gap in active positions at $pos (expected contiguous 0..$(n_cycle-1))")
        sensors[pos + 1] = by_pos[pos]
    end

    return sensors, all_names
end

"""
    read_cache_file(path) -> String

Read a cache file's contents.  Supports plain `.cac` (text) and compressed
`.ccc` (LZ4) cache files.
"""
function read_cache_file(path::AbstractString)::String
    if endswith(lowercase(path), ".ccc")
        bytes = open(decompress_glider_stream, path, "r")
        return String(bytes)
    else
        return read(path, String)
    end
end

# ── Time parsing ──────────────────────────────────────────────────────────────

"""
    parse_fileopen_time(s) -> Float64

Parse `fileopen_time` strings of the form `Sun_Jul_21_23:00:36_2024` into
epoch seconds (UTC).  Returns `NaN` on failure (rather than throwing) so
metadata queries on malformed files don't crash.

Locale-independent — we hand-parse the month abbreviation rather than
relying on the C library's locale-sensitive parser.
"""
const MONTH_ABBR = Dict(
    "Jan"=>1, "Feb"=>2, "Mar"=>3, "Apr"=>4,  "May"=>5,  "Jun"=>6,
    "Jul"=>7, "Aug"=>8, "Sep"=>9, "Oct"=>10, "Nov"=>11, "Dec"=>12,
)

function parse_fileopen_time(s::AbstractString)::Float64
    try
        # Format: DayName_Month_DD_HH:MM:SS_YYYY
        parts = split(s, '_')
        length(parts) >= 5 || return NaN
        # parts[1] = day name (ignored)
        # parts[2] = month abbr
        # parts[3] = day of month
        # parts[4] = time HH:MM:SS
        # parts[5] = year
        month = get(MONTH_ABBR, String(parts[2]), 0)
        month == 0 && return NaN
        day = parse(Int, parts[3])
        year = parse(Int, parts[5])
        hms = split(parts[4], ':')
        length(hms) == 3 || return NaN
        h = parse(Int, hms[1])
        m = parse(Int, hms[2])
        sec = parse(Int, hms[3])
        # Build DateTime and convert to Unix epoch seconds
        dt = DateTime(year, month, day, h, m, sec)
        epoch = DateTime(1970, 1, 1)
        return (dt - epoch).value / 1000.0  # milliseconds → seconds
    catch
        return NaN
    end
end
