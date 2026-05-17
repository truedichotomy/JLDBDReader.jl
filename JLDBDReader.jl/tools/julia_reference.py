#!/usr/bin/env python3
"""
Python reference implementation that mirrors the Julia JLDBDReader algorithm
byte-for-byte.  Used to validate the algorithm against `dbdreader`'s output
when Julia cannot be executed in the sandbox.

This is a pure-Python port of the same algorithm intended for the Julia
package, so if this matches `dbdreader`, the Julia version (which uses
identical logic) is also correct.
"""

import os
import re
import struct
import math
from dataclasses import dataclass
from typing import List, Dict, Tuple, Optional

# ── Header parsing ────────────────────────────────────────────────────────────

HEADER_KEYS = {
    "dbd_label": str, "total_num_sensors": int, "sensor_list_crc": str,
    "state_bytes_per_cycle": int, "sensors_per_cycle": int,
    "sensor_list_factored": int, "num_ascii_tags": int,
    "mission_name": str, "fileopen_time": str, "encoding_ver": int,
    "full_filename": str, "the8x3_filename": str,
    "filename_extension": str,
}

def parse_header(fp) -> dict:
    info = {}
    line = fp.readline().decode('ascii', errors='replace').rstrip('\n')
    key, _, val = line.partition(':')
    assert key == 'dbd_label', f"Not a DBD file: first key={key!r}"
    info[key] = val.strip()
    n_read = 1
    while True:
        line = fp.readline().decode('ascii', errors='replace').rstrip('\n')
        key, _, val = line.partition(':')
        if key in HEADER_KEYS:
            info[key] = HEADER_KEYS[key](val.strip())
        n_read += 1
        if 'num_ascii_tags' in info and n_read == info['num_ascii_tags']:
            break
    assert info.get('encoding_ver') == 5, f"Unsupported encoding_ver={info.get('encoding_ver')}"
    return info

# ── Sensor (cache) list ───────────────────────────────────────────────────────

@dataclass
class SensorInfo:
    name: str
    unit: str
    bytesize: int

def parse_sensor_list(text: str, total_num_sensors: int) -> List[Optional[SensorInfo]]:
    """Parse cache-style sensor list. Returns a list of length `sensors_per_cycle`
    where index i corresponds to cycle position i.  Inactive sensors return None."""
    cycle_sensors: Dict[int, SensorInfo] = {}
    lines = text.splitlines()
    for i in range(total_num_sensors):
        words = lines[i].split()
        # Format: "s: F/T  full_idx  active_pos  bytesize  name  unit"
        active_pos = int(words[3])
        if active_pos == -1:
            continue
        bytesize = int(words[4])
        name = words[5]
        unit = words[6] if len(words) >= 7 else ""
        cycle_sensors[active_pos] = SensorInfo(name=name, unit=unit, bytesize=bytesize)
    # Build dense list indexed by cycle position
    n_cycle = max(cycle_sensors.keys()) + 1 if cycle_sensors else 0
    result = [None] * n_cycle
    for pos, si in cycle_sensors.items():
        result[pos] = si
    return result

# ── Binary preamble (byte-order detection) ────────────────────────────────────

def detect_byte_order(fp) -> bool:
    """Read the 17-byte known-cycle preamble and return True if byte-swap is needed."""
    fp.read(2)  # 's' + tag
    two_byte = fp.read(2)
    fp.read(13)  # float32 + float64 + 'd'
    # Native-LE read: if file is LE, this gives 0x1234 = 4660
    val_le = struct.unpack('<H', two_byte)[0]
    return val_le != 4660

# ── Sensor value reader ───────────────────────────────────────────────────────

def read_sensor_value(fp, bytesize: int, flip: bool) -> float:
    if bytesize == 1:
        return float(struct.unpack('b', fp.read(1))[0])
    elif bytesize == 2:
        endian = '>' if flip else '<'
        return float(struct.unpack(f'{endian}h', fp.read(2))[0])
    elif bytesize == 4:
        endian = '>' if flip else '<'
        return float(struct.unpack(f'{endian}f', fp.read(4))[0])
    elif bytesize == 8:
        endian = '>' if flip else '<'
        return float(struct.unpack(f'{endian}d', fp.read(8))[0])
    else:
        raise ValueError(f"Unsupported sensor byte size: {bytesize}")

