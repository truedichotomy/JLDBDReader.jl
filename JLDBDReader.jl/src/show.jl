"""
Display methods for the major types.  Designed to give a useful summary in
the REPL without dumping the full internals.
"""

function Base.show(io::IO, ::MIME"text/plain", dbd::DBDFile)
    println(io, "DBDFile: ", basename(dbd.filename))
    println(io, "  full_filename     : ", dbd.header.full_filename)
    println(io, "  mission           : ", dbd.header.mission_name)
    println(io, "  fileopen_time     : ", dbd.header.fileopen_time)
    println(io, "  extension         : ", dbd.header.filename_extension)
    println(io, "  encoding_ver      : ", dbd.header.encoding_ver)
    println(io, "  sensor_list_crc   : ", dbd.header.sensor_list_crc,
                 dbd.header.sensor_list_factored == 1 ? " (factored)" : " (inline)")
    println(io, "  total_num_sensors : ", dbd.header.total_num_sensors)
    println(io, "  sensors_per_cycle : ", dbd.header.sensors_per_cycle)
    println(io, "  state_bytes/cycle : ", dbd.header.state_bytes_per_cycle)
    println(io, "  binary_offset     : ", dbd.binary_offset, " bytes")
    println(io, "  time variable     : ", dbd.time_var_name,
                 " (cycle pos ", dbd.time_pos, ")")
    print(io,   "  active sensors    : ", length(dbd.sensors))
end

Base.show(io::IO, dbd::DBDFile) =
    print(io, "DBDFile(\"", basename(dbd.filename), "\")")

function Base.show(io::IO, ::MIME"text/plain", m::MultiDBD)
    n_eng = length(m.files_eng)
    n_sci = length(m.files_sci)
    println(io, "MultiDBD:")
    println(io, "  engineering files : ", n_eng)
    println(io, "  science files     : ", n_sci)
    println(io, "  missions          : ", join(m.mission_names, ", "))
    println(io, "  eng parameters    : ", length(m.all_param_names_eng))
    println(io, "  sci parameters    : ", length(m.all_param_names_sci))
    tmin, tmax = m.time_range
    if isfinite(tmin) && isfinite(tmax)
        # ISO-format approximate range
        try
            d1 = Dates.unix2datetime(tmin)
            d2 = Dates.unix2datetime(tmax)
            print(io, "  time range (UTC)  : ", d1, " → ", d2)
        catch
            print(io, "  time range (epoch): ", tmin, " → ", tmax)
        end
    end
end

Base.show(io::IO, m::MultiDBD) =
    print(io, "MultiDBD(", length(m.files_eng) + length(m.files_sci), " files)")

function Base.show(io::IO, ::MIME"text/plain", ts::TimeSeries)
    n = length(ts)
    println(io, "TimeSeries (", n, " points)")
    if n == 0
        print(io, "  (empty)")
    else
        valid = filter(isfinite, ts.value)
        if !isempty(valid)
            print(io, "  value range : ", minimum(valid), " .. ", maximum(valid))
            n_finite = length(valid)
            n_finite < n && print(io, "   (", n - n_finite, " non-finite)")
        else
            print(io, "  all values non-finite")
        end
    end
end

Base.show(io::IO, ts::TimeSeries) = print(io, "TimeSeries(", length(ts), ")")
