import AppKit
import ApplicationServices
import Foundation
import Vision

/// Harvests KakaoTalk chat history by opening chats, scrolling to load messages,
/// and clicking "View Previous Chats" to fetch older history.
/// Also captures display names from the UI that may be missing from the database.
public enum ChatHarvester {

    public struct HarvestResult {
        public let chatId: Int64
        public let uiName: String
        public let messagesBefore: Int
        public let messagesAfter: Int
        public let skipped: Bool
        public let skipReason: String?
    }

    public struct Options {
        public var maxChats: Int
        public var maxScrollsPerChat: Int
        public var maxPreviousClicks: Int
        public var namesOnly: Bool
        public var skipUnread: Bool
        public var scrollDelay: TimeInterval

        public init(
            maxChats: Int = 0,
            maxScrollsPerChat: Int = 15,
            maxPreviousClicks: Int = 10,
            namesOnly: Bool = false,
            skipUnread: Bool = true,
            scrollDelay: TimeInterval = 1.5
        ) {
            self.maxChats = maxChats
            self.maxScrollsPerChat = maxScrollsPerChat
            self.maxPreviousClicks = maxPreviousClicks
            self.namesOnly = namesOnly
            self.skipUnread = skipUnread
            self.scrollDelay = scrollDelay
        }
    }