# ── State byte decoding ───────────────────────────────────────────────────────

def decode_state_bytes(state_buf: bytes, n_sensors: int) -> List[int]:
    """Decode state bytes into per-sensor state list.
    Returns list of length n_sensors with values 0 (NOTSET), 1 (SAME), 2 (UPDATED)."""
    states = [0] * n_sensors
    i = 0
    for b in state_buf:
        for k in range(4):
            if i >= n_sensors:
                return states
            states[i] = (b >> (6 - 2 * k)) & 0x03
            i += 1
    return states

# ── Main binary reader ────────────────────────────────────────────────────────

NOTSET, SAME, UPDATED = 0, 1, 2

def read_binary(
    filename: str,
    binary_offset: int,
    n_state_bytes: int,
    n_sensors: int,
    cycle_bytesizes: List[int],     # length n_sensors, indexed by cycle position
    time_index: int,                # 0-based cycle position of time variable
    var_indices: List[int],         # 0-based cycle positions to read (sorted)
    skip_initial_line: bool = True,
    return_nans: bool = False,
    max_values: int = -1,
):
    """Returns list of (times, values) tuples, one per requested variable."""
    nv = len(var_indices)
    # Combined sorted index list including time
    all_indices = sorted(set([time_index] + list(var_indices)))
    time_pos_in_all = all_indices.index(time_index)
    nall = len(all_indices)
    all_indices_set = set(all_indices)
    # Map cycle position → position in `all_indices`
    pos_lookup = {idx: i for i, idx in enumerate(all_indices)}

    # Per-variable output buffers
    times_out = [[] for _ in range(nv)]
    values_out = [[] for _ in range(nv)]

    # SAME-state memory (per requested variable)
    memory = [math.nan] * nall

    min_offset = -2 if return_nans else -1
    fsize = os.path.getsize(filename)

    with open(filename, 'rb') as fp:
        fp.seek(binary_offset)
        flip = detect_byte_order(fp)

        is_first = True
        total_emitted = 0

        while fp.tell() < fsize:
            # Read state bytes (one cycle's worth)
            remaining = fsize - fp.tell()
            if remaining < n_state_bytes:
                break
            state_buf = fp.read(n_state_bytes)
            states = decode_state_bytes(state_buf, n_sensors)

            # Single pass over ALL cycle positions to compute:
            #   (a) total chunk_size
            #   (b) offset (within chunk) for each REQUESTED variable
            chunk_size = 0
            offsets = [-2] * nall  # -2=NOTSET, -1=SAME, ≥0=byte offset
            for pos in range(n_sensors):
                st = states[pos]
                if st == UPDATED:
                    if pos in all_indices_set:
                        offsets[pos_lookup[pos]] = chunk_size
                    chunk_size += cycle_bytesizes[pos]
                elif st == SAME:
                    if pos in all_indices_set:
                        offsets[pos_lookup[pos]] = -1

            # Read requested values from the chunk
            chunk_start = fp.tell()
            read_values = [math.nan] * nall
            for i, idx in enumerate(all_indices):
                off = offsets[i]
                if off >= 0:
                    fp.seek(chunk_start + off)
                    v = read_sensor_value(fp, cycle_bytesizes[idx], flip)
                    read_values[i] = v
                    memory[i] = v
                elif off == -1:
                    read_values[i] = memory[i]
                # else: NaN (NOTSET)

            # Advance past chunk + 1-byte separator
            fp.seek(chunk_start + chunk_size + 1)

            # Output decisions
            if skip_initial_line and is_first:
                is_first = False
                continue
            is_first = False

            t = read_values[time_pos_in_all]
            for vi, var_idx in enumerate(var_indices):
                pi = pos_lookup[var_idx]
                if pi == time_pos_in_all and var_idx == time_index:
                    # Special case: requesting the time variable itself
                    # dbdreader behaviour: still emit (t, t) pairs for time-only request
                    pass
                off = offsets[pi]
                if off >= min_offset:
                    v = read_values[pi]
                    times_out[vi].append(t)
                    values_out[vi].append(math.nan if off == -2 else v)

            total_emitted += 1
            if max_values > 0 and total_emitted >= max_values:
                break

    return [(times_out[i], values_out[i]) for i in range(nv)]


# ── High-level API for testing ────────────────────────────────────────────────

