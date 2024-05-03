import Foundation
import MachO

let _dyld_get_shared_cache_range = unsafeBitCast(dlsym(dlopen(nil, RTLD_LAZY), "_dyld_get_shared_cache_range"), to: (@convention(c) (UnsafeMutablePointer<Int>) -> UnsafeRawPointer?)?.self)!

enum StringCollector {
	static var initialized = false
	static var strings = [UnsafeRawBufferPointer]()
	static var _strings = Set<UnsafeRawPointer>()

	static func initializeIfNeeded() {
		guard !initialized else {
			return
		}
		initialized = true

		for i in 0..<_dyld_image_count() {
			Self.addStrings(from: _dyld_get_image_header(i))
		}

		_dyld_register_func_for_add_image { header, _ in
			Self.addStrings(from: header!)
		}
	}

	static func addStrings(from image: UnsafePointer<mach_header>) {
		#if _pointerBitWidth(_64)
			let image = UnsafeRawPointer(image).assumingMemoryBound(to: mach_header_64.self)
			let getter = getsectiondata
			var size: UInt = 0
		#elseif _pointerBitWidth(_32)
			let getter = getsectdatafromheader
			var size: UInt32 = 0
		#else
			#error("Only 32- and 64-bit platforms are supported")
		#endif
		// This is where StaticStrings go. Ideally we'd get our own section for
		// just our log messages but this would require the ability to move
		// things there: https://github.com/apple/swift/issues/73218
		guard let base = UnsafeRawPointer(getter(image, "__TEXT", "__cstring", &size)),
			!_strings.contains(base)
		else {
			return
		}
		var extent = 0
		guard let range = _dyld_get_shared_cache_range(&extent),
			  base < range || base >= range + extent else {
			return
		}
		
		strings.append(UnsafeRawBufferPointer(start: base, count: Int(size)))
		_strings.insert(base)
	}
}
