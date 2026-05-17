"""
NMEA coordinate conversion and validation for Slocum glider lat/lon parameters.

Slocum gliders encode latitude/longitude in NMEA format `±DDDMM.MMMM`
(degrees × 100 + minutes).  The original `dbdreader` validates only the
degree-bounds; it does not check `minutes < 60`, which allows values like
`5360.0` (= 53°60′ = 54°00′ after conversion) to slip through with no
indication of malformation.  This module catches that case.
"""

# Parameters that use NMEA encoding.  Slocum convention: any parameter whose
# name ends in "_lat" or "_lon" and whose unit string in the cache file is
# "lat" or "lon".  We hardcode the canonical list since most files have it
# but also expose `is_latlon_param_by_unit` for unit-based detection.

const LATLON_PARAMS = Set{String}([
    "m_lat", "m_lon", "c_wpt_lat", "c_wpt_lon",
    "x_last_wpt_lat", "x_last_wpt_lon",
    "m_gps_lat", "m_gps_lon",
    "u_lat_goto_l99", "u_lon_goto_l99",
    "m_last_gps_lat_1", "m_last_gps_lon_1",
    "m_last_gps_lat_2", "m_last_gps_lon_2",
    "m_last_gps_lat_3", "m_last_gps_lon_3",
    "m_last_gps_lat_4", "m_last_gps_lon_4",
    "m_gps_ignored_lat", "m_gps_ignored_lon",
    "m_gps_invalid_lat", "m_gps_invalid_lon",
    "m_gps_toofar_lat", "m_gps_toofar_lon",
    "xs_lat", "xs_lon", "s_ini_lat", "s_ini_lon",
])

"""
    is_latlon_param(name) -> Bool

Returns `true` if `name` is a known lat/lon parameter that uses NMEA encoding.
"""
is_latlon_param(name::AbstractString) = name in LATLON_PARAMS

"""
    is_latlon_param(name, unit) -> Bool

Detect lat/lon parameters using both the name and the unit string from the
cache file (`unit == "lat"` or `unit == "lon"`).  More robust than the
hardcoded list for non-standard parameter naming.
"""
is_latlon_param(name::AbstractString, unit::AbstractString) =
    is_latlon_param(name) || lowercase(unit) in ("lat", "lon")

"""
    is_lat_param(name) -> Bool

Returns `true` for latitude (rather than longitude) parameters.
"""
is_lat_param(name::AbstractString) = endswith(name, "_lat") ||
    name == "m_lat" || occursin("lat", lowercase(name)) && !occursin("lon", lowercase(name))

"""
    nmea_to_decimal(x) -> Float64

Convert from NMEA `±DDDMM.MMMM` to decimal degrees.

`5312.345` → `53 + 12.345/60` = `53.20575`.
"""
function nmea_to_decimal(x::Float64)::Float64
    isfinite(x) || return x
    s = sign(x)
    a = abs(x)
    d = floor(a / 100.0)
    m = a - d * 100.0
    return s * (d + m / 60.0)
end

"""
    is_valid_nmea(x, is_latitude::Bool) -> Bool

Strict NMEA validation: checks finite, degree bounds, AND `minutes < 60`.

The minutes-check catches encoding corruption that `dbdreader`'s
bounds-only check misses (e.g., values like `5360.0` that would silently
become `54.0°`).
"""
function is_valid_nmea(x::Float64, is_latitude::Bool)::Bool
    isfinite(x) || return false
    a = abs(x)
    limit = is_latitude ? 9000.0 : 18000.0
    a <= limit || return false
    m = a - floor(a / 100.0) * 100.0
    m < 60.0
end
