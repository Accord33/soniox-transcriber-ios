<div align="center">

# 🎙️ Soniox Transcriber

**話した言葉を、その場で読みやすいテキストへ。**

Soniox Speech-to-Text API を使った、シンプルな iOS リアルタイム文字起こしアプリです。

![Platform](https://img.shields.io/badge/platform-iOS%2017%2B-000000?logo=apple)
![Swift](https://img.shields.io/badge/Swift-5.0-F05138?logo=swift&logoColor=white)
![Xcode](https://img.shields.io/badge/Xcode-15%2B-147EFB?logo=xcode&logoColor=white)
![License](https://img.shields.io/badge/license-MIT-2ea44f)

</div>

## ✨ 主な機能

| 機能 | 内容 |
| --- | --- |
| リアルタイム文字起こし | マイク音声を Soniox WebSocket API へ送り、認識結果を随時表示します |
| バックグラウンド録音 | 録音開始後は、画面ロック中や他のアプリを表示中も文字起こしを継続します |
| Live Activity | 録音状態と経過時間をロック画面とDynamic Islandに表示します |
| 話者分離 | 話者ごとに発言をまとめて表示します |
| 履歴保存 | 文字起こし結果を SwiftData で端末内に保存します |
| テキスト共有 | 文字起こし結果を `.txt` ファイルとして共有できます |
| 安全なキー管理 | Soniox API キーを iOS Keychain に保存します |

## 🔐 プライバシーとセキュリティ

- API キーはソースコードや UserDefaults に保存せず、利用端末の Keychain にのみ保存します。
- マイク音声は録音ファイルとして端末に保存しません。
- 通信や音声セッションの一時的な切断後は自動再接続しますが、切断中の音声は保存されません。
- 文字起こし履歴は端末内の SwiftData に保存されます。
- 音声は文字起こしのため Soniox API に送信されます。利用前に [Soniox のプライバシーポリシー](https://soniox.com/privacy-policy)をご確認ください。
- このリポジトリに API キーをコミットしないでください。

## 🧰 必要なもの

- macOS / Xcode 15 以降
- iOS 17 以降を搭載した iPhone（マイク入力のため実機推奨）
- [Soniox Console](https://console.soniox.com/) で発行した API キー

## 🚀 セットアップ

1. リポジトリをクローンします。

   ```bash
   git clone https://github.com/Accord33/soniox-transcriber-ios.git
   cd soniox-transcriber-ios
   ```

2. `SonioxTranscriber.xcodeproj` を Xcode で開きます。

   ```bash
   open SonioxTranscriber.xcodeproj
   ```

3. Xcode の **Signing & Capabilities** で、自分の Team と一意の Bundle Identifier を設定します。
4. iPhone 実機を選択してアプリをビルド・実行します。
5. 初回起動時に Soniox API キーを入力します。

> [!IMPORTANT]
> サンプルの Bundle Identifier は `com.example.SonioxTranscriber` です。実機で動かす際は、自分が管理する一意の値へ変更してください。

### 署名設定を安全に登録する

Apple Team ID はリポジトリに保存せず、ローカル設定ファイルへ自動登録できます。

```bash
./Scripts/setup-signing.sh
./Scripts/build.sh
```

`Signing.local.xcconfig` は `.gitignore` で除外されているため、Team ID や Bundle Identifier が GitHub に公開されることはありません。Xcode の GUI から実機実行する場合は、Xcode の **Signing & Capabilities** で同じ Team を選択してください。

## 🏗️ 構成

```text
SonioxTranscriber/
├── SonioxTranscriberApp.swift  # アプリのエントリーポイント
├── Views.swift                 # 設定・録音・履歴・共有 UI
├── SonioxService.swift         # WebSocket 通信と音声処理
├── Models.swift                # API レスポンスと SwiftData モデル
├── KeychainStore.swift         # API キーの安全な保存
└── Info.plist                  # アプリ設定・マイク権限
```

音声は `AVAudioEngine` で取得し、16 kHz / 16-bit / mono PCM に変換して Soniox のリアルタイム API へ送信します。確定トークンは話者ごとにまとめ、完了後に SwiftData へ保存します。

## ✅ テスト

Xcode の **Product > Test**、または次のコマンドでテストできます。

```bash
xcodebuild test \
  -project SonioxTranscriber.xcodeproj \
  -scheme SonioxTranscriber \
  -destination 'platform=iOS Simulator,name=iPhone 16'
```

利用可能な Simulator 名は環境に合わせて変更してください。

## 🤝 コントリビューション

Issue や Pull Request を歓迎します。大きな変更を提案する場合は、実装前に Issue で目的や方針を共有してください。

## 📄 ライセンス

このプロジェクトは [MIT License](LICENSE) のもとで公開されています。

---

<div align="center">
Made with SwiftUI, SwiftData, and Soniox
</div>
