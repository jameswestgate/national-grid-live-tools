//
//  main.swift
//  national grid live tools — Backfill snapshot generator
//
//  Aggregates historical UK grid data from the open APIs the app uses
//  (Elexon FUELINST + market-index, Carbon Intensity, NESO embedded) into a
//  hosted snapshot.json (`year` = daily, `allTime` = monthly).
//
//  Designed to run incrementally on GitHub Actions: it keeps a persistent
//  `data/daily.csv` (+ `data/monthly.csv`) in the repo, and each daily run
//  fetches only the new day(s) and appends — so a run is seconds, not 365 MB.
//
//  Modes (env MODE):
//    daily      (default) append missing days up to yesterday (capped), roll up
//               the previous completed month, rewrite outputs.
//    bootstrap  seed daily.csv across the last 365 days (sampled at STEP_DAYS)
//               and monthly.csv from 2018-06 (one sample day/month).
//  Env: DATA_DIR (default "data"), OUT_DIR (default "public/v1"),
//       STEP_DAYS (bootstrap year spacing, default 5), ALLTIME (bootstrap, 0/1),
//       MAX_CATCHUP (daily, default 14).
//
//  Run locally:  swift "national grid live tools/main.swift"
//

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking   // Linux: URLSession lives here
#endif

func logErr(_ s: String) { FileHandle.standardError.write((s + "\n").data(using: .utf8)!) }

// MARK: - App-matching models (encode identically to the app's Snapshot.decoder)

enum FuelType: String, CaseIterable, Codable { case gas, coal, wind, solar, hydro, nuclear, biomass, pumped }
enum Interconnector: String, CaseIterable, Codable { case france, norway, belgium, denmark, ireland, netherlands }
enum Granularity: String, Codable { case halfHour, hour, day, month }

struct TimeSeries: Codable {
    let from: String; let to: String; let granularity: Granularity; let dates: [String]
    let price: [Double?]; let emissions: [Double?]; let demand: [Double?]
    let generation: [Double?]; let transfers: [Double?]
    let fuels: [FuelType: [Double?]]; let interconnectors: [Interconnector: [Double?]]
}
struct Snapshot: Codable {
    let schemaVersion: Int; let generated: Date; let sources: SourceAttributions
    let year: TimeSeries; let allTime: TimeSeries
    struct SourceAttributions: Codable { let elexon: String; let carbonIntensity: String; let neso: String }
}

// MARK: - Time helpers (UTC)

let utc = TimeZone(identifier: "UTC")!
let calendar: Calendar = { var c = Calendar(identifier: .iso8601); c.timeZone = utc; return c }()
func fmtDate(_ d: Date, _ pattern: String) -> String {
    let f = DateFormatter(); f.calendar = calendar; f.locale = Locale(identifier: "en_US_POSIX")
    f.timeZone = utc; f.dateFormat = pattern; return f.string(from: d)
}
func isoZ(_ d: Date) -> String { fmtDate(d, "yyyy-MM-dd'T'HH:mm:ss'Z'") }
func dayString(_ d: Date) -> String { fmtDate(d, "yyyy-MM-dd") }
func monthString(_ d: Date) -> String { fmtDate(d, "yyyy-MM") }
func parseDay(_ s: String) -> Date? {
    let f = DateFormatter(); f.timeZone = utc; f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd"
    return f.date(from: s)
}

// MARK: - Cached synchronous fetch

let cacheDir = "/tmp/nglsim/bf-cache"
try? FileManager.default.createDirectory(atPath: cacheDir, withIntermediateDirectories: true)
func cacheKey(_ url: String) -> String {
    cacheDir + "/" + String(url.replacingOccurrences(of: "[^A-Za-z0-9]", with: "_", options: .regularExpression).suffix(180))
}
func fetch(_ urlStr: String) -> Data? {
    let key = cacheKey(urlStr)
    if let d = FileManager.default.contents(atPath: key), d.count > 0 { return d }
    guard let url = URL(string: urlStr) else { return nil }
    var result: Data?
    let sem = DispatchSemaphore(value: 0)
    var req = URLRequest(url: url); req.timeoutInterval = 90
    URLSession.shared.dataTask(with: req) { data, resp, _ in
        if let data = data, let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) { result = data }
        sem.signal()
    }.resume()
    sem.wait()
    if let r = result { try? r.write(to: URL(fileURLWithPath: key)) }
    return result
}
func mean(_ xs: [Double]) -> Double? { xs.isEmpty ? nil : xs.reduce(0,+) / Double(xs.count) }

// MARK: - NESO embedded wind/solar (historic demand data, half-hourly, MW)

