import StateMachine

/// A generated transfer list whose downloads are keyed by file and whose edges log what they do.
///
/// Each file's download is its own work, so starting a file again replaces only that file's
/// download and cancelling a file revokes only its work. Going offline leaves `Browsing`, which
/// revokes every download. The `Logged` event carries a line for the app's log in each batch that
/// needs one.
@StateMachine(mode: .shared)
nonisolated public enum GeneratedTransfers: Sendable, Equatable {
    /// The files and the transfers in progress.
    public struct Browsing: Sendable, Equatable {
        /// The downloaded contents by file identifier.
        public let files: [Int: String]
        /// The files whose last download failed, in failure order.
        public let failures: [Int]
        /// Creates ordinary browsing data.
        public init(files: [Int: String] = [:], failures: [Int] = []) {
            self.files = files
            self.failures = failures
        }
    }
    /// No transfer can run while offline, though downloaded files stay available.
    public struct Offline: Sendable, Equatable {
        /// The downloaded contents by file identifier.
        public let files: [Int: String]
        /// Creates ordinary offline data.
        public init(files: [Int: String] = [:]) { self.files = files }
    }
    @Initial case browsing(Browsing = Browsing())
    case offline(Offline)
    /// Closed dynamic inputs.
    public enum Input: Sendable, Equatable {
        /// Downloads one file.
        case download(Int)
        /// Cancels one file's download.
        case cancel(Int)
        /// Leaves the network.
        case goOffline
        /// Returns to the network.
        case goOnline
    }
    /// Why a download failed.
    public enum TransferFailure: Error, Sendable, Equatable {
        /// The file could not be reached.
        case unavailable
    }
    /// One file's download, replaced only by another download of the same file.
    @Operation(activeIn: [Browsing.self], admission: .latest)
    public enum Download {
        /// The file identifier.
        public typealias Key = Int
        /// The address to download.
        public typealias Input = String
        /// The downloaded contents.
        public typealias Output = String
        /// Why the download failed.
        public typealias Failure = TransferFailure
    }
    /// A line for the app's log.
    @Event public enum Logged {
        /// The line.
        public typealias Payload = String
    }
    /// Logs the request and downloads the file.
    @Transition(on: Input.download, starts: [Download.self], emits: [Logged.self])
    fileprivate static func download(_ source: Browsing, _ id: Int) -> Change<Browsing, Effect.Download> {
        Change(source, effects: [.logged("download \(id)"), .download(key: id, input: "file-\(id)")])
    }
    /// Cancels one file's download, doing nothing for a file without an active download.
    @Transition(on: Input.cancel, cancels: [Download.self])
    fileprivate static func cancel(_ source: Browsing, _ id: Int) -> Change<Browsing, Effect.Cancel> {
        Change(source, effects: [.cancelDownload(key: id)])
    }
    /// Leaves the network, which revokes every download.
    @Transition(on: Input.goOffline, emits: [Logged.self])
    fileprivate static func goOffline(_ source: Browsing) -> Change<Offline, Effect.GoOffline> {
        Change(Offline(files: source.files), effects: [.logged("offline")])
    }
    /// Returns to the network with the downloaded files.
    @Transition(on: Input.goOnline)
    fileprivate static func goOnline(_ source: Offline) -> Browsing { Browsing(files: source.files) }
    /// Files the contents under the key its download was started for, and logs it.
    @Transition(onSuccess: Download.self, emits: [Logged.self])
    fileprivate static func downloaded(
        _ source: Browsing,
        _ contents: Download.Output,
        request: DownloadRequest
    ) -> Change<Browsing, Effect.Downloaded> {
        var files = source.files
        files[request.key] = contents
        return Change(
            Browsing(files: files, failures: source.failures),
            effects: [.logged("downloaded \(request.key)")]
        )
    }
    /// Records a failed download of the key it was started for.
    @Transition(onFailure: Download.self)
    fileprivate static func failed(
        _ source: Browsing,
        _ failure: Download.Failure,
        request: DownloadRequest
    ) -> Browsing {
        Browsing(files: source.files, failures: source.failures + [request.key])
    }
}
