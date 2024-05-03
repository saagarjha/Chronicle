import Foundation

public enum Field: CustomStringConvertible {
	case int(Int64)
	case uint(UInt64)
	case float(Double)
	case bool(Bool)
	case string(String)
	case literal(String)

	public var description: String {
		switch self {
			case .int(let value):
				value.description
			case .uint(let value):
				value.description
			case .float(let value):
				value.description
			case .bool(let value):
				value.description
			case .string(let value):
				value.description
			case .literal(let value):
				value.description
		}
	}
}

public struct Entry: CustomStringConvertible {
	public let timestamp: Date
	public let logger: String
	public let fields: [Field]

	init(data: Data, epilog: Epilog) {
		var position = data.startIndex

		func read(size: Int) -> Data {
			precondition(data.endIndex - position >= size)
			let _position = position
			position += size
			return data[_position..<position]
		}

		func read<T>(_ t: T.Type) -> T {
			read(size: MemoryLayout<T>.size).withUnsafeBytes {
				$0.loadUnaligned(as: T.self)
			}
		}

		let timestamp = read(UInt64.self)
		let base = TimeInterval(epilog.timing.seconds) + TimeInterval(epilog.timing.nanoseconds) / 1e9
		let first: UInt64
		let second: UInt64
		let sign: TimeInterval
		if timestamp < epilog.timing.timestamp {
			first = timestamp
			second = epilog.timing.timestamp
			sign = -1
		} else {
			first = epilog.timing.timestamp
			second = timestamp
			sign = 1
		}
		let offset = sign * TimeInterval(UInt64(epilog.timing.numerator) * (second - first)) / TimeInterval(epilog.timing.denominator) / 1e9
		self.timestamp = Date(timeIntervalSince1970: base + offset)

		logger = epilog.loggers[Int(read(UInt16.self))]
		let count = Int(read(UInt8.self))
		let types = read(size: count)

		var fields = [Field]()

		for i in 0..<count {
			switch Character(UnicodeScalar(types[types.startIndex.advanced(by: i)])) {
				case "1":
					fields.append(.int(Int64(read(Int8.self))))
				case "2":
					fields.append(.int(Int64(read(Int16.self))))
				case "4":
					fields.append(.int(Int64(read(Int32.self))))
				case "8":
					fields.append(.int(Int64(read(Int64.self))))
				case "i":
					switch epilog.bitWidth {
						case UInt32.bitWidth:
							fields.append(.int(Int64(read(Int32.self))))
						case UInt64.bitWidth:
							fields.append(.int(Int64(read(Int64.self))))
						default:
							preconditionFailure()
					}
				case "!":
					fields.append(.uint(UInt64(read(UInt8.self))))
				case "@":
					fields.append(.uint(UInt64(read(UInt16.self))))
				case "$":
					fields.append(.uint(UInt64(read(UInt32.self))))
				case "*":
					fields.append(.uint(UInt64(read(UInt64.self))))
				case "I":
					switch epilog.bitWidth {
						case UInt32.bitWidth:
							fields.append(.uint(UInt64(read(UInt32.self))))
						case UInt64.bitWidth:
							fields.append(.uint(UInt64(read(UInt64.self))))
						default:
							preconditionFailure()
					}
				case "f":
					fields.append(.float(Double(read(Float.self))))
				case "F":
					fields.append(.float(Double(read(Double.self))))
				case "b":
					switch read(UInt8.self) {
						case 0:
							fields.append(.bool(false))
						case 1:
							fields.append(.bool(true))
						default:
							preconditionFailure()
					}
				case "s":
					let size: Int
					switch epilog.bitWidth {
						case UInt32.bitWidth:
							size = Int(read(UInt32.self))
						case UInt64.bitWidth:
							size = Int(read(UInt64.self))
						default:
							preconditionFailure()
					}
					fields.append(.string(String(data: read(size: size), encoding: .utf8)!))
				case "S":
					let address: UInt64
					switch epilog.bitWidth {
						case UInt32.bitWidth:
							address = UInt64(read(UInt32.self))
						case UInt64.bitWidth:
							address = UInt64(read(UInt64.self))
						default:
							preconditionFailure()
					}
					fields.append(.literal(epilog.strings[address]!))
				default:
					preconditionFailure()
			}
		}

		self.fields = fields
	}

	static let dateFormatter: DateFormatter = {
		let dateFormatter = DateFormatter()
		dateFormatter.dateFormat = "yyyy-dd-MM hh:mm:ss.SSSZ"
		return dateFormatter
	}()

	public var description: String {
		"\(Self.dateFormatter.string(from: timestamp)) [\(logger)] \(fields.map(\.description).joined())"
	}
}
