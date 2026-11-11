import Compression
import Foundation

/// Zip mínimo (PKWARE APPNOTE 6.3) para o pacote `.fitjourney`, sem dependências de terceiros.
///
/// Escreve entradas *stored* (mídia já comprimida) ou *deflate* (JSON, via `NSData.compressed(.zlib)`,
/// que é DEFLATE cru — RFC 1951). Lê os dois métodos e confere o CRC-32. Sem Zip64: até 65.535
/// entradas e 4 GB — acima disso a exportação falha com erro claro. Nomes UTF-8 (bit 11).
enum ZipError: Error, Equatable, Sendable {
    case notAZip
    case corrupted(String)
    case unsupportedMethod(UInt16)
    case tooLarge
    case entryNotFound(String)
}

/// Escrita sequencial num arquivo novo. Use `finish()` no fim; em erro, apague o arquivo.
final class ZipWriter {
    private struct CentralRecord {
        var name: Data
        var method: UInt16
        var crc: UInt32
        var compressedSize: UInt32
        var size: UInt32
        var offset: UInt32
    }

    private let handle: FileHandle
    private var records: [CentralRecord] = []
    private var offset: UInt64 = 0
    private let dosTime: UInt16
    private let dosDate: UInt16
    private static let chunkSize = 1 << 20

    init(url: URL, date: Date = .now) throws {
        guard FileManager.default.createFile(atPath: url.path(percentEncoded: false), contents: nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        handle = try FileHandle(forWritingTo: url)
        (dosTime, dosDate) = Self.dosDateTime(date)
    }

    deinit { try? handle.close() }

    /// Entrada a partir de bytes em memória. `compress` tenta DEFLATE (cai para *stored* se não ganhar).
    func add(name: String, data: Data, compress: Bool) throws {
        let crc = CRC32.checksum(data)
        var method: UInt16 = 0
        var payload = data
        if compress, !data.isEmpty, let deflated = try? (data as NSData).compressed(using: .zlib) as Data,
           deflated.count < data.count {
            method = 8
            payload = deflated
        }
        guard data.count <= UInt32.max, payload.count <= UInt32.max else { throw ZipError.tooLarge }
        let headerOffset = try beginEntry(name: name, method: method, crc: crc,
                                          compressedSize: UInt32(payload.count), size: UInt32(data.count))
        try write(payload)
        records.append(CentralRecord(name: Data(name.utf8), method: method, crc: crc,
                                     compressedSize: UInt32(payload.count), size: UInt32(data.count), offset: headerOffset))
    }

    /// Entrada com bytes e cabeçalho informados como estão (testes de arquivos malformados).
    func addRaw(name: String, payload: Data, method: UInt16, crc: UInt32, size: UInt32) throws {
        let headerOffset = try beginEntry(name: name, method: method, crc: crc,
                                          compressedSize: UInt32(payload.count), size: size)
        try write(payload)
        records.append(CentralRecord(name: Data(name.utf8), method: method, crc: crc,
                                     compressedSize: UInt32(payload.count), size: size, offset: headerOffset))
    }

    /// Entrada *stored* copiada de um arquivo em blocos (não carrega o arquivo inteiro na memória).
    /// `onBytes` informa o progresso (bytes copiados neste bloco).
    func add(name: String, contentsOf source: URL, onBytes: (Int) -> Void = { _ in }) throws {
        let reader = try FileHandle(forReadingFrom: source)
        defer { try? reader.close() }
        let headerOffset = try beginEntry(name: name, method: 0, crc: 0, compressedSize: 0, size: 0)
        var crc = CRC32()
        var total: UInt64 = 0
        while true {
            try Task.checkCancellation()
            guard let chunk = try reader.read(upToCount: Self.chunkSize), !chunk.isEmpty else { break }
            crc.update(chunk)
            total += UInt64(chunk.count)
            guard total <= UInt32.max else { throw ZipError.tooLarge }
            try write(chunk)
            onBytes(chunk.count)
        }
        // Volta ao cabeçalho local para gravar CRC e tamanhos.
        let end = offset
        try handle.seek(toOffset: UInt64(headerOffset) + 14)
        var patch = Data()
        patch.appendLE(crc.value)
        patch.appendLE(UInt32(total))
        patch.appendLE(UInt32(total))
        try handle.write(contentsOf: patch)
        try handle.seek(toOffset: end)
        records.append(CentralRecord(name: Data(name.utf8), method: 0, crc: crc.value,
                                     compressedSize: UInt32(total), size: UInt32(total), offset: headerOffset))
    }

    func finish() throws {
        guard records.count < UInt16.max else { throw ZipError.tooLarge }
        let centralStart = offset
        for record in records {
            var d = Data()
            d.appendLE(UInt32(0x0201_4B50))
            d.appendLE(UInt16(0x031E)) // feito por: Unix, spec 3.0
            d.appendLE(UInt16(20))
            d.appendLE(UInt16(0x0800))
            d.appendLE(record.method)
            d.appendLE(dosTime)
            d.appendLE(dosDate)
            d.appendLE(record.crc)
            d.appendLE(record.compressedSize)
            d.appendLE(record.size)
            d.appendLE(UInt16(record.name.count))
            d.appendLE(UInt16(0)) // extra
            d.appendLE(UInt16(0)) // comentário
            d.appendLE(UInt16(0)) // disco
            d.appendLE(UInt16(0)) // atributos internos
            d.appendLE(UInt32(0o100644) << 16) // atributos externos (rw-r--r--)
            d.appendLE(record.offset)
            d.append(record.name)
            try write(d)
        }
        let centralSize = offset - centralStart
        guard offset <= UInt32.max else { throw ZipError.tooLarge }
        var end = Data()
        end.appendLE(UInt32(0x0605_4B50))
        end.appendLE(UInt16(0))
        end.appendLE(UInt16(0))
        end.appendLE(UInt16(records.count))
        end.appendLE(UInt16(records.count))
        end.appendLE(UInt32(centralSize))
        end.appendLE(UInt32(centralStart))
        end.appendLE(UInt16(0))
        try write(end)
        try handle.synchronize()
        try handle.close()
    }

    private func beginEntry(name: String, method: UInt16, crc: UInt32, compressedSize: UInt32, size: UInt32) throws -> UInt32 {
        guard offset <= UInt32.max else { throw ZipError.tooLarge }
        let headerOffset = UInt32(offset)
        let nameData = Data(name.utf8)
        var d = Data()
        d.appendLE(UInt32(0x0403_4B50))
        d.appendLE(UInt16(20))
        d.appendLE(UInt16(0x0800))
        d.appendLE(method)
        d.appendLE(dosTime)
        d.appendLE(dosDate)
        d.appendLE(crc)
        d.appendLE(compressedSize)
        d.appendLE(size)
        d.appendLE(UInt16(nameData.count))
        d.appendLE(UInt16(0))
        d.append(nameData)
        try write(d)
        return headerOffset
    }

    private func write(_ data: Data) throws {
        try handle.write(contentsOf: data)
        offset += UInt64(data.count)
    }

    private static func dosDateTime(_ date: Date) -> (UInt16, UInt16) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        let year = max(1980, min(2107, c.year ?? 1980))
        let time = UInt16((c.hour ?? 0) << 11 | (c.minute ?? 0) << 5 | (c.second ?? 0) / 2)
        let day = UInt16((year - 1980) << 9 | (c.month ?? 1) << 5 | (c.day ?? 1))
        return (time, day)
    }
}

