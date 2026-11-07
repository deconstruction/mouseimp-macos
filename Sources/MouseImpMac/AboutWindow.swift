// About window: name, version and where the source lives. A menu bar app has no
// application menu of its own, so the usual "About" item simply sits near the
// bottom of the status menu.

import SwiftUI

struct AboutView: View {
    /// Version from the bundle the build script assembled, so it always matches
    /// the disk image it came in.
    private var version: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
    }

    private var repository: URL {
        URL(string: "https://github.com/deconstruction/mouseimp-macos")!
    }

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "computermouse")
                .font(.system(size: 46, weight: .light))
                .foregroundStyle(.tint)
                .frame(width: 88, height: 88)
                .background(
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .fill(.quaternary)
                )
                .padding(.bottom, 4)

            Text("MouseImp")
                .font(.title.bold())

            Text("about.tagline")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            Text(String(format: NSLocalizedString("about.version", comment: ""), version))
                .font(.callout.monospacedDigit())
                .padding(.top, 2)

            Divider()
                .padding(.vertical, 4)

            Text("about.source")
                .font(.caption)
                .foregroundStyle(.secondary)

            Link(destination: repository) {
                Label(repository.absoluteString
                        .replacingOccurrences(of: "https://", with: "")
                        .trimmingCharacters(in: CharacterSet(charactersIn: "/")),
                      systemImage: "arrow.up.right.square")
                    .font(.callout)
            }
            .help(repository.absoluteString)
        }
        .padding(.horizontal, 26)
        .padding(.vertical, 22)
        .frame(width: 340)
    }
}
