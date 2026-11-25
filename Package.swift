// swift-tools-version:5.9
import PackageDescription

let package = Package(
	name: "Bol",
	platforms: [.macOS(.v13)],
	targets: [
		.executableTarget(
			name: "Bol",
			path: "src/swift",
			linkerSettings: [
				.linkedFramework("AppKit"),
				.linkedFramework("AVFoundation"),
				.linkedFramework("ServiceManagement"),
				.linkedFramework("Speech"),
			]
		),
		.testTarget(name: "BolTests", dependencies: ["Bol"], path: "tests/swift"),
	]
)
