import SwiftUI

struct WatchReadingHelp: View {
    var body: some View {
        List {
            Section("轻点或转动表冠") {
                Label("轻点中央大区域，继续向下阅读",systemImage:"hand.tap")
                Label("转动表冠，向下阅读或向上回看",systemImage:"digitalcrown.horizontal.arrow.clockwise")
                Text("手表会跟随阅读器的滚动或分页模式。支持双指互点的型号，唤醒后也可用手势继续阅读。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section("连接 Mac") {
                Text("在 Mac 点“手表遥控 → 连接新设备”，在手表选择这台 Mac，核对数字后在 Mac 允许连接。")
                Text("以后打开两端书籍人生即可自动重连。Mac 保持唤醒、蓝牙开启，阅读窗口不要最小化。")
            }
            Section("连接手机或 iPad") {
                Text("在手表“连接设置 → 阅读设备”中选择“iPhone / iPad”。手机直接打开书籍；iPad 首次需在手机上添加并配对。")
                Text("iPad 与手机连接同一 Wi-Fi，手机保持在手表附近。阅读页面保持亮屏。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section("断开后怎么办") {
                Text("回到手表 App，等待自动重连；仍未恢复时，在连接设置点“重新连接”。已经配对的设备无需重新添加。")
                Text("熄屏后先唤醒再操作。常亮屏不能保证垂腕时接收手势。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section {
                DisclosureGroup("减少返回表盘") {
                    Text("手表“设置 → 通用 → 返回表盘 → 书籍人生 → 自定 → 1 小时后”。这会延长 App 停留时间，不会让屏幕一直亮着。")
                }
                DisclosureGroup("Ultra 操作按钮") {
                    Text("在快捷指令中添加书籍人生的“下一页”，开启“在 Apple Watch 上显示”；再到手表“设置 → 操作按钮 → 快捷指令”选中它。首次使用可能需要系统授权。")
                }
            }
        }
        .navigationTitle("操作与连接帮助").navigationBarTitleDisplayMode(.inline)
    }
}
