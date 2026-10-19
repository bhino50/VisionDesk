import Foundation

/// Entry point for `script/test_mac_behavior.sh`.
///
/// These checks run against the production Mac sources. They never post a Quartz event,
/// never request an OS permission, never start a capture, and never open a network service.
@main
@MainActor
struct ChecksMain {
    static func main() async {
        print("VisionDesk Mac behavior checks")
        print("No Quartz event is posted, no OS permission is requested, no capture is started.")
        print("")

        let runner = CheckRunner()
        await runCompanionLifecycleChecks(runner)
        await runCompanionWindowChecks(runner)
        await runRemoteAccessChecks(runner)
        await runLANHostChecks(runner)
        await runDockDisplayChecks(runner)
        await runFrameDeliveryChecks(runner)
        await runVideoDeliveryChecks(runner)
        await runInputMappingChecks(runner)
        await runScrollRemainderChecks(runner)
        await runClientGeometryChecks(runner)
        await runHostRecoveryChecks(runner)
        await runHostRecoveryLimitChecks(runner)
        await runHostEfficiencyChecks(runner)
        await runPreviewPacingChecks(runner)
        runner.finish()
    }
}
