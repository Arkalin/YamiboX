<p align="center">
  <img src="YamiboX/Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png" width="128" alt="Yamibo X 圖示">
</p>

<h1 align="center">Yamibo X</h1>

<p align="center">
  <a href="README.md" lang="zh-Hans">简体中文</a> · <strong>繁體中文</strong>
</p>

<p align="center">
  面向百合會論壇的非官方 iOS 綜合用戶端
</p>

<p align="center">
  <a href="https://github.com/Arkalin/YamiboX/releases"><img src="https://img.shields.io/github/v/release/Arkalin/YamiboX?style=flat-square&label=%E4%B8%8B%E8%BC%89&color=2f6f73" alt="最新版本"></a>
  <img src="https://img.shields.io/badge/平台-iOS%2018.0%2B-247344?style=flat-square" alt="iOS 18.0+">
  <a href="LICENSE"><img src="https://img.shields.io/badge/授權-AGPL--3.0-1f5f9c?style=flat-square" alt="AGPL-3.0 授權"></a>
</p>

<p align="center">
  <a href="#安裝與更新">安裝與更新</a> ·
  <a href="#功能概覽">功能概覽</a> ·
  <a href="#開發者">開發文件</a> ·
  <a href="https://github.com/Arkalin/YamiboX/issues">問題回報</a>
</p>

---

Yamibo X 是面向百合會論壇的非官方 iOS 綜合用戶端，使用 SwiftUI 與 UIKit 建構原生介面，整合論壇瀏覽與互動、書架、收藏管理、小說閱讀和漫畫閱讀。支援 iPhone 與 iPad，並提供簡體中文和繁體中文介面。

## 安裝與更新

**系統需求** · iOS 18.0 及以上，支援 iPhone 和 iPad。

