# Chronicle

Chronicle is an experiment built to answer a single question: what would an [os_log](https://developer.apple.com/documentation/os/logging) designed for third-party developers, by third-party developers, look like? It turns out, kind of like this:

```swift
let chronicle = Chronicle(url: URL(fileURLWithPath: "log.chronicle"), bufferSize: 1 << 20)
let logger = try chronicle.logger(name: "test")

#log(logger, "Invocation: \(String(cString: getprogname())) [\(CommandLine.argc) arguments]")
#log(logger, "It's been \(Date.now.timeIntervalSince1970) seconds since the epoch")
```

Chronicle is:

* **Fast.** You can throw millions of messages a second at Chronicle and it won't break a sweat. With logging this cheap (just a few dozen nanoseconds per message!) there's no reason to turn it off.
* **Persistent.** A memory-mapped ring buffer puts you in control with where you keep your logs, and provides durability for the harshest environments when you need your logs the most.
* **Structured.** Embed any data you want (with a few exceptions) into your logs. Extract it out later and operate on it with the analysis tooling of your choice. Or don't: if you like strings, Chronicle is fine with that.

Chronicle is *not*:

* A general purpose logger. It won't also make network requests to your backend or track your user across multiple app sessions.
* Available for other languages. It's Swift-only and will likely stay that way.
* Complete or ready for use. See below.

## Why not os_log?
os_log is part of Apple's high-performance unified logging solution for their platforms. Inside the company, it powers many analysis tools that engineers use to diagnose and investigate problems in their code. It has a number of neat features: it collects logs in a central location from all parts of the system, has relatively low overhead, is highly configurable on a level/subsystem/category basis, and has integration with software such as Console and Instruments. Apple would like you to use it, too, which is why they make the API available to third-party developers. Unfortunately, sometimes it's not particularly well suited to the job.

### It's "unified"
App developers care first and foremost about *their* logs. A unified log, while helpful when trying to track down issues across components, is less useful to someone trying to diagnose issues in their own code. For logging, the shared log means that system services often spew "spam" into it: messages that are rarely useful, except to the immediate developers of a system API. While there are some ways to silence logs from chatty sources (at least, if the developers use an appropriate subsystem and category) even then the sheer *number* of sources is hard to grapple with. And as the OS gets larger, the number of clients continues to grow with it.

### It's system-managed
While you have some control over your log persistence, by and large logs are saved for as long as the system would like to keep them. And getting them back is a pain: the [public APIs](https://developer.apple.com/documentation/oslog/oslogstore) (which are not what Apple uses!) are limited and broken. Asking users to take a sysdiagnose to get your logs is a pain and privacy-invading, since it contains data from other apps in it.

This design also limits the implementation: any buffers in your process are sized by the system, and if you overrun them or log too quickly messages will be dropped. Messages that are persisted to disk or streamed necessarily incur the cost of XPC. Even the logging configuration is system-wide, and while significant work has been put into making accesses efficient (commpage, etc.) it's still overhead if you don't need it.

### It has a constrained API
os_log is designed for what Apple needs it to do. This means that they run special compiler optimization passes on your code to try to optimize log buffers into the shape the API wants. It means that activity IDs are carried across processes but not between different computers. Information you stick in a log message is stuck there unless you use Apple's tooling to extract it out, and if you wanted to find the 99- and 90-percentile values and Apple only shows you a median, you're out of luck. If you want to backdeploy to Catalina and the system doesn't support what you want to do, there's not much you can do. Apple's official solution to wrapping os_log, of course, is "don't".

## Design
Chronicle is designed a bit like os_log, but local to your process. By default it opens a file as a ring buffer and maps it in, so that it doesn't have to ever explicitly flush any data. This means it can persist through a crash without any special handlers being installed, and it doesn't hit the disk for each message (which would be both slow and terrible for your flash storage). The log format is carefully designed as a linear doubly-linked list so that it can be recovered even if interrupted part of the way through a write.

Logs in Chronicle are typed and, like os_log, the in-memory format writes as little as possible as a performance optimization. For example, constant strings in your log message are not written out, but instead noted down as an offset into the originating binary. The types of data you can write to a log are likewise limited: simple integral and floating point types, booleans, and strings. This information can be extracted for later analysis, or formatted into a human-readable string log message.

While Chronicle has typed logs, it does very little to dictate the "schema" of your log messages. In particular, there is no special support for things like logging subsystems, categories, activities, or event IDs. The only metadata that is written alongside your message is a high-resolution timestamp and the originating logger's ID. A logger in Chronicle likewise is just something that is named and can be disabled selectively. Any organization on top of this is up to you. It is supported and recommended to layer your own organization in-line by e.g. logging something like this:

```swift
let category: StaticString = "ImageDecoder"
#log(logger, "\(category): Started decode of \(image)")
```

Unlike os_log, Chronicle does not use special compiler optimization passes to reduce logging overhead. Instead, it uses the `#log` macro and careful inlining to collapse the code into direct writes to the logging buffer. Since it is a library that you ship with your app, it has no ABI concerns beyond the format of the log itself.

## Log format
By default, Chronicle logs to a ".chronicle" bundle. Inside it are a directory and two files. The first file is metadata.json, which contains data needed to reconstruct the logs. In particular, it contains the log version, logger names, timing information, and some string table information. The string tables (currently, a wholesale dump of `__TEXT,__cstring` from images outside of the shared cache) themselves are stored in the directory called strings, with a filename that represents the load address for the section and the contents of the file being the strings data.

### Buffer format
The actual logs themselves are stored in the other file (called buffer) and it has the following high-level format:

```
[array of log messages]
[unused space]
[trailer]
```

Log messages always start at the start of the file. If the buffer was never filled completely, then they will use as much as the buffer as needed. If the buffer has wrapped around, then messages will still begin from the very start of the file, but the topmost message will no longer be the first message chronologically. Instead, the messages from the time at which the log wrapped going forward can be read going forward in the file from the start, walking the chain of in-use messages (see below). Messages from earlier can be read going backwards in the file, traversing the other end of the linked list. The trailer at the very bottom of the file indicates an "offset distance" to the end of the last message, encoded in reversed ULEB-128 bytes (least significant byte at the very end of the buffer, second least significant second-to-last byte, etc.). This trailer is necessary because log messages may not fill the entire buffer. There will always be at least one trailer byte at the end of the file. The "offset distance" is the true distance from the end of the last message to the end of the buffer, but with one subtracted from it. This is because a full log buffer only extends to the second-to-last byte in the file, because of the necessity of at least one trailer byte. Note that the trailer encodes the number of bytes of unused space when small, but it diverges as the trailer gets larger to incorporate more bytes.

<details>
<summary>An example</summary>
Assume we have a 0x2000 byte file that is 0x1800 full of log messages (for example, if 0x1800 bytes were filled and a 0x1000 byte message came in). The first 0x1800 bytes are log messages. The space between 0x1800 and 0x1ffd is unused (garbage). At the very end we encode (0x2000 - 0x1800 - 1) in ULEB-128, as [0x0f, 0xff].


```
0x0000: [log messages]
0x0010: [log messages]
......: ...............
0x0ff0: [log messages]
-Log messages end here-
0x1000: [unused space]
0x1010: [unused space]
......: ...............
--Trailer starts here--
0x1ffe: 0x0f
0x1fff: 0xff
```
</details>

### Log Message format
Log messages have a fixed format and are stored back-to-back with no padding. The general format of an in individual message (also stored with no padding) is:

* `UInt8` header
* `UInt32` payload size
* `UInt64` timestamp
* `UInt16` logger ID
* `UInt8` log component count
* `[UInt8]` component type string
* `[[UInt8]]` log component data
* `UInt32` message size

#### Header
The header is a number between 0 and 5 inclusive, and indicates how complete the message is. If the previous message is complete, then the next message will be guaranteed to have a valid header that can be read (i.e. the header for the next message is written before the last message is marked as complete). The meaning for these values are as follows:

* 0: The message is in unused state. (All bytes past the header are untouched.)
* 1: The message's payload size has started being written. (The bytes for the payload size may be trashed, but bytes past that are untouched.)
* 2: The message's payload size is committed and the payload has started being written. (The payload size is valid, and the payload afterwards may be trashed.)
* 3: The message's message size has started being written. (The payload is finished. The bytes for the message size may be trashed.)
* 4: The message's message size has been written to completion. (The next message's header may be trashed.)
* 5: The message is complete. (The header for the next message is valid to parse.)

#### Payload size
The payload size includes the size to encode the timestamp, logger ID, log component count, component type string, and log component data.

#### Component type string
The component type string has a length specified by the log component count. It specifies the type of each log component with a single character each, as follows:

| Type            | Character |
|-----------------|-----------|
| `Bool`          | b         |
| `Int8`          | 1         |
| `Int16`         | 2         |
| `Int32`         | 4         |
| `Int64`         | 8         |
| `Int`           | i         |
| `UInt8`         | !         |
| `UInt16`        | @         |
| `UInt32`        | $         |
| `UInt64`        | *         |
| `UInt`          | I         |
| `Float`         | f         |
| `Double`        | F         |
| `String`        | s         |
| `StaticString`  | S         |

#### Log component data
The log component data includes the data for each log component, joined together with no padding.

| Type            | Encoding                          |
|-----------------|-----------------------------------|
| `Bool`          | 1-byte data                       |
| `Int8`          | 1-byte data                       |
| `Int16`         | 2-byte data                       |
| `Int32`         | 4-byte data                       |
| `Int64`         | 8-byte data                       |
| `Int`           | Pointer-sized data                |
| `UInt8`         | 1-byte data                       |
| `UInt16`        | 2-byte data                       |
| `UInt32`        | 4-byte data                       |
| `UInt64`        | 8-byte data                       |
| `UInt`          | Pointer-sized data                |
| `Float`         | 4-byte data                       |
| `Double`        | 8-byte data                       |
| `String`        | Pointer-sized count + count bytes |
| `StaticString`  | Pointer-sized data                |

#### Message size
The message size is the payload size, plus the size of the header, the size of the payload count, and the size of the message size (itself). In other words, it's the size of the whole message including itself.

### String interpolation macro

The `#log` macro splits apart the string interpolation provided as the second argument into "components". Each literal part of the string is encoded as a `StaticString`. The interpolations are encoded as individual components. Thus, a string like `"Invocation: \(String(cString: getprogname())) [\(CommandLine.argc) arguments]"` is split into the following:

```swift
let component1: StaticString = "Invocation: "
let component2: String = String(cString: getprogname())
let component3: StaticString = " ["
let component4: CInt = CommandLine.argc
let component5: Staticstring = " arguments]"
```

The macro itself is vaguely structured like follows:

```swift
let string1...N = /* Literal parts of the log message*/

if logger.enabled {
	let component1...N = /* Each component of the log message */
	let totalSize = /* Sum up the sizes of each component */
	let buffer = logger.prepare(totalSize)
	component1...N.log(into: buffer)
	logger.complete()
}
```

This design means that all the writes and sizing happens inlined at the call site, so maximum optimizations can take place. In practice, each component is written directly to the log buffer, without any extra copies. This includes strings if they are already laid out as UTF-8 internally.

## Status

**Chronicle is not yet ready for general-purpose use**. In fact it may never be ready for that. It was designed as a test, but also to support [Ensemble](https://github.com/saagarjha/Ensemble). It has many serious limitations:

* It may evolve or break without warning.
* Optimizations are done with underscored compiler attributes I barely understand.
* Macros are parsed without [swift-syntax](https://github.com/apple/swift-syntax), using string replacement.

Seriously, do not use it. It's there for you to think about what you might from your own logging framework.