def open_dbd(filename: str, cachedir: str):
    """Open a DBD file: parse header, find cache, return (info, cycle_sensors, binary_offset)."""
    with open(filename, 'rb') as fp:
        info = parse_header(fp)
        binary_offset_after_header = fp.tell()
        # If sensor list is inline (factored=0), read it here; else load from cache
        if info['sensor_list_factored'] == 1:
            crc = info['sensor_list_crc']
            cac_path = os.path.join(cachedir, f"{crc}.cac")
            if not os.path.exists(cac_path):
                raise FileNotFoundError(f"Cache file {cac_path} not found")
            with open(cac_path) as fc:
                cac_text = fc.read()
            binary_offset = binary_offset_after_header
        else:
            # Read inline sensor list lines
            lines = []
            for _ in range(info['total_num_sensors']):
                lines.append(fp.readline().decode('ascii', errors='replace'))
            cac_text = ''.join(lines)
            binary_offset = fp.tell()
        cycle_sensors = parse_sensor_list(cac_text, info['total_num_sensors'])
    return info, cycle_sensors, binary_offset


def get(filename, params, cachedir='/tmp/cache', skip_initial_line=True, return_nans=False, max_values=-1):
    info, cycle_sensors, binary_offset = open_dbd(filename, cachedir)
    n_sensors = info['sensors_per_cycle']
    n_state_bytes = info['state_bytes_per_cycle']

    # Build name→cycle position map and bytesize array
    name_to_pos = {}
    cycle_bytesizes = [0] * n_sensors
    for i, si in enumerate(cycle_sensors):
        if si is None:
            continue
        name_to_pos[si.name] = i
        cycle_bytesizes[i] = si.bytesize

    # Determine time variable
    if 'm_present_time' in name_to_pos:
        time_var = 'm_present_time'
    elif 'sci_m_present_time' in name_to_pos:
        time_var = 'sci_m_present_time'
    else:
        raise RuntimeError(f"No time variable found in {filename}")
    time_index = name_to_pos[time_var]

    # Find param indices
    var_indices = []
    valid_params = []
    for p in params:
        if p in name_to_pos:
            var_indices.append(name_to_pos[p])
            valid_params.append(p)
    if not var_indices:
        return {p: ([], []) for p in params}

    # Sort indices for the reader
    perm = sorted(range(len(var_indices)), key=lambda i: var_indices[i])
    sorted_indices = [var_indices[i] for i in perm]

    sorted_results = read_binary(
        filename, binary_offset, n_state_bytes, n_sensors, cycle_bytesizes,
        time_index, sorted_indices,
        skip_initial_line=skip_initial_line, return_nans=return_nans,
        max_values=max_values,
    )

    # Re-sort back to original param order
    results = [None] * len(valid_params)
    for sorted_i, orig_i in enumerate(perm):
        results[orig_i] = sorted_results[sorted_i]

    # Build output dict
    out = {}
    j = 0
    for p in params:
        if p in name_to_pos:
            out[p] = results[j]
            j += 1
        else:
            out[p] = ([], [])
    return out


if __name__ == '__main__':
    import sys
    import numpy as np
    import hashlib

    cachedir = '/tmp/cache'

    files_params = [
        ("/mnt/user-data/uploads/02010000.dbd", ["m_depth", "m_heading", "m_pitch", "m_roll", "m_gps_lat", "m_battery"]),
        ("/mnt/user-data/uploads/02010000.sbd", ["m_depth", "m_gps_lat", "m_gps_lon"]),
        ("/mnt/user-data/uploads/02010000.tbd", ["sci_water_temp", "sci_water_cond", "sci_water_pressure"]),
    ]

    print("="*78)
    print(f"{'PARAMETER':30s}  {'N':>6s}  {'MIN':>14s}  {'MAX':>14s}  {'SHA':>10s}")
    print("="*78)
    for fn, params in files_params:
        print(f"\n--- {os.path.basename(fn)} ---")
        out = get(fn, params, cachedir=cachedir)
        for p in params:
            t, v = out[p]
            n = len(v)
            if n == 0:
                print(f"  {p:28s}  {'0':>6s}  --")
                continue
            arr = np.array(v, dtype=np.float64)
            sha = hashlib.sha256(arr.tobytes()).hexdigest()[:10]
            print(f"  {p:30s}  {n:>6d}  {arr.min():>14.4f}  {arr.max():>14.4f}  {sha:>10s}")