從 [Releases](https://github.com/Arkalin/YamiboX/releases) 下載最新的 `.ipa`，透過 [AltStore](https://altstore.io) 等工具簽署安裝；也可加入下方軟體來源，在 AltStore 內安裝和更新。

<p align="center">
  <a href="https://celloserenity.github.io/altdirect/?url=https://raw.githubusercontent.com/Arkalin/YamiboX/main/app-repo.json">
    <img src="https://github.com/CelloSerenity/altdirect/blob/main/assets/png/AltSource_Blue.png?raw=true" alt="加入 AltStore 軟體來源" width="200">
  </a>
</p>

**檢查更新** · 在「我的 → 關於」中查看新版本與更新說明，或透過 AltStore 軟體來源更新。

## 功能概覽

### 閱讀與書架

- **書架與續讀**：展示最近閱讀的小說和漫畫，可分別設定數量或混合展示，支援僅顯示收藏作品和自訂書架背景。
- **閱讀模式**：按板塊設定一般帖子、小說、漫畫或智慧漫畫模式，也可在閱讀時切換。小說與漫畫均支援橫向分頁和縱向滾動；分頁動畫可選無動畫、滑動、卷頁或快速淡入淡出，支援翻頁方向與點擊區域設定，並依可用空間自動調整為雙頁。
- **小說閱讀器**：支援字型匯入與管理、字級、行距、字距、頁邊距、正文圖片、簡繁轉換，以及粗體、顏色、注音、引用等原帖格式的顯示開關。
- **漫畫閱讀器**：支援畫面縮放、適配方式和邊緣填充；智慧漫畫可辨識、彙整同一作品的章節帖子，並提供目錄編輯及列表／網格瀏覽。
- **閱讀工具**：支援章節目錄、閱讀進度儲存、書籤、文字與圖片摘錄；「我的喜歡」可依作品和內容類型瀏覽、搜尋。閱讀器提供沉浸模式，以及「液態玻璃」和「圖書」兩種工具欄樣式。
- **章節評論與周邊裝置**：支援查看評論、對話和評分理由，發表章節評論及設定封鎖規則；支援 Apple Pencil（含 Pro）、遊戲控制器和鍵盤操作，並可自訂按鍵綁定。

### 論壇與收藏

- **原生論壇瀏覽**：支援板塊、帖子、搜尋、標籤、公告、使用者空間、日誌與積分紀錄；暫不支援的站內頁面透過內建網頁瀏覽器開啟。可辨識剪貼簿中的論壇連結並提示開啟。
- **發帖與互動**：原生編輯器支援視覺化 BBCode、格式編輯、表情、圖片與附件上傳，以及依帳號儲存草稿；支援發帖、回覆、撰寫日誌、評分和點評。
- **帳號與消息**：支援多帳號管理、私訊與消息提醒、未讀標記和論壇黑名單；提供手動簽到，以及透過 iOS 捷徑自動化執行簽到。
- **收藏管理**：支援論壇收藏同步、分類、合集、標籤、手動排序、搜尋、批次操作與封面管理；可檢查作品更新、接收更新通知並管理更新未讀標記。

### 下載、同步與個人化

- **離線下載**：統一管理小說、漫畫、智慧漫畫和論壇附件的下載佇列與本機內容，支援暫停、繼續和失敗重試，已下載小說可自動更新。iOS 26 及以上可申請背景持續下載並顯示系統進度；是否獲准及持續時間由系統決定，不保證強制結束後繼續下載。
- **WebDAV 同步**：可依類別選擇同步收藏、喜歡、書籤、閱讀進度、封面設定、應用程式設定、漫畫目錄和瀏覽紀錄，支援手動與自動同步。
- **介面自訂**：支援自訂應用程式主題、書架和啟動畫面背景、底部導覽順序及啟動頁；書架、消息、歷史、喜歡可作為可選導覽項目。iPad 支援側邊欄、自適應版面配置和多視窗閱讀。

## 資料與安全

- 登入狀態、收藏、歷史、閱讀進度、下載內容和快取等資料儲存在裝置本機或來自百合會論壇帳號本身。
- WebDAV 同步直接連接使用者設定的伺服器，密碼儲存在系統鑰匙圈中，同步紀錄依伺服器與論壇帳號隔離。
- WebDAV 不同步離線下載；封面只同步索引與顯示偏好，不傳輸圖片檔案。
- 封面圖片獨立持久化儲存，不隨一般圖片快取清理或容量淘汰而移除；可在儲存空間設定中單獨管理。
- 請只從本儲存庫 Releases 或上方 AltSource 安裝 `.ipa`，避免使用來源不明的修改版本。
- 清理應用程式資料、解除安裝或更換裝置可能導致本機歷史、下載內容、快取和設定遺失。

## 內容邊界

- 本專案為非官方用戶端，與百合會論壇營運方無隸屬關係。
- 請遵守目標論壇規則、著作權要求以及所在地法律法規。
- 論壇內容、圖片和使用者發表的資訊來自原站點，其著作權與內容責任歸原始來源所有。
- 本專案在功能設計上參考了相關上游專案，相關來源與授權資訊請同時參考本儲存庫的 [LICENSE](./LICENSE)。

## 開發者

### 專案結構與相依套件

[`Package.swift`](Package.swift) 定義 `YamiboXCore` 和 `YamiboXUI` 兩個模組，UI 單向依賴 Core：

| 目錄 | 職責 | 組織方式 |
| --- | --- | --- |
| [`Sources/YamiboXCore`](Sources/YamiboXCore) | 業務模型、應用流程、網路、解析、同步與持久化 | `Domain` · `Application` · `Data` |
| [`Sources/YamiboXUI`](Sources/YamiboXUI) | 功能介面、共用 UI、平台實作與應用程式組裝 | `Features` · `SharedUI` · `Platform` · `AppEntry` |
| [`YamiboX`](YamiboX) | App 入口、資源與系統設定 | [`YamiboX.xcodeproj`](YamiboX.xcodeproj) |

模組邊界與程式碼歸屬見[專案結構](docs/architecture.md)，開發與驗證約定見 [`AGENTS.md`](AGENTS.md)。

主要相依套件為 [`GRDB.swift`](https://github.com/groue/GRDB.swift)（資料庫）、[`Kanna`](https://github.com/tid-kijyun/Kanna)（HTML 解析）和 [`Nuke`](https://github.com/kean/Nuke)（圖片載入），具體版本以 `Package.swift` 為準。

### 本機開發

**工具鏈** · Swift 6.2+，部署目標 iOS 18+，CI 使用 Xcode 27。

**開發環境** · iOS 模擬器，`YamiboX-Local` Scheme，`Debug-Local` 設定。安裝識別碼為 `com.arkalin.YamiboX.local`，與一般 Debug 和正式版隔離。

在儲存庫根目錄查看可用模擬器，然後將下方 `<SIMULATOR_UDID>` 替換為所選 iOS 模擬器的識別碼：

```bash
xcrun simctl list devices available

xcodebuild build \
  -project YamiboX.xcodeproj \
  -scheme YamiboX-Local \
  -destination 'platform=iOS Simulator,id=<SIMULATOR_UDID>'
```

也可使用 Xcode 開啟專案，選擇 `YamiboX-Local` 和 iOS 模擬器。執行前依[測試 App 啟動參數](docs/tests/launch-arguments.md)準備本機論壇；預設位址為 `http://127.0.0.1:8088`，每次啟動都須透過參數傳入。

> 安裝到模擬器的建置須保留簽章，確保 Keychain 正常運作；`CODE_SIGNING_ALLOWED=NO` 僅用於不安裝執行的編譯檢查。

### 驗證

架構邊界檢查：

```bash
bash scripts/check-architecture.sh
```

CI 執行架構檢查和模擬器編譯，設定見 [Swift 工作流程](.github/workflows/swift.yml)。

## 授權與致謝

本專案依據 [GNU AGPL-3.0](./LICENSE) 發布。

第三方相依套件和相關專案以其原作者或原專案的授權聲明為準。

感謝以下專案的原作者與貢獻者，Yamibo X 的功能設計參考了其中的相關實作：

- [prprbell/YamiboReaderPro](https://github.com/prprbell/YamiboReaderPro)
- [flben233/YamiboReader](https://github.com/flben233/YamiboReader)
- [LittleSurvival/yamibo-app](https://github.com/LittleSurvival/yamibo-app)
- [KrelinnBios/YamiboReaderLite](https://github.com/KrelinnBios/YamiboReaderLite)

## 回饋與貢獻

歡迎透過 [GitHub Issue](https://github.com/Arkalin/YamiboX/issues) 提交使用問題、相容性問題、功能建議或其他改善建議。
