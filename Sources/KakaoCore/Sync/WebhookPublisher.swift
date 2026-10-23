import Foundation

/// Posts new messages to a webhook URL as JSON.
public final class WebhookPublisher: @unchecked Sendable {
    private let url: URL
    private let session: URLSession

    public init(url: URL) {
        self.url = url
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 10
        self.session = URLSession(configuration: config)
    }

    /// POST a batch of messages to the webhook. Returns true on 2xx response.
    public func publish(_ messages: [SyncMessage]) -> Bool {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let body = try? encoder.encode(messages) else { return false }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("kakaocli/\(kakaocliVersion)", forHTTPHeaderField: "User-Agent")
        request.httpBody = body

        nonisolated(unsafe) var success = false
        let semaphore = DispatchSemaphore(value: 0)
        let task = session.dataTask(with: request) { _, response, error in
            if error == nil, let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) {
                success = true
            }
            semaphore.signal()
        }
        task.resume()
        semaphore.wait()
        return success
    }
}