let nesoResources: [Int: String] = [
    2016:"3bb75a28-ab44-4a0b-9b1c-9be9715d3c44", 2017:"2f0f75b8-39c5-46ff-a914-ae38088ed022",
    2018:"fcb12133-0db0-4f27-a4a5-1669fd9f6d33", 2019:"dd9de980-d724-415a-b344-d8ae11321432",
    2020:"33ba6857-2a55-479f-9308-e5c4c53d4381", 2021:"18c69c42-f20d-46f0-84e9-e279045befc6",
    2022:"bb44a1b5-75b1-4db2-8491-257f23385006", 2023:"bf5ab335-9b40-4ea4-b93a-ab4af7bce003",
    2024:"f6d02c0f-957b-48cb-82ee-09003f2ba759", 2025:"b2bde559-3455-4021-b179-dfe60c0337b0",
    2026:"8a4a771c-3929-4e56-93ad-cdf13219dea5"
]
var embeddedByDate: [String: (wind: Double, solar: Double)] = [:]
var loadedYears = Set<Int>()
func loadEmbedded(year: Int) {
    guard !loadedYears.contains(year), let res = nesoResources[year] else { return }
    loadedYears.insert(year)
    guard let d = fetch("https://api.neso.energy/datastore/dump/\(res)"),
          let csv = String(data: d, encoding: .utf8) else { return }
    let lines = csv.split(separator: "\n", omittingEmptySubsequences: true)
    func cells(_ s: Substring) -> [String] {
        s.split(separator: ",", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "\"\r ")) }
    }
    guard let header = lines.first.map(cells),
          let iDate = header.firstIndex(of: "SETTLEMENT_DATE"),
          let iWind = header.firstIndex(of: "EMBEDDED_WIND_GENERATION"),
          let iSolar = header.firstIndex(of: "EMBEDDED_SOLAR_GENERATION") else { return }
    var sums: [String: (w: Double, s: Double, n: Double)] = [:]
    for line in lines.dropFirst() {
        let c = cells(line)
        guard c.count > max(iDate, iWind, iSolar), let w = Double(c[iWind]), let s = Double(c[iSolar]) else { continue }
        let date = String(c[iDate].prefix(10))
        var cur = sums[date] ?? (0,0,0); cur.w += w; cur.s += s; cur.n += 1; sums[date] = cur
    }
    for (date, v) in sums where v.n > 0 { embeddedByDate[date] = (v.w/v.n/1000.0, v.s/v.n/1000.0) }
}
func embedded(for day: Date) -> (wind: Double, solar: Double) {
    loadEmbedded(year: calendar.component(.year, from: day)); return embeddedByDate[dayString(day)] ?? (0,0)
}

// MARK: - Per-day aggregation

struct DayAgg {
    var fuels: [FuelType: Double] = [:]; var ics: [Interconnector: Double] = [:]
    var price: Double?; var emissions: Double?
    var generation = 0.0; var transfers = 0.0; var demand = 0.0
}
func aggregateDay(_ day: Date) -> DayAgg? {
    let from = calendar.startOfDay(for: day), to = calendar.date(byAdding: .day, value: 1, to: from)!
    let fuelURL = "https://data.elexon.co.uk/bmrs/api/v1/datasets/FUELINST/stream?publishDateTimeFrom=\(isoZ(from))&publishDateTimeTo=\(isoZ(to))"
    guard let fd = fetch(fuelURL),
          let arr = try? JSONSerialization.jsonObject(with: fd) as? [[String: Any]], !arr.isEmpty else { return nil }
    var perCode: [String: Double] = [:]; var slots = Set<String>()
    for item in arr {
        guard let code = item["fuelType"] as? String, let g = item["generation"] as? Int, let st = item["startTime"] as? String else { continue }
        slots.insert(st); perCode[code, default: 0] += Double(g)
    }
    let n = Double(max(slots.count, 1))
    func gw(_ code: String) -> Double { (perCode[code] ?? 0) / n / 1000.0 }
    var agg = DayAgg()
    for (f, codes) in [(FuelType.gas, ["CCGT","OCGT","OIL"]), (.coal, ["COAL"]), (.nuclear, ["NUCLEAR"]),
                       (.biomass, ["BIOMASS"]), (.hydro, ["NPSHYD"]), (.pumped, ["PS"])] {
        agg.fuels[f] = codes.reduce(0.0) { $0 + gw($1) }
    }
    for (ic, codes) in [(Interconnector.france, ["INTFR","INTIFA2","INTELEC"]), (.ireland, ["INTIRL","INTEW","INTGRNL"]),
                        (.netherlands, ["INTNED"]), (.belgium, ["INTNEM"]), (.norway, ["INTNSL"]), (.denmark, ["INTVKL"])] {
        agg.ics[ic] = codes.reduce(0.0) { $0 + gw($1) }
    }
    // wind = transmission (FUELINST) + embedded (NESO); solar = embedded (NESO)
    let emb = embedded(for: day)
    agg.fuels[.wind] = gw("WIND") + emb.wind
    agg.fuels[.solar] = emb.solar
    agg.generation = FuelType.allCases.reduce(0.0) { $0 + (agg.fuels[$1] ?? 0) }
    agg.transfers = Interconnector.allCases.reduce(0.0) { $0 + (agg.ics[$1] ?? 0) }
    agg.demand = agg.generation + agg.transfers
    if let cd = fetch("https://api.carbonintensity.org.uk/intensity/\(isoZ(from))/\(isoZ(to))"),
       let obj = try? JSONSerialization.jsonObject(with: cd) as? [String: Any], let data = obj["data"] as? [[String: Any]] {
        agg.emissions = mean(data.compactMap { ($0["intensity"] as? [String: Any]).flatMap { ($0["actual"] as? Int) ?? ($0["forecast"] as? Int) }.map(Double.init) })
    }
    if let pd = fetch("https://data.elexon.co.uk/bmrs/api/v1/balancing/pricing/market-index?from=\(isoZ(from))&to=\(isoZ(to))&dataProviders=APXMIDP"),
       let obj = try? JSONSerialization.jsonObject(with: pd) as? [String: Any], let data = obj["data"] as? [[String: Any]] {
        agg.price = mean(data.compactMap { $0["price"] as? Double })
    }
    return agg
}

