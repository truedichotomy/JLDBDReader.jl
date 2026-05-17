"""
Interpolation utilities for synchronising multiple parameters onto a common
time base.  Built-in alternatives to `scipy.interpolate.interp1d`, with the
addition of `heading_interp` for compass-style angular data that needs
correct wrapping around 0/2π.
"""

# ── Linear interpolation with out-of-bounds → NaN ─────────────────────────────

"""
    linear_interp(t_target, t_src, v_src) -> Vector{Float64}

Linear interpolation of `(t_src, v_src)` evaluated at `t_target`.  Returns
`NaN` for target times outside the source range (rather than extrapolating).

Both `t_src` and `t_target` must be sorted in ascending order — sortedness
is not checked for performance.  `t_src` should not contain NaN; `t_target`
may, in which case the corresponding output is NaN.

# Algorithm
Two-pointer walk through `t_src`, O(n+m) instead of O(n log m).
"""
function linear_interp(t_target::AbstractVector{Float64},
                       t_src::AbstractVector{Float64},
                       v_src::AbstractVector{Float64})::Vector{Float64}
    n = length(t_src)
    m = length(t_target)
    result = fill(NaN, m)
    n < 2 && return result   # need at least 2 source points

    j = 1
    @inbounds for i in 1:m
        ti = t_target[i]
        (isnan(ti) || ti < t_src[1] || ti > t_src[n]) && continue
        while j < n && t_src[j + 1] < ti
            j += 1
        end
        # ti is in [t_src[j], t_src[j+1]]
        t0, t1 = t_src[j], t_src[j + 1]
        v0, v1 = v_src[j], v_src[j + 1]
        if t0 == t1
            result[i] = v0
        else
            α = (ti - t0) / (t1 - t0)
            result[i] = v0 + α * (v1 - v0)
        end
    end
    return result
end

# ── Heading interpolation (correct wrap-around) ───────────────────────────────

"""
    heading_interp(t_target, t_src, v_src) -> Vector{Float64}

Linear interpolation for heading-like angular data in radians, [0, 2π).

Decomposes into sin/cos components, interpolates separately, then
recomposes with `atan` — this gives the correct result when the data
crosses the 0/2π boundary (e.g., 350° → 10° should interpolate through
0°, not through 180°).

Returns values in [0, 2π).
"""
function heading_interp(t_target::AbstractVector{Float64},
                        t_src::AbstractVector{Float64},
                        v_src::AbstractVector{Float64})::Vector{Float64}
    n = length(v_src)
    s = Vector{Float64}(undef, n)
    c = Vector{Float64}(undef, n)
    @inbounds for i in 1:n
        s[i], c[i] = sincos(v_src[i])
    end
    si = linear_interp(t_target, t_src, s)
    ci = linear_interp(t_target, t_src, c)
    return [isnan(si[i]) ? NaN : mod(atan(si[i], ci[i]), 2π) for i in eachindex(si)]
end

# ── Synchronise a vector of TimeSeries ────────────────────────────────────────

"""
    get_sync(series; interp_fn=linear_interp) -> Tuple

Synchronise a vector of `TimeSeries` onto the time base of `series[1]`,
returning `(t, v1, v2, ..., vN)` where `t == series[1].time` and `v_i` is
the i-th series interpolated onto that time base (`v1 == series[1].value`).

`interp_fn` may be:
- A function (applied to all series after the first); or
- A `Dict{Int,Function}` mapping series index (2-based) to a custom
  interpolator, e.g., `Dict(3 => heading_interp)` to use heading
  interpolation for the third series only.
"""
function get_sync(series::AbstractVector{TimeSeries};
                  interp_fn = linear_interp)::Tuple
    isempty(series) && error("get_sync needs at least one series")
    n = length(series)
    base = series[1]
    out = Any[base.time, base.value]
    for i in 2:n
        s = series[i]
        if isempty(s)
            push!(out, fill(NaN, length(base)))
        else
            f = interp_fn isa AbstractDict ? get(interp_fn, i, linear_interp) : interp_fn
            push!(out, f(base.time, s.time, s.value))
        end
    end
    return Tuple(out)
end
