繼續開發 Matrix ClimbMill → Apple Watch / HealthKit 整合 App。

已完成的實機驗證

健身房有多台相同型號或相同系列的 Matrix ClimbMill，每台 BLE 裝置名稱不同，因此不得將特定 BLE device name 寫死在程式中。

目前已驗證其中一台實機：

CTM774D2605K00186

此名稱只作為測試範例，不代表唯一支援設備。

主控台：

* Matrix TOUCH BASE-C
* BLE / FTMS 可正常連線

已用 nRF Connect 實測確認：

* Fitness Machine Service：0x1826
* Fitness Machine Feature：0x2ACC
* Step Climber Data：0x2ACF
* Fitness Machine Status：0x2ADA
* 0x2ACF 支援 Notify 並持續提供即時資料
* 實測 Flags：0x01FE

已確認 0x2ACF 可取得：

* Floors
* Step Count
* Current Steps per Minute
* Average Step Rate
* Positive Elevation Gain
* Total Energy
* Energy per Hour
* Energy per Minute
* Heart Rate
* MET
* Elapsed Time
* Remaining Time

BLE 裝置探索需求

App 不得依賴固定裝置名稱，例如：

CTM774D2605K00186

健身房內可能同時存在：

CTM774D2605K00186
CTM774D2605K00208
CTM774xxxxxxxxxxx
...

而且未來可能遇到其他同樣實作標準 FTMS Step Climber 的 Matrix 裝置。

裝置探索應以 BLE capability 為核心，而不是完整 device name。

優先判定條件：

1. 掃描附近 BLE peripherals。
2. 優先辨識 advertising data 中包含 Fitness Machine Service 0x1826 的裝置。
3. Matrix 的 CTM774... local name 可以作為 UI 顯示及輔助篩選條件，但不能作為唯一相容性條件。
4. 如果裝置 advertising packet 未宣告 0x1826，仍應允許透過 local name 等方式列為候選，再於連線後做正式 capability discovery。
5. 連線後 discover services。
6. 必須確認存在 Fitness Machine Service 0x1826。
7. 必須確認其中存在 Step Climber Data characteristic 0x2ACF 且具有 Notify capability。
8. 通過上述驗證後才標記為「相容樓梯機」。

不要把目前實測的 peripheral name 當作程式常數。

多台樓梯機 UX

附近可能同時有多台相容 Matrix ClimbMill。

App 應顯示裝置選擇列表，例如：

Matrix ClimbMill
CTM774D2605K00186     RSSI -42 dBm
CTM774D2605K00208     RSSI -61 dBm
CTM774D2605K00417     RSSI -78 dBm

RSSI 只用來協助判斷距離，不可直接自動假設訊號最強的一台就是使用者正在使用的機器。

預設可將裝置依 RSSI 由強到弱排序，但由使用者明確選擇目標設備。

連線成功後顯示：

* BLE device name
* connection state
* Floors
* SPM
* elapsed time

讓使用者能直接確認選到正確機台。

可以記錄最近一次成功使用的 peripheral identifier 以加速下次連線，但不能假設它永遠有效；重新掃描及 capability verification 必須保留作為 fallback。

FTMS Parser

實作標準 FTMS Step Climber Data 0x2ACF parser。

不得假設所有封包永遠固定為目前實測的 0x01FE。

必須：

1. 先解析 little-endian Flags。
2. 依 Flags 決定後續欄位是否存在。
3. 動態前進 byte offset。
4. 做完整長度檢查，禁止越界解析。
5. 對 malformed packet 做安全處理。
6. 將解析後資料轉換成明確 Swift model。

例如：

struct StepClimberMetrics {
    var floors: UInt16?
    var stepCount: UInt16?
    var stepsPerMinute: UInt16?
    var averageStepRate: UInt16?
    var positiveElevationGainMeters: Double?
    var totalEnergyKcal: UInt16?
    var energyPerHourKcal: UInt16?
    var energyPerMinuteKcal: UInt8?
    var heartRateBPM: UInt8?
    var metabolicEquivalent: Double?
    var elapsedTimeSeconds: UInt16?
    var remainingTimeSeconds: UInt16?
}

