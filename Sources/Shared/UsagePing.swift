import Foundation

/// One anonymous ping a day to the app's own endpoint, so the author can count how many copies are in use
/// and which versions they run. GitHub counts downloads, but not who keeps using the app.
///
/// What's sent is a random install id made on first launch (not derived from the Mac, the user or
/// anything on disk), the app's version, the macOS version and the CPU architecture. Nothing about the
/// user's repositories, folders or tools. The endpoint is the `UsagePingURL` key in the app's Info.plist;
/// without it (or when run unbundled with `swift run`) nothing is sent. A failed ping is silent and
/// tried again an hour later.
@MainActor
public final class UsagePing: ObservableObject {
    public static let shared = UsagePing()

    static let enabledKey = "sendsUsagePing"
    private static let idKey = "usagePingInstallID"
    private static let lastDayKey = "usagePingLastDay"

    /// Off in Settings stops the pings; the install id stays, so turning it on again isn't a new install.
    @Published public var isEnabled = UserDefaults.standard.object(forKey: UsagePing.enabledKey) as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(isEnabled, forKey: Self.enabledKey)
            if isEnabled { sendIfDue() }
        }
    }

    private var timer: Timer?
    private var isSending = false

    /// Pings now if today's hasn't gone out, and checks again every hour, as a menu bar app can run for
    /// weeks without being relaunched.
    public func start() {
        sendIfDue()
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 60 * 60, repeats: true) { _ in
            MainActor.assumeIsolated { UsagePing.shared.sendIfDue() }
        }
    }

    public func sendIfDue() {
        guard isEnabled, !isSending, let endpoint = Self.endpoint, Bundle.main.bundleIdentifier != nil else { return }
        let today = Self.today()
        guard UserDefaults.standard.string(forKey: Self.lastDayKey) != today else { return }
        isSending = true
        let body = Self.payload()
        Task {
            let sent = await Self.post(body, to: endpoint)
            if sent { UserDefaults.standard.set(today, forKey: Self.lastDayKey) }
            isSending = false
        }
    }

    nonisolated public static var endpoint: URL? {
        guard let string = Bundle.main.object(forInfoDictionaryKey: "UsagePingURL") as? String,
              !string.isEmpty else { return nil }
        return URL(string: string)
    }

    /// The day in UTC, the same calendar the endpoint counts in.
    private static func today() -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: Date())
    }

    private static func installID() -> String {
        if let id = UserDefaults.standard.string(forKey: idKey) { return id }
        let id = UUID().uuidString.lowercased()
        UserDefaults.standard.set(id, forKey: idKey)
        return id
    }

    private static func payload() -> [String: String] {
        let os = ProcessInfo.processInfo.operatingSystemVersion
        #if arch(arm64)
        let arch = "arm64"
        #else
        let arch = "x86_64"
        #endif
        return [
            "id": installID(),
            "version": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0",
            "os": "\(os.majorVersion).\(os.minorVersion)",
            "arch": arch,
        ]
    }

    nonisolated private static func post(_ body: [String: String], to endpoint: URL) async -> Bool {
        var request = URLRequest(url: endpoint, timeoutInterval: 15)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        // No cookies or cache, so the request carries nothing but the body.
        let session = URLSession(configuration: .ephemeral)
        defer { session.finishTasksAndInvalidate() }
        guard let (_, response) = try? await session.data(for: request) else { return false }
        return (200..<300).contains((response as? HTTPURLResponse)?.statusCode ?? 0)
    }
}