// MARK: - CSV persistence

let valueColumns = ["price","emissions","demand","generation","transfers"]
    + FuelType.allCases.map { $0.rawValue } + Interconnector.allCases.map { $0.rawValue }
func aggValue(_ a: DayAgg, _ col: String) -> Double? {
    switch col {
    case "price": return a.price; case "emissions": return a.emissions; case "demand": return a.demand
    case "generation": return a.generation; case "transfers": return a.transfers
    default:
        if let f = FuelType(rawValue: col) { return a.fuels[f] }
        if let ic = Interconnector(rawValue: col) { return a.ics[ic] }
        return nil
    }
}
typealias Row = (date: String, vals: [String: Double?])
func rowFromAgg(_ date: String, _ a: DayAgg) -> Row {
    var v: [String: Double?] = [:]; for c in valueColumns { v[c] = aggValue(a, c) }; return (date, v)
}
func loadCSV(_ path: String) -> [Row] {
    guard let s = try? String(contentsOfFile: path, encoding: .utf8) else { return [] }
    let lines = s.split(separator: "\n").map(String.init)
    guard let header = lines.first?.split(separator: ",", omittingEmptySubsequences: false).map(String.init) else { return [] }
    return lines.dropFirst().compactMap { line in
        let c = line.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
        guard c.count == header.count else { return nil }
        var v: [String: Double?] = [:]
        for (i, col) in header.enumerated() where i > 0 { v[col] = c[i].isEmpty ? nil : Double(c[i]) }
        return (c[0], v)
    }
}
func saveCSV(_ path: String, _ rows: [Row]) {
    var out = (["date"] + valueColumns).joined(separator: ",") + "\n"
    for r in rows { out += ([r.date] + valueColumns.map { (r.vals[$0] ?? nil).map { String(format: "%.3f", $0) } ?? "" }).joined(separator: ",") + "\n" }
    try? FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
    try? out.write(toFile: path, atomically: true, encoding: .utf8)
}

// MARK: - Snapshot assembly + outputs

