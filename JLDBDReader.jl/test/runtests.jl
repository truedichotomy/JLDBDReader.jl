using Test
using JLDBDReader
using JLDBDReader: bswap_int16, bswap_float32, bswap_float64,
                   decode_state_bytes!, detect_byte_order,
                   parse_sensor_list, parse_fileopen_time,
                   is_valid_nmea, is_lat_param,
                   candidate_cachedirs, default_cachedir,
                   read_file_header, find_cache_file,
                   _slocum_sort_key, sort_slocum!,
                   paired_extension, paired_filename, glob_files,
                   read_sensor_value

# Optional reference-data validation (only runs if test fixtures present)
const HAS_REFERENCE = let
    p = joinpath(@__DIR__, "reference_fingerprints.json")
    f1 = "/mnt/user-data/uploads/02010000.dbd"
    isfile(p) && isfile(f1)
end

@testset "JLDBDReader.jl" begin

# ── Unit tests (no I/O) ──────────────────────────────────────────────────────

@testset "NMEA conversion" begin
    @test nmea_to_decimal(5312.345) ≈ 53.20575 atol=1e-10
    @test nmea_to_decimal(-5312.345) ≈ -53.20575 atol=1e-10
    @test nmea_to_decimal(0.0) == 0.0
    @test nmea_to_decimal(5300.0) ≈ 53.0 atol=1e-10
    @test isnan(nmea_to_decimal(NaN))
end

@testset "NMEA validation" begin
    @test is_valid_nmea(5312.345, true) == true
    @test is_valid_nmea(12045.678, false) == true
    @test is_valid_nmea(9100.0, true) == false        # > 90° lat
    @test is_valid_nmea(18100.0, false) == false      # > 180° lon
    # The dbdreader bug fix: minutes ≥ 60 is invalid
    @test is_valid_nmea(5360.0, true) == false
    @test is_valid_nmea(5359.9999, true) == true
    @test is_valid_nmea(NaN, true) == false
    @test is_valid_nmea(Inf, false) == false
end

@testset "Lat/lon param detection" begin
    @test is_latlon_param("m_lat") == true
    @test is_latlon_param("m_gps_lon") == true
    @test is_latlon_param("m_depth") == false
    @test is_lat_param("m_lat") == true
    @test is_lat_param("m_lon") == false
end

@testset "File type classification" begin
    @test is_science_file("test.ebd") == true
    @test is_science_file("test.tbd") == true
    @test is_science_file("test.dbd") == false
    @test is_science_file("test.sbd") == false
    @test is_science_file("test.EBD") == true        # case-insensitive
    @test is_compressed("test.dcd") == true
    @test is_compressed("test.ecd") == true
    @test is_compressed("test.dbd") == false
end

@testset "Eng↔Sci file pairing" begin
    @test paired_extension(".dbd") == ".ebd"
    @test paired_extension(".ebd") == ".dbd"
    @test paired_extension(".sbd") == ".tbd"
    @test paired_extension(".tbd") == ".sbd"
    @test paired_filename("/a/b/comet-2024-1-0-0.dbd") == "/a/b/comet-2024-1-0-0.ebd"
end

@testset "Slocum filename sorting" begin
    files = [
        "comet-2024-100-1-9.dbd",
        "comet-2024-100-1-10.dbd",
        "comet-2024-100-1-2.dbd",
        "comet-2024-100-2-0.dbd",
        "comet-2024-99-7-0.dbd",
    ]
    sort_slocum!(files)
    @test files == [
        "comet-2024-99-7-0.dbd",
        "comet-2024-100-1-2.dbd",
        "comet-2024-100-1-9.dbd",
        "comet-2024-100-1-10.dbd",
        "comet-2024-100-2-0.dbd",
    ]
end

@testset "Linear interpolation" begin
    t_src = [1.0, 2.0, 3.0, 4.0, 5.0]
    v_src = [10.0, 20.0, 30.0, 40.0, 50.0]

    # Exact points
    @test linear_interp([1.0, 3.0, 5.0], t_src, v_src) ≈ [10.0, 30.0, 50.0]
    # Midpoints
    @test linear_interp([1.5, 2.5, 3.5], t_src, v_src) ≈ [15.0, 25.0, 35.0]
    # Out of bounds → NaN
    result = linear_interp([0.0, 6.0], t_src, v_src)
    @test all(isnan, result)
    # Empty source
    @test all(isnan, linear_interp([1.0], Float64[], Float64[]))
