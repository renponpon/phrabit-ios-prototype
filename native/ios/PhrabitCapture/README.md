# Phrabit iPhone音声翻訳プロトタイプ

状態: 2026年11月14日、標準macOSランナーのXcode 16.4でCoreのXCTest9件・アプリとコントロールの未署名iOS Simulatorビルドが成功しました。[検証したコミット2bfb5a0の実行結果](https://github.com/renponpon/phrabit-ios-prototype/actions/runs/43587257182)で確認できます。iPhoneでの起動・録音・描画・1秒の目標は未検証です。App Store公開・TestFlight配布・署名・実API接続は行っていません。

初回にカスタムシンボルのガイド不足、2回目にAppIconの不足を検出し、修正版の3回目で成功しました。既存Phrabitロゴから1024pxの不透明AppIconを用意し、コントロールのシンボルとは別に設定しています。ActionsのNodeランタイム移行警告・macOSの待ち時間通知はありましたが、Swiftコンパイルの警告・エラーは出ていません。画面が実機で使えることや、App Storeの審査通過を意味しません。

配布準備の追加検証：コミット`2fc30073074c30fe88252d077ed64078ff3ca59c`でXcode26.2・iOS SDK26.2のビルドとCore9件が成功しました。アプリとコントロールのPrivacyInfo.xcprivacyが実際の出力に含まれることも確認済みです。[SDK26の実行結果](https://github.com/renponpon/phrabit-ios-prototype/actions/runs/43597321827)を参照してください。Nodeランタイムの警告は解消しました。

2026年11月17日の`1140ee0`では、登録済みのBundle IDで静的9項目・公開搬出ポリシー6件・Core9件・未署名Simulatorビルド・未署名iPhone用Release archive・本体と拡張のIDおよびプライバシー宣言の同梱確認が成功しました。[実行結果](https://github.com/renponpon/phrabit-ios-prototype/actions/runs/43909442072)を参照してください。署名・配布・実機動作は未検証です。

このarchiveで検出した画面方向の警告への対応として、4方向を宣言し、古い`UIRequiresFullScreen`は追加しません。生成したInfo.plistの方向リストとarchiveログの警告をCIで検査します。この設定変更を実機の横画面表示まで確認済みとは扱いません。

## アプリ識別子と配布前検査

アプリ本体は`com.phrabit.app`、ロック画面コントロールは`com.phrabit.app.control`を使用します。XcodeGen設定と静的検査で本体と拡張の識別子の一致を確認します。

手動CIはSimulatorビルドに加え、署名しない実機用Release archiveと、その本体/拡張のBundle ID・プライバシー宣言を検査します。署名情報・Artifact保存・TestFlightアップロードは使用しません。実機向けarchiveの成功と、iPhoneへのインストールや録音の動作確認は別です。

このREADMEには開発者の契約状況、連絡先、請求情報や署名情報を記載しません。

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

現在の翻訳APIは保存を省略する明示指定が必要です。実API接続前に`persist: false`、認証・利用上限・既存の予算制御を維持することを検証します。この段階ではAPIクライアント自体を実装しません。

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

最初の構成確認はXcode16.4で通過しましたが、2026年4月28日以降のApp Store Connect提出にはXcode26以上・iOS SDK26以上が必要です。配布準備用の手動CIは標準macos-26ランナー上のXcode26.2を指定し、バージョン不足時は停止するよう更新しました。対応端末の最小OSはiOS18のままです。XcodeGenは2.44以上を使用します。現状のプロジェクトにはAppleチームや証明書を設定しません。生成ファイルはローカルのみに置きます。

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

試作ファイルは専用の公開リポジトリ`renponpon/phrabit-ios-prototype`で管理します。本番Webのリポジトリや自動デプロイとは分離し、署名情報や環境変数は含めません。クラウド実行には標準のGitHub-hosted macOSランナーを使用します。

本番や秘密情報を含めずに搬出する準備は、リポジトリ直下から`node scripts/prepare-ios-cloud-build.mjs`で行います。明示したファイルだけを`tmp/ios-cloud-build-20261114/`へコピーしてSHA-256を記録します。搬出先が既にある場合は、空の別フォルダーを第1引数で指定します。ファイルの公開・Git操作・クラウド実行はしません。

このCIはSimulatorビルドと実機向けの未署名archiveを検査します。実機向けarchiveが成功しても、自分のiPhoneへ入る署名済みアプリや配布用IPAは生成しません。

## TestFlight準備で本人が行うこと

署名・提出専用の`ios-testflight.yml`は未署名CIとは別です。手動実行時に承認した40桁のコミットSHAを指定し、専用の保護環境でmainの実行承認を受けます。署名用証明書・プロファイル・APIキーは環境Secretsから必要な工程だけへ渡します。鍵の発行・保管・利用は別途本人の許可が必要です。

署名コマンドの生ログ・証明書情報・IPA・鍵を公開ArtifactやCacheへ保存しません。一時キーチェーン・プロファイル・アップロードキーは終了時に片付けます。アップロード成功だけで内部テスターへの配布完了とは扱わず、Appleの処理状態と本人の受信を確認します。一般公開や外部テスター招待は自動化しません。

1. Apple Developerアカウントへ、普段iPhoneで使っているApple Accountでログインし、既存のメンバーシップがあるか確認します。パスワードや認証コードはチャットへ送らないでください。
2. Apple Developer Programの加入条件や費用はApple公式ページで確認します。購入や規約同意はこのリポジトリのワークフローでは行いません。
3. 個人登録では、将来ストアで販売元として正式な個人名が表示されます。Phrabitというブランド名だけを販売元として表示できる契約ではありません。法人名での表示を希望する場合は組織登録の条件を確認してから選びます。
4. 2026年11月17日に本体`com.phrabit.app`・拡張`com.phrabit.app.control`とPhrabitの管理枠を登録済みです。アプリと署名用プロファイルはこのIDに一致させます。登録済みのIDを、以前の`com.phrabit.quickcapture.prototype`へ戻しません。
5. 署名用証明書・プロファイル・App Store Connectの認証を準備する段階で、用途・権限・保管先を説明して確認します。秘密情報は公開リポジトリ・チャット・実行ログへ置きません。GitHub環境の保護・実行するコミットの確認を先に行い、署名なしCIへ秘密情報を混ぜません。
6. 最初は自分のApple Accountを内部テスターにして、iPhoneのTestFlightで受け取ります。一般公開の申請や外部テスターへの公開は別の操作です。契約・Appleでの処理待ちにより、その場で配布できるとは限りません。

アプリ本体・コントロールにPrivacyInfo.xcprivacyを追加しました。UserDefaultsは端末内の設定、systemUptimeは録音経過時間、ファイルメタデータは自アプリの一時録音を確認する目的で宣言しています。現在の模擬版は音声を送らず追跡・データ収集を行わない構成です。実API接続時にはプライバシー申告と説明を見直します。このソース追加だけで、App Store Connectの申告や同意・審査を完了したとは扱いません。

## 実機テストと公開までの残作業

1. CoreのXCTest9件と、アプリ・コントロール・カスタムシンボル・AppIconのコンパイルは通過済み。次は端末での描画・録音・起動を確認します。
2. Apple Developer Programの契約状況と費用、App Store Connectのアプリ・Bundle ID、署名・配布用の権限を本人と確認。購入・契約は自動実行しません。
3. AppIconの配布要件・実機表示、プライバシー表示・必要な配布情報・提出時点のSDK要件を確認し、承認された安全な経路で証明書等を管理。キー・パスワードをチャットやGitへ貼りません。
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
- [Apple Developer Program登録条件と価格](https://developer.apple.com/jp/help/account/membership/program-enrollment/)
- [App Store Connectの提出SDK要件](https://developer.apple.com/news/upcoming-requirements/?id=04282026a)
- [必須理由APIの分類と理由](https://developer.apple.com/documentation/bundleresources/app-privacy-configuration/nsprivacyaccessedapitypes/nsprivacyaccessedapitype)

