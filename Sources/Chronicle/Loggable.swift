public protocol __LogContext {
	associatedtype T
	init(value: T)
}

public struct _PassthroughLogContext<T>: __LogContext {
	@usableFromInline
	let value: T
	
	public init(value: T) {
		self.value = value
	}
}

public protocol _Loggable where _LogContext: __LogContext, _LogContext.T == Self {
	associatedtype _LogContext

	static var __log_type: UInt8 { get }
	static func __log_size(context: _LogContext) -> Int

	static func __log(into buffer: _LogBuffer, context: _LogContext)
}

protocol __Loggable: _Loggable {
	static var ___log_type: StaticString { get }
}

extension __Loggable {
	// The optimizer seems to need this to coalesce writes of these together
	@_transparent
	public static var __log_type: UInt8 {
		___log_type.utf8Start.pointee
	}
}

public protocol _TriviallyLoggable {
}

extension _Loggable where Self: _TriviallyLoggable {
	public static func __log_size(context: _LogContext) -> Int {
		MemoryLayout<Self>.size
	}

	// Otherwise this doesn't inline fully
	@_transparent
	public static func __log(into buffer: _LogBuffer, context: _PassthroughLogContext<Self>) {
		buffer.storeBytes(of: context.value, as: Self.self)
	}
}

extension Int8: __Loggable, _TriviallyLoggable {
	static let ___log_type: StaticString = "1"
}

extension Int16: __Loggable, _TriviallyLoggable {
	static let ___log_type: StaticString = "2"
}

extension Int32: __Loggable, _TriviallyLoggable {
	static let ___log_type: StaticString = "4"
}

extension Int64: __Loggable, _TriviallyLoggable {
	static let ___log_type: StaticString = "8"
}

extension Int: __Loggable, _TriviallyLoggable {
	static let ___log_type: StaticString = "i"
}

extension UInt8: __Loggable, _TriviallyLoggable {
	static let ___log_type: StaticString = "!"
}

extension UInt16: __Loggable, _TriviallyLoggable {
	static let ___log_type: StaticString = "@"
}

extension UInt32: __Loggable, _TriviallyLoggable {
	static let ___log_type: StaticString = "$"
}

extension UInt64: __Loggable, _TriviallyLoggable {
	static let ___log_type: StaticString = "*"
}

extension UInt: __Loggable, _TriviallyLoggable {
	static let ___log_type: StaticString = "I"
}

extension Float: __Loggable, _TriviallyLoggable {
	static let ___log_type: StaticString = "f"
}

extension Double: __Loggable, _TriviallyLoggable {
	static let ___log_type: StaticString = "F"
}

extension Bool: __Loggable, _TriviallyLoggable {
	static let ___log_type: StaticString = "b"
}

extension String: __Loggable {
	public struct _LogContext: __LogContext {
		@usableFromInline
		var utf8: String

		public init(value: String) {
			utf8 = value
			utf8.makeContiguousUTF8()
		}

		func ensureContiguousUTF8Optimizations() {
			guard utf8.isContiguousUTF8 else {
				// Poor man's Builtin.unreachable()
				unsafeBitCast((), to: Never.self)
			}
		}
	}

	static let ___log_type: StaticString = "s"

	public static func __log_size(context: _LogContext) -> Int {
		context.ensureContiguousUTF8Optimizations()
		let count = context.utf8.utf8.count
		return MemoryLayout.size(ofValue: count) + count
	}

	// This is intentionally not @_transparent so it gets outlined. It would
	// help performance a little bit but the code is kind of big. The inline
	// marker avoids a thunk from being generated for no reason.
	@inline(__always)
	public static func __log(into buffer: _LogBuffer, context: _LogContext) {
		context.ensureContiguousUTF8Optimizations()
		var copy = context
		copy.utf8.withUTF8 {
			buffer.storeBytes(of: $0.count, as: type(of: $0.count))
			#if DEBUG
				buffer.baseAddress!.advanced(by: MemoryLayout.size(ofValue: $0.count)).copyMemory(from: $0.baseAddress!, byteCount: $0.count)
			#else
				buffer.advanced(by: MemoryLayout.size(ofValue: $0.count)).copyMemory(from: $0.baseAddress!, byteCount: $0.count)
			#endif
		}
	}
}

extension StaticString: __Loggable {
	static let ___log_type: StaticString = "S"

	public static func __log_size(context: _LogContext) -> Int {
		MemoryLayout<UInt>.size
	}

	public static func __log(into buffer: _LogBuffer, context: _PassthroughLogContext<Self>) {
		// TODO: handle non-pointer StaticStrings
		buffer.storeBytes(of: UInt(bitPattern: context.value.utf8Start), as: UInt.self)
	}
}
