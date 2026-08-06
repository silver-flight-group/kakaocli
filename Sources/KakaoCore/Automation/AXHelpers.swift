import AppKit
import ApplicationServices

/// Low-level helpers for macOS Accessibility API.
public enum AXHelpers {

    /// Get the AXUIElement for a running application by bundle identifier.
    public static func appElement(bundleId: String) throws -> AXUIElement {
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleId).first else {
            throw KakaoError.kakaoTalkNotInstalled
        }
        return AXUIElementCreateApplication(app.processIdentifier)
    }

    /// Activate (bring to front) an app by bundle identifier.
    public static func activateApp(bundleId: String) throws {
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleId).first else {
            throw KakaoError.kakaoTalkNotInstalled
        }
        app.activate()
        Thread.sleep(forTimeInterval: 0.3)
    }

    /// Get a string attribute from an AXUIElement.
    public static func attribute(_ element: AXUIElement, _ attr: String) -> String? {
        var value: AnyObject?
        let result = AXUIElementCopyAttributeValue(element, attr as CFString, &value)
        guard result == .success else { return nil }
        return value as? String
    }

    /// Get an integer attribute from an AXUIElement.
    public static func intAttribute(_ element: AXUIElement, _ attr: String) -> Int? {
        var value: AnyObject?
        let result = AXUIElementCopyAttributeValue(element, attr as CFString, &value)
        guard result == .success else { return nil }
        return value as? Int
    }

    /// Get a boolean attribute from an AXUIElement.
    public static func boolAttribute(_ element: AXUIElement, _ attr: String) -> Bool? {
        var value: AnyObject?
        let result = AXUIElementCopyAttributeValue(element, attr as CFString, &value)
        guard result == .success else { return nil }
        if let num = value as? NSNumber { return num.boolValue }
        return nil
    }

    /// Get children of an AXUIElement.
    public static func children(_ element: AXUIElement) -> [AXUIElement] {
        var value: AnyObject?
        let result = AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &value)
        guard result == .success, let children = value as? [AXUIElement] else { return [] }
        return children
    }

    /// Get all windows of an app element.
    /// Note: KakaoTalk may return AXApplication elements instead of AXWindow elements
    /// when the window is in certain states. We return whatever is in the list.
    public static func windows(_ appElement: AXUIElement) -> [AXUIElement] {
        var value: AnyObject?
        let result = AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &value)
        guard result == .success, let windows = value as? [AXUIElement] else { return [] }
        return windows
    }

    /// Get the role of an element.
    public static func role(_ element: AXUIElement) -> String? {
        attribute(element, kAXRoleAttribute as String)
    }

    /// Get the title/description of an element.
    public static func title(_ element: AXUIElement) -> String? {
        attribute(element, kAXTitleAttribute as String)
    }

    /// Get the value of an element.
    public static func value(_ element: AXUIElement) -> String? {
        attribute(element, kAXValueAttribute as String)
    }

    /// Get the description of an element.
    public static func description(_ element: AXUIElement) -> String? {
        attribute(element, kAXDescriptionAttribute as String)
    }

    /// Get the role description of an element.
    public static func roleDescription(_ element: AXUIElement) -> String? {
        attribute(element, kAXRoleDescriptionAttribute as String)
    }

    /// Get the identifier of an element.
    public static func identifier(_ element: AXUIElement) -> String? {
        attribute(element, kAXIdentifierAttribute as String)
    }

    /// Set the value of an element.
    public static func setValue(_ element: AXUIElement, _ value: String) -> Bool {
        AXUIElementSetAttributeValue(element, kAXValueAttribute as CFString, value as CFTypeRef) == .success
    }

    /// Perform an action (e.g., press, confirm).
    public static func performAction(_ element: AXUIElement, _ action: String) -> Bool {
        AXUIElementPerformAction(element, action as CFString) == .success
    }

    /// Set focus on an element.
    public static func focus(_ element: AXUIElement) -> Bool {
        AXUIElementSetAttributeValue(element, kAXFocusedAttribute as CFString, true as CFTypeRef) == .success
    }

    /// Close a window via its close button.
    public static func closeWindow(_ window: AXUIElement) -> Bool {
        var value: AnyObject?
        let result = AXUIElementCopyAttributeValue(window, kAXCloseButtonAttribute as CFString, &value)
        guard result == .success, let closeButton = value else { return false }
        return AXUIElementPerformAction(closeButton as! AXUIElement, kAXPressAction as CFString) == .success
    }

    /// Dump the UI tree recursively for inspection.
    public static func dumpTree(_ element: AXUIElement, depth: Int = 0, maxDepth: Int = 6) -> String {
        guard depth <= maxDepth else { return "" }
        let indent = String(repeating: "  ", count: depth)
        let r = role(element) ?? "?"
        let t = title(element)
        let v = value(element)
        let d = description(element)
        let id = identifier(element)

        var line = "\(indent)[\(r)]"
        if let t { line += " title=\"\(t.prefix(60))\"" }
        if let v, !v.isEmpty { line += " value=\"\(v.prefix(60))\"" }
        if let d, !d.isEmpty { line += " desc=\"\(d.prefix(60))\"" }
        if let id, !id.isEmpty { line += " id=\"\(id)\"" }
        line += "\n"

        for child in children(element) {
            line += dumpTree(child, depth: depth + 1, maxDepth: maxDepth)
        }
        return line
    }

    /// Find all elements matching a role, searching recursively.
    public static func findAll(_ element: AXUIElement, role targetRole: String, maxDepth: Int = 10, currentDepth: Int = 0) -> [AXUIElement] {
        guard currentDepth <= maxDepth else { return [] }
        var results: [AXUIElement] = []
        if role(element) == targetRole {
            results.append(element)
        }
        for child in children(element) {
            results += findAll(child, role: targetRole, maxDepth: maxDepth, currentDepth: currentDepth + 1)
        }
        return results
    }

    /// Find the first element matching a role and containing text.
    public static func findFirst(_ element: AXUIElement, role targetRole: String, text: String, maxDepth: Int = 10, currentDepth: Int = 0) -> AXUIElement? {
        guard currentDepth <= maxDepth else { return nil }
        if role(element) == targetRole {
            let t = title(element) ?? value(element) ?? ""
            if t.localizedCaseInsensitiveContains(text) {
                return element
            }
        }
        for child in children(element) {
            if let found = findFirst(child, role: targetRole, text: text, maxDepth: maxDepth, currentDepth: currentDepth + 1) {
                return found
            }
        }
        return nil
    }

    /// Find the first element matching a role and identifier.
    public static func findFirst(_ element: AXUIElement, role targetRole: String, identifier targetId: String, maxDepth: Int = 10, currentDepth: Int = 0) -> AXUIElement? {
        guard currentDepth <= maxDepth else { return nil }
        if role(element) == targetRole {
            if identifier(element) == targetId {
                return element
            }
        }
        for child in children(element) {
            if let found = findFirst(child, role: targetRole, identifier: targetId, maxDepth: maxDepth, currentDepth: currentDepth + 1) {
                return found
            }
        }
        return nil
    }

    /// The chat name shown on a chat-list row, or nil if the row has no label.
    ///
    /// This used to key off the AXIdentifier `_NS:18`. Those identifiers are
    /// AppKit internals (`_NS:` + a nib-encoding ordinal) and are **not stable
    /// across KakaoTalk builds**: on current versions the name label is
    /// `_NS:40`, and `_NS:18` is the "badge openchat room" *AXImage*. Since the
    /// old lookup also required role `AXStaticText`, it matched nothing at all —
    /// silently, so `findChatRow` returned nil for every chat and `harvest`
    /// recorded every name as "(unknown)".
    ///
    /// Match on structure instead, which has been stable: inside the row's
    /// AXCell the name is the first AXStaticText. The optional openchat badge
    /// ahead of it is an AXImage, and the unread "Count Label" and the timestamp
    /// both come after it.
    public static func chatRowName(_ row: AXUIElement) -> String? {
        for cell in children(row) {
            guard role(cell) == "AXCell" else { continue }
            for child in children(cell) {
                guard role(child) == "AXStaticText" else { continue }
                if let name = value(child), !name.isEmpty { return name }
            }
        }
        return nil
    }

    /// Find the AXRow in a chat list whose name label matches the given text.
    ///
    /// Note this only sees rows in the **top-level** chat list. KakaoTalk groups
    /// chats into folders — the `NTChatFolder` table, plus "Silent Chatroom" —
    /// and a folder appears as a single collapsed row whose members are not
    /// children of this table. They therefore cannot be found here at all. On my
    /// install that hides 17 of 59 chats, so `send` fails for any of them.
    public static func findChatRow(_ table: AXUIElement, chatName: String, exact: Bool = false) -> AXUIElement? {
        for row in children(table) {
            guard role(row) == "AXRow", let name = chatRowName(row) else { continue }
            let matches = exact ? name == chatName : name.localizedCaseInsensitiveContains(chatName)
            if matches { return row }
        }
        return nil
    }

    /// Find the self-chat row (identified by "badge me" image in the cell).
    public static func findSelfChatRow(_ table: AXUIElement) -> AXUIElement? {
        for row in children(table) {
            guard role(row) == "AXRow" else { continue }
            for cell in children(row) {
                guard role(cell) == "AXCell" else { continue }
                for child in children(cell) {
                    if role(child) == "AXImage" {
                        let desc = description(child) ?? ""
                        if desc.contains("badge me") {
                            return row
                        }
                    }
                }
            }
        }
        return nil
    }

    /// Scroll a table row into the visible area of its parent scroll area.
    /// Returns true if the row is now visible (or was already visible).
    public static func scrollRowToVisible(_ row: AXUIElement, in scrollArea: AXUIElement) -> Bool {
        guard let rowPos = position(row), let rowSize = size(row),
              let areaPos = position(scrollArea), let areaSize = size(scrollArea) else {
            return false
        }

        let areaTop = areaPos.y
        let areaBottom = areaPos.y + areaSize.height
        let rowTop = rowPos.y
        let rowBottom = rowPos.y + rowSize.height

        // Already visible
        if rowTop >= areaTop && rowBottom <= areaBottom {
            return true
        }

        // Scroll using CGEvent wheel events on the scroll area center
        let scrollCenter = CGPoint(x: areaPos.x + areaSize.width / 2,
                                    y: areaPos.y + areaSize.height / 2)
        let maxAttempts = 80
        for _ in 0..<maxAttempts {
            let curPos = position(row)
            guard let curY = curPos?.y, let curH = size(row)?.height else { break }

            if curY >= areaTop && (curY + curH) <= areaBottom {
                return true // Row is now visible
            }

            // Scroll down if row is below visible area, up if above
            let deltaY: Int32 = curY > areaBottom ? -3 : 3
            scrollLines(deltaY: deltaY, at: scrollCenter)
            usleep(50000) // 50ms between scrolls
        }

        // Check one more time
        if let finalPos = position(row), let finalSize = size(row) {
            return finalPos.y >= areaTop && (finalPos.y + finalSize.height) <= areaBottom
        }
        return false
    }

    /// Get the AXTable (chat list) from the main window.
    public static func chatListTable(_ window: AXUIElement) -> AXUIElement? {
        // Structure: AXWindow > AXScrollArea > AXTable
        for child in children(window) {
            if role(child) == "AXScrollArea" {
                for subchild in children(child) {
                    if role(subchild) == "AXTable" {
                        return subchild
                    }
                }
            }
        }
        return nil
    }

    /// Get the AXScrollArea containing the chat list table from the main window.
    public static func chatListScrollArea(_ window: AXUIElement) -> AXUIElement? {
        for child in children(window) {
            if role(child) == "AXScrollArea" {
                for subchild in children(child) {
                    if role(subchild) == "AXTable" {
                        return child
                    }
                }
            }
        }
        return nil
    }

    /// Select a row in a table via AX API.
    public static func selectRow(_ row: AXUIElement, in table: AXUIElement) -> Bool {
        let result = AXUIElementSetAttributeValue(
            table,
            kAXSelectedRowsAttribute as CFString,
            [row] as CFTypeRef
        )
        return result == .success
    }

    /// Get the parent of an AXUIElement.
    public static func parent(_ element: AXUIElement) -> AXUIElement? {
        var value: AnyObject?
        let result = AXUIElementCopyAttributeValue(element, kAXParentAttribute as CFString, &value)
        guard result == .success else { return nil }
        return (value as! AXUIElement)
    }

    /// Get the position (frame origin) of an element.
    public static func position(_ element: AXUIElement) -> CGPoint? {
        var value: AnyObject?
        let result = AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &value)
        guard result == .success, let axValue = value else { return nil }
        var point = CGPoint.zero
        AXValueGetValue(axValue as! AXValue, .cgPoint, &point)
        return point
    }

    /// Get the size of an element.
    public static func size(_ element: AXUIElement) -> CGSize? {
        var value: AnyObject?
        let result = AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &value)
        guard result == .success, let axValue = value else { return nil }
        var size = CGSize.zero
        AXValueGetValue(axValue as! AXValue, .cgSize, &size)
        return size
    }

    /// Click at the center of an element using CGEvent.
    public static func clickElement(_ element: AXUIElement) {
        guard let pos = position(element), let sz = size(element) else { return }
        let center = CGPoint(x: pos.x + sz.width / 2, y: pos.y + sz.height / 2)
        if let mouseDown = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: center, mouseButton: .left),
           let mouseUp = CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: center, mouseButton: .left) {
            mouseDown.post(tap: .cghidEventTap)
            usleep(50000)
            mouseUp.post(tap: .cghidEventTap)
        }
    }

    // MARK: - Mouse Movement & Scroll

    /// Move the mouse cursor to a screen position.
    public static func moveMouse(to point: CGPoint) {
        if let event = CGEvent(mouseEventSource: nil, mouseType: .mouseMoved,
                               mouseCursorPosition: point, mouseButton: .left) {
            event.post(tap: .cghidEventTap)
        }
    }

    /// Send a scroll wheel event (pixel units). Negative deltaY = scroll up, positive = scroll down.
    public static func scroll(deltaY: Int32, at point: CGPoint? = nil) {
        if let point {
            moveMouse(to: point)
            usleep(50000) // 50ms settle
        }
        if let event = CGEvent(scrollWheelEvent2Source: nil, units: .pixel,
                               wheelCount: 1, wheel1: deltaY, wheel2: 0, wheel3: 0) {
            event.post(tap: .cghidEventTap)
        }
    }

    /// Send a scroll wheel event (line units). Negative deltaY = scroll down, positive = scroll up.
    public static func scrollLines(deltaY: Int32, at point: CGPoint? = nil) {
        if let point {
            moveMouse(to: point)
            usleep(50000) // 50ms settle
        }
        if let event = CGEvent(scrollWheelEvent2Source: nil, units: .line,
                               wheelCount: 1, wheel1: deltaY, wheel2: 0, wheel3: 0) {
            event.post(tap: .cghidEventTap)
        }
    }

    // MARK: - Keyboard Helpers

    /// Type text using CGEvent (handles Unicode correctly).
    public static func typeText(_ text: String) {
        for char in text {
            let utf16 = Array(char.utf16)
            if let down = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true),
               let up = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: false) {
                down.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: utf16)
                up.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: utf16)
                down.post(tap: .cghidEventTap)
                up.post(tap: .cghidEventTap)
                usleep(5000) // 5ms between keystrokes
            }
        }
    }

    /// Press a key using CGEvent.
    public static func pressKey(keyCode: CGKeyCode, flags: CGEventFlags = []) {
        if let down = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: true),
           let up = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: false) {
            down.flags = flags
            up.flags = flags
            down.post(tap: .cghidEventTap)
            up.post(tap: .cghidEventTap)
        }
    }

    /// Select all text (Cmd+A).
    public static func selectAll() {
        pressKey(keyCode: 0, flags: .maskCommand)
        Thread.sleep(forTimeInterval: 0.05)
    }

    /// Double-click at the center of an element using CGEvent.
    public static func doubleClickElement(_ element: AXUIElement) {
        guard let pos = position(element), let sz = size(element) else { return }
        let center = CGPoint(x: pos.x + sz.width / 2, y: pos.y + sz.height / 2)
        for _ in 0..<2 {
            if let mouseDown = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: center, mouseButton: .left),
               let mouseUp = CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: center, mouseButton: .left) {
                mouseDown.setIntegerValueField(.mouseEventClickState, value: 2)
                mouseUp.setIntegerValueField(.mouseEventClickState, value: 2)
                mouseDown.post(tap: .cghidEventTap)
                usleep(20000)
                mouseUp.post(tap: .cghidEventTap)
                usleep(20000)
            }
        }
    }
}