    /// Harvest chat history and names by automating the KakaoTalk UI.
    ///
    /// For each chat: opens it, reads the UI name, scrolls up and clicks
    /// "View Previous Chats" to load older messages, then saves metadata.
    /// Skips chats with unread messages.
    public static func harvest(
        db: DatabaseReader,
        metadata: MetadataStore,
        options: Options,
        progress: @escaping (String) -> Void
    ) throws -> [HarvestResult] {
        // 1. Get the DB chat list, plus the name and last message text that let
        //    a UI row be identified. The old code ordered by lastUpdatedAt DESC
        //    and paired row i with chat i, on the assumption that the DB order
        //    "matches UI order". It does not: chats filed under "Silent
        //    Chatroom" are collapsed into a folder row and absent from the
        //    top-level list, so the two lists differ in both length and order
        //    and every pairing after the first hidden chat was wrong.
        let dbChats = try db.rawQuery("""
            SELECT r.chatId, r.type, r.activeMembersCount,
                   r.countOfNewMessage, r.lastUpdatedAt,
                   (SELECT COUNT(*) FROM NTChatMessage m WHERE m.chatId = r.chatId) as msgCount,
                   COALESCE(r.chatName, u.displayName, u.friendNickName, u.nickName) as dbName,
                   (SELECT m.message FROM NTChatMessage m
                     WHERE m.chatId = r.chatId ORDER BY m.sentAt DESC LIMIT 1) as lastMessage
            FROM NTChatRoom r
            LEFT JOIN NTUser u ON r.directChatMemberUserId = u.userId AND u.linkId = 0
            ORDER BY r.lastUpdatedAt DESC
        """)

        progress("Found \(dbChats.count) chats in database")

        // 2. Ensure KakaoTalk is running, logged in, *and showing its window*.
        //    ensureReady() has to be called unconditionally. A running,
        //    logged-in KakaoTalk whose main window has been closed still
        //    reports .loggedIn, so the old state guard skipped the one call
        //    that reopens it — ensureWindowVisible() — and harvest then threw
        //    noWindows from step 3. `KakaoAutomator.sendMessage` already calls
        //    it unconditionally for exactly this reason.
        let state = AppLifecycle.detectState()
        try AppLifecycle.ensureReady(credentials: CredentialStore())
        if state != .loggedIn {
            Thread.sleep(forTimeInterval: 2.0)
        }

        // 3. Activate and get windows
        let bundleId = KakaoAutomator.bundleId
        try AXHelpers.activateApp(bundleId: bundleId)
        Thread.sleep(forTimeInterval: 0.5)
        let app = try AXHelpers.appElement(bundleId: bundleId)
        var windows = AXHelpers.windows(app)

        guard let mainWindow = windows.first(where: { AXHelpers.identifier($0) == "Main Window" }) else {
            throw AutomationError.noWindows
        }

        // 4. Close any open chat windows
        for w in windows where AXHelpers.identifier(w) != "Main Window" {
            _ = AXHelpers.closeWindow(w)
        }
        Thread.sleep(forTimeInterval: 0.3)

        // 5. Switch to chats tab
        if let tab = AXHelpers.findFirst(mainWindow, role: "AXCheckBox", identifier: "chatrooms") {
            _ = AXHelpers.performAction(tab, kAXPressAction as String)
            Thread.sleep(forTimeInterval: 0.3)
        }

        // 6. Get chat list table and rows
        guard let table = AXHelpers.chatListTable(mainWindow) else {
            throw AutomationError.chatNotFound("chat list table")
        }

        let allRows = AXHelpers.children(table).filter { AXHelpers.role($0) == "AXRow" }
        progress("Found \(allRows.count) chats in UI, \(dbChats.count) in database")

        // 7. Pair each UI row with its database chat *by identity*, never by
        //    position. A row is matched on its name when the database already
        //    knows one, otherwise on its last-message preview — the two lists
        //    are different lengths in different orders, so an index is not a
        //    join key. A row that matches nothing is skipped and reported: the
        //    cost of a miss is a chat that keeps its existing name, while the
        //    cost of a bad guess is a *wrong* name written onto a real chat id.
        let pairs = pairRows(allRows, with: dbChats, progress: progress)
        let limit = options.maxChats > 0 ? min(options.maxChats, pairs.count) : pairs.count

        var results: [HarvestResult] = []

        for i in 0..<limit {
            let (row, dbChat, uiName) = pairs[i]

            let chatId = dbChat[0] as! Int64
            let chatType = Int(dbChat[1] as! Int64)
            let memberCount = Int(dbChat[2] as! Int64)
            let unreadCount = dbChat[3] as! Int64
            let msgCount = Int(dbChat[5] as! Int64)

            // Skip unread chats (safety: opening could mark as read)
            if options.skipUnread && unreadCount > 0 {
                progress("[\(i+1)/\(limit)] Skipping \(uiName) (\(unreadCount) unread)")
                results.append(HarvestResult(
                    chatId: chatId, uiName: uiName,
                    messagesBefore: msgCount, messagesAfter: msgCount,
                    skipped: true, skipReason: "\(unreadCount) unread"
                ))
                metadata.update(chatId: chatId, name: uiName,
                               memberCount: memberCount, chatType: chatType,
                               messageCount: msgCount)
                continue
            }

            progress("[\(i+1)/\(limit)] \(uiName) (\(msgCount) msgs)...")

            metadata.update(chatId: chatId, name: uiName,
                           memberCount: memberCount, chatType: chatType)

            if options.namesOnly {
                metadata.update(chatId: chatId, name: uiName,
                               memberCount: memberCount, chatType: chatType,
                               messageCount: msgCount)
                results.append(HarvestResult(
                    chatId: chatId, uiName: uiName,
                    messagesBefore: msgCount, messagesAfter: msgCount,
                    skipped: false, skipReason: nil
                ))
                continue
            }

            // Open the chat by double-clicking
            AXHelpers.doubleClickElement(row)
            Thread.sleep(forTimeInterval: 1.2)

            // Find the chat window
            windows = AXHelpers.windows(app)
            guard let chatWindow = windows.first(where: { AXHelpers.identifier($0) != "Main Window" }) else {
                progress("  Warning: chat window didn't open, skipping")
                results.append(HarvestResult(
                    chatId: chatId, uiName: uiName,
                    messagesBefore: msgCount, messagesAfter: msgCount,
                    skipped: true, skipReason: "window didn't open"
                ))
                continue
            }

            // Load older messages: scroll to top, then click "View Previous Chats" repeatedly
            let windowTitle = AXHelpers.title(chatWindow) ?? uiName
            let messagesAfter = loadHistory(
                app: app,
                chatWindow: chatWindow,
                db: db, chatId: chatId,
                windowTitle: windowTitle,
                initialCount: msgCount,
                options: options,
                progress: progress
            )

            metadata.update(chatId: chatId, name: uiName,
                           memberCount: memberCount, chatType: chatType,
                           messageCount: messagesAfter)

            // Close the chat window
            _ = AXHelpers.closeWindow(chatWindow)
            Thread.sleep(forTimeInterval: 0.5)

            let loaded = messagesAfter - msgCount
            if loaded > 0 {
                progress("  +\(loaded) messages (total: \(messagesAfter))")
            } else {
                progress("  No new messages to load")
            }

            results.append(HarvestResult(
                chatId: chatId, uiName: uiName,
                messagesBefore: msgCount, messagesAfter: messagesAfter,
                skipped: false, skipReason: nil
            ))
        }

        return results
    }

