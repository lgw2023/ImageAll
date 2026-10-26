import Foundation

@main
struct SharePresentationTests {
    static func main() {
        var task = LocalShareTask()
        task.begin(itemCount: 2_889, target: "Fixture Mac")
        task.pause()
        let ui = LocalSharePresentation.resolve(task: task, selectedCount: 2_889,
            canReadPhotos: true, needsFullAccess: false, connected: true,
            awaitingConsent: false, otherWork: false, selectionMatches: true)
        precondition(ui.title == "已暂停")
        precondition(ui.action == .resume && ui.isEnabled)
        precondition(task.itemCount == 2_889 && task.target == "Fixture Mac")
        print("PASS: 暂停保留任务范围与目标，提供显式继续入口")
        let differentMac = LocalSharePresentation.resolve(task: task, selectedCount: 2_889,
            canReadPhotos: true, needsFullAccess: false, connected: true,
            awaitingConsent: false, otherWork: false, selectionMatches: true, targetMatches: false)
        precondition(differentMac.action == .connect)
        print("PASS: 连到其他 Mac 时仍要求恢复原目标，不能把继续绑定到新 Mac")
        func resolve(_ task: LocalShareTask, count: Int = 2_889, connected: Bool = true,
                     canRead: Bool = true, fullAccessNeeded: Bool = false, matches: Bool = true,
                     otherWork: Bool = false, phase: String = "传输原件") -> LocalSharePresentation {
            .resolve(task: task, selectedCount: count, canReadPhotos: canRead,
                needsFullAccess: fullAccessNeeded, connected: connected, awaitingConsent: false,
                otherWork: otherWork, selectionMatches: matches, transferPhase: phase)
        }
        task.begin(itemCount: 2_889, target: "Fixture Mac")
        let running = resolve(task, count: 0, connected: false, canRead: false)
        precondition(running.title == "正在传输" && running.action == .pause)
        task.phase = .pausing
        precondition(!resolve(task).isEnabled)
        print("PASS: 运行时条件变化仍有暂停入口，正在暂停时不能重复操作")
        task.phase = .failed; task.detail = "source unavailable"
        precondition(resolve(task).action == .retry && resolve(task).isError)
        precondition(resolve(task, connected: false).action == .connect)
        precondition(resolve(task, matches: false).action == .select)
        precondition(task.detail == "source unavailable" && task.itemCount == 2_889)
        print("PASS: 失败保留原因，断连和范围变化分别给出恢复入口")
        task.phase = .received
        precondition(resolve(task).title == "Mac 已接收 · 状态待核对")
        precondition(resolve(task).action == .macNextStep)
        print("PASS: 接收回执只引导 Mac 入库，不显示最终完成")
        task.begin(itemCount: 2_889, target: "Fixture Mac", intent: .sealReceived)
        task.requestPause(.appBackground)
        task.requestPause(.userRequested)
        task.pause()
        precondition(task.pauseReason == .appBackground && task.intent == .sealReceived)
        precondition(resolve(task).message.contains("仅封存"))
        let retryIntent = task.intent
        task.begin(itemCount: 2_889, target: "Fixture Mac", intent: retryIntent)
        precondition(task.intent == .sealReceived && task.pauseReason == nil)
        task.phase = .failed
        precondition(resolve(task).action == .retry && task.intent == .sealReceived)
        print("PASS: 后台暂停和失败重试保留仅封存意图，首个暂停原因不会被覆盖")
        task.begin(itemCount: 2_889, target: "Fixture Mac")
        task.requestPause(.userRequested); task.pause(reason: .usbDisconnected)
        precondition(task.pauseReason == .userRequested)
        task.begin(itemCount: 2_889, target: "Fixture Mac")
        task.pause(reason: .usbDisconnected)
        precondition(resolve(task).message.contains("USB 连接已中断"))
        task.begin(itemCount: 2_889, target: "Fixture Mac"); task.pause()
        precondition(task.pauseReason == .cancelled)
        print("PASS: 用户暂停、USB 断连、未知取消保留可区分的原因")
        task.receive(itemCount: 2_866)
        precondition(task.itemCount == 2_889 && task.receivedItemCount == 2_866)
        precondition(resolve(task).message.contains("2866") && !resolve(task).message.contains("保留待处理"))
        precondition(!resolve(task).message.contains("2889 项已发送"))
        precondition(resolve(task).action == .macNextStep)
        print("PASS: 子集回执仅报告实际接收数，保留历史选择且不自动生成差额待办")
        task = LocalShareTask()
        precondition(resolve(task, count: 0).action == .select)
        precondition(resolve(task, canRead: false).action == .permission)
        precondition(resolve(task, fullAccessNeeded: true).action == .permission)
        precondition(resolve(task).action == .start)
        precondition(!resolve(task, otherWork: true).isEnabled)
        print("PASS: 准备条件及互斥操作均提供可解释的下一步")
    }
}
