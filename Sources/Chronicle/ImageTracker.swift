import Foundation
import MachO

let _dyld_get_image_uuid = unsafeBitCast(dlsym(dlopen(nil, RTLD_LAZY), "_dyld_get_image_uuid"), to: (@convention(c) (UnsafePointer<mach_header>, UnsafeRawPointer) -> Bool)?.self)!
let dyld_image_path_containing_address = unsafeBitCast(dlsym(dlopen(nil, RTLD_LAZY), "dyld_image_path_containing_address"), to: (@convention(c) (UnsafeRawPointer) -> UnsafePointer<CChar>?)?.self)!

public struct Image: Hashable, Codable {
	public let uuid: uuid_t
	public let path: String?
	public let base: UnsafeRawPointer
	public let slide: Int

	init?(base: UnsafePointer<mach_header>, slide: Int) {
		var _uuid = UUID().uuid
		let result = withUnsafeMutablePointer(to: &_uuid) {
			_dyld_get_image_uuid(base, $0)
		}
		guard result else {
			return nil
		}

		uuid = _uuid
		path = dyld_image_path_containing_address(base).flatMap(String.init(cString:))
		self.base = UnsafeRawPointer(base)
		self.slide = slide
	}

	enum CodingKeys: String, CodingKey {
		case uuid
		case path
		case base
		case slide
	}

	public init(from decoder: any Decoder) throws {
		let container = try decoder.container(keyedBy: CodingKeys.self)
		let _uuid = try container.decode(UUID.self, forKey: .uuid)
		uuid = _uuid.uuid
		path = try container.decode(String?.self, forKey: .path)
		base = UnsafeRawPointer(bitPattern: UInt(try container.decode(UInt64.self, forKey: .base)))!
		slide = Int(try container.decode(UInt64.self, forKey: .slide))
	}

	public func encode(to encoder: any Encoder) throws {
		var container = encoder.container(keyedBy: CodingKeys.self)
		try container.encode(UUID(uuid: uuid), forKey: .uuid)
		try container.encode(path, forKey: .path)
		try container.encode(UInt64(UInt(bitPattern: base)), forKey: .base)
		try container.encode(UInt64(slide), forKey: .slide)
	}

	public static func == (lhs: Self, rhs: Self) -> Bool {
		withUnsafePointer(to: lhs.uuid) { lhs in
			withUnsafePointer(to: rhs.uuid) { rhs in
				memcmp(lhs, rhs, MemoryLayout<uuid_t>.size) == 0
			}
		}
	}

	public func hash(into hasher: inout Hasher) {
		withUnsafePointer(to: uuid) {
			hasher.combine(bytes: UnsafeRawBufferPointer(start: $0, count: MemoryLayout.size(ofValue: $0.pointee)))
		}
	}
}

enum ImageTracker {
	static var initialized = false
	static var images = [Image]()
	static var _images = Set<Image>()
	static var lookup = [UnsafeRawPointer: Image]()

	static func initializeIfNeeded() {
		guard !initialized else {
			return
		}
		initialized = true

		for i in 0..<_dyld_image_count() {
			let header = _dyld_get_image_header(i)
			let slide = _dyld_get_image_vmaddr_slide(i)
			guard let image = Image(base: header!, slide: slide) else {
				break
			}

			Self.register(image)
		}

		_dyld_register_func_for_add_image { header, slide in
			guard let image = Image(base: header!, slide: slide) else {
				return
			}

			if !Self._images.contains(image) {
				Self.register(image)
			}
		}
	}

	static func register(_ image: Image) {
		Self.images.append(image)
		Self._images.insert(image)
		Self.lookup[image.base] = image
	}
}
