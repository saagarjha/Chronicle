import Foundation
import os

// Enables intra-object bounds tracking in the log buffer
#if DEBUG
	public typealias _LogBuffer = UnsafeMutableRawBufferPointer
#else
	public typealias _LogBuffer = UnsafeMutableRawPointer
#endif

public struct Metadatav1: Codable {
	public struct Timing: Codable {
		public let numerator: UInt32
		public let denominator: UInt32
		public let timestamp: UInt64
		public let seconds: Int
		public let nanoseconds: Int
	}

	public struct Strings: Codable {
		public let start: UInt64
		public let size: UInt64
	}

	public var version = 1
	public var bitWidth = Int.bitWidth
	public var compressedStrings: Bool = {
		if #available(macOS 10.15, iOS 13, macCatalyst 13.1, tvOS 13, watchOS 6, *) {
			return true
		} else {
			return false
		}
	}()
	public let strings: [Strings]
	public let loggers: [String]
	public let timing: Timing
	
	static let radix = 0x10
}

public typealias Metadata = Metadatav1

public struct Chronicle {
	class Guts {
		let lock: UnsafeMutablePointer<os_unfair_lock>
		let cleanup: (() -> Void)?
		var loggers = [String]()

		init(cleanup: (() -> Void)?) {
			lock = .allocate(capacity: 1)
			lock.initialize(to: .init())
			self.cleanup = cleanup
		}

		func addLogger(named name: String) -> UInt16 {
			defer {
				loggers.append(name)
			}
			return UInt16(loggers.count)
		}

		deinit {
			lock.deallocate()
			cleanup?()
		}
	}

	static let metadataPath = "metadata.json"
	static let bufferPath = "buffer"
	static let stringsPath = "strings"

	let metadataUpdate: (Metadata, [UnsafeRawBufferPointer]) throws -> Void
	let buffer: Buffer
	let guts: Guts

	public init(buffer: UnsafeMutableRawBufferPointer, cleanup: (() -> Void)? = nil, metadataUpdate: @escaping (Metadata, [UnsafeRawBufferPointer]) throws -> Void) rethrows {
		StringCollector.initializeIfNeeded()

		self.buffer = Buffer(buffer: buffer)
		guts = Guts(cleanup: cleanup)
		self.metadataUpdate = metadataUpdate
		try metadataUpdate(updatedMetadata(), StringCollector.strings)
	}

	public init(url: URL, bufferSize: Int) throws {
		try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
		
		let strings = url.appendingPathComponent(Self.stringsPath)
		try FileManager.default.createDirectory(at: strings, withIntermediateDirectories: false)

		let _metadata = open(url.appendingPathComponent(Self.metadataPath).path, O_RDWR | O_CREAT, 0o644)
		guard _metadata >= 0 else {
			throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
		}
		let metadata = FileHandle(fileDescriptor: _metadata)

		let fd = open(url.appendingPathComponent(Self.bufferPath).path, O_RDWR | O_CREAT, 0o644)
		guard fd >= 0 else {
			throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
		}
		guard ftruncate(fd, off_t(bufferSize)) >= 0 else {
			throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
		}

		let _buffer = mmap(nil, bufferSize, PROT_READ | PROT_WRITE, MAP_FILE | MAP_SHARED, fd, 0)
		guard _buffer != MAP_FAILED else {
			throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
		}
		close(fd)
		let buffer = UnsafeMutableRawBufferPointer(start: _buffer, count: bufferSize)

		try self.init(
			buffer: buffer,
			cleanup: {
				munmap(buffer.baseAddress, buffer.count)
			},
			metadataUpdate: {
				metadata.seek(toFileOffset: 0)
				try metadata.write(JSONEncoder().encode($0))
				let existing = try Set(FileManager.default.contentsOfDirectory(atPath: strings.path).compactMap {
					UInt($0, radix: Metadata.radix).map(UnsafeRawPointer.init)
				})
				for data in $1 where !existing.contains(data.baseAddress) {
					var name = String(UInt(bitPattern: data.baseAddress), radix: Metadata.radix)
					while name.count < MemoryLayout<UInt>.size * (1 << 8).trailingZeroBitCount / Metadata.radix.trailingZeroBitCount {
						name = "0\(name)"
					}
					if #available(macOS 10.15, iOS 13, macCatalyst 13.1, tvOS 13, watchOS 6, *) {
						try NSData(bytesNoCopy: UnsafeMutableRawPointer(mutating: data.baseAddress!), length: data.count, freeWhenDone: false).compressed(using: .lzfse).write(to: strings.appendingPathComponent(name))
					} else {
						try Data(data).write(to: strings.appendingPathComponent(name))
					}
				}
			})
	}

	func updatedMetadata() -> Metadata {
		var timebase = mach_timebase_info()
		mach_timebase_info(&timebase)

		var time = timespec()
		clock_gettime(CLOCK_REALTIME, &time)

		return Metadata(
			strings: StringCollector.strings.map {
				.init(start: UInt64(UInt(bitPattern: $0.baseAddress)), size: UInt64($0.count))
			},
			loggers: guts.loggers,
			timing: .init(
				numerator: timebase.numer,
				denominator: timebase.denom,
				timestamp: mach_continuous_time(),
				seconds: time.tv_sec,
				nanoseconds: time.tv_nsec
			)
		)
	}

	public func logger(name: String) throws -> Logger {
		os_unfair_lock_lock(guts.lock)
		let id = guts.addLogger(named: name)
		let metadata = updatedMetadata()
		os_unfair_lock_unlock(guts.lock)

		try metadataUpdate(metadata, StringCollector.strings)
		return Logger(chronicle: self, id: id)
	}

	func __prepare_log(size: Int) -> _LogBuffer? {
		os_unfair_lock_lock(guts.lock)
		guard let buffer = buffer.reserve(size: size) else {
			os_unfair_lock_unlock(guts.lock)
			return nil
		}
		return buffer
	}

	func __complete_log() {
		buffer.complete()
		os_unfair_lock_unlock(guts.lock)
	}
}
