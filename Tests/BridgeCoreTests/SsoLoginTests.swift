import Foundation
import BridgeCore

func runSsoLoginTests() {
    section("sso login: prompt parsing and arguments") {
        let text = "Attempting to open...\n\nhttps://device.sso.eu-west-1.amazonaws.com/\n\nThen enter the code:\n\nABCD-EFGH\n"
        expect(SsoLoginPrompt.parse(text) == SsoLoginPrompt(url: "https://device.sso.eu-west-1.amazonaws.com/", userCode: "ABCD-EFGH"), "url and code found")
        expect(SsoLoginPrompt.parse("nothing useful here") == SsoLoginPrompt(url: nil, userCode: nil), "nothing found")
        expect(SsoLoginPrompt.parse("https://a.example/start?user_code=WXYZ-1234 more").userCode == "WXYZ-1234", "code inside a url is still found")
        expect(SsoLogin.arguments(profile: "example-dev", noBrowser: false) == ["sso", "login", "--profile", "example-dev"], "plain arguments")
        expect(SsoLogin.arguments(profile: "my profile", noBrowser: true) == ["sso", "login", "--profile", "my profile", "--no-browser"], "no-browser variant, profile as one argument")
    }

    let login = SsoLogin(awsPath: fakeAws, environment: testEnvironment)

    section("sso login: success streams the device code while running") {
        let prompts = PromptBox(), texts = PromptBox()
        let r = blocking { try await login.login(profile: "example-dev", onText: { texts.addText($0) }, onPrompt: { prompts.addPrompt($0) }) }
        expect({ if case .success = r { return true }; return false }(), "login succeeded, got \(r)")
        expect(prompts.last == SsoLoginPrompt(url: "https://device.sso.eu-west-1.amazonaws.com/", userCode: "ABCD-EFGH"), "final prompt has url and code")
        expect(texts.allText.contains("Successfully logged into"), "raw output is also delivered")
    }

    section("sso login: failures, hostile names, timeout, cancel") {
        if case .failure(let e) = blocking({ try await login.login(profile: "will-fail") }), let le = e as? SsoLoginError, case .failed(let st, let s) = le {
            expect(st == 255 && s.contains("denied"), "status and stderr kept")
        } else { expect(false, "failure surfaced as SsoLoginError.failed") }
        for bad in ["-x", "", "tab\tname", String(repeating: "a", count: 200)] {
            if case .failure(let e) = blocking({ try await login.login(profile: bad) }), let le = e as? SsoLoginError { expect(le == .invalidProfile, "invalid profile \(bad.debugDescription.prefix(20)) rejected") }
            else { expect(false, "profile \(bad.debugDescription.prefix(20)) must be rejected") }
        }
        killLeaks()
        let t0 = ProcessInfo.processInfo.systemUptime
        if case .failure(let e) = blocking({ try await login.login(profile: "slow", timeout: 0.8) }), let le = e as? SsoLoginError, case .timedOut = le {
            expect(ProcessInfo.processInfo.systemUptime - t0 < 5, "timed out promptly")
        } else { expect(false, "timeout surfaced") }
        expect(!leakedSleepProcesses(), "no child left after the timeout")
        killLeaks()

        let sem = DispatchSemaphore(value: 0)
        var result: Result<Void, Error>?
        let task = Task.detached { () -> Void in
            do { try await login.login(profile: "slow", timeout: 60); result = .success(()) } catch { result = .failure(error) }
            sem.signal()
        }
        Thread.sleep(forTimeInterval: 0.6)
        let c0 = ProcessInfo.processInfo.systemUptime
        task.cancel(); sem.wait()
        if case .failure(let e)? = result, e is CancellationError { expect(ProcessInfo.processInfo.systemUptime - c0 < 3, "cancel returned promptly") } else { expect(false, "cancel surfaces CancellationError") }
        expect(!leakedSleepProcesses(), "no child left after the cancel")
        killLeaks()
        let missing = SsoLogin(awsPath: "/nonexistent/aws", environment: [:])
        if case .failure(let e) = blocking({ try await missing.login(profile: "example-dev") }), let le = e as? SsoLoginError, case .spawnFailed(let n) = le { expect(n == ENOENT, "missing binary reported") } else { expect(false, "missing binary is spawnFailed") }
    }
}

final class PromptBox: @unchecked Sendable {
    private let lock = NSLock()
    private var prompts: [SsoLoginPrompt] = []
    private var text = ""
    func addPrompt(_ p: SsoLoginPrompt) { lock.lock(); prompts.append(p); lock.unlock() }
    func addText(_ t: String) { lock.lock(); text += t; lock.unlock() }
    var last: SsoLoginPrompt? { lock.lock(); defer { lock.unlock() }; return prompts.last }
    var allText: String { lock.lock(); defer { lock.unlock() }; return text }
}
