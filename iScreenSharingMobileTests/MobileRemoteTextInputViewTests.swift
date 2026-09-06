import UIKit
import XCTest
@testable import iScreenSharingMobile

@MainActor
final class MobileRemoteTextInputViewTests: XCTestCase {
    func testCandidateUpdatesStayLocalAndCommitOnlyOnce() {
        let input = MobileRemoteTextInputView()
        var commits = [String]()
        input.onCommit = { commits.append($0) }
        input.setMarkedText("ni", selectedRange: NSRange(location: 2, length: 0))
        input.setMarkedText("nihao", selectedRange: NSRange(location: 5, length: 0))
        XCTAssertNotNil(input.markedTextRange)
        XCTAssertTrue(commits.isEmpty)
        input.insertText("你好")
        input.textViewDidChange(input)
        input.unmarkText()
        XCTAssertEqual(commits, ["你好"])
        XCTAssertEqual(input.text, "")
        input.insertText("!")
        XCTAssertEqual(commits, ["你好", "!"])
    }

    func testDeletingCompositionDoesNotDeleteRemoteText() {
        let input = MobileRemoteTextInputView()
        var commits = [String]()
        var deletes = 0
        input.onCommit = { commits.append($0) }
        input.onDelete = { deletes += 1 }
        input.setMarkedText("ni", selectedRange: NSRange(location: 2, length: 0))
        input.deleteBackward()
        XCTAssertTrue(commits.isEmpty)
        XCTAssertEqual(deletes, 0)
        input.discardPendingText()
        input.deleteBackward()
        XCTAssertEqual(deletes, 1)
    }

    func testInterruptionDiscardsDraftAndRejectsLateInput() {
        let input = MobileRemoteTextInputView()
        var commits = [String]()
        input.onCommit = { commits.append($0) }
        input.setMarkedText("wei", selectedRange: NSRange(location: 3, length: 0))
        input.acceptsInput = false
        input.unmarkText()
        input.insertText("stale")
        input.acceptsInput = true
        input.insertText("fresh")
        XCTAssertEqual(commits, ["fresh"])
        XCTAssertNil(input.markedTextRange)
    }

    func testUnmarkConfirmsButExplicitDiscardDoesNot() {
        let input = MobileRemoteTextInputView()
        var commits = [String]()
        input.onCommit = { commits.append($0) }
        input.setMarkedText("好", selectedRange: NSRange(location: 1, length: 0))
        input.unmarkText()
        input.setMarkedText("取消", selectedRange: NSRange(location: 2, length: 0))
        input.discardPendingText()
        input.unmarkText()
        input.insertText("👩🏽‍💻\n")
        XCTAssertEqual(commits, ["好", "👩🏽‍💻\n"])
    }

    func testResigningDoesNotImplicitlyConfirmComposition() {
        let input = MobileRemoteTextInputView()
        var commits = [String]()
        input.onCommit = { commits.append($0) }
        input.setMarkedText("quxiao", selectedRange: NSRange(location: 6, length: 0))
        _ = input.resignFirstResponder()
        input.unmarkText()
        XCTAssertTrue(commits.isEmpty)
        XCTAssertEqual(input.text, "")
    }
}
