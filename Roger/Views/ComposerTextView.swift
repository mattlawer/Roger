import SwiftUI
import AppKit

/// The message editor: a plain NSTextView that grows with its content, sends on Return and
/// inserts a newline on Option- or Shift-Return. Files dropped on it become attachments
/// instead of having their paths pasted, and pasted images become image attachments.
struct ComposerTextView: NSViewRepresentable {
    @Binding var text: String
    @Binding var height: CGFloat
    var placeholder: String
    /// Bumped by the parent to move keyboard focus into the editor.
    var focusRequest: Int
    var maxLines = 12
    var onSubmit: () -> Void
    var onDropFiles: ([URL]) -> Void
    var onPasteImage: (Data) -> Void
    var onDragTargeted: (Bool) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let textView = DropAwareTextView()
        textView.delegate = context.coordinator
        textView.isRichText = false
        textView.allowsUndo = true
        textView.font = NSFont.preferredFont(forTextStyle: .body)
        textView.textColor = .labelColor
        textView.drawsBackground = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isContinuousSpellCheckingEnabled = true
        textView.textContainerInset = NSSize(width: 0, height: 2)
        textView.textContainer?.lineFragmentPadding = 2
        textView.textContainer?.widthTracksTextView = true
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.minSize = .zero
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.placeholder = placeholder
        textView.setAccessibilityPlaceholderValue(placeholder)
        textView.string = text

        let scroll = NSScrollView()
        scroll.documentView = textView
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.hasHorizontalScroller = false
        scroll.verticalScrollElasticity = .none
        context.coordinator.textView = textView
        DispatchQueue.main.async { context.coordinator.updateHeight() }
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let tv = context.coordinator.textView else { return }
        context.coordinator.parent = self
        tv.onSubmit = onSubmit
        tv.onDropFiles = onDropFiles
        tv.onPasteImage = onPasteImage
        tv.onDragTargeted = onDragTargeted
        if tv.string != text {
            tv.string = text
            tv.needsDisplay = true
            DispatchQueue.main.async { context.coordinator.updateHeight() }
        }
        if context.coordinator.lastFocusRequest != focusRequest {
            context.coordinator.lastFocusRequest = focusRequest
            DispatchQueue.main.async { tv.window?.makeFirstResponder(tv) }
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: ComposerTextView
        weak var textView: DropAwareTextView?
        var lastFocusRequest = -1

        init(_ parent: ComposerTextView) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard let tv = textView else { return }
            parent.text = tv.string
            tv.needsDisplay = true
            updateHeight()
        }

        /// One line minimum, `maxLines` maximum, then the editor scrolls.
        func updateHeight() {
            guard let tv = textView, let lm = tv.layoutManager, let tc = tv.textContainer, let font = tv.font else { return }
            lm.ensureLayout(for: tc)
            let inset = tv.textContainerInset.height * 2
            let line = lm.defaultLineHeight(for: font)
            let used = lm.usedRect(for: tc).height
            let h = min(line * CGFloat(parent.maxLines) + inset, max(line + inset, used + inset))
            if abs(h - parent.height) > 0.5 {
                DispatchQueue.main.async { self.parent.height = h }
            }
        }

        func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            switch commandSelector {
            case #selector(NSResponder.insertNewline(_:)):
                let flags = NSApp.currentEvent?.modifierFlags ?? []
                if flags.contains(.option) || flags.contains(.shift) {
                    textView.insertNewlineIgnoringFieldEditor(nil)
                    return true
                }
                parent.onSubmit()
                return true
            default:
                return false
            }
        }
    }
}

final class DropAwareTextView: NSTextView {
    var placeholder = ""
    var onSubmit: () -> Void = {}
    var onDropFiles: ([URL]) -> Void = { _ in }
    var onPasteImage: (Data) -> Void = { _ in }
    var onDragTargeted: (Bool) -> Void = { _ in }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard string.isEmpty, !placeholder.isEmpty else { return }
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font ?? NSFont.preferredFont(forTextStyle: .body),
            .foregroundColor: NSColor.placeholderTextColor,
        ]
        let origin = NSPoint(x: textContainerInset.width + (textContainer?.lineFragmentPadding ?? 0), y: textContainerInset.height)
        (placeholder as NSString).draw(at: origin, withAttributes: attrs)
    }

    override func didChangeText() {
        super.didChangeText()
        needsDisplay = true
    }

    // MARK: Drops: files become attachments, anything else behaves as usual.

    private func fileURLs(_ info: NSDraggingInfo) -> [URL] {
        (info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        if !fileURLs(sender).isEmpty { onDragTargeted(true); return .copy }
        return super.draggingEntered(sender)
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        if !fileURLs(sender).isEmpty { return .copy }
        return super.draggingUpdated(sender)
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        onDragTargeted(false)
        super.draggingExited(sender)
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        !fileURLs(sender).isEmpty || super.prepareForDragOperation(sender)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        onDragTargeted(false)
        let urls = fileURLs(sender)
        if !urls.isEmpty {
            onDropFiles(urls)
            return true
        }
        return super.performDragOperation(sender)
    }

    override func concludeDragOperation(_ sender: NSDraggingInfo?) {
        onDragTargeted(false)
        super.concludeDragOperation(sender)
    }

    // MARK: Paste: an image on the clipboard becomes an attachment.

    override func paste(_ sender: Any?) {
        let pb = NSPasteboard.general
        if pb.string(forType: .string) == nil, let image = NSImage(pasteboard: pb), let png = image.pngData() {
            onPasteImage(png)
            return
        }
        super.paste(sender)
    }
}

extension NSImage {
    func pngData() -> Data? {
        guard let tiff = tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }
}
