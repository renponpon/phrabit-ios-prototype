# Phrabit iPhone prototype

SwiftUIの録音画面とロック画面コントロールの試作です。訳文は固定サンプルで、音声・翻訳APIは呼びません。

本番Web・DB・認証情報・APIキー・保存データは含みません。この搬出処理は署名・配布を行いません。

手動ビルドは標準macOSランナーで行い、ArtifactやCacheは保存しません。
署名・内部TestFlight提出は別の手動ワークフローです。承認済みコミット・main限定の保護環境・環境Secrets・実行承認を必要とし、一般公開や外部テスター招待は行いません。

[クラウドビルドの実行結果](https://github.com/renponpon/phrabit-ios-prototype/actions/workflows/ios-prototype.yml)で、検証したコミットと結果を確認できます。ビルド成功とiPhoneの実機検証は別です。

実装内容・未確認事項・検証手順は [native README](native/ios/PhrabitCapture/README.md) を参照してください。
