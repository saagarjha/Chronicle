import Foundation

struct IO {
	enum HostToPluginMessage: Codable {
		struct Syntax: Codable {
			var source: String
		}

		case getCapability
		case expandFreestandingMacro(syntax: Syntax)
	}

	enum PluginToHostMessage: Codable {
		struct PluginCapability: Codable {
			var protocolVersion: Int = 1
		}

		case getCapabilityResult(capability: PluginCapability)
		case expandMacroResult(expandedSource: String?, diagnostics: [Never])
	}

	func read() -> Data? {
		var size: UInt64 = 0
		let data = FileHandle.standardInput.readData(ofLength: MemoryLayout.size(ofValue: size))
		guard data.count == MemoryLayout.size(ofValue: size) else {
			// Generally means stdin is closed, so nothing required of us
			return nil
		}
		size = data.withUnsafeBytes {
			$0.loadUnaligned(as: type(of: size))
		}
		return FileHandle.standardInput.readData(ofLength: Int(size))
	}

	func write(_ data: Data) {
		var count = data.count
		withUnsafeBytes(of: &count) {
			FileHandle.standardOutput.write(Data($0))
		}
		FileHandle.standardOutput.write(data)
	}

	func receive() throws -> HostToPluginMessage? {
		try read().flatMap {
			try JSONDecoder().decode(HostToPluginMessage.self, from: $0)
		}
	}

	func reply(_ message: PluginToHostMessage) throws {
		try write(JSONEncoder().encode(message))
	}
}

@main
struct Main {
	static func stripComments(_ source: String) -> String {
		var stripped = [Character]()

		enum State {
			case code
			case start(Int)
			case comment(Int)
			case end(Int)
		}

		var state = State.code
		for c in source {
			switch (state, c) {
				case (.code, "/"):
					state = .start(0)
				case (.code, _):
					stripped.append(c)
				case let (.start(level), "*"):
					state = .comment(level + 1)
				case let (.start(level), _):
					if level == 0 {
						state = .code
						stripped.append("/")
						stripped.append(c)
					}
				case let (.comment(level), "*"):
					state = .end(level)
				case (.comment, _):
					break
				case let (.end(level), "/"):
					if level == 0 {
						state = .code
					} else {
						state = .comment(level - 1)
					}
				case let (.end(level), _):
					state = .comment(level)
			}
		}

		return String(stripped).split(separator: "\n").filter {
			!$0.trimmingCharacters(in: .whitespacesAndNewlines).starts(with: "//")
		}.joined(separator: "\n")
	}

	static func parseMessage(_ message: String) -> ([String], [String])? {
		var arguments = [String]()
		var strings = [String]()

		enum State {
			case literal([Character])
			case escape([Character])
			case interpolation(Int, [Character])
		}

		var state = State.literal([])
		for c in message {
			switch (state, c) {
				case (let .literal(string), "\\"):
					state = .escape(string)
				case (let .literal(string), _):
					state = .literal(string + [c])
				case (let .escape(string), "("):
					if !string.isEmpty {
						arguments.append("string\(strings.count)")
						strings.append(String(string))
					}
					state = .interpolation(1, [])
				case (let .escape(string), _):
					state = .literal(string + ["\\", c])
				case (let .interpolation(level, string), "("):
					state = .interpolation(level + 1, string + [c])
				case (let .interpolation(level, string), ")"):
					let newLevel = level - 1
					if newLevel == 0 {
						arguments.append(String(string))
						state = .literal([])
					} else {
						state = .interpolation(level - 1, string + [c])
					}
				case (let .interpolation(level, string), _):
					state = .interpolation(level, string + [c])
			}
		}

		switch state {
			case let .literal(string):
				if !string.isEmpty {
					arguments.append("string\(strings.count)")
					strings.append(String(string))
				}
				return (arguments, strings)
			default:
				return nil
		}
	}

	static func expand(source: String) -> String? {
		var source = stripComments(source).trimmingCharacters(in: .whitespacesAndNewlines)

		let macro = "#log"

		guard source.hasPrefix(macro) else {
			return nil
		}

		source = String(source[source.index(source.startIndex, offsetBy: macro.count)...])
		source = source.trimmingCharacters(in: .init("()".unicodeScalars))

		guard let firstComma = source.firstIndex(of: ",") else {
			return nil
		}
		let logger = source[..<firstComma].trimmingCharacters(in: .whitespacesAndNewlines)
		var message = source[source.index(after: firstComma)...].trimmingCharacters(in: .whitespacesAndNewlines)

		while message.hasPrefix("\""), message.hasSuffix("\"") {
			message = String(message.dropFirst().dropLast())
		}

		guard let (arguments, strings) = parseMessage(message) else {
			return nil
		}

		return
			"""
			{
				\(strings.enumerated().map {
					"let string\($0): StaticString = \"\($1)\""
				}.joined(separator: "\n\t"))
				
				if \(logger).enabled {
					\(arguments.enumerated().map {
						"let argument\($0) = \($1)"
					}.joined(separator: "\n\t\t"))
					
					\(arguments.indices.map {
						"let argument\($0)Context = Swift.type(of: argument\($0))._LogContext(value: argument\($0))"
					}.joined(separator: "\n\t\t"))
					
					\(arguments.indices.map {
						"let argument\($0)Size = Swift.type(of: argument\($0)).__log_size(context: argument\($0)Context)"
					}.joined(separator: "\n\t\t"))
					
					let argumentsCount = \(arguments.count) as UInt8
					let headerSize = MemoryLayout.size(ofValue: argumentsCount) + MemoryLayout<UInt8>.size * \(arguments.count)
					let bodySize = \(arguments.indices.map {
						"argument\($0)Size"
					}.joined(separator: " + "))
					let totalSize = headerSize + bodySize
					guard let buffer = \(logger).__prepare(size: totalSize) else {
						return
					}
					
					buffer.storeBytes(of: argumentsCount, as: Swift.type(of: argumentsCount))
					
					\(arguments.indices.map {
						"buffer.storeBytes(of: Swift.type(of: argument\($0)).__log_type, toByteOffset: MemoryLayout.size(ofValue: argumentsCount) + \($0), as: UInt8.self)"
					}.joined(separator: "\n\t\t"))
					
					#if DEBUG
					var offset = buffer.startIndex + headerSize
					#else
					var offset = headerSize
					#endif
					
					\(arguments.indices.map {
						"""
						#if DEBUG
						Swift.type(of: argument\($0)).__log(into: UnsafeMutableRawBufferPointer(rebasing: buffer[offset..<offset + argument\($0)Size]), context: argument\($0)Context)
						offset += argument\($0)Size
						#else
						Swift.type(of: argument\($0)).__log(into: buffer + offset, context: argument\($0)Context)
						offset &+= argument\($0)Size
						#endif
						"""
						.split(separator: "\n").joined(separator: "\n\t\t")
					}.joined(separator: "\n\n\t\t"))
					
					\(logger).__complete()
				}
			}()
			"""
	}

	static func main() throws {
		let io = IO()

		repeat {
			switch try io.receive() {
				case .getCapability:
					try io.reply(.getCapabilityResult(capability: .init()))
				case .expandFreestandingMacro(let syntax):
					try io.reply(.expandMacroResult(expandedSource: expand(source: syntax.source), diagnostics: []))
				case nil:
					return
			}
		} while true
	}
}
