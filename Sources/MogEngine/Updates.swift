import Foundation
import MogCore

/// "Check for Updates": reads the Homebrew formula from the tap (one ~2 KB file) and compares its
/// version with this build. Nothing else is sent or received; runs only when asked.
public enum UpdateChecker {
    /// The formula `brew upgrade` installs from. Served by GitHub's raw CDN (cached up to 5 min).
    public static let formulaURL = URL(string: "https://raw.githubusercontent.com/c4rb0nx1/homebrew-tap/main/Formula/mog.rb")!
    public static let formulaName = "c4rb0nx1/tap/mog"

    public enum Outcome: Equatable {
        case upToDate(current: String)
        case available(latest: String, current: String)
    }

    public enum CheckError: Error, CustomStringConvertible {
        case network(String)
        case unreadable
        public var description: String {
            switch self {
            case .network(let s): "couldn't reach GitHub (\(s))"
            case .unreadable: "the Homebrew formula didn't say which version it installs"
            }
        }
    }

    /// Fetches the formula. `done` runs on the main queue.
    public static func check(current: String = MogInfo.version,
                             done: @escaping (Result<Outcome, CheckError>) -> Void) {
        let config = URLSessionConfiguration.ephemeral  // no cookies, no disk cache
        config.timeoutIntervalForRequest = 10
        config.timeoutIntervalForResource = 15
        let session = URLSession(configuration: config)
        var request = URLRequest(url: formulaURL, cachePolicy: .reloadIgnoringLocalCacheData)
        request.setValue("Mog/\(current)", forHTTPHeaderField: "User-Agent")
        session.dataTask(with: request) { data, response, error in
            let result: Result<Outcome, CheckError>
            if let error {
                result = .failure(.network(error.localizedDescription))
            } else if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                result = .failure(.network("HTTP \(http.statusCode)"))
            } else if let data, data.count < 64 << 10, let text = String(data: data, encoding: .utf8),
                      let latest = UpdateInfo.version(inFormula: text) {
                result = .success(UpdateInfo.isNewer(latest, than: current)
                    ? .available(latest: latest, current: current) : .upToDate(current: current))
            } else {
                result = .failure(.unreadable)
            }
            session.finishTasksAndInvalidate()
            DispatchQueue.main.async { done(result) }
        }.resume()
    }

    /// Blocking version for the CLI. Don't call on the main thread of an app.
    public static func checkNow(current: String = MogInfo.version) -> Result<Outcome, CheckError> {
        var out: Result<Outcome, CheckError> = .failure(.network("timed out"))
        let sem = DispatchSemaphore(value: 0)
        // `check` answers on the main queue; the CLI has no run loop yet, so spin it while waiting.
        check(current: current) { out = $0; sem.signal() }
        let deadline = Date().addingTimeInterval(20)
        while sem.wait(timeout: .now()) == .timedOut && Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        return out
    }

    /// Writes a Terminal script that upgrades Mog with Homebrew, reinstalls Mog.app into `appDirectory`
    /// and reopens it. Opening a `.command` file runs it in Terminal, visibly, with no extra permission.
    public static func makeUpdateScript(appDirectory: URL) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mog-update-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let url = dir.appendingPathComponent("Update Mog.command")
        let script = """
        #!/bin/zsh
        # Written by Mog.app for "Update Mog". Deletes itself when done.
        set -u
        APP_DIR=\(shellQuote(appDirectory.path))
        FORMULA=\(shellQuote(formulaName))
        cleanup() { rm -rf \(shellQuote(dir.path)); }
        trap cleanup EXIT

        BREW=""
        for b in /opt/homebrew/bin/brew /usr/local/bin/brew; do [ -x "$b" ] && BREW="$b" && break; done
        if [ -z "$BREW" ]; then
          echo "Homebrew isn't installed, so Mog can't update itself."
          echo "Get the latest version from https://github.com/c4rb0nx1/mog"
          open "$APP_DIR/Mog.app"
          exit 1
        fi

        echo "==> Updating Mog with Homebrew (this builds from source, about a minute)"
        "$BREW" update --quiet || true
        # Make sure the tap really has the latest formula, even if `brew update` only fetched it.
        TAP="$("$BREW" --repository c4rb0nx1/tap 2>/dev/null)"
        [ -d "$TAP/.git" ] && git -C "$TAP" pull --ff-only --quiet 2>/dev/null || true

        if "$BREW" list --versions mog >/dev/null 2>&1; then
          "$BREW" upgrade "$FORMULA"; rc=$?
        else
          echo "==> Mog isn't installed with Homebrew yet; installing it"
          "$BREW" install "$FORMULA"; rc=$?
        fi

        if [ $rc -eq 0 ]; then
          echo "==> Reinstalling Mog.app"
          "$("$BREW" --prefix)/bin/mog" install-app --dir "$APP_DIR"; rc=$?
        fi

        echo
        if [ $rc -eq 0 ]; then
          echo "Mog is up to date: $("$("$BREW" --prefix)/bin/mog" version)"
        else
          echo "Update failed (exit $rc). Your previous Mog.app is unchanged; reopening it."
        fi
        open "$APP_DIR/Mog.app"
        echo "You can close this window."
        exit $rc
        """
        try Data(script.utf8).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        return url
    }

    /// Single-quotes `s` for zsh/sh.
    static func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
