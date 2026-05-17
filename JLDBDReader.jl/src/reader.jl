"""
Binary reader for Slocum DBD-family files.

This is the core of JLDBDReader.jl, replacing the C extension in `dbdreader`.
It has been validated against real glider files (and `dbdreader`'s output)
via a Python twin algorithm: all SHA-256 fingerprints over the float64 result
arrays match `dbdreader` byte-for-byte.

# Cycle structure (verified empirically against real .sbd/.dbd/.tbd data)

After the ASCII header, the binary section begins with a 17-byte known-cycle
preamble used for endianness detection:

```
offset 0  : 's'      (0x73)            — start tag
offset 1  : int8     (arbitrary)       — diagnostic byte
offset 2-3: uint16   0x1234            — endianness marker
offset 4-7: float32  123.456           — endianness double-check
offset 8-15: double  123456789.12345   — endianness triple-check
offset 16 : 'd'      (0x64)            — end tag
```

After the preamble, each data cycle occupies:

```
sbpc state bytes        (2 bits per sensor, MSB first within each byte)
chunk_size payload      (sum of bytesizes for UPDATED sensors, in cycle order)
1 separator byte        (typically 0x64 'd' or 0x73 's', not checked)
```

The 1-byte separator was the most easily-overlooked detail when reading the
C extension — it is implicit in the `chunksize + 1` advance in the original
code's `fp_current += chunksize + 1` line.

# State byte decoding

Each state byte packs four 2-bit fields, MSB first.  For byte value `b`,
field index `k ∈ 0..3`:

```
state[4*byte_index + k] = (b >> (6 - 2*k)) & 0x03
```

State values: `0 = NOTSET`, `1 = SAME` (use previous value), `2 = UPDATED`
(read new value from chunk).
"""

# ── Byte-swap helpers ─────────────────────────────────────────────────────────

bswap_int16(x::Int16) = bswap(x)
bswap_float32(x::Float32) = reinterpret(Float32, bswap(reinterpret(UInt32, x)))
bswap_float64(x::Float64) = reinterpret(Float64, bswap(reinterpret(UInt64, x)))

# ── Single value reader ───────────────────────────────────────────────────────

"""
Read one sensor value of `bytesize` bytes from the stream, byte-swapping
if `flip` is true.  Promotes to Float64 regardless of native width.
"""
@inline function read_sensor_value(io::IO, bytesize::Int, flip::Bool)::Float64
    if bytesize == 1
        return Float64(read(io, Int8))
    elseif bytesize == 2
        v = read(io, Int16)
        return Float64(flip ? bswap_int16(v) : v)
    elseif bytesize == 4
        v = read(io, Float32)
        return Float64(flip ? bswap_float32(v) : v)
    elseif bytesize == 8
        v = read(io, Float64)
        return flip ? bswap_float64(v) : v
    else
        error("Unsupported sensor byte size: $bytesize")
    end
end

# ── Byte-order detection ──────────────────────────────────────────────────────

"""
Read the 17-byte known-cycle preamble and return `true` if the file's
byte order is opposite to the host's (i.e., values must be swapped on read).

Validates the entire preamble, raising an error if any of the four sentinel
values fails, since that would indicate a corrupted or non-DBD file.
"""
function detect_byte_order(io::IO)::Bool
    s_byte = read(io, UInt8)
    s_byte == UInt8('s') ||
        error("Expected 's' at start of known cycle, got 0x$(string(s_byte, base=16))")
    _tag = read(io, UInt8)
    two = read(io, UInt16)  # native read
    flip = (two != 0x1234)
    if flip
        bswap(two) == 0x1234 ||
            error("Endianness marker invalid: got 0x$(string(two, base=16)) (host) / 0x$(string(bswap(two), base=16)) (flipped)")
    end
    f32 = read(io, Float32)
    flip && (f32 = bswap_float32(f32))
    abs(f32 - 123.456f0) < 1f-3 ||
        error("Float32 sentinel mismatch: got $f32, expected 123.456")
    f64 = read(io, Float64)
    flip && (f64 = bswap_float64(f64))
    abs(f64 - 123456789.12345) < 1e-3 ||
        error("Float64 sentinel mismatch: got $f64")
    d_byte = read(io, UInt8)
    d_byte == UInt8('d') ||
        error("Expected 'd' at end of known cycle, got 0x$(string(d_byte, base=16))")
    return flip
end

# ── State byte decoding ───────────────────────────────────────────────────────

"""
Fill `states` (length ≥ n_sensors) from `nsb` state bytes read from `io`.
Each state byte holds 4 fields, MSB first.
"""
@inline function decode_state_bytes!(states::Vector{UInt8}, io::IO,
                                     nsb::Int, n_sensors::Int)
    i = 0
    @inbounds for _ in 1:nsb
        b = read(io, UInt8)
        for k in 0:3
            i >= n_sensors && break
            states[i + 1] = (b >> (6 - 2*k)) & 0x03
            i += 1
        end
    end
    return states
end

# ── Main binary reader ────────────────────────────────────────────────────────

