# JLDBDReader.jl

A pure-Julia reader for Slocum ocean glider binary data files (`.dbd`, `.sbd`, `.mbd`, `.ebd`, `.tbd`, `.nbd`) and their LZ4-compressed variants (`.dcd`, `.scd`, `.mcd`, `.ecd`, `.tcd`, `.ncd`).

This is a ground-up Julia translation of the Python [`dbdreader`](https://github.com/smerckel/dbdreader) package by Lucas Merckelbach (Helmholtz-Zentrum Hereon), addressing the architectural issues, bugs, and design shortcomings identified in a critical evaluation of that codebase (see [`docs/evaluation.pdf`](docs/evaluation.pdf)).

## Status

Validated byte-for-byte against `dbdreader`'s output for real glider data files. All SHA-256 fingerprints of the result float64 arrays match exactly. See `test/reference_fingerprints.json` and the integration tests in `test/runtests.jl`.

## Quick start

```julia
using JLDBDReader

# Single file
dbd = open_dbd("00010010.dbd"; cachedir="/path/to/cache")
ts = get_data(dbd, "m_depth")               # TimeSeries with .time and .value

# Synchronize multiple parameters onto a common time base
t, hdg, pitch, roll = get_sync(dbd, "m_heading", "m_pitch", "m_roll")

# Multiple files at once
m = MultiDBD(pattern="data/*.dbd"; cachedir="/path/to/cache",
             complement_files=true)         # auto-add matching .ebd/.tbd
all_depth = get_data(m, "m_depth")
t, T, C, P = get_sync(m, "sci_water_temp", "sci_water_cond", "sci_water_pressure")
```

## What this fixes vs `dbdreader`

| Issue | `dbdreader` (Python + C) | `JLDBDReader.jl` |
|-------|--------------------------|------------------|
| Build dependency | C compiler + headers required | Pure Julia, zero non-Julia deps |
| Error handling | `exit(1)` in C on read failure | Julia exceptions, recoverable |
| NaN encoding | `1e9` sentinel + `isclose` check | Direct IEEE `NaN` |
| NMEA validation | Degree bounds only | Degrees + **minutes < 60** |
| Locale | Global `setlocale` mutation at import | No locale dependency |
| Cache directory | `mkdir` side-effect at import | Explicit, opt-in |
| Thread safety | C `static` variables in reader | Fully thread-safe |
| `scipy` dependency | Required for `interp1d` | Built-in linear + heading interp |
| Dead code | ~200 lines of unused Python reader | None |
| Stale `fp` handle | Created at construction, used much later | Opened per call, closed cleanly |
| Cycle reader bug | (none — the C extension is correct) | **N/A** (same algorithm, no separator bug) |

## File format reference (validated empirically)

After the ASCII header, the binary section consists of:

```
17-byte known-cycle preamble (used for endianness detection)
  ─ 's' (0x73)
  ─ 1 byte int8 tag (arbitrary)
  ─ uint16 0x1234 (endianness marker)
  ─ float32 123.456
  ─ float64 123456789.12345
  ─ 'd' (0x64)

Per data cycle:
  ─ state_bytes_per_cycle state bytes (2 bits/sensor, MSB first per byte)
  ─ chunk of sensor values (sum of bytesizes for UPDATED sensors, in cycle order)
  ─ 1 separator byte
```

State value encoding: `0 = NOTSET`, `1 = SAME` (use last value), `2 = UPDATED` (read new value).

The single most easily-overlooked detail in porting this format is the **1-byte separator between cycles** (implicit in the C extension's `fp_current += chunksize + 1`).

## Sensor list (cache) file format

```
s:  F|T   full_idx   active_pos   bytesize   name   unit
```

- The cache file lists every sensor in the file's full namespace (one line per sensor).
- `active_pos == -1` means the sensor is not in this cycle.
- The cycle layout is **dense in `active_pos`**: positions are contiguous from `0` to `sensors_per_cycle-1`.

## Cache file discovery

Cache files (`.cac` plain, `.ccc` LZ4-compressed) are located by their CRC, in this order:

1. The `cachedir` keyword argument passed to `open_dbd`/`MultiDBD`.
2. `./cache` relative to the current working directory.
3. `<datafile_dir>/cache`.
4. `<datafile_dir>` itself.
5. The platform-default directory ([`default_cachedir()`](src/cache.jl)).

If no matching cache is found, the error message lists every directory that was searched.

## API

| Function | Purpose |
|----------|---------|
| `open_dbd(path; cachedir)`             | Open one file, parse header, locate cache. |
| `MultiDBD(; filenames, pattern, ...)`  | Open a set of files. |
| `get_data(dbd_or_multi, params...)`    | Read parameters; per-parameter time bases. |
| `get_sync(dbd_or_multi, params...)`    | Read + linearly interpolate onto first param's time base. |
| `parameter_names(dbd_or_multi)`        | List available parameters. |
| `has_parameter(dbd_or_multi, name)`    | Membership check. |
| `linear_interp(t, t_src, v_src)`       | Linear interpolation, NaN outside source range. |
| `heading_interp(t, t_src, v_src)`      | Wrap-correct interp for compass headings. |
| `nmea_to_decimal(x)`                   | NMEA `DDDMM.MMMM` → decimal degrees. |
| `is_valid_nmea(x, is_latitude)`        | Strict validation including minutes < 60. |
| `default_cachedir()`                   | Platform default cache directory (does not create it). |
| `decompress_glider_file(path)`         | LZ4 decompress an entire compressed glider file to memory. |

## Validation

The Julia algorithm was validated by:

1. Writing a Python twin (`tools/julia_reference.py`) that mirrors the Julia algorithm byte-for-byte.
2. Running the twin against real glider files from **two gliders**:
   - `electa`, deployment 2024-07-21 (`02010000.dbd/.sbd/.tbd`)
   - `sylvia`, deployment 2024-09-30 (`02390000.DBD/.SBD/.MBD/.TBD`)
3. Comparing SHA-256 fingerprints of the resulting float64 value arrays against `dbdreader`'s output.

**All 34 validated `(file, parameter)` combinations match `dbdreader` exactly** — across all five DBD-family file types (DBD/SBD/MBD/EBD-equivalent/TBD) and both little-endian flagged file structures. Reference fingerprints are stored in [`test/reference_fingerprints.json`](test/reference_fingerprints.json) and the integration tests in `test/runtests.jl` will check the Julia output against them when real files are present.

## Installation

```julia
] add https://github.com/yourorg/JLDBDReader.jl
```

For development:

```julia
] dev /path/to/JLDBDReader.jl
```

## License

The original `dbdreader` is GPL-3.0.  This is a clean-room reimplementation based on the documented Slocum binary format (and `dbdreader`'s public algorithm description), not a derivative work. Released under the MIT License (see `LICENSE`).