/// Leitura por acesso aleatório (o pacote pode ter centenas de MB de vídeo).
final class ZipReader {
    struct Entry: Sendable, Equatable {
        var name: String
        var method: UInt16
        var crc: UInt32
        var compressedSize: UInt32
        var size: UInt32
        var localHeaderOffset: UInt32
        var isDirectory: Bool { name.hasSuffix("/") }
    }

    let entries: [Entry]
    private let handle: FileHandle
    private let fileSize: UInt64

    init(url: URL) throws {
        handle = try FileHandle(forReadingFrom: url)
        fileSize = try handle.seekToEnd()
        do {
            entries = try Self.readCentralDirectory(handle: handle, fileSize: fileSize)
        } catch {
            try? handle.close()
            throw error
        }
    }

    deinit { try? handle.close() }

    /// O arquivo começa com a assinatura de cabeçalho local zip ("PK\u{3}\u{4}").
    static func looksLikeZip(_ url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        return (try? handle.read(upToCount: 4)) == Data([0x50, 0x4B, 0x03, 0x04])
    }

    func entry(named name: String) -> Entry? { entries.first { $0.name == name } }

    /// Conteúdo inteiro em memória (só para entradas pequenas, como `data.json`). Confere tamanho e CRC.
    /// DEFLATE é inflado em blocos e abortado assim que passar de `entry.size` (bomba de descompressão).
    func data(for entry: Entry, maxSize: Int) throws -> Data {
        guard Int(entry.size) <= maxSize, Int(entry.compressedSize) <= maxSize else { throw ZipError.tooLarge }
        let raw = try readRaw(entry)
        let data: Data
        switch entry.method {
        case 0:
            data = raw
        case 8:
            data = try Self.inflate(raw, limit: Int(entry.size), name: entry.name)
        default:
            throw ZipError.unsupportedMethod(entry.method)
        }
        guard data.count == Int(entry.size), CRC32.checksum(data) == entry.crc else { throw ZipError.corrupted(entry.name) }
        return data
    }

