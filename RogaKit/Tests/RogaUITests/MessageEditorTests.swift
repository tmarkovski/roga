import AppKit
import SwiftUI
import Testing
@testable import RogaUI

/// The commit box's text view and Command-Z: text put in from elsewhere, such
/// as an agent's message, is an edit that undoing takes back, rather than one
/// that leaves undo steps for text that's gone.
@Suite(.timeLimit(.minutes(1)))
struct MessageEditorTests {
    /// What the box's binding holds, as the composer's message does.
    final class Message {
        var text = ""
    }

    /// The editor's text view, set up as SwiftUI would set it up, in a window
    /// that's never shown, which gives it an undo manager. The undo manager
    /// groups by hand, since no events go by to group by.
    struct Editor {
        let message: Message
        let coordinator: MessageEditor.Coordinator
        let scrollView: NSScrollView
        let window: NSWindow
        let undo: UndoManager

        var textView: NSTextView { coordinator.textView! }

        @MainActor init(_ text: String = "") throws {
            message = Message()
            message.text = text
            let editor = Self.editor(message, isEditable: true)
            coordinator = editor.makeCoordinator()
            scrollView = editor.makeScrollView(coordinator: coordinator)
            window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 200), styleMask: .borderless, backing: .buffered, defer: true)
            window.isReleasedWhenClosed = false
            window.contentView = scrollView
            undo = try #require(window.undoManager)
            undo.groupsByEvent = false
            editor.update(scrollView, coordinator: coordinator)
        }

        @MainActor static func editor(_ message: Message, isEditable: Bool, isCovered: Bool = false) -> MessageEditor {
            MessageEditor(
                text: Binding { message.text } set: { message.text = $0 },
                isEditable: isEditable,
                focusRequests: 0,
                textHeight: .constant(0),
                leave: {},
                isCovered: isCovered
            )
        }

        /// Types at the end, as someone would.
        @MainActor func type(_ text: String) {
            step {
                textView.setSelectedRange(NSRange(location: (textView.string as NSString).length, length: 0))
                textView.insertText(text, replacementRange: textView.selectedRange())
            }
        }

        /// Puts text in the binding, as the composer does, and lets the editor
        /// hear of it.
        @MainActor func show(_ text: String, isEditable: Bool = true, isCovered: Bool = false) {
            message.text = text
            step { Self.editor(message, isEditable: isEditable, isCovered: isCovered).update(scrollView, coordinator: coordinator) }
        }

        @MainActor func step(_ body: () -> Void) {
            undo.beginUndoGrouping()
            body()
            undo.endUndoGrouping()
        }
    }

    @Test func undoingAnAgentsMessageGivesBackYourWords() throws {
        let editor = try Editor()
        editor.type("my words")
        #expect(editor.message.text == "my words")

        editor.show("Rename the app\n\nIt's Roga now.")
        #expect(editor.textView.string == "Rename the app\n\nIt's Roga now.")
        // The box doesn't hand the text it was given back to the composer.
        #expect(editor.message.text == "Rename the app\n\nIt's Roga now.")

        editor.undo.undo()
        #expect(editor.textView.string == "my words")
        #expect(editor.message.text == "my words")
        editor.undo.redo()
        #expect(editor.textView.string == "Rename the app\n\nIt's Roga now.")
        #expect(editor.message.text == "Rename the app\n\nIt's Roga now.")
    }

    @Test func undoingTypingAfterwardLeavesTheMessageWhole() throws {
        let editor = try Editor()
        // Longer than what replaces it, which used to throw on undoing.
        editor.type("Retry signing in once the session token has expired, please")
        editor.show("Retry sign-in")
        editor.type(" after a 401")
        #expect(editor.message.text == "Retry sign-in after a 401")

        editor.undo.undo()
        #expect(editor.textView.string == "Retry sign-in")
        editor.undo.undo()
        #expect(editor.textView.string == "Retry signing in once the session token has expired, please")
        #expect(editor.message.text == editor.textView.string)
    }

    @Test func textThatCantBeEditedStillComesIn() throws {
        let editor = try Editor()
        editor.type("my words")
        // A rebase's message, which shows as it is.
        editor.show("Change the app", isEditable: false)
        #expect(editor.textView.string == "Change the app")
        #expect(!editor.textView.isEditable)
        #expect(editor.message.text == "Change the app")

        editor.show("my words")
        #expect(editor.textView.isEditable)
        #expect(editor.textView.string == "my words")
    }

    /// While an agent writes, the gray bars cover the text view, which still
    /// has the text from before, so VoiceOver mustn't find it there.
    @Test func aCoveredEditorIsntReadAloud() throws {
        let editor = try Editor()
        editor.type("my words")
        #expect(editor.textView.isAccessibilityElement())
        #expect(editor.scrollView.isAccessibilityElement())

        editor.show("my words", isEditable: false, isCovered: true)
        #expect(!editor.textView.isAccessibilityElement())
        #expect(!editor.scrollView.isAccessibilityElement())

        editor.show("Rename the app")
        #expect(editor.textView.isAccessibilityElement())
        #expect(editor.scrollView.isAccessibilityElement())
    }
}
