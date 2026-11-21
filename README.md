# EWI5000_BackupTool（EWI5000 Bank Manager for Mac）

なんとなく作ったMac版のEWI5000ユーザープリセットのバックアップツールです。

AKAI Professional EWI5000 のユーザーバンク（00〜99）を、USB MIDI でバックアップ・復元する macOS アプリです。
A macOS app to back up and restore the AKAI EWI5000 user bank (00–99) over USB MIDI.

> Windows 版 [shingoaoki1985/ewi5000-bank-manager](https://github.com/shingoaoki1985/ewi5000-bank-manager) に触発されて作りました。
> 元アプリのコードは使っておらず、実機と公式 Sound Editor の通信を記録して仕様を調べ、Swift で一から書いています。
> AKAI Professional とは関係のない非公式ツールです。

## ダウンロード / Download
[Releases](../../releases) から `EWI5000_Bank_Manager_Mac_vX.Y.Z.zip` をダウンロードし、展開したアプリを「アプリケーション」に入れてください。
Apple Silicon / Intel 両対応、macOS 14 以降。

初回は「開発元を確認できない」ため開けません。一度ダブルクリックしたあと、
**システム設定 → プライバシーとセキュリティ** の下にある **「このまま開く」** を押してください（初回のみ）。

## できること / Features
- ユーザーバンク一括バックアップ（.syx）／選んだ音色の個別バックアップ（.syx）
- 本体設定（Control モードの約 330 項目）のバックアップ（.syx と一覧の .csv）
- .syx、または SD カードの `USERLIB.EWI` / `patchlib.ewi` から、選んだ番号へ書き戻し
  - 同じサンプルを使う音色を呼び出し → 違うパラメータだけ NRPN で送る → 読み戻して 266 バイトすべて一致したときだけ保存
  - 書き込み前に今のユーザーバンクを自動バックアップ（`~/Library/Application Support/EWI5000 Bank Manager/バックアップ`）
  - 書き込み後に本体から読み直して照合
- 本体内コピー（User xx → User yy）
- SD カード用 `USERLIB.EWI` の書き出し

## 使い方 / Usage
1. EWI5000 を USB でつないで電源を入れる。公式 Sound Editor は閉じる
2. 「接続」を押すと、ユーザーバンクの一覧が表示される
3. 書き戻しは、まず消えても困らない番号で試してください

## 注意 / Notes
- 本体設定の書き戻しには、まだ対応していません。
- 実機での確認は限られています。大切な音色は、書き込む前に必ずバックアップしてください。自己責任でお使いください。

## 通信仕様のメモ / Protocol notes
詳しくは `Sources/EWIProtocol.swift` の先頭にまとめています。

| 内容 | 送信 | 応答 |
|---|---|---|
| ユーザー/プリセットバンク | `F0 47 7F 20 02 00 03 F7` | `02 00 06` + 266×128 |
| 今の音色 | `F0 47 7F 20 02 00 07 F7` | `02 00 08` + 266 + bank + program |
| 保存 | `F0 47 7F 20 02 00 0A bank program F7` | – |
| 音色選択 | `B0 00 00` `B0 20 bank` `C0 program`（bank 0=Preset, 1=User） | – |
| パラメータ n | NRPN `63 00` `62 n` `06 msb` `26 lsb` → 音色データの 10+2n バイト目 | – |

## ビルド / Build
```
./build.sh
```
Xcode のコマンドラインツールが必要です。`dist/` にアプリと配布用 zip ができます。
ビルド時に自己テスト（模擬 EWI5000 を相手にした読み出し・復元・コピー）を実行します。

## License
MIT
