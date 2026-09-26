import XCTest
import AppKit
@testable import LumiBase

final class SidebarShortcutMergeTests: XCTestCase {
    @MainActor func testF7AndF8ToggleOnlyTheirOwnPanel() throws {
        _ = NSApplication.shared
        let state = AppState()
        let initialLeft = state.isLeftSidebarVisible
        let initialRight = state.isRightInspectorVisible
        func event(_ code: UInt16) throws -> NSEvent {
            try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                timestamp: 0, windowNumber: 0, context: nil, characters: "", charactersIgnoringModifiers: "",
                isARepeat: false, keyCode: code))
        }
        XCTAssertTrue(state.handleGlobalKeyEvent(try event(98)))
        XCTAssertEqual(state.isLeftSidebarVisible, !initialLeft)
        XCTAssertEqual(state.isRightInspectorVisible, initialRight)
        XCTAssertTrue(state.handleGlobalKeyEvent(try event(100)))
        XCTAssertEqual(state.isLeftSidebarVisible, !initialLeft)
        XCTAssertEqual(state.isRightInspectorVisible, !initialRight)
        XCTAssertTrue(state.handleGlobalKeyEvent(try event(98)))
        XCTAssertTrue(state.handleGlobalKeyEvent(try event(100)))
        XCTAssertEqual(state.isLeftSidebarVisible, initialLeft)
        XCTAssertEqual(state.isRightInspectorVisible, initialRight)
    }
}
