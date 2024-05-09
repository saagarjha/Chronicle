class Buffer {
	typealias Size = UInt32
	
	enum Progress: UInt8 {
		case unused
		case preparing
		case prepared
		case completing
		case completed
		case used
	}

	let buffer: UnsafeMutableRawBufferPointer
	var offset: Int
	var checkpoint: Int

	init(buffer: UnsafeMutableRawBufferPointer) {
		let minSize = MemoryLayout<Progress.RawValue>.size
		
		precondition(buffer.count >= minSize)
		self.buffer = buffer
		checkpoint = buffer.startIndex  // progress for current block
		offset = checkpoint.advanced(by: minSize)  // for the next block header

	}

	func wraparound(size: Int) -> Bool {
		offset = buffer.endIndex
		var distance = UInt(offset - checkpoint - 1)
		
		checkpoint = offset - 1
		buffer[checkpoint] = 0
		
		repeat {
			let bits = UInt8(distance & 0b0111_1111) | 0b1000_0000
			offset -= 1
			buffer[offset] = bits
			distance >>= 7
		} while distance != 0
		
		buffer[offset] &= ~0b1000_0000
		
		checkpoint = buffer.startIndex
		offset = checkpoint.advanced(by: MemoryLayout<Progress.RawValue>.size)
		
		return offset + size < buffer.count
	}

	func reserve(size: Int) -> _LogBuffer? {
		updateProgress(.preparing)

		#if DEBUG
		let _size = Size(size)
		#else
		let _size = Size(UInt(bitPattern: size))
		#endif

		let totalSize =
			MemoryLayout.size(ofValue: _size)  // size
			+ size  // block data
			+ MemoryLayout.size(ofValue: _size)  // backwards size
			+ MemoryLayout<Progress.RawValue>.size  // progress for next block

		guard offset + totalSize <= buffer.count || wraparound(size: totalSize) else {
			// TODO: Note dropped oversize messages?
			return nil
		}

		buffer.storeBytes(of: _size, toByteOffset: offset, as: type(of: _size))
		updateProgress(.prepared)

		#if DEBUG
		offset += MemoryLayout.size(ofValue: _size)
		defer {
			offset += size + MemoryLayout.size(ofValue: _size) + MemoryLayout<Progress.RawValue>.size
		}
		#else
		offset &+= MemoryLayout.size(ofValue: _size)
		defer {
			offset &+= size &+ MemoryLayout.size(ofValue: _size) &+ MemoryLayout<Progress.RawValue>.size
		}
		#endif

		let base = buffer.startIndex.advanced(by: offset)
		#if DEBUG
		return UnsafeMutableRawBufferPointer(rebasing: buffer[base..<base + size])
		#else
		return buffer.baseAddress.unsafelyUnwrapped.advanced(by: base)
		#endif
	}

	func complete() {
		let oldCheckpoint = checkpoint
		#if DEBUG
		let subtract: (Int, Int) -> Int = { $0 - $1 }
		#else
		let subtract: (Int, Int) -> Int = { $0 &- $1 }
		#endif
		let newCheckpoint = subtract(offset, 1)

		updateProgress(.completing)
		
		#if DEBUG
		let size = Size(subtract(newCheckpoint, oldCheckpoint))
		#else
		let size = Size(truncatingIfNeeded: subtract(newCheckpoint, oldCheckpoint))
		#endif
		buffer.storeBytes(of: size, toByteOffset: subtract(newCheckpoint, MemoryLayout.size(ofValue: size)), as: type(of: size))
		
		updateProgress(.completed)
		
		checkpoint = newCheckpoint
		updateProgress(.unused)
		checkpoint = oldCheckpoint
		updateProgress(.used)
		checkpoint = newCheckpoint
	}

	func updateProgress(_ progress: Progress) {
		buffer[checkpoint] = progress.rawValue
	}
}
