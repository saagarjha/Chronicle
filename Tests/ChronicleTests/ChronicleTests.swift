import Chronicle
import Foundation
import XCTest

final class ChronicleTests: XCTestCase {
	static func inMemoryChronicleWithBuffer(size: Int, metadataUpdate: ((Metadata) -> Void)? = nil) -> (Chronicle, UnsafeMutableRawBufferPointer) {
		let buffer = UnsafeMutableRawBufferPointer.allocate(byteCount: size, alignment: 1)
		return (
			Chronicle(
				buffer: buffer,
				cleanup: {
					buffer.deallocate()
				}
			) {
				metadataUpdate?($0)
			}, buffer
		)
	}

	static func inMemoryChronicle(size: Int, metadataUpdate: ((Metadata) -> Void)? = nil) -> Chronicle {
		inMemoryChronicleWithBuffer(size: size, metadataUpdate: metadataUpdate).0
	}

	func testCreation() {
		let chronicle = Self.inMemoryChronicle(size: 1_000)
		_ = chronicle
	}

	func testBasicUsage() throws {
		let chronicle = Self.inMemoryChronicle(size: 1_000)
		let logger = try chronicle.logger(name: "test")
		#log(logger, "Invocation: \(String(cString: getprogname())) [\(CommandLine.argc) arguments]")
		#log(logger, "It's been \(Date.now.timeIntervalSince1970) seconds since the epoch")
	}

	func testMetadata() {
		var _metadata: Metadata?
		let chronicle = Self.inMemoryChronicle(size: 1) {
			_metadata = $0
		}
		_ = chronicle
		let metadata = _metadata!

		XCTAssertNotNil(metadata.images.map(\.base).firstIndex(of: #dsohandle))
		XCTAssertEqual(TimeInterval(metadata.timing.seconds), Date().timeIntervalSince1970, accuracy: 1)
		let time = mach_continuous_time()
		XCTAssertEqual(TimeInterval(time - metadata.timing.timestamp) * TimeInterval(metadata.timing.numerator) / TimeInterval(metadata.timing.denominator) / TimeInterval(NSEC_PER_SEC), 0, accuracy: 1)
	}

	func testLoggers() throws {
		let loggers = ["LoggerA", "LoggerB"]

		var metadata: Metadata?
		let chronicle = Self.inMemoryChronicle(size: 1) {
			metadata = $0
		}
		for logger in loggers {
			_ = try chronicle.logger(name: logger)
		}
		XCTAssertEqual(loggers, metadata?.loggers)
	}

	func testFormat() throws {
		let (chronicle, buffer) = Self.inMemoryChronicleWithBuffer(size: 1_000)
		let logger = try chronicle.logger(name: "test")
		let string = String(cString: getprogname())
		let number = CommandLine.argc

		#log(logger, "Invocation: \(string) [\(number) arguments]")

		func bytes<T>(of value: T) -> [UInt8] {
			withUnsafeBytes(of: value) {
				Array($0)
			}
		}

		let s1: StaticString = "Invocation: "
		let s2: StaticString = " ["
		let s3: StaticString = " arguments]"

		let types = [
			StaticString.__log_type,
			String.__log_type,
			StaticString.__log_type,
			CInt.__log_type,
			StaticString.__log_type,
		]

		let header = [
			UInt8(0x04)  // .used
		]
		let nextHeader = [
			UInt8(0x00)  // .unused
		]

		let timestamp: UInt64 = 0
		let loggerID: UInt16 = 0

		let payload =
			bytes(of: timestamp)
			+ bytes(of: loggerID)
			+ [
				UInt8(types.count)
			] + types
			+ bytes(of: s1.utf8Start)
			+ bytes(of: string.utf8.count) + Array(string.utf8)
			+ bytes(of: s2.utf8Start)
			+ bytes(of: number)
			+ bytes(of: s3.utf8Start)
		let payloadCount = UInt32(payload.count)
		let trailingCount = UInt32(header.count + MemoryLayout.size(ofValue: payloadCount) + MemoryLayout.size(ofValue: payloadCount)) + payloadCount

		buffer.storeBytes(of: timestamp, toByteOffset: header.count + MemoryLayout.size(ofValue: payloadCount), as: type(of: timestamp))

		let expected =
			header
			+ bytes(of: payloadCount)
			+ payload
			+ bytes(of: trailingCount)
			+ nextHeader
		XCTAssert(expected.elementsEqual(buffer.prefix(expected.count)))
	}

	func testOverflow() throws {
		let chronicle = Self.inMemoryChronicle(size: 1)
		let logger = try chronicle.logger(name: "test")
		#log(logger, "test")
	}

	func testTrailer() throws {
		let baseSize =
			MemoryLayout<UInt8>.size // header
			+ MemoryLayout<UInt32>.size // payload size
		+ MemoryLayout<UInt64>.size // timestamp
		+ MemoryLayout<UInt16>.size // logger ID
		+ MemoryLayout<UInt8>.size // argument count
		+ 1 // types
		+ MemoryLayout<Int>.size // string count
		+ MemoryLayout<UInt32>.size // trailing size
		+ MemoryLayout<UInt8>.size // next header
		
		var string = ""
		do {
			let (chronicle, buffer) = Self.inMemoryChronicleWithBuffer(size: baseSize)
			let logger = try chronicle.logger(name: "test")
			
			#log(logger, "\(string)")
			#log(logger, "\(string)")
			
			XCTAssertEqual(buffer.last, 0)
		}
		
		do {
			let (chronicle, buffer) = Self.inMemoryChronicleWithBuffer(size: baseSize + 1)
			let logger = try chronicle.logger(name: "test")
			
			#log(logger, "\(string)")
			#log(logger, "\(string)")
			
			XCTAssertEqual(buffer.last, 1)
		}
		
		string = "a"
		do {
			let (chronicle, buffer) = Self.inMemoryChronicleWithBuffer(size: baseSize + 1)
			let logger = try chronicle.logger(name: "test")
			
			#log(logger, "\(string)")
			#log(logger, "\(string)")
			
			XCTAssertEqual(buffer.last, 0)
		}
		
		string = String(repeating: "a", count: baseSize)
		do {
			let (chronicle, buffer) = Self.inMemoryChronicleWithBuffer(size: baseSize * 3)
			let logger = try chronicle.logger(name: "test")
			
			#log(logger, "\(string)")
			#log(logger, "\(string)")
			
			XCTAssertEqual(buffer.last, UInt8(baseSize))
		}
		
		let count = 1_000
		string = String(repeating: "a", count: count)
		do {
			let (chronicle, buffer) = Self.inMemoryChronicleWithBuffer(size: baseSize + string.count * 2)
			let logger = try chronicle.logger(name: "test")
			
			#log(logger, "\(string)")
			#log(logger, "\(string)")
			
			var count = UInt(count)
			var _buffer = Array(buffer)
			while count != 0 {
				XCTAssertEqual(_buffer.popLast()! & ~0b1000_0000, UInt8(count & 0b111_1111))
				count >>= 7
			}
		}
	}
	
	func testDisabled() throws {
		let (chronicle, buffer) = Self.inMemoryChronicleWithBuffer(size: 1_000)
		var logger = try chronicle.logger(name: "test")
		logger.enabled = false
		#log(logger, "Invocation: \(String(cString: getprogname())) [\(CommandLine.argc) arguments]")
		#log(logger, "It's been \(Date.now.timeIntervalSince1970) seconds since the epoch")
		XCTAssert(buffer.allSatisfy {
			$0 == 0
		})
	}
}
