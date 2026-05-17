# JLDBDReader.jl — basic usage
#
# Run from the package directory with: `julia --project=. examples/basic_usage.jl`
# Adjust `cachedir` and file paths to your environment.

using JLDBDReader

# ── 1. Open a single file ─────────────────────────────────────────────────────

dbd = open_dbd("data/00010010.dbd"; cachedir="cache")
println(dbd)            # short summary
display(dbd)            # full MIME"text/plain" summary

# Inspect what's available
println("\nAvailable parameters: ", length(parameter_names(dbd)))
println("Sample: ", parameter_names(dbd)[1:5])

# ── 2. Read one parameter ────────────────────────────────────────────────────

depth = get_data(dbd, "m_depth")
println("\nm_depth: ", depth)        # uses Base.show(io, ts)
println("First 3 times: ",  depth.time[1:3])
println("First 3 values: ", depth.value[1:3])

# ── 3. Read several parameters with their own time bases ─────────────────────

ts_list = get_data(dbd, "m_heading", "m_pitch", "m_roll")
for (name, ts) in zip(("m_heading", "m_pitch", "m_roll"), ts_list)
    println(name, ": ", length(ts), " points")
end

# ── 4. Synchronise onto a common time base ───────────────────────────────────

t, dep, hdg, pitch, roll = get_sync(dbd, "m_depth", "m_heading", "m_pitch", "m_roll")
println("\nSynced length: ", length(t))
println("Sync uses linear interp for all by default")

# Custom interpolator for heading (correct wrap-around at 0/2π)
t, dep, hdg = get_sync(dbd, "m_depth", "m_heading";
                       interp_fn = Dict(3 => heading_interp))

# ── 5. Multi-file usage ──────────────────────────────────────────────────────

m = MultiDBD(pattern="data/*.dbd"; cachedir="cache",
             complement_files=true)   # auto-add matching .ebd files
display(m)

# All m_depth across all engineering files, concatenated in chronological order
all_depth = get_data(m, "m_depth")
println("\nTotal depth points across files: ", length(all_depth))

# Cross-source synchronisation: CTD (science) timed to glider depth (eng)
# get_data returns separate eng/sci series; merge with get_sync
t_ctd, temp, cond, pres = get_sync(m, "sci_water_temp", "sci_water_cond", "sci_water_pressure")
println("CTD synced points: ", length(t_ctd))

# ── 6. Lat/lon with strict NMEA validation ───────────────────────────────────

ts_lat = get_data(dbd, "m_gps_lat")               # decimal + filtered (default)
ts_lat_raw = get_data(dbd, "m_gps_lat";
                      decimal_latlon=false,
                      discard_bad_latlon=false)   # raw NMEA, unfiltered

println("\nDecimal lat range: ", extrema(ts_lat.value))
println("Raw NMEA lat range: ", extrema(ts_lat_raw.value))
