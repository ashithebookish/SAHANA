// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SAHANA",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "SAHANA", targets: ["Caregiver"])],
    targets: [.executableTarget(name: "Caregiver", resources: [.process("Resources")])]
)
