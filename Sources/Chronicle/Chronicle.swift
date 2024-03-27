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

	public var version = 1
	public let images: [Image]
	public let loggers: [String]
	public let timing: Timing
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

	let metadataUpdate: (Metadata) throws -> Void
	let buffer: Buffer
	let guts: Guts
	
	public init(buffer: UnsafeMutableRawBufferPointer, cleanup: (() -> Void)? = nil, metadataUpdate: @escaping (Metadata) throws -> Void) rethrows {		
		ImageTracker.initializeIfNeeded()

		self.buffer = Buffer(buffer: buffer)
		guts = Guts(cleanup: cleanup)
		self.metadataUpdate = metadataUpdate
		try metadataUpdate(updatedMetadata())
	}

	public init(url: URL, bufferSize: Int) throws {
		try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)

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

		try self.init(buffer: buffer, cleanup: {
			munmap(buffer.baseAddress, buffer.count)
		}, metadataUpdate: {
			metadata.seek(toFileOffset: 0)
			try metadata.write(JSONEncoder().encode($0))
		})
	}

	func updatedMetadata() -> Metadata {
		var timebase = mach_timebase_info()
		mach_timebase_info(&timebase)

		var time = timespec()
		clock_gettime(CLOCK_REALTIME, &time)

		return Metadata(
			images: ImageTracker.images,
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

		try metadataUpdate(metadata)
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