    /// DEFLATE cru em blocos com `compression_stream`; passou de `limit` bytes → `corrupted`.
    static func inflate(_ input: Data, limit: Int, name: String) throws -> Data {
        var stream = compression_stream(dst_ptr: UnsafeMutablePointer<UInt8>(bitPattern: 1)!, dst_size: 0,
                                        src_ptr: UnsafePointer<UInt8>(bitPattern: 1)!, src_size: 0, state: nil)
        guard compression_stream_init(&stream, COMPRESSION_STREAM_DECODE, COMPRESSION_ZLIB) == COMPRESSION_STATUS_OK else {
            throw ZipError.corrupted(name)
        }
        defer { compression_stream_destroy(&stream) }
        let chunk = 64 * 1024
        var output = Data()
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: chunk)
        defer { buffer.deallocate() }
        return try input.withUnsafeBytes { (source: UnsafeRawBufferPointer) -> Data in
            guard let base = source.bindMemory(to: UInt8.self).baseAddress else { return Data() }
            stream.src_ptr = base
            stream.src_size = source.count
            while true {
                stream.dst_ptr = buffer
                stream.dst_size = chunk
                let status = compression_stream_process(&stream, Int32(COMPRESSION_STREAM_FINALIZE.rawValue))
                let produced = chunk - stream.dst_size
                if produced > 0 {
                    guard output.count + produced <= limit else { throw ZipError.corrupted(name) }
                    output.append(buffer, count: produced)
                }
                switch status {
                case COMPRESSION_STATUS_END: return output
                case COMPRESSION_STATUS_OK:
                    if produced == 0 && stream.src_size == 0 { throw ZipError.corrupted(name) }
                default: throw ZipError.corrupted(name)
                }
            }
        }
    }

    /// Extrai uma entrada *stored* para `destination` em blocos (nunca infla: a mídia do pacote é sempre
    /// *stored*). Grava num temporário vizinho e move no fim (atômico); confere tamanho e CRC.
    func extract(_ entry: Entry, to destination: URL, maxSize: Int64) throws {
        guard entry.method == 0 else { throw ZipError.unsupportedMethod(entry.method) }
        guard entry.size == entry.compressedSize, Int64(entry.size) <= maxSize else { throw ZipError.tooLarge }
        let start = try dataOffset(of: entry)
        guard start + UInt64(entry.compressedSize) <= fileSize else { throw ZipError.corrupted(entry.name) }
        let temporary = destination.deletingLastPathComponent()
            .appending(path: ".partial-\(UUID().uuidString)", directoryHint: .notDirectory)
        guard FileManager.default.createFile(atPath: temporary.path(percentEncoded: false), contents: nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        let out = try FileHandle(forWritingTo: temporary)
        var crc = CRC32()
        do {
            try handle.seek(toOffset: start)
            var remaining = Int(entry.compressedSize)
            while remaining > 0 {
                try Task.checkCancellation()
                guard let chunk = try handle.read(upToCount: min(remaining, 1 << 20)), !chunk.isEmpty else {
                    throw ZipError.corrupted(entry.name)
                }
                crc.update(chunk)
                try out.write(contentsOf: chunk)
                remaining -= chunk.count
            }
            try out.close()
            guard crc.value == entry.crc else { throw ZipError.corrupted(entry.name) }
            try FileManager.default.moveItem(at: temporary, to: destination)
        } catch {
            try? out.close()
            try? FileManager.default.removeItem(at: temporary)
            throw error
        }
    }

    /// Início dos dados da entrada. O nome do cabeçalho local tem de ser igual ao do diretório central.
    private func dataOffset(of entry: Entry) throws -> UInt64 {
        try handle.seek(toOffset: UInt64(entry.localHeaderOffset))
        guard let header = try handle.read(upToCount: 30), header.count == 30,
              header.readLE(UInt32.self, at: 0) == 0x0403_4B50 else { throw ZipError.corrupted(entry.name) }
        let nameLength = Int(header.readLE(UInt16.self, at: 26))
        let extraLength = UInt64(header.readLE(UInt16.self, at: 28))
        guard let localName = try handle.read(upToCount: nameLength), localName == Data(entry.name.utf8) else {
            throw ZipError.corrupted(entry.name)
        }
        return UInt64(entry.localHeaderOffset) + 30 + UInt64(nameLength) + extraLength
    }

    private func readRaw(_ entry: Entry) throws -> Data {
        let start = try dataOffset(of: entry)
        guard start + UInt64(entry.compressedSize) <= fileSize else { throw ZipError.corrupted(entry.name) }
        try handle.seek(toOffset: start)
        let data = try handle.read(upToCount: Int(entry.compressedSize)) ?? Data()
        guard data.count == Int(entry.compressedSize) else { throw ZipError.corrupted(entry.name) }
        return data
    }

    private static func readCentralDirectory(handle: FileHandle, fileSize: UInt64) throws -> [Entry] {
        guard fileSize >= 22 else { throw ZipError.notAZip }
        let tailLength = min(fileSize, 22 + 65_535)
        try handle.seek(toOffset: fileSize - tailLength)
        guard let tail = try handle.read(upToCount: Int(tailLength)), tail.count == Int(tailLength) else {
            throw ZipError.notAZip
        }
        var eocd: Int?
        var index = tail.count - 22
        while index >= 0 {
            if tail.readLE(UInt32.self, at: index) == 0x0605_4B50 { eocd = index; break }
            index -= 1
        }
        guard let eocd else { throw ZipError.notAZip }
        let count = Int(tail.readLE(UInt16.self, at: eocd + 10))
        let centralSize = UInt64(tail.readLE(UInt32.self, at: eocd + 12))
        let centralOffset = UInt64(tail.readLE(UInt32.self, at: eocd + 16))
        guard centralOffset + centralSize <= fileSize else { throw ZipError.corrupted("central directory") }
        try handle.seek(toOffset: centralOffset)
        guard let central = try handle.read(upToCount: Int(centralSize)), central.count == Int(centralSize) else {
            throw ZipError.corrupted("central directory")
        }
        var entries: [Entry] = []
        var cursor = 0
        for _ in 0 ..< count {
            guard cursor + 46 <= central.count, central.readLE(UInt32.self, at: cursor) == 0x0201_4B50 else {
                throw ZipError.corrupted("central directory")
            }
            let method = central.readLE(UInt16.self, at: cursor + 10)
            let crc = central.readLE(UInt32.self, at: cursor + 16)
            let compressed = central.readLE(UInt32.self, at: cursor + 20)
            let size = central.readLE(UInt32.self, at: cursor + 24)
            let nameLength = Int(central.readLE(UInt16.self, at: cursor + 28))
            let extraLength = Int(central.readLE(UInt16.self, at: cursor + 30))
            let commentLength = Int(central.readLE(UInt16.self, at: cursor + 32))
            let offset = central.readLE(UInt32.self, at: cursor + 42)
            let nameStart = cursor + 46
            guard nameStart + nameLength <= central.count else { throw ZipError.corrupted("central directory") }
            let name = String(decoding: central.subdata(in: central.startIndex + nameStart ..< central.startIndex + nameStart + nameLength),
                              as: UTF8.self)
            entries.append(Entry(name: name, method: method, crc: crc, compressedSize: compressed, size: size,
                                 localHeaderOffset: offset))
            cursor = nameStart + nameLength + extraLength + commentLength
        }
        // Nomes repetidos permitiriam trocar o conteúdo visto pela validação e pela extração.
        guard Set(entries.map(\.name)).count == entries.count else { throw ZipError.corrupted("nomes repetidos") }
        return entries
    }
}

