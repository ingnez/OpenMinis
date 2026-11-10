import SwiftUI
import WidgetKit

@main
struct AgentWidgetBundle: WidgetBundle {
    var body: some Widget {
        CloudBotsWidget()
        CloudTodayWidget()
        if #available(iOSApplicationExtension 16.2, *) {
            AgentLiveActivityWidget()
        }
        if #available(iOS 18.0, *) {
            CloudVoiceControl()
        }
    }
}
