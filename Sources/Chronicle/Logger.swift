import Darwin

public struct Logger {
	let chronicle: Chronicle
	let id: UInt16
	// TODO: figure out how this should be synchronized
	public var enabled = true

	public func __prepare(size: Int) -> _LogBuffer? {
		let timestamp = mach_continuous_time()
		guard let buffer = chronicle.__prepare_log(size: MemoryLayout.size(ofValue: timestamp) + MemoryLayout.size(ofValue: id) + size) else {
			return nil
		}
		buffer.storeBytes(of: timestamp, as: type(of: timestamp))
		buffer.storeBytes(of: id, toByteOffset: MemoryLayout.size(ofValue: timestamp), as: type(of: id))
		#if DEBUG
			return UnsafeMutableRawBufferPointer(rebasing: buffer[buffer.startIndex.advanced(by: MemoryLayout.size(ofValue: timestamp) + MemoryLayout.size(ofValue: id))...])
		#else
			return buffer.advanced(by: MemoryLayout.size(ofValue: timestamp) + MemoryLayout.size(ofValue: id))
		#endif
	}

	public func __complete() {
		chronicle.__complete_log()
	}
}
