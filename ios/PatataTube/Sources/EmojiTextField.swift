import SwiftUI
import UIKit

/// A text field that comes up on the emoji keyboard.
///
/// SwiftUI has no knob for this: which keyboard a field opens with is decided by
/// `UITextInputMode`, and only a `UITextField` subclass can override that. The
/// override is a preference, not a guarantee — a user with no emoji keyboard
/// installed has no emoji entry in `activeInputModes`, and the field falls back
/// to the default keyboard instead of coming up blank.
struct EmojiTextField: UIViewRepresentable {
    let placeholder: String
    @Binding var text: String
    var font: UIFont = .preferredFont(forTextStyle: .body)
    var alignment: NSTextAlignment = .natural
    /// Takes first responder itself, so callers don't need `@FocusState` — which
    /// does not reach into a representable's `UIView` anyway.
    var focusOnAppear: Bool = true
    /// Selects the existing text when editing starts, so the first character
    /// typed replaces it instead of appending. For a one-emoji field appending
    /// is never what the user meant.
    var selectAllOnFocus: Bool = true
    var onSubmit: () -> Void = {}

    func makeUIView(context: Context) -> UITextField {
        let field = EmojiFirstTextField()
        field.placeholder = placeholder
        field.delegate = context.coordinator
        field.font = font
        field.textAlignment = alignment
        field.autocorrectionType = .no
        field.returnKeyType = .done
        field.text = text
        field.addTarget(
            context.coordinator,
            action: #selector(Coordinator.editingChanged(_:)),
            for: .editingChanged
        )
        // Without this the field stretches the Form row to the intrinsic width
        // of its text instead of filling the row.
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        if focusOnAppear {
            // Not in the same turn of the run loop as view creation: the field
            // is not in a window yet, and `becomeFirstResponder` returns false.
            DispatchQueue.main.async { field.becomeFirstResponder() }
        }
        return field
    }

    func updateUIView(_ field: UITextField, context: Context) {
        context.coordinator.parent = self
        if field.text != text { field.text = text }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UITextFieldDelegate {
        var parent: EmojiTextField

        init(_ parent: EmojiTextField) { self.parent = parent }

        @objc func editingChanged(_ field: UITextField) {
            parent.text = field.text ?? ""
        }

        func textFieldDidBeginEditing(_ field: UITextField) {
            guard parent.selectAllOnFocus, field.text?.isEmpty == false else { return }
            // Deferred: selecting inside the delegate callback is undone by the
            // caret placement UIKit does right after it.
            DispatchQueue.main.async { field.selectAll(nil) }
        }

        func textFieldShouldReturn(_ field: UITextField) -> Bool {
            parent.onSubmit()
            return true
        }
    }
}

private final class EmojiFirstTextField: UITextField {
    // A non-nil identifier lets UIKit restore whichever keyboard the user last
    // used in this field, which would defeat the override on the second visit.
    // "" opts out of that memory, so every appearance starts on emoji.
    override var textInputContextIdentifier: String? { "" }

    override var textInputMode: UITextInputMode? {
        UITextInputMode.activeInputModes.first { $0.primaryLanguage == "emoji" }
            ?? super.textInputMode
    }
}
