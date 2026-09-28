import Foundation

/// Just enough of the WAV format to find the samples: the fmt chunk and the data chunk,
/// skipping anything else (AVAudioFile writes a FLLR padding chunk, for one).
struct WavHeader: Equatable {
    var format: UInt16        // 1 = PCM int, 3 = float
    var channels: UInt16
    var sampleRate: UInt32
    var bitsPerSample: UInt16
    var dataOffset: Int
    var dataLength: Int

    var bytesPerFrame: Int { Int(channels) * Int(bitsPerSample) / 8 }
    var frames: Int { bytesPerFrame > 0 ? dataLength / bytesPerFrame : 0 }
    var seconds: Double { sampleRate > 0 ? Double(frames) / Double(sampleRate) : 0 }

    static func parse(_ bytes: UnsafeRawBufferPointer, fileSize: Int? = nil) -> WavHeader? {
        guard bytes.count >= 12 else { return nil }
        func u32(_ o: Int) -> UInt32 { UInt32(bytes[o]) | UInt32(bytes[o+1]) << 8 | UInt32(bytes[o+2]) << 16 | UInt32(bytes[o+3]) << 24 }
        func u16(_ o: Int) -> UInt16 { UInt16(bytes[o]) | UInt16(bytes[o+1]) << 8 }
        func tag(_ o: Int) -> String { String(bytes: bytes[o..<o+4], encoding: .ascii) ?? "" }
        guard tag(0) == "RIFF", tag(8) == "WAVE" else { return nil }
        var o = 12
        var fmt: (UInt16, UInt16, UInt32, UInt16)?
        while o + 8 <= bytes.count {
            let id = tag(o)
            let len = Int(u32(o + 4))
            let body = o + 8
            if id == "fmt ", body + 16 <= bytes.count {
                var f = u16(body)
                if f == 0xFFFE, body + 26 <= bytes.count { f = u16(body + 24) } // WAVE_FORMAT_EXTENSIBLE
                fmt = (f, u16(body + 2), u32(body + 4), u16(body + 14))
            } else if id == "data", let fm = fmt {
                let available = (fileSize ?? bytes.count) - body
                // A recording cut off mid-write leaves the length at 0 or too big; trust the file.
                let length = (len == 0 || len > available) ? available : len
                return WavHeader(format: fm.0, channels: fm.1, sampleRate: fm.2, bitsPerSample: fm.3, dataOffset: body, dataLength: length)
            }
            o = body + len + (len & 1)
        }
        return nil
    }

    static func read(url: URL) -> WavHeader? {
        guard let h = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? h.close() }
        guard let head = try? h.read(upToCount: 4096) else { return nil }
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? head.count
        let parsed = head.withUnsafeBytes { parse($0, fileSize: size) }
        return parsed
    }
}

/// A WAV file mapped into memory, read one sample at a time by the tape head.
final class MappedWav {
    let url: URL
    let header: WavHeader
    private let base: UnsafeRawPointer
    private let size: Int

    init?(url: URL) {
        self.url = url
        let fd = open(url.path, O_RDONLY)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var st = stat()
        guard fstat(fd, &st) == 0, st.st_size > 44 else { return nil }
        let n = Int(st.st_size)
        guard let p = mmap(nil, n, PROT_READ, MAP_PRIVATE, fd, 0), p != MAP_FAILED else { return nil }
        guard let h = WavHeader.parse(UnsafeRawBufferPointer(start: p, count: min(n, 65536)), fileSize: n) else { munmap(p, n); return nil }
        header = h
        base = UnsafeRawPointer(p)
        size = n
    }

    deinit { munmap(UnsafeMutableRawPointer(mutating: base), size) }

    var seconds: Double { header.seconds }

    /// Loudest sample per bin, 0...1, for waveform drawing. Samples a few dozen frames per
    /// bin rather than all of them, so an hour of audio takes a moment, not a minute.
    func peaks(perSecond: Double) -> [Float] {
        let sr = Double(header.sampleRate)
        guard sr > 0, header.frames > 0 else { return [] }
        let perBin = max(1, Int(sr / perSecond))
        let bins = header.frames / perBin + 1
        let stride = max(1, perBin / 48)
        var out = [Float](repeating: 0, count: bins)
        for b in 0..<bins {
            var m: Float = 0
            var f = b * perBin
            let end = min(header.frames, f + perBin)
            while f < end { let v = abs(raw(f)); if v > m { m = v }; f += stride }
            out[b] = m
        }
        return out
    }

    /// First channel at a time in seconds, linearly interpolated.
    @inline(__always) func sample(at seconds: Double) -> Float {
        let pos = seconds * Double(header.sampleRate)
        let i = Int(pos)
        let frac = Float(pos - Double(i))
        return raw(i) * (1 - frac) + raw(i + 1) * frac
    }

    @inline(__always) private func raw(_ frame: Int) -> Float {
        guard frame >= 0, frame < header.frames else { return 0 }
        let o = header.dataOffset + frame * header.bytesPerFrame
        switch (header.format, header.bitsPerSample) {
        case (1, 16): return Float(base.loadUnaligned(fromByteOffset: o, as: Int16.self)) / 32768
        case (3, 32): return base.loadUnaligned(fromByteOffset: o, as: Float.self)
        case (1, 24):
            let b0 = Int32(base.load(fromByteOffset: o, as: UInt8.self))
            let b1 = Int32(base.load(fromByteOffset: o + 1, as: UInt8.self))
            let b2 = Int32(base.load(fromByteOffset: o + 2, as: Int8.self))
            return Float(b0 | b1 << 8 | b2 << 16) / 8388608
        default: return 0
        }
    }
}