    // MARK: - Private Helpers

    /// Extract the display name from a chat list row.
    private static func extractName(from row: AXUIElement) -> String {
        AXHelpers.chatRowName(row) ?? "(unknown)"
    }

    /// The last-message preview shown on a chat-list row, used as a join key.
    /// Lives in an AXTextArea inside the row's AXScrollArea.
    private static func extractPreview(from row: AXUIElement) -> String? {
        for cell in AXHelpers.children(row) where AXHelpers.role(cell) == "AXCell" {
            for child in AXHelpers.children(cell) where AXHelpers.role(child) == "AXScrollArea" {
                for area in AXHelpers.children(child) where AXHelpers.role(area) == "AXTextArea" {
                    if let text = AXHelpers.value(area), !text.isEmpty { return text }
                }
            }
        }
        return nil
    }

    private static func normalize(_ s: String) -> String {
        s.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    /// Match UI rows to database chats by identity rather than by index.
    ///
    /// Two passes, most reliable first:
    ///   1. **Name.** If the database already has a title for a chat and it
    ///      equals the row's label, that's the chat. (These rows teach us
    ///      nothing new, but claiming them keeps them out of pass 2.)
    ///   2. **Last-message preview.** For rows the database can't name — the
    ///      ones harvest exists for — the row's message preview is matched
    ///      against the chat's most recent message. The UI truncates, so this
    ///      is a prefix comparison, and a prefix that matches more than one
    ///      chat is rejected as ambiguous rather than guessed.
    ///
    /// Rows matching nothing are dropped with a progress note.
    private static func pairRows(
        _ rows: [AXUIElement],
        with dbChats: [[Any]],
        progress: (String) -> Void
    ) -> [(AXUIElement, [Any], String)] {
        var byName: [String: [Any]] = [:]
        for chat in dbChats {
            guard let name = chat[6] as? String, !name.isEmpty else { continue }
            // Ambiguous titles can't identify a chat; drop both.
            if byName[name] != nil { byName[name] = nil } else { byName[name] = chat }
        }

        var claimed = Set<Int64>()
        var paired: [(AXUIElement, [Any], String)] = []
        var deferred: [(AXUIElement, String)] = []

        for row in rows {
            guard let uiName = AXHelpers.chatRowName(row) else { continue }
            if let chat = byName[uiName], let id = chat[0] as? Int64, !claimed.contains(id) {
                claimed.insert(id)
                paired.append((row, chat, uiName))
            } else {
                deferred.append((row, uiName))
            }
        }

        for (row, uiName) in deferred {
            guard let preview = extractPreview(from: row).map(normalize), preview.count >= 4 else {
                progress("  ! \(uiName): no preview to match on — skipped")
                continue
            }
            let hits = dbChats.filter { chat in
                guard let id = chat[0] as? Int64, !claimed.contains(id),
                      let last = chat[7] as? String else { return false }
                return normalize(last).hasPrefix(preview)
            }
            guard hits.count == 1, let id = hits[0][0] as? Int64 else {
                let why = hits.isEmpty ? "no database chat matches its preview" : "\(hits.count) chats match its preview"
                progress("  ! \(uiName): \(why) — skipped")
                continue
            }
            claimed.insert(id)
            paired.append((row, hits[0], uiName))
        }

        progress("Paired \(paired.count) of \(rows.count) UI rows to database chats")
        return paired
    }

    /// Main history loading loop for a single chat.
    /// Scrolls to top, then uses OCR to find "View Previous Chats" and click it.
    private static func loadHistory(
        app: AXUIElement,
        chatWindow: AXUIElement,
        db: DatabaseReader,
        chatId: Int64,
        windowTitle: String,
        initialCount: Int,
        options: Options,
        progress: @escaping (String) -> Void
    ) -> Int {
        guard let winPos = AXHelpers.position(chatWindow),
              let winSize = AXHelpers.size(chatWindow) else {
            return initialCount
        }

        var currentCount = initialCount
        let scrollX = Int(winPos.x + winSize.width / 2)
        let scrollY = Int(winPos.y + winSize.height / 2)

        // Phase 1: Activate KakaoTalk and raise the chat window BEFORE scrolling.
        // This avoids scroll-position reset that can happen when peekaboo click --app
        // activates the app (focus change can cause the chat to jump to the bottom).
        activateAndRaise(chatWindow)

        // Phase 2: Scroll to top with KakaoTalk in the foreground.
        scrollToTop(scrollX: scrollX, scrollY: scrollY, progress: progress)

        // Phase 3: Repeatedly find + click "View Previous Chats" via OCR
        for attempt in 0..<options.maxPreviousClicks {
            // Take screenshot and OCR to find "View Previous Chats"
            let screenshotPath = "/tmp/kakaocli_harvest_\(chatId).png"
            guard let buttonCenter = findViewPreviousChatsViaOCR(
                windowTitle: windowTitle,
                windowPos: winPos,
                windowSize: winSize,
                screenshotPath: screenshotPath
            ) else {
                progress("  No 'View Previous Chats' found in screenshot")
                break
            }

            let clickX = Int(buttonCenter.x)
            let clickY = Int(buttonCenter.y)

            // Click using direct CGEvent (KakaoTalk is already frontmost from activate above)
            progress("  Clicking 'View Previous Chats' at (\(clickX),\(clickY)) (attempt \(attempt + 1))...")
            clickAtScreenPoint(CGPoint(x: Double(clickX), y: Double(clickY)))
            Thread.sleep(forTimeInterval: 2.5)

            // Check if paywall dialog appeared (new popup window)
            if dismissPaywallIfPresent(app: app, chatWindowTitle: windowTitle) {
                progress("  Hit Talk Drive Plus paywall, dismissed")
                break
            }

            // Wait for messages to load into DB
            Thread.sleep(forTimeInterval: options.scrollDelay)

            // Check message count
            let newCount = queryMessageCount(db: db, chatId: chatId)
            if newCount > currentCount {
                let delta = newCount - initialCount
                progress("  +\(delta) messages loaded so far")
                currentCount = newCount
                // Re-activate and scroll to top for next "View Previous Chats"
                activateAndRaise(chatWindow)
                scrollToTop(scrollX: scrollX, scrollY: scrollY, progress: progress)
            } else {
                // No new messages — might have hit the limit silently
                break
            }
        }

        return currentCount
    }

    /// Activate KakaoTalk and raise a specific window to the front.
    /// This ensures CGEvent clicks reach the correct window.
    private static func activateAndRaise(_ window: AXUIElement) {
        try? AXHelpers.activateApp(bundleId: KakaoAutomator.bundleId)
        _ = AXHelpers.performAction(window, kAXRaiseAction as String)
        Thread.sleep(forTimeInterval: 0.3)
    }

    /// Click at a screen point using CGEvent (goes to frontmost window at those coordinates).
    private static func clickAtScreenPoint(_ point: CGPoint) {
        if let mouseDown = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown,
                                    mouseCursorPosition: point, mouseButton: .left),
           let mouseUp = CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp,
                                  mouseCursorPosition: point, mouseButton: .left) {
            mouseDown.post(tap: .cghidEventTap)
            usleep(50_000)
            mouseUp.post(tap: .cghidEventTap)
        }
    }

    /// Scroll to the top of the chat's message area.
    /// Positions cursor over the chat window and scrolls without focus change,
    /// relying on macOS sending scroll events to the window under the cursor.
    private static func scrollToTop(scrollX: Int, scrollY: Int, progress: @escaping (String) -> Void) {
        progress("  Scrolling to top...")
        shellExec("cliclick", "m:\(scrollX),\(scrollY)")
        Thread.sleep(forTimeInterval: 0.2)
        for _ in 0..<15 {
            shellExec("peekaboo", "scroll", "--direction", "up",
                      "--amount", "100", "--no-auto-focus")
            Thread.sleep(forTimeInterval: 0.15)
        }
        Thread.sleep(forTimeInterval: 0.5)
    }

    // MARK: - Vision OCR

    /// Get the CGWindow ID for a KakaoTalk window by title.
    private static func getWindowId(title: String) -> Int? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["peekaboo", "window", "list", "--app", "KakaoTalk", "-j"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
        } catch { return nil }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let dataObj = json["data"] as? [String: Any],
              let windows = dataObj["windows"] as? [[String: Any]] else {
            return nil
        }
        for w in windows {
            if let wTitle = w["window_title"] as? String, wTitle == title,
               let wId = w["window_id"] as? Int {
                return wId
            }
        }
        // Fallback: partial match
        for w in windows {
            if let wTitle = w["window_title"] as? String, wTitle.contains(title),
               let wId = w["window_id"] as? Int {
                return wId
            }
        }
        return nil
    }

    /// Take a screenshot of the chat window and use Vision OCR to find "View Previous Chats".
    /// Returns the screen coordinates of the text center, or nil if not found.
    private static func findViewPreviousChatsViaOCR(
        windowTitle: String,
        windowPos: CGPoint,
        windowSize: CGSize,
        screenshotPath: String
    ) -> CGPoint? {
        // Get window ID for reliable capture (--app alone can capture hidden sub-windows)
        guard let windowId = getWindowId(title: windowTitle) else {
            return nil
        }

        // Take screenshot using window ID
        let exitCode = shellExec(
            "peekaboo", "image",
            "--window-id", "\(windowId)",
            "--path", screenshotPath
        )
        guard exitCode == 0, FileManager.default.fileExists(atPath: screenshotPath) else {
            return nil
        }

        guard let image = NSImage(contentsOfFile: screenshotPath),
              let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return nil
        }

        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["en", "ko"]

        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        do {
            try handler.perform([request])
        } catch {
            return nil
        }

        guard let observations = request.results else { return nil }

        for observation in observations {
            guard let topCandidate = observation.topCandidates(1).first else { continue }
            let text = topCandidate.string.lowercased()
            if text.contains("view previous") || text.contains("이전 대화") {
                // Bounding box is normalized (0-1), origin at bottom-left
                let box = observation.boundingBox
                let centerX = box.origin.x + box.width / 2
                let centerY = 1.0 - (box.origin.y + box.height / 2)  // Flip Y (Vision uses bottom-left origin)

                // Convert to screen coordinates relative to window
                let screenX = windowPos.x + CGFloat(centerX) * windowSize.width
                let screenY = windowPos.y + CGFloat(centerY) * windowSize.height

                return CGPoint(x: screenX, y: screenY)
            }
        }

        return nil
    }

    // MARK: - Paywall Detection

    /// Check if any popup appeared after clicking "View Previous Chats".
    /// Uses CGWindow API (peekaboo window list) since the paywall popup may not
    /// appear in the AX window list (it's a sheet/panel, not a standard window).
    private static func dismissPaywallIfPresent(app: AXUIElement, chatWindowTitle: String) -> Bool {
        // Use peekaboo window list to get CGWindow-level windows
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["peekaboo", "window", "list", "--app", "KakaoTalk", "-j"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run(); process.waitUntilExit() } catch { return false }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let dataObj = json["data"] as? [String: Any],
              let windows = dataObj["windows"] as? [[String: Any]] else {
            return false
        }

        // Expected: Main Window + chat window = 2. Any extra = popup.
        var popupFound = false
        for w in windows {
            let title = w["window_title"] as? String ?? ""
            if title == "KakaoTalk" { continue }       // Main window
            if title == chatWindowTitle { continue }    // Chat window
            popupFound = true
            break
        }

        guard popupFound else { return false }

        // Dismiss popup: Escape key
        shellExec("peekaboo", "type", "--escape", "--app", "KakaoTalk")
        Thread.sleep(forTimeInterval: 0.5)

        return true
    }

    /// Query the current message count for a chat.
    private static func queryMessageCount(db: DatabaseReader, chatId: Int64) -> Int {
        if let result = try? db.rawQuery(
            "SELECT COUNT(*) FROM NTChatMessage WHERE chatId = \(chatId)"
        ), let first = result.first, let count = first[0] as? Int64 {
            return Int(count)
        }
        return 0
    }

    /// Run a shell command, returning its exit code.
    @discardableResult
    private static func shellExec(_ args: String...) -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = Array(args)
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus
        } catch {
            return -1
        }
    }
}
