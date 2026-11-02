import Foundation

/// `--theme-hot-reload-selftest`: exercise flat themes and package contents in a temporary directory.
@MainActor
enum ThemeHotReloadSelfTest {
    private static let schema = "winstripe-theme/1"

    static func run() -> Int {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("Winstripe-ThemeHotReload-\(UUID().uuidString)", isDirectory: true)
        var failures = 0
        func check(_ ok: Bool, _ name: String) {
            print("\(ok ? "PASS" : "FAIL") \(name)")
            if !ok { failures += 1 }
        }

        defer { try? fm.removeItem(at: root) }
        guard (try? fm.createDirectory(at: root, withIntermediateDirectories: true)) != nil else {
            print("FAIL theme-hot-reload-selftest: unable to create temporary directory")
            print("theme-hot-reload-selftest failures=1")
            return 1
        }

        let flat = root.appendingPathComponent("flat.json")
        let flatCore = makeCore(directory: root)
        let flatReloads = Counter()
        flatCore.onReload = { result in
            if result.succeeded { flatReloads.value += 1 }
        }
        do {
            try writeTheme(to: flat, id: "flat")
            flatCore.watch(directory: root, themeID: "flat")
            try writeTheme(to: flat, id: "flat", marker: "updated")
            check(waitFor { flatReloads.value > 0 }, "flat JSON overwrite fires and loads")
        } catch {
            check(false, "flat JSON setup: \(error)")
        }
        flatCore.stop()

        let package = root.appendingPathComponent("package.rdtheme", isDirectory: true)
        let packageJSON = package.appendingPathComponent("theme.json")
        let assets = package.appendingPathComponent("assets", isDirectory: true)
        let asset = assets.appendingPathComponent("marker.txt")
        let packageCore = makeCore(directory: root)
        let packageReloads = Counter()
        packageCore.onReload = { result in
            if result.succeeded { packageReloads.value += 1 }
        }
        do {
            try fm.createDirectory(at: assets, withIntermediateDirectories: true)
            try writeTheme(to: packageJSON, id: "package")
            try Data("before".utf8).write(to: asset)
            packageCore.watch(directory: root, themeID: "package")
            try writeTheme(to: packageJSON, id: "package", marker: "nested-edit")
            check(waitFor { packageReloads.value > 0 }, "rdtheme theme.json edit fires and loads")
            let beforeAsset = packageReloads.value
            try Data("after".utf8).write(to: asset, options: .atomic)
            check(waitFor { packageReloads.value > beforeAsset }, "rdtheme asset edit fires reload")
        } catch {
            check(false, "rdtheme setup: \(error)")
        }
        packageCore.stop()

        let lateCore = makeCore(directory: root)
        let lateReloads = Counter()
        lateCore.onReload = { result in
            if result.succeeded { lateReloads.value += 1 }
        }
        lateCore.watch(directory: root, themeID: "late")
        let latePackage = root.appendingPathComponent("late.rdtheme", isDirectory: true)
        let lateJSON = latePackage.appendingPathComponent("theme.json")
        do {
            try fm.createDirectory(at: latePackage, withIntermediateDirectories: true)
            try writeTheme(to: lateJSON, id: "late")
            RunLoop.main.run(until: Date().addingTimeInterval(0.5))
            let beforeNestedEdit = lateReloads.value
            try writeTheme(to: lateJSON, id: "late", marker: "after-add")
            check(waitFor { lateReloads.value > beforeNestedEdit }, "new rdtheme nested edit fires")
        } catch {
            check(false, "late rdtheme setup: \(error)")
        }
        let beforeStop = lateReloads.value
        lateCore.stop()
        do {
            try writeTheme(to: lateJSON, id: "late", marker: "after-stop")
            check(waitFor(timeout: 0.7) { lateReloads.value > beforeStop } == false, "stop cancels reload sources")
        } catch {
            check(false, "stop setup: \(error)")
        }

        print("theme-hot-reload-selftest failures=\(failures)")
        return failures == 0 ? 0 : 1
    }

    private static func makeCore(directory: URL) -> ThemeHotReloadCore {
        ThemeHotReloadCore(loadTheme: { id in
            try? ThemeLoader().loadForID(id, userDirectory: directory)
        })
    }

    private static func writeTheme(to url: URL, id: String, marker: String = "initial") throws {
        let object: [String: Any] = [
            "$schema": schema,
            "id": id,
            "family": "classic",
            "extends": "win95",
            "name": ["en": marker]
        ]
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        try data.write(to: url, options: .atomic)
    }

    private static func waitFor(timeout: TimeInterval = 1.8, _ predicate: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !predicate() && Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
        return predicate()
    }

    private final class Counter: @unchecked Sendable {
        var value = 0
    }
}
