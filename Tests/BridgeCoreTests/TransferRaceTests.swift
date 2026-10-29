import Foundation
import BridgeCore

func runTransferRaceTests() {
    section("download: destination race and concurrent staging") {
        let folder = freshDir()
        defer { try? FileManager.default.removeItem(at: folder) }
        let helper = folder.appendingPathComponent("fake-downloader")
        let script = """
        #!/bin/sh
        for output do :; done
        case "$*" in
          *race.bin*) printf 'created meanwhile' > "$HOME/race.bin" ;;
          *)
            if mkdir "$HOME/first" 2>/dev/null; then
              n=0
              while [ ! -f "$HOME/second" ] && [ "$n" -lt 200 ]; do sleep 0.01; n=$((n+1)); done
            else
              touch "$HOME/second"
            fi ;;
        esac
        printf 'downloaded payload' > "$output"
        printf '{}'
        """
        try! script.write(to: helper, atomically: true, encoding: .utf8)
        try! FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: helper.path)
        let downloader = S3Downloader(awsPath: helper.path, environment: ["HOME": folder.path, "BRIDGE_SETTINGS": folder.appendingPathComponent("settings.json").path])
        let race = blocking { try await downloader.download(downloadRequest(key: "race.bin"), to: folder) }
        if case .failure(let error) = race, case TransferError.destinationExists = error {
            expect(true, "destination created during transfer is not replaced")
        } else { expect(false, "destination race must return destinationExists") }
        expect((try? String(contentsOf: folder.appendingPathComponent("race.bin"), encoding: .utf8)) == "created meanwhile", "concurrent destination content preserved")
        let outcomes = blocking {
            await withTaskGroup(of: String.self) { group in
                for _ in 0..<2 {
                    group.addTask {
                        do { _ = try await downloader.download(downloadRequest(key: "concurrent.bin"), to: folder); return "saved" }
                        catch TransferError.destinationExists { return "exists" }
                        catch { return "unexpected" }
                    }
                }
                var results: [String] = []
                for await result in group { results.append(result) }
                return results.sorted()
            }
        }.successValue
        expect(outcomes == ["exists", "saved"], "concurrent downloads cannot delete each other's staging output")
        expect(!listing(folder).contains { $0.hasPrefix(S3Downloader.stagingPrefix) }, "all private staging directories cleaned")
    }
}