func timeSeries(_ rows: [Row], _ g: Granularity) -> TimeSeries {
    func round3(_ v: Double?) -> Double? { v.map { ($0 * 1000).rounded() / 1000 } }
    func arr(_ c: String) -> [Double?] { rows.map { round3($0.vals[c] ?? nil) } }
    var fuels: [FuelType: [Double?]] = [:]; for f in FuelType.allCases { fuels[f] = arr(f.rawValue) }
    var ics: [Interconnector: [Double?]] = [:]; for ic in Interconnector.allCases { ics[ic] = arr(ic.rawValue) }
    return TimeSeries(from: rows.first?.date ?? "", to: rows.last?.date ?? "", granularity: g, dates: rows.map { $0.date },
                      price: arr("price"), emissions: arr("emissions"), demand: arr("demand"),
                      generation: arr("generation"), transfers: arr("transfers"), fuels: fuels, interconnectors: ics)
}
func writeOutputs(daily: [Row], monthly: [Row], outDir: String) {
    let snap = Snapshot(schemaVersion: 1, generated: Date(),
        sources: .init(
            elexon: "Contains BMRS data © Elexon Limited copyright and database right 2026.",
            carbonIntensity: "Carbon intensity data © National Grid ESO and Oxford CS, used under CC BY 4.0.",
            neso: "Contains NESO Data Portal data, used under the NESO Open Licence."),
        year: timeSeries(Array(daily.suffix(365)), .day), allTime: timeSeries(monthly, .month))
    let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601; enc.outputFormatting = [.sortedKeys]
    try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)
    if let d = try? enc.encode(snap) { try? d.write(to: URL(fileURLWithPath: outDir + "/snapshot.json")); logErr("wrote \(outDir)/snapshot.json (\(d.count) B)") }
    try? "{\"schemaVersion\":1,\"generated\":\"\(isoZ(Date()))\"}\n".write(toFile: outDir + "/manifest.json", atomically: true, encoding: .utf8)
}

// MARK: - Main

let env = ProcessInfo.processInfo.environment
let mode = env["MODE"] ?? "daily"
let dataDir = env["DATA_DIR"] ?? "data"
let outDir = env["OUT_DIR"] ?? "public/v1"
let dailyPath = dataDir + "/daily.csv", monthlyPath = dataDir + "/monthly.csv"
let today = calendar.startOfDay(for: Date())
let yesterday = calendar.date(byAdding: .day, value: -1, to: today)!

if mode == "bootstrap" {
    let step = Int(env["STEP_DAYS"] ?? "5") ?? 5
    var daily: [Row] = []
    var d = calendar.date(byAdding: .day, value: -360, to: today)!
    while d <= yesterday { logErr("daily seed \(dayString(d))"); if let a = aggregateDay(d) { daily.append(rowFromAgg(dayString(d), a)) }; d = calendar.date(byAdding: .day, value: step, to: d)! }
    saveCSV(dailyPath, daily)
    var monthly: [Row] = []
    if (env["ALLTIME"] ?? "1") == "1" {
        let firstThisMonth = calendar.date(from: calendar.dateComponents([.year,.month], from: today))!
        var cur = calendar.date(from: DateComponents(year: 2018, month: 6, day: 15))!
        while cur < firstThisMonth { logErr("monthly seed \(monthString(cur))"); if let a = aggregateDay(cur) { monthly.append(rowFromAgg(monthString(cur), a)) }; cur = calendar.date(byAdding: .month, value: 1, to: cur)! }
    }
    saveCSV(monthlyPath, monthly)
    writeOutputs(daily: daily, monthly: monthly, outDir: outDir)
    logErr("bootstrap complete: \(daily.count) daily, \(monthly.count) monthly")
} else {
    var daily = loadCSV(dailyPath)
    let maxCatchup = Int(env["MAX_CATCHUP"] ?? "14") ?? 14
    var start = daily.last.flatMap { parseDay($0.date) }.map { calendar.date(byAdding: .day, value: 1, to: $0)! }
        ?? calendar.date(byAdding: .day, value: -maxCatchup, to: today)!
    if let earliest = calendar.date(byAdding: .day, value: -maxCatchup, to: yesterday), start < earliest { start = earliest }
    var appended = 0, d = start
    while d <= yesterday && appended < maxCatchup { logErr("daily append \(dayString(d))"); if let a = aggregateDay(d) { daily.append(rowFromAgg(dayString(d), a)); appended += 1 }; d = calendar.date(byAdding: .day, value: 1, to: d)! }
    daily = Array(daily.suffix(400))
    saveCSV(dailyPath, daily)
    // Roll up the previous completed month from full-resolution daily data.
    var monthly = loadCSV(monthlyPath)
    let prevKey = monthString(calendar.date(byAdding: .month, value: -1, to: today)!)
    if !monthly.contains(where: { $0.date == prevKey }) {
        let daysIn = daily.filter { $0.date.hasPrefix(prevKey) }
        if daysIn.count >= 20 {
            var v: [String: Double?] = [:]
            for col in valueColumns { let xs = daysIn.compactMap { $0.vals[col] ?? nil }; v[col] = xs.isEmpty ? nil : xs.reduce(0,+)/Double(xs.count) }
            monthly.append((prevKey, v)); monthly.sort { $0.date < $1.date }; saveCSV(monthlyPath, monthly)
            logErr("rolled up month \(prevKey)")
        }
    }
    writeOutputs(daily: daily, monthly: monthly, outDir: outDir)
    logErr("daily complete: appended \(appended) day(s); \(daily.count) daily rows, \(monthly.count) monthly rows")
}
