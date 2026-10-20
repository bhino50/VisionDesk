import AppKit
import Foundation
import Network
import DeskCore
import DeskTransport

@MainActor
func runDockAppLauncherChecks(_ runner: CheckRunner) async {
    let finder = URL(fileURLWithPath: "/System/Library/CoreServices/Finder.app")
    await runner.check("Dock catalog preserves order, uses bounded real icons, and allowlists opaque launches") {
        var sources = [finder, finder, URL(fileURLWithPath: "/bin/sh"), URL(string: "https://example.com/Test.app")!]
        var opened: [URL] = []
        let launcher = DockAppLauncher(discover: { sources }, open: { url, complete in opened.append(url); complete(123) })
        let apps = launcher.catalog()
        runner.expectEqual(apps.count, 1, "duplicate and non-application sources are excluded")
        guard let app = apps.first else { return }
        runner.expect(app.isValid && !app.id.contains("/"), "only valid opaque IDs leave the Mac")
        runner.expectEqual(app.name, "Finder", "localized bundle names omit the .app suffix")
        runner.expect(app.iconPNG != nil, "the installed app provides a real bounded PNG")
        if let data = app.iconPNG, let bitmap = NSBitmapImageRep(data: data) {
            runner.expectEqual(bitmap.pixelsWide, 64, "icons have a bounded pixel width")
            runner.expectEqual(bitmap.pixelsHigh, 64, "icons have a bounded pixel height")
        }
        runner.expectEqual(launcher.catalog().first?.id, app.id, "refresh preserves identifiers")
        launcher.launch(id: finder.path) { runner.expect(!$0, "a remote file path is never an app ID") }
        runner.expect(opened.isEmpty, "unknown ID does not invoke NSWorkspace")
        launcher.launch(id: app.id) { runner.expect($0, "advertised app reaches the injected opener") }
        runner.expectEqual(opened, [finder], "the opener receives only the validated local URL")
        sources = []
        _ = launcher.catalog()
        launcher.launch(id: app.id) { runner.expect(!$0, "removed app IDs are revoked on refresh") }
        runner.expectEqual(opened.count, 1, "old catalog cannot launch after refresh")
    }
    await runner.check("Dock launch requires negotiated capability, fresh control, and one bounded request") {
        var opens = 0
        var completion: (@MainActor (pid_t?) -> Void)?
        let launcher = DockAppLauncher(discover: { [finder] }, open: { _, finish in opens += 1; completion = finish })
        guard let id = launcher.catalog().first?.id else { runner.expect(false, "Finder fixture exists"); return }
        let model = CompanionModel(saveLANConfiguration: { _ in }, inventory: { [syntheticDisplay(1)] },
            liveSession: { HostSessionObservation(onConsole: true, screenLocked: false, displaysAsleep: false) },
            screenCaptureAccess: { true }, controlAccess: controlAccess(true), dockAppLauncher: launcher)
        let connection = DeskConnection(endpoint: .hostPort(host: "127.0.0.1", port: 1), key: PairingKey.generate())
        model.attach(connection)
        let launch = DeskMessage(kind: "launchApp", appID: id, appRequestID: UUID().uuidString)
        model.controlEnabled = true
        model.receive(DeskMessage(kind: "heartbeat"))
        model.receive(launch)
        runner.expectEqual(opens, 0, "old peers cannot launch")
        model.receive(DeskMessage(kind: "capabilities", videoCodec: "h264", dockLauncher: true))
        model.controlEnabled = false
        model.receive(launch)
        runner.expectEqual(opens, 0, "viewing alone cannot launch")
        model.controlEnabled = true
        model.receive(DeskMessage(kind: "launchApp", displayID: UInt32.max, appID: id, appRequestID: UUID().uuidString))
        runner.expectEqual(opens, 0, "a missing or unshared destination is refused before opening")
        model.receive(launch)
        runner.expectEqual(opens, 1, "fresh approved control launches an advertised app")
        model.receive(DeskMessage(kind: "launchApp", appID: id, appRequestID: UUID().uuidString))
        runner.expectEqual(opens, 1, "concurrent requests are refused")
        model.stop()
        completion?(123)
        runner.expect(!model.connected && !model.controlEnabled, "late completion cannot revive a stopped session")
    }
    await runner.check("Dock launch refuses missing heartbeat or revoked Accessibility") {
        for allowed in [true, false] {
            var opens = 0
            let launcher = DockAppLauncher(discover: { [finder] }, open: { _, finish in opens += 1; finish(123) })
            guard let id = launcher.catalog().first?.id else { continue }
            let model = CompanionModel(saveLANConfiguration: { _ in }, inventory: { [syntheticDisplay(1)] },
                liveSession: { HostSessionObservation(onConsole: true, screenLocked: false, displaysAsleep: false) },
                screenCaptureAccess: { true }, controlAccess: controlAccess(allowed), dockAppLauncher: launcher)
            let connection = DeskConnection(endpoint: .hostPort(host: "127.0.0.1", port: 1), key: PairingKey.generate())
            model.attach(connection)
            model.receive(DeskMessage(kind: "capabilities", videoCodec: "h264", dockLauncher: true))
            model.controlEnabled = true
            if !allowed { model.receive(DeskMessage(kind: "heartbeat")) }
            model.receive(DeskMessage(kind: "launchApp", appID: id, appRequestID: UUID().uuidString))
            runner.expectEqual(opens, 0, allowed ? "no launch without recent heartbeat" : "no launch after Accessibility refusal")
            model.stop()
        }
    }

    await runner.check("Window destination geometry fits negative-origin and portrait displays in logical points") {
        let visible = CGRect(x: -1080, y: -1800, width: 1080, height: 1800)
        let frame = DockWindowPlacement.frame(size: CGSize(width: 1600, height: 900), visible: visible)
        runner.expectEqual(frame?.width, 1080, "an oversized window fits a portrait display")
        runner.expectEqual(frame?.height, 900, "a fitting dimension preserves its original size")
        runner.expect(frame.map(visible.contains) == true, "the result stays inside the target with a negative origin")
        runner.expect(DockWindowPlacement.frame(size: CGSize(width: CGFloat.infinity, height: 100), visible: visible) == nil, "invalid AX sizes cannot produce a placement")
        runner.expect(DockWindowPlacement.frame(size: CGSize(width: 100, height: 100), visible: .zero) == nil, "missing display geometry cannot produce a placement")
    }
    await runner.check("Targeted app launches route only the returned PID and revoke routing before delayed completion") {
        var openerCompletion: (@MainActor (pid_t?) -> Void)?
        var routes = 0
        let authorization = RoutingAuthorizationState()
        let target = syntheticDisplay(123)
        let launcher = DockAppLauncher(discover: { [finder] }, open: { _, done in openerCompletion = done },
            route: { pid, url, display, canRoute, done in
                routes += 1
                runner.expectEqual(pid, 456, "routing receives exactly the launched process")
                runner.expectEqual(url, finder, "routing receives the validated advertised URL")
                runner.expectEqual(display, target, "routing receives the selected display")
                runner.expect(canRoute(), "authorization is live at routing dispatch")
                done(true)
            })
        guard let id = launcher.catalog().first?.id else { return }
        launcher.launch(id: id, target: target, canRoute: { authorization.allowed }) { outcome in
            runner.expect(outcome.opened && outcome.placed == false && !outcome.succeeded, "opened but revoked placement is explicit and cannot report destination success")
        }
        authorization.allowed = false
        openerCompletion?(456)
        runner.expectEqual(routes, 0, "a Stop while opening prevents subsequent AX writes")
        authorization.allowed = true
        launcher.launch(id: id, target: target, canRoute: { authorization.allowed }) { outcome in
            runner.expect(outcome.opened && outcome.placed == true && outcome.succeeded, "confirmed routing is distinguished from opening")
        }
        openerCompletion?(456)
        runner.expectEqual(routes, 1, "one selected app window router is invoked")
    }

}

@MainActor
private final class RoutingAuthorizationState { var allowed = true }