實作時依 Bluetooth FTMS 正式規格確認每個欄位的型別、解析順序與 resolution，不依靠單一測試封包猜測。

App 整體目標

iPhone

使用 CoreBluetooth：

Matrix ClimbMill
        │
        │ Bluetooth FTMS
        ▼
     iPhone App
        │
        ├─ Device Discovery
        ├─ Connection Management
        ├─ FTMS 0x2ACF Parser
        ├─ Floors
        ├─ Step Count
        ├─ SPM
        ├─ Elevation
        ├─ Matrix Energy
        └─ Workout UI

Apple Watch

Apple Watch 啟動：

HKWorkoutSession
activityType = .stairClimbing
locationType = .indoor

使用：

* HKWorkoutSession
* HKLiveWorkoutBuilder
* HKLiveWorkoutDataSource

Apple Watch / HealthKit 負責：

* Heart Rate
* Active Energy
* 其他 Apple Watch 人體感測資料

Matrix 負責：

* Floors
* Step Count
* Current SPM
* Average SPM
* Positive Elevation Gain
* Machine workout time

Matrix 回報的 kcal 保留供比較與除錯，不要覆蓋 Apple Watch / HealthKit 的 Active Energy。

iPhone / Apple Watch 資料同步

使用 Apple 官方 multi-device workout / workout mirroring API。

架構：

Matrix FTMS
    │
    ▼
iPhone
    │
    │ FTMS metrics
    ▼
Mirrored Workout Session
    │
    ▼
Apple Watch
    │
    ├─ Apple Watch HR
    ├─ Apple Active Energy
    └─ Matrix workout metrics
    │
    ▼
HealthKit

不要自己設計不必要的 socket protocol。

HealthKit 最終輸出

最終只建立一筆：

HKWorkoutActivityType.stairClimbing

的 workout。

目標寫入：

* Workout duration
* Heart Rate
* Active Energy
* Flights Climbed
* Elevation Ascended

資料來源：

Workout Type       → App / HealthKit
Heart Rate         → Apple Watch
Active Energy      → Apple Watch / HealthKit
Flights Climbed    → Matrix FTMS Floors
Elevation Ascended → Matrix FTMS Positive Elevation Gain
SPM                → Matrix FTMS
Step Count         → Matrix FTMS

SPM 與 Matrix Step Count 若沒有合適的標準 HealthKit quantity type，完整保存在 App 自己的 workout record，不要硬塞進不相關的 HealthKit 欄位。

資料一致性

Matrix 的 Floors 是設備計算值。

不要自行用：

stepCount / 固定 stepsPerFloor

取代 Matrix Floors。

Matrix 已直接提供 Positive Elevation Gain 時，也優先使用設備資料，不再由樓層數反推高度。

保留原始 FTMS metrics，以便後續比對：

Matrix Floors
Matrix Steps
Matrix SPM
Matrix Elevation
Matrix kcal
Apple Watch kcal
Apple Watch HR

MVP

第一版優先完成：

1. iPhone CoreBluetooth 掃描。
2. 列出附近可能的 Matrix / FTMS fitness machines。
3. 使用者選擇其中一台。
4. 連線。
5. 驗證 0x1826。
6. 驗證 0x2ACF。
7. Enable Notify。
8. 正確解析 Flags 與 Step Climber Data。
9. 即時顯示：
    * Floors
    * Steps
    * SPM
    * Elevation
    * Matrix kcal
    * Elapsed Time
10. Apple Watch .stairClimbing workout。
11. 即時取得 Apple Watch Heart Rate 與 Active Energy。
12. iPhone / Watch workout synchronization。
13. Workout 結束後產生單一 HealthKit workout。
14. 驗證 Apple Fitness / Health 中資料沒有重複紀錄。

優先做可以直接在實體 iPhone + Apple Watch + Matrix ClimbMill 上執行的最小可用版本。

不要重新討論可行性。

直接建立 Xcode 專案架構、Swift models、CoreBluetooth manager、FTMS parser、HealthKit workout manager 與第一版可執行程式碼。