# Phrabit iPhone音声翻訳プロトタイプ

状態: ソースと手動クラウドビルド設定を準備した段階。Windows上の構成検査と、Macで行うSwiftコンパイル・実機検証は別です。App Store公開・TestFlight配布・署名・実API接続は行いません。

## 今回の範囲

- iOS 18以上のiPhoneを対象にしたSwiftUIアプリとWidgetKitコントロール。
- 初回に翻訳先を選択し、マイクを許可。ロック画面の配置は本人がiOSのカスタマイズで行います。
- 配置したPhrabitの単色シンボルからアプリを開き、初期設定済みなら自動で録音開始。アプリ内でも開始できます。
- 録音中の表示・開始後の振動・手動停止・20秒停止・キャンセル・割込時の中断。
- 停止後は英語または中国語の固定サンプル。中国語にはピンインを表示。
- 録音は端末内の保護付き一時ファイルだけ。通常の完了・キャンセル・割込で削除し、端末外へ送りません。OS強制終了時の即時削除は保証しませんが、次のアプリ起動で残った試作録音を削除します。
- 保存・ドリル・履歴・解説・ログイン・時計対応・バックグラウンド録音は対象外。

この試作版は音声認識も実翻訳もしません。「録音した言葉の訳」と誤認しないよう、模擬表示を画面に常設します。結果はすべて「部屋の掃除をお願いできますか？」の固定例です。

## SwiftUIとGeminiの役割

SwiftUIは画面・操作を実装するAppleのUIフレームワークで、翻訳モデルではありません。次段階の接続先は既存Phrabitサーバーです。

```text
iPhoneの録音
  → 既存の音声認識APIで文字起こし
  → 既存PhrabitのGemini 3.5 Flash-Lite翻訳
  → iPhoneに訳文・ピンインを表示
```

端末内AIへの切替や別モデル導入はしません。同じ翻訳品質を狙うためにモデルだけでなく既存のプロンプト・構造化出力・後処理を再利用し、APIキーはサーバー内に置きます。同モデルでも音声認識・入力・設定による差はあるため、品質同一を保証済みとは扱いません。

現在の翻訳APIは保存を省略する明示指定が必要です。実API接続前に`persist: false`、認証・利用上限・月3,000円の共通予算を維持することを検証します。この段階ではAPIクライアント自体を実装しません。

## ロック解除と起動

コントロールは`OpenIntent`でアプリを前面に出す方式です。カメラ専用の権限やバックグラウンド機能を録音に流用しません。安全のため端末認証を要求する設定で、必要時はFace ID・パスコードを挟みます。ロックしたまま録音・訳文表示が完結する方式ではありません。

起動要求はアプリで一度だけ消費します。録音・翻訳の最中に入口を押し直しても、二重録音・二重処理を始めません。アプリとコントロールの両方に同じIntentソースを含めています。実機でコントロール→アプリへの処理移行を確認するまで「動作済み」とは扱いません。

「1秒」は起動・発話開始の目標であって翻訳生成時間ではありません。ロック画面の起動ジェスチャー、認証、初回権限、コールド起動を含めて測定します。現時点では未計測です。

## Windowsで確認できること

リポジトリ直下で実行します。

```powershell
node scripts/check-ios-prototype.mjs
```

構成・ネットワーク未接続・録音上限・手動ビルドなどの静的検査です。Swiftの型検査・録音・起動・シンボル描画の検証を代替しません。

## Mac環境でのビルド

Xcode 16以上とXcodeGen 2.44以上が必要です。現状のプロジェクトにはAppleチームや証明書を設定しません。生成ファイルはローカルのみに置きます。

```sh
cd native/ios/PhrabitCapture
swift test --package-path Core
xcodegen generate
xcodebuild -project PhrabitCapture.xcodeproj \
  -scheme PhrabitCapture -configuration Debug \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath build/DerivedData CODE_SIGNING_ALLOWED=NO build
```

クラウド用の`.github/workflows/ios-prototype.yml`も同じ処理を実行します。`workflow_dispatch`だけで、push・PR・定期実行はありません。利用枠と料金を確認した上で入力`confirm_usage`を有効にして手動実行します。1回最大20分で、署名情報・外部APIキー不要です。課金対象となり得るArtifactとCacheの保存は行わず、結果は通常のActions実行ログで確認します。

既存リポジトリは公開ですが、本番Vercelの自動デプロイとつながっています。手動ワークフローを初めて実行するにはデフォルトブランチへの登録が必要なため、本番リポジトリのmainへ追加しません。本人の承認を受け、専用の公開リポジトリ`renponpon/phrabit-ios-prototype`を作成し、試作ファイルだけを分離します。公開リポジトリで標準のGitHub-hosted macOSランナーを使う計算処理は無料です。ソース公開・今回の試作だけのコミット/push・無料unsignedビルドの実行は承認済みです。有料登録・実API・TestFlight配布・本番変更は承認範囲外です。非公開・大型ランナーなどへ切り替える場合は、料金・利用枠を改めて確認します。

本番や秘密情報を含めずに搬出する準備は、リポジトリ直下から`node scripts/prepare-ios-cloud-build.mjs`で行います。明示したファイルだけを`tmp/ios-cloud-build-20261114/`へコピーしてSHA-256を記録します。搬出先が既にある場合は、空の別フォルダーを第1引数で指定します。ファイルの公開・Git操作・クラウド実行はしません。

このビルドはシミュレーター用です。ログが成功しても、自分のiPhoneへ入る署名済みアプリは生成しません。

## 実機テストと公開までの残作業

1. 承認後に手動クラウドビルドとCoreのXCTestを実行し、コンパイルエラー・カスタムシンボルを確認。
2. Apple Developer Programの契約状況と費用、App Store Connectのアプリ・Bundle ID、署名・配布用の権限を本人と確認。購入・契約は自動実行しません。
3. App Icon等の配布用素材と設定、プライバシー表示・必要な配布情報を整備し、承認された安全な経路で証明書等を管理。キー・パスワードをチャットやGitへ貼りません。
4. 別の署名・配布用ワークフローでTestFlightへ配布。今回の unsigned 検査に配布を混ぜません。ストア一般公開は不要です。
5. iPhoneで初回許可・拒否・再許可、手動起動、コントロール起動、Face ID、再起動後、長時間未使用、開始音の欠け、最大20秒、すぐ停止、キャンセル、通話割込、画面を閉じたとき、連打、英中・大きな文字・VoiceOverを確認。
6. 起動と録音が合格してから、既存サーバーへ音声認識・翻訳だけを接続。料金・残予算の確認前には実APIを呼びません。本番Web・DBはこの試作で変更しません。

自分のMacがなくてもクラウドでビルドできますが、マイクとロック画面の実挙動は本人のiPhoneでの操作確認が必要です。画面イメージやソース準備を実機検証の合格と混同しません。

## 根拠

- [Apple ControlsとOpenIntent](https://developer.apple.com/documentation/widgetkit/creating-controls-to-perform-actions-across-the-system)
- [Appleのカスタムシンボル](https://developer.apple.com/documentation/uikit/creating-custom-symbol-images-for-your-app)
- [GitHubのmacOSランナー](https://docs.github.com/en/actions/reference/runners/github-hosted-runners)
- [GitHub Actionsの公開リポジトリの料金](https://docs.github.com/en/billing/concepts/product-billing/github-actions)
- [手動実行とデフォルトブランチの条件](https://docs.github.com/en/actions/how-tos/manage-workflow-runs/manually-run-a-workflow)
- [TestFlight等の配布方法](https://developer.apple.com/documentation/xcode/distributing-your-app-for-beta-testing-and-releases)

