import Foundation

public struct Epilog {
	let forwardBuffer: Data
	let backwardBuffer: Data
	let bitWidth: Int
	let loggers: [String]
	let timing: Metadata.Timing
	let strings: [UInt64: String]

	public var entries: EntrySequence {
		EntrySequence(epilog: self)
	}

	public init(buffer: Data, metadata: Metadatav1, strings: [(UInt64, Data)]) {
		(forwardBuffer, backwardBuffer) = Self.readLogs(in: buffer)
		bitWidth = metadata.bitWidth
		loggers = metadata.loggers
		timing = metadata.timing

		self.strings = Dictionary(
			uniqueKeysWithValues: strings.reduce([]) {
				$0 + Self.strings(in: $1.1, relativeTo: $1.0)
			})
	}

	init(_url url: URL, stringsTransform: (Data, Metadatav1) throws -> Data) throws {
		let buffer = try Data(contentsOf: url.appendingPathComponent(Chronicle.bufferPath))
		let metadata = try JSONDecoder().decode(Metadatav1.self, from: try Data(contentsOf: url.appendingPathComponent(Chronicle.metadataPath)))

		let _strings = url.appendingPathComponent(Chronicle.stringsPath)
		let strings: [(UInt64, Data)] = try FileManager.default.contentsOfDirectory(atPath: _strings.path).compactMap {
			guard let base = UInt64($0, radix: Metadatav1.radix) else {
				return nil
			}
			return (base, try stringsTransform(Data(contentsOf: _strings.appendingPathComponent($0)), metadata))
		}
		self.init(buffer: buffer, metadata: metadata, strings: strings)
	}

	public init(url: URL) throws {
		try self.init(_url: url) {
			guard $1.compressedStrings else {
				return $0
			}
			guard #available(macOS 10.15, iOS 13, macCatalyst 13.1, tvOS 13, watchOS 6, *) else {
				preconditionFailure()
			}
			return try ($0 as NSData).decompressed(using: .lzfse) as Data
		}
	}

	static func readLogs(in buffer: Data) -> (Data, Data) {
		var position = buffer.startIndex

		var last: Data.Index!
		var forward: Data!

		while true {
			var _last: Data.Index = position.advanced(by: MemoryLayout<Buffer.Progress.RawValue>.size)
			var advances = [() -> Void]()
			var next = false

			func advance(by size: @escaping @autoclosure () -> Int) {
				advances.append({
					let size = size()
					precondition(buffer.endIndex - _last >= size)
					_last += size
				})
			}

			switch Buffer.Progress(rawValue: buffer[position])! {
				case .used:
					next = true
					fallthrough
				case .completed:
					advance(by: MemoryLayout<Buffer.Progress.RawValue>.size)
					fallthrough
				case .completing:
					advance(by: MemoryLayout<Buffer.Size>.size)
					fallthrough
				case .prepared:
					advance(
						by: Int(
							buffer[_last...].withUnsafeBytes {
								$0.baseAddress!.loadUnaligned(fromByteOffset: -MemoryLayout<Buffer.Size>.size, as: Buffer.Size.self)
							}))
					fallthrough
				case .preparing:
					advance(by: MemoryLayout<Buffer.Size>.size)
				case .unused:
					advance(by: MemoryLayout<Buffer.Progress.RawValue>.size)
			}

			for advance in advances.reversed() {
				advance()
			}

			guard next else {
				forward = buffer[..<position]
				last = _last
				break
			}

			position = _last - MemoryLayout<Buffer.Progress.RawValue>.size
		}

		var distance = 0
		var trailer = buffer.endIndex

		var bits: UInt8
		repeat {
			trailer -= 1
			// We've clobbered the trailer. This means we've gone close enough
			// to the end of the buffer that we aren't going to have any
			// backward entries. (The largest distance we can represent in a
			// 64-bit ULEB-128 integer is not enough to fit an entry.)
			guard trailer >= last else {
				return (forward, Data())
			}
			bits = buffer[trailer]
			distance |= Int(bits & 0b0111_1111) << (7 * (buffer.index(before: buffer.endIndex) - trailer))
		} while bits & 0b1000_0000 != 0
		distance += 1

		var start = buffer.endIndex

		func retreat(size: Int) -> Int? {
			guard start - last >= size else {
				return nil
			}
			return start - size
		}

		start = retreat(size: distance)!
		let end = start

		while var _start = retreat(size: MemoryLayout<Buffer.Size>.size) {
			let size = buffer[_start...].withUnsafeBytes {
				$0.loadUnaligned(as: Buffer.Size.self)
			}

			// If size is zero, we never wrote a backward chain.
			guard size != 0 else {
				return (forward, Data())
			}

			swap(&start, &_start)
			guard let __start = retreat(size: Int(size) - MemoryLayout<Buffer.Size>.size) else {
				return (forward, buffer[_start..<end])
			}
			start = __start
		}

		fatalError()
	}

	static func strings(in strings: Data, relativeTo base: UInt64) -> [(UInt64, String)] {
		strings.split(separator: 0, omittingEmptySubsequences: false).compactMap {
			guard let string = String(data: $0, encoding: .utf8) else {
				return nil
			}
			return (UInt64($0.startIndex - strings.startIndex) + base, string)
		}
	}
}
