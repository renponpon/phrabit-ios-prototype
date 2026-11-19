import AppIntents
import Foundation
import SwiftUI
import WidgetKit

@main
struct PhrabitCaptureControls: WidgetBundle {
    var body: some Widget {
        PhrabitCaptureControl()
    }
}

struct PhrabitCaptureControl: ControlWidget {
    private let diagnosticsOnly = Bundle.main.object(forInfoDictionaryKey: "PhrabitDiagnosticsOnly") as? Bool == true

    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "com.phrabit.quickcapture.record") {
            ControlWidgetButton(action: OpenRecorderIntent()) {
                Label {
                    Text("Phrabit")
                } icon: {
                    Image("PhrabitControl")
                }
                .controlWidgetActionHint(diagnosticsOnly ? "接続確認を開く" : "話して翻訳")
            }
        }
        .displayName("Phrabit")
        .description(diagnosticsOnly ? "検証用の接続確認画面を開きます。録音はしません。" : "音声翻訳の録音画面を開きます。試作版の訳文は固定サンプルです。")
    }
}