// MARK: - CRC-32 (IEEE 802.3, o do zip)

struct CRC32: Sendable {
    private static let table: [UInt32] = (0 ..< 256).map { n in
        var c = UInt32(n)
        for _ in 0 ..< 8 { c = (c & 1) != 0 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1 }
        return c
    }

    private var state: UInt32 = 0xFFFF_FFFF

    mutating func update(_ data: Data) {
        var c = state
        Self.table.withUnsafeBufferPointer { table in
            data.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in
                for byte in bytes { c = table[Int((c ^ UInt32(byte)) & 0xFF)] ^ (c >> 8) }
            }
        }
        state = c
    }

    var value: UInt32 { state ^ 0xFFFF_FFFF }

    static func checksum(_ data: Data) -> UInt32 {
        var crc = CRC32()
        crc.update(data)
        return crc.value
    }
}

// MARK: - Little endian

extension Data {
    mutating func appendLE<T: FixedWidthInteger>(_ value: T) {
        Swift.withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) }
    }

    func readLE<T: FixedWidthInteger>(_: T.Type, at offset: Int) -> T {
        var value: T = 0
        let size = MemoryLayout<T>.size
        guard offset >= 0, offset + size <= count else { return 0 }
        for i in 0 ..< size {
            value |= T(self[startIndex + offset + i]) << (8 * i)
        }
        return value
    }
}
