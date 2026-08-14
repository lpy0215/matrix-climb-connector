// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "MatrixClimbConnectorCore",
    targets: [
        .target(
            name: "MatrixClimbConnector",
            path: "MatrixClimbConnector/Shared",
            exclude: [
                "FTMSUUIDs.swift",
                "Formatters.swift",
                "WorkoutRecord.swift",
            ],
            sources: [
                "StepClimberMetrics.swift",
                "FTMSStepClimberParser.swift",
                "WorkoutMessages.swift",
            ]
        ),
        .testTarget(
            name: "MatrixClimbConnectorTests",
            dependencies: ["MatrixClimbConnector"],
            path: "MatrixClimbConnectorTests"
        ),
    ]
)
