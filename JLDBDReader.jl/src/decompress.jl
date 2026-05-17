"""
LZ4 block decompression for Slocum compressed glider data files.

Compressed Slocum files (extensions `.dcd`, `.ecd`, ..., `.ccc`) contain a
sequence of LZ4 blocks, each preceded by a 2-byte big-endian length.  Each
block decompresses to at most 32 KiB.

This is a pure-Julia decoder for the LZ4 block format
(https://github.com/lz4/lz4/blob/dev/doc/lz4_Block_format.md) — no external
library needed.  No frame format, just bare blocks.
"""

const LZ4_MAX_BLOCK_BYTES = 32 * 1024

"""
    lz4_decompress_block(src, max_output=LZ4_MAX_BLOCK_BYTES) -> Vector{UInt8}

Decompress a single LZ4 block.

# Arguments
- `src::AbstractVector{UInt8}` : compressed block payload (no frame header)
- `max_output::Int` : maximum allowed decompressed size

Throws `ErrorException` for malformed input or buffer overflow.
"""
function lz4_decompress_block(src::AbstractVector{UInt8},
                              max_output::Int=LZ4_MAX_BLOCK_BYTES)::Vector{UInt8}
    n = length(src)
    n > 0 || return UInt8[]
    dst = Vector{UInt8}(undef, max_output)
    si = 1   # 1-based source index
    di = 1   # 1-based destination index

    @inbounds while si <= n
        # ── Token byte: high nibble = literal length, low nibble = match length ──
        token = src[si]; si += 1
        lit_len = Int(token >> 4)
        match_len = Int(token & 0x0F)

        # Extend literal length
        if lit_len == 15
            while si <= n
                extra = src[si]; si += 1
                lit_len += Int(extra)
                extra == 0xFF || break
            end
        end

        # Copy literals
        if lit_len > 0
            src_end = si + lit_len - 1
            (src_end <= n) || error("LZ4: literal copy reads past end of source")
            (di + lit_len - 1 <= max_output) || error("LZ4: output buffer too small for literals")
            copyto!(dst, di, src, si, lit_len)
            si += lit_len
            di += lit_len
        end

        # End-of-block: per spec, last block ends after final literal copy
        si > n && break
        # Need at least 2 bytes for the match offset
        si + 1 > n && error("LZ4: truncated match offset")

        # Match offset (little-endian 16-bit)
        offset = Int(src[si]) | (Int(src[si+1]) << 8)
        si += 2
        offset > 0 || error("LZ4: invalid zero match offset")

        # Extend match length (min match = 4)
        if match_len == 15
            while si <= n
                extra = src[si]; si += 1
                match_len += Int(extra)
                extra == 0xFF || break
            end
        end
        match_len += 4

        match_start = di - offset
        match_start >= 1 || error("LZ4: match offset before output start")
        (di + match_len - 1 <= max_output) || error("LZ4: output overflow on match copy")

        # Byte-by-byte copy (matches may overlap; standard LZ4 behaviour)
        for k in 0:match_len-1
            dst[di + k] = dst[match_start + k]
        end
        di += match_len
    end

    return resize!(dst, di - 1)
end

"""
    decompress_glider_stream(io::IO) -> Vector{UInt8}

Read and decompress an entire stream of (2-byte-BE length, LZ4 block) pairs.
"""
function decompress_glider_stream(io::IO)::Vector{UInt8}
    chunks = Vector{UInt8}[]
    while !eof(io)
        sb = read(io, 2)
        length(sb) == 2 || break
        blocksize = (Int(sb[1]) << 8) | Int(sb[2])
        blocksize == 0 && break
        compressed = read(io, blocksize)
        length(compressed) == blocksize ||
            error("LZ4: truncated block (expected $blocksize, got $(length(compressed)))")
        push!(chunks, lz4_decompress_block(compressed))
    end
    return isempty(chunks) ? UInt8[] : reduce(vcat, chunks)
end

"""
    decompress_glider_file(filename) -> Vector{UInt8}

Decompress an entire compressed glider data file, returning the raw bytes.
"""
decompress_glider_file(filename::AbstractString)::Vector{UInt8} =
    open(decompress_glider_stream, filename, "r")

"""
    decompressed_extension(ext) -> String

Map a compressed extension to its uncompressed counterpart.  Examples:
`.dcd` → `.dbd`, `.ecg` → `.elg`, `.ccc` → `.cac`.
"""
function decompressed_extension(ext::AbstractString)::String
    e = lowercase(ext)
    startswith(e, ".") || (e = "." * e)
    length(e) == 4 || error("Invalid compressed extension: $ext")
    suffix = e[3:4]
    if suffix == "cg"
        return e[1:2] * "lg"
    elseif suffix == "cd"
        return e[1:2] * "bd"
    elseif suffix == "cc"
        return e[1:2] * "ac"
    else
        error("Unrecognised compressed extension: $ext")
    end
end
