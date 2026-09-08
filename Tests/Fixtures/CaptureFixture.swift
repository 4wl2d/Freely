import AppKit
import AVFoundation

@MainActor final class FixtureDelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow?
    var player: AVAudioPlayer?
    func applicationDidFinishLaunching(_ notification: Notification) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 520),
            styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "Freely capture fixture — public test content"
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 520))
        let title = NSTextField(labelWithString: "Screen understanding fixture")
        title.font = .systemFont(ofSize: 26, weight: .semibold); title.frame = NSRect(x: 30, y: 445, width: 730, height: 40)
        content.addSubview(title)
        let code = NSTextView(frame: NSRect(x: 30, y: 135, width: 740, height: 280))
        code.isEditable = false; code.isSelectable = true
        code.font = .monospacedSystemFont(ofSize: 22, weight: .regular)
        code.string = """
        // Question: What does this Kotlin code print?
        val values = listOf(1, 2, 3, 4)
        val answer = values
            .filter { it % 2 == 0 }
            .map { it * it }
            .sum()
        println(answer)
        """
        content.addSubview(code)
        let note = NSTextField(wrappingLabelWithString: "This isolated test window contains public test content. Audio playback uses a locally selected licensed fixture.")
        note.frame = NSRect(x: 30, y: 65, width: 570, height: 45)
        content.addSubview(note)
        let play = NSButton(title: "Play audio fixture", target: self, action: #selector(playAudio))
        play.frame = NSRect(x: 615, y: 72, width: 160, height: 30); content.addSubview(play)
        window.contentView = content; window.center(); window.makeKeyAndOrderFront(nil)
        self.window = window
        NSApp.activate(ignoringOtherApps: true)
    }
    @objc func playAudio() {
        guard let index = CommandLine.arguments.firstIndex(of: "--audio-file"), CommandLine.arguments.indices.contains(index + 1) else { return }
        do {
            player = try AVAudioPlayer(contentsOf: URL(fileURLWithPath: CommandLine.arguments[index + 1]))
            player?.play()
        } catch { NSLog("Public fixture playback failed") }
    }
}
@main struct CaptureFixture {
    @MainActor static func main() {
        let app = NSApplication.shared
        let delegate = FixtureDelegate()
        app.delegate = delegate; app.setActivationPolicy(.regular); app.run()
        withExtendedLifetime(delegate) {}
    }
}