end

@testset "Heading interpolation" begin
    # Wrap around 0/2π: 350° → 10°, midpoint should be ~0°
    t_src = [0.0, 1.0]
    v_src = [350.0 * π/180, 10.0 * π/180]
    result = heading_interp([0.5], t_src, v_src)
    # midpoint should be near 0 (or 2π); not 180°
    angle_diff = min(abs(result[1]), abs(result[1] - 2π))
    @test angle_diff < 0.1
end

@testset "Byte-swap helpers" begin
    @test bswap_int16(Int16(0x1234)) == Int16(0x3412)
    @test bswap_float32(Float32(1.0)) != Float32(1.0)
    @test bswap_float32(bswap_float32(Float32(1.0))) == Float32(1.0)
    @test bswap_float64(bswap_float64(1.0)) == 1.0
end

@testset "State byte decoding" begin
    # 0xAA = 10101010 = [2,2,2,2] = all UPDATED
    states = Vector{UInt8}(undef, 8)
    decode_state_bytes!(states, IOBuffer([0xAA, 0xAA]), 2, 8)
    @test all(==(JLDBDReader.UPDATED), states)
    # 0x00 = all NOTSET, 0x55 = [1,1,1,1] = all SAME
    decode_state_bytes!(states, IOBuffer([0x00, 0x55]), 2, 8)
    @test states[1:4] == fill(JLDBDReader.NOTSET, 4)
    @test states[5:8] == fill(JLDBDReader.SAME, 4)
end

@testset "fileopen_time parsing" begin
    t = parse_fileopen_time("Sun_Jul_21_23:00:36_2024")
    @test t ≈ 1721602836.0 atol=2.0
    @test isnan(parse_fileopen_time("garbage"))
    @test isnan(parse_fileopen_time("Sun_Xyz_21_23:00:36_2024"))  # bad month
end

@testset "LZ4 block decoder" begin
    # Trivial: 4 literal bytes, no match
    # token=0x40 (lit_len=4, match_len=0), then 4 literal bytes
    @test JLDBDReader.lz4_decompress_block(UInt8[0x40, 0x48, 0x65, 0x6C, 0x6F]) == UInt8[0x48, 0x65, 0x6C, 0x6F]
end

@testset "Cache directory resolution" begin
    @test !isempty(default_cachedir())
    cands = candidate_cachedirs("/foo/bar")
    @test "/foo/bar" in cands
    @test default_cachedir() in cands
end

@testset "TimeSeries iteration" begin
    ts = TimeSeries([1.0, 2.0, 3.0], [10.0, 20.0, 30.0])
    @test length(ts) == 3
    @test !isempty(ts)
    @test collect(ts) == [(1.0, 10.0), (2.0, 20.0), (3.0, 30.0)]
end

# ── Integration tests with real files (only if available) ────────────────────

