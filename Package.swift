// swift-tools-version: 5.9

import CompilerPluginSupport
import PackageDescription

let package = Package(
	name: "Chronicle",
	products: [
		.library(name: "Chronicle", targets: ["Chronicle"])
	],
	targets: [
		.target(name: "Chronicle", dependencies: ["Macros"]),
		.macro(name: "Macros"),
		.testTarget(name: "ChronicleTests", dependencies: ["Chronicle"]),
	]
)