"""
    read_binary(dbd::DBDFile, params; skip_initial_line=true, return_nans=false, max_values=-1)
            -> Vector{TimeSeries}

Read the requested parameters from a DBD file.

Each returned `TimeSeries` has its own time base (the cycles in which that
parameter was UPDATED or SAME).  Use [`get_sync`](@ref) to interpolate them
onto a common time base.

# Algorithm

For each cycle:

1. Read `state_bytes_per_cycle` state bytes and decode into per-sensor states.
2. Single pass over all `sensors_per_cycle` positions:
   - Compute total `chunk_size` over UPDATED positions.
   - Record byte-offset within chunk for each REQUESTED position.
3. For each requested position, seek to `chunk_start + offset` and read.
4. Advance to `chunk_start + chunk_size + 1` (the `+1` is the separator).

The first cycle (which Slocum writes as a fully-UPDATED initialisation cycle)
is dropped when `skip_initial_line=true`, matching `dbdreader`'s default.

# Keyword arguments
- `skip_initial_line::Bool=true`  — drop the first cycle (initialisation).
- `return_nans::Bool=false`        — if true, emit `NaN` for NOTSET cycles
  in addition to the normal UPDATED+SAME emission.
- `max_values::Int=-1`             — early-exit cap on emitted rows.

# Returns
A `Vector{TimeSeries}` in the same order as `params`.  Parameters not present
in the file return an empty `TimeSeries` rather than throwing.
"""
function read_binary(dbd::DBDFile,
                     params::AbstractVector{<:AbstractString};
                     skip_initial_line::Bool=true,
                     return_nans::Bool=false,
                     max_values::Int=-1)::Vector{TimeSeries}

    n_sensors = length(dbd.sensors)
    n_state_bytes = dbd.header.state_bytes_per_cycle

    # Map requested params to 1-based cycle positions (0 means absent)
    nv = length(params)
    var_pos = Vector{Int}(undef, nv)
    @inbounds for i in 1:nv
        var_pos[i] = get(dbd.name_to_pos, String(params[i]), 0)
    end

    # Build the combined sorted unique cycle-position list (includes time)
    all_set = Set{Int}()
    push!(all_set, dbd.time_pos)
    for p in var_pos
        p > 0 && push!(all_set, p)
    end
    all_indices = sort!(collect(all_set))
    nall = length(all_indices)

    # pos_in_all[cycle_pos] → index in all_indices (or 0 if absent)
    pos_in_all = zeros(Int, n_sensors)
    @inbounds for (i, pos) in pairs(all_indices)
        pos_in_all[pos] = i
    end
    time_pos_in_all = pos_in_all[dbd.time_pos]

    # Per-requested-variable output buffers (length nv, one per param)
    times_out  = [Float64[] for _ in 1:nv]
    values_out = [Float64[] for _ in 1:nv]

    # Scratch buffers (reused across cycles)
    states     = Vector{UInt8}(undef, n_sensors)
    offsets    = fill(Int32(-2), nall)       # -2=NOTSET, -1=SAME, ≥0=byte offset
    memory     = fill(NaN, nall)             # last UPDATED value per position
    read_vals  = fill(NaN, nall)             # values for this cycle

    min_offset = return_nans ? Int32(-2) : Int32(-1)

    # Open the file (or wrap decompressed bytes)
    io = dbd.decompressed === nothing ? open(dbd.filename, "r") : IOBuffer(dbd.decompressed)
    try
        seek(io, dbd.binary_offset)
        flip = detect_byte_order(io)

        fsize = dbd.decompressed === nothing ?
                filesize(dbd.filename) : length(dbd.decompressed)

        is_first = true
        total_emitted = 0

        while position(io) < fsize
            # Need at least one state byte block + 1 chunk byte to proceed.
            position(io) + n_state_bytes >= fsize && break

            decode_state_bytes!(states, io, n_state_bytes, n_sensors)

            # Single pass: compute chunk size and per-requested-var offsets
            chunk_size = Int32(0)
            fill!(offsets, Int32(-2))
            @inbounds for pos in 1:n_sensors
                st = states[pos]
                ai = pos_in_all[pos]
                if st == UPDATED
                    if ai != 0
                        offsets[ai] = chunk_size
                    end
                    chunk_size += dbd.bytesizes[pos]
                elseif st == SAME
                    if ai != 0
                        offsets[ai] = Int32(-1)
                    end
                end
            end

            # Read requested values from the chunk
            chunk_start = position(io)
            if chunk_start + chunk_size + 1 > fsize
                # Truncated final cycle (rare but possible during transmission)
                break
            end

            @inbounds for i in 1:nall
                off = offsets[i]
                if off >= 0
                    seek(io, chunk_start + off)
                    v = read_sensor_value(io, dbd.bytesizes[all_indices[i]], flip)
                    read_vals[i] = v
                    memory[i] = v
                elseif off == Int32(-1)
                    read_vals[i] = memory[i]
                else
                    read_vals[i] = NaN
                end
            end

            # Advance past the chunk + 1-byte separator
            seek(io, chunk_start + chunk_size + 1)

            # Decide whether to emit this cycle
            if skip_initial_line && is_first
                is_first = false
                continue
            end
            is_first = false

            t = read_vals[time_pos_in_all]
            @inbounds for i in 1:nv
                p = var_pos[i]
                if p == 0
                    continue   # param not in this file
                end
                ai = pos_in_all[p]
                off = offsets[ai]
                if off >= min_offset
                    push!(times_out[i], t)
                    push!(values_out[i], off == Int32(-2) ? NaN : read_vals[ai])
                end
            end

            total_emitted += 1
            if max_values > 0 && total_emitted >= max_values
                break
            end
        end
    finally
        io isa IOBuffer || close(io)
    end

    return [TimeSeries(times_out[i], values_out[i]) for i in 1:nv]
end
