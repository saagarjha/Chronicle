// Unused save for type checking macro arguments
public struct _ChronicleLogMessage: ExpressibleByStringLiteral, ExpressibleByStringInterpolation {
	public struct StringInterpolation: StringInterpolationProtocol {
		public init(literalCapacity: Int, interpolationCount: Int) {
		}

		public func appendLiteral(_ literal: StaticString) {
		}

		public func appendInterpolation(_: some _Loggable) {
		}
	}

	public init(stringLiteral value: StaticString) {
	}

	public init(stringInterpolation: StringInterpolation) {
	}
}

@freestanding(expression)
public macro log(_ log: Logger, _ message: _ChronicleLogMessage) = #externalMacro(module: "Macros", type: "")
