import AppKit
import SwiftUI

@main
struct CaregiverApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @AppStorage("readingSize") private var readingSize = ReadingSize.standard

    var body: some Scene {
        Window("SAHANA", id: "main") {
            SahanaWindow()
                .dynamicTypeSize(readingSize.typeSize)
                .frame(minWidth: 510, minHeight: 400)
        }
        .defaultSize(width: 1120, height: 860)
        .commands {
            CommandMenu("Reading Size") {
                Picker("Reading Size", selection: $readingSize) {
                    ForEach(ReadingSize.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.inline)
            }
        }
    }
}

private struct SahanaWindow: View {
    @State private var role: Role = .caregiver
    @State private var workspace = WorkspaceModel()
    @State private var patient = PatientModel()
    @State private var camera = LiveCamera()
    @Environment(\.dynamicTypeSize) private var typeSize

    private enum Role: String, CaseIterable, Identifiable {
        case caregiver = "Caregiver hub"
        case patient = "Patient screen"

        var id: Self { self }
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 12) {
                BrandHeader()
                if camera.running || camera.starting {
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 16) {
                            rolePicker
                            cameraIndicator
                        }
                        VStack(spacing: 8) {
                            rolePicker
                            cameraIndicator
                        }
                    }
                } else {
                    rolePicker
                }
            }
            .frame(maxWidth: 1200)
            .padding(.horizontal, 23)
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity)
            Rectangle().fill(Brand.line).frame(height: 1)

            switch role {
            case .caregiver:
                WorkspaceView(model: workspace, camera: camera)
            case .patient:
                PatientView(model: patient, camera: camera)
            }
        }
        .background(Brand.background)
        .foregroundStyle(Brand.cream)
        .tint(Brand.blue)
        .controlSize(typeSize >= .xxxLarge ? .extraLarge : .large)
        .preferredColorScheme(.dark)
    }

    @ViewBuilder private var cameraIndicator: some View {
        if camera.running || camera.starting {
            HStack(spacing: 8) {
                Label(
                    camera.recording ? "Recording" : (camera.starting ? "Starting camera" : "Camera on"),
                    systemImage: camera.recording ? "record.circle" : "video.fill"
                )
                .font(.caption.weight(.semibold))
                .foregroundStyle(camera.recording ? .red : Brand.gold)

                Button("Stop") { Task { await camera.stop() } }
                    .accessibilityLabel("Stop this Mac’s camera")
            }
        } else {
            Color.clear.frame(width: 0, height: 0).accessibilityHidden(true)
        }
    }

    private var rolePicker: some View {
        Picker("Workspace", selection: $role) {
            ForEach(Role.allCases) { Text($0.rawValue).tag($0) }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .accessibilityLabel("Choose caregiver or patient workspace")
        .fixedSize()
    }
}

private enum ReadingSize: String, CaseIterable, Identifiable {
    case standard = "Standard"
    case large = "Large"
    case extraLarge = "Extra Large"
    case accessibility = "Accessibility Large"

    var id: Self { self }

    var typeSize: DynamicTypeSize {
        switch self {
        case .standard: .large
        case .large: .xLarge
        case .extraLarge: .xxxLarge
        case .accessibility: .accessibility2
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}