if HAS_REFERENCE
    using JSON

    @testset "Real-file: header parsing" begin
        path = "/mnt/user-data/uploads/02010000.sbd"
        dbd = open_dbd(path; cachedir="/tmp/cache")
        @test dbd.header.encoding_ver == 5
        @test dbd.header.sensors_per_cycle == 64
        @test dbd.header.state_bytes_per_cycle == 16
        @test dbd.header.sensor_list_crc == "0f682cb2"
        @test dbd.header.sensor_list_factored == 1
        @test dbd.header.total_num_sensors == 2709
        @test dbd.header.mission_name == "electa.mi"
        @test length(dbd.sensors) == 64
        @test dbd.time_var_name == "m_present_time"
        @test has_parameter(dbd, "m_depth")
        @test has_parameter(dbd, "m_gps_lat")
        @test !has_parameter(dbd, "bogus_sensor_name")
    end

    @testset "Real-file: binary reading vs reference (electa)" begin
        ref = JSON.parsefile(joinpath(@__DIR__, "reference_fingerprints.json"))
        cases = [
            ("/mnt/user-data/uploads/02010000.dbd",
                ["m_depth", "m_heading", "m_pitch", "m_roll", "m_battery"]),
            ("/mnt/user-data/uploads/02010000.sbd",
                ["m_depth"]),
            ("/mnt/user-data/uploads/02010000.tbd",
                ["sci_water_temp", "sci_water_cond", "sci_water_pressure"]),
        ]
        for (path, params) in cases
            dbd = open_dbd(path; cachedir="/tmp/cache")
            r = get_data(dbd, params...)
            r isa TimeSeries && (r = [r])
            file_ref = ref[basename(path)]["params"]
            for (i, p) in pairs(params)
                expect = file_ref[p]["value"]
                @test length(r[i]) == expect["n"]
                if expect["n"] > 0
                    finite = filter(isfinite, r[i].value)
                    @test minimum(finite) ≈ expect["min"] rtol=1e-9
                    @test maximum(finite) ≈ expect["max"] rtol=1e-9
                end
            end
        end
    end

    @testset "Real-file: binary reading vs reference (sylvia)" begin
        ref = JSON.parsefile(joinpath(@__DIR__, "reference_fingerprints.json"))
        cases = [
            ("/mnt/user-data/uploads/02390000.DBD",
                ["m_depth", "m_heading", "m_pitch", "m_roll", "m_battery"]),
            ("/mnt/user-data/uploads/02390000.SBD",
                ["m_depth"]),
            ("/mnt/user-data/uploads/02390000.MBD",
                ["m_depth", "m_pitch", "m_heading"]),
            ("/mnt/user-data/uploads/02390000.TBD",
                ["sci_water_temp", "sci_water_cond", "sci_water_pressure"]),
        ]
        for (path, params) in cases
            dbd = open_dbd(path; cachedir="/tmp/cache")
            r = get_data(dbd, params...)
            r isa TimeSeries && (r = [r])
            file_ref = ref[basename(path)]["params"]
            for (i, p) in pairs(params)
                expect = file_ref[p]["value"]
                @test length(r[i]) == expect["n"]
                if expect["n"] > 0
                    finite = filter(isfinite, r[i].value)
                    @test minimum(finite) ≈ expect["min"] rtol=1e-9
                    @test maximum(finite) ≈ expect["max"] rtol=1e-9
                end
            end
        end
    end

    @testset "Real-file: NMEA conversion validates" begin
        dbd = open_dbd("/mnt/user-data/uploads/02010000.sbd"; cachedir="/tmp/cache")
        # Raw NMEA
        ts_raw = get_data(dbd, "m_gps_lat"; decimal_latlon=false, discard_bad_latlon=false)
        @test length(ts_raw) == 19
        @test all(v -> 3850 < v < 3900, ts_raw.value)   # NMEA degrees×100
        # Decimal
        ts_dec = get_data(dbd, "m_gps_lat")
        @test all(v -> 38 < v < 40, ts_dec.value)        # decimal degrees
    end

    @testset "Real-file: get_sync" begin
        dbd = open_dbd("/mnt/user-data/uploads/02010000.dbd"; cachedir="/tmp/cache")
        t, dep, hdg = get_sync(dbd, "m_depth", "m_heading")
        @test length(t) == length(dep)
        @test length(t) == length(hdg)
        # m_heading interpolated from sparser time base: NaNs only at edges if any
        @test sum(isfinite, hdg) > 100
    end

    @testset "Real-file: MultiDBD" begin
        # Use just the electa engineering files we have caches for
        m = MultiDBD(filenames=["/mnt/user-data/uploads/02010000.dbd",
                                "/mnt/user-data/uploads/02010000.sbd"];
                     cachedir="/tmp/cache")
        @test nfiles(m) == 2
        @test "m_depth" in parameter_names(m, :eng)
        ts = get_data(m, "m_depth")
        # DBD has 2881 + SBD has 1 = 2882 m_depth values (concat eng→eng)
        @test length(ts) == 2882
    end
end

end  # outer testset

println("\nAll tests passed", HAS_REFERENCE ? " (including real-file validation)." : " (unit-only — no reference data found).")
