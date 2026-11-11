import Foundation
#if canImport(MediaPlayer)
import MediaPlayer
import UIKit

/// 口袋模式打开时，监听耳机 / AirPods 上的播放、暂停键。只增加自己的 target，不会拆掉 App 里已有的音频遥控。
/// 音量键系统不开放。App 需要已经打开过、口袋模式是开着的；系统会把按键发给当前的 Now Playing 会话，所以这不是 100% 后台都能收到，设置页里有说明。
final class CloudPocketHeadset: NSObject {
    static let shared = CloudPocketHeadset()
    private var registered = false

    func apply(enabled: Bool = CloudPocketMode.isEnabled(.standard)) {
        let cc = MPRemoteCommandCenter.shared()
        if enabled && !registered {
            cc.playCommand.addTarget(self, action: #selector(handle))
            cc.pauseCommand.addTarget(self, action: #selector(handle))
            cc.togglePlayPauseCommand.addTarget(self, action: #selector(handle))
            registered = true
        } else if !enabled && registered {
            cc.playCommand.removeTarget(self)
            cc.pauseCommand.removeTarget(self)
            cc.togglePlayPauseCommand.removeTarget(self)
            registered = false
        }
    }

    @objc private func handle(_ event: MPRemoteCommandEvent) -> MPRemoteCommandHandlerStatus {
        DispatchQueue.main.async {
            CloudBotEntry.pendingPocket = true
            CloudBotEntry.openVoice(bot: nil)
        }
        return .success
    }
}
#endif
