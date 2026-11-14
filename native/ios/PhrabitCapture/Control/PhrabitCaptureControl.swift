import AppIntents
import SwiftUI
import WidgetKit

@main
struct PhrabitCaptureControls: WidgetBundle {
    var body: some Widget {
        PhrabitCaptureControl()
    }
}

struct PhrabitCaptureControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "com.phrabit.quickcapture.record") {
            ControlWidgetButton(action: OpenRecorderIntent()) {
                Label {
                    Text("Phrabit")
                } icon: {
                    Image("PhrabitControl")
                }
                .controlWidgetActionHint("話して翻訳")
            }
        }
        .displayName("Phrabit")
        .description("音声翻訳の録音画面を開きます。試作版の訳文は固定サンプルです。")
    }
}

