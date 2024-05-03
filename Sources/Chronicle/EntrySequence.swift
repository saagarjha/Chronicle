import Foundation

public struct EntrySequence: Sequence, IteratorProtocol {
	enum Position {
		case forward(Data.Index)
		case backward(Data.Index)

		var index: Data.Index {
			get {
				switch self {
					case .backward(let index), .forward(let index):
						return index
				}
			}
			set {
				switch self {
					case .backward(_):
						self = .backward(newValue)
					case .forward(_):
						self = .forward(newValue)
				}
			}
		}
	}

	let epilog: Epilog
	var position: Position

	init(epilog: Epilog) {
		self.epilog = epilog
		position = .backward(epilog.backwardBuffer.startIndex)
	}

	public mutating func next() -> Entry? {
		var index: Data.Index
		let buffer: Data
		switch position {
			case .backward(let _index):
				guard _index < epilog.backwardBuffer.endIndex else {
					position = .forward(epilog.forwardBuffer.startIndex)
					return next()
				}
				index = _index
				buffer = epilog.backwardBuffer
			case .forward(let _index):
				guard _index < epilog.forwardBuffer.endIndex else {
					return nil
				}
				index = _index
				buffer = epilog.forwardBuffer
		}

		func advance(by size: Int) -> Data.Index {
			precondition(buffer.endIndex - index >= size)
			return index + size
		}

		index = advance(by: MemoryLayout<Buffer.Progress.RawValue>.size)

		var _index = index
		index = advance(by: MemoryLayout<Buffer.Size>.size)
		let size = Int(
			buffer[_index..<index].withUnsafeBytes {
				$0.loadUnaligned(as: Buffer.Size.self)
			})

		_index = index
		index = advance(by: size)

		defer {
			position.index = advance(by: MemoryLayout<Buffer.Size>.size)
		}

		return Entry(data: buffer[_index..<index], epilog: epilog)
	}
}
