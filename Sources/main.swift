// ClaudeUsage — macOS menu-bar widget showing your REAL Claude plan usage, like a battery.
//
// Reads Claude's own usage endpoint (https://api.anthropic.com/api/oauth/usage) using your
// Claude Code OAuth token from the macOS Keychain — the same numbers `/usage` shows. Refreshes
// the token automatically (exactly as Claude Code does) and only writes a refreshed token back
// to the Keychain on success, so a failed refresh can never corrupt your login.
//
// Run with `--once` to print a one-shot text report and exit (useful for verifying in a terminal).

import Cocoa

// MARK: - Config

let KC_SERVICE = "Claude Code-credentials"
let CLIENT_ID  = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"            // Claude Code public OAuth client
let TOKEN_URL  = "https://platform.claude.com/v1/oauth/token"
let USAGE_URL  = "https://api.anthropic.com/api/oauth/usage"
let BETA       = "oauth-2025-04-20"

// MARK: - Keychain (via /usr/bin/security)

func security(_ args: [String]) -> (code: Int32, out: String) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/security")
    p.arguments = args
    let out = Pipe(); p.standardOutput = out; p.standardError = Pipe()
    do { try p.run() } catch { return (-1, "") }
    p.waitUntilExit()
    let d = out.fileHandleForReading.readDataToEndOfFile()
    return (p.terminationStatus, String(data: d, encoding: .utf8) ?? "")
}

struct Token { var access: String; var expiresAt: Double; var refresh: String; var blob: [String: Any] }

func readToken() -> Token? {
    let r = security(["find-generic-password", "-s", KC_SERVICE, "-w"])
    guard r.code == 0,
          let data = r.out.trimmingCharacters(in: .whitespacesAndNewlines).data(using: .utf8),
          let blob = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let o = blob["claudeAiOauth"] as? [String: Any],
          let at = o["accessToken"] as? String else { return nil }
    let exp = (o["expiresAt"] as? NSNumber)?.doubleValue ?? 0
    let rt = (o["refreshToken"] as? String) ?? ""
    return Token(access: at, expiresAt: exp, refresh: rt, blob: blob)
}

func writeToken(_ blob: [String: Any]) {
    guard let data = try? JSONSerialization.data(withJSONObject: blob),
          let json = String(data: data, encoding: .utf8) else { return }
    _ = security(["add-generic-password", "-U", "-s", KC_SERVICE, "-a", NSUserName(), "-w", json])
}

// MARK: - HTTP (synchronous; always called off the main thread)

func httpSync(_ req: URLRequest) -> (status: Int, data: Data)? {
    let sem = DispatchSemaphore(value: 0)
    var result: (Int, Data)?
    URLSession.shared.dataTask(with: req) { d, resp, _ in
        if let h = resp as? HTTPURLResponse { result = (h.statusCode, d ?? Data()) }
        sem.signal()
    }.resume()
    _ = sem.wait(timeout: .now() + 15)
    return result
}

/// Refresh the OAuth token. Writes the rotated token back to the Keychain ONLY on success.
func refresh(_ tok: Token) -> String? {
    guard !tok.refresh.isEmpty, let url = URL(string: TOKEN_URL) else { return nil }
    var cs = CharacterSet.urlQueryAllowed; cs.remove(charactersIn: "+&=")
    let ert = tok.refresh.addingPercentEncoding(withAllowedCharacters: cs) ?? tok.refresh
    var req = URLRequest(url: url); req.httpMethod = "POST"
    req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
    req.setValue(BETA, forHTTPHeaderField: "anthropic-beta")
    req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
    req.httpBody = "grant_type=refresh_token&refresh_token=\(ert)&client_id=\(CLIENT_ID)".data(using: .utf8)
    guard let r = httpSync(req), r.status == 200,
          let o = try? JSONSerialization.jsonObject(with: r.data) as? [String: Any],
          let access = (o["access_token"] as? String) ?? (o["accessToken"] as? String) else { return nil }
    let newRt = (o["refresh_token"] as? String) ?? (o["refreshToken"] as? String) ?? tok.refresh
    let expIn = (o["expires_in"] as? NSNumber)?.doubleValue ?? 3600
    var blob = tok.blob
    if var c = blob["claudeAiOauth"] as? [String: Any] {
        c["accessToken"] = access
        c["refreshToken"] = newRt
        c["expiresAt"] = Date().timeIntervalSince1970 * 1000 + expIn * 1000
        blob["claudeAiOauth"] = c
        writeToken(blob)
    }
    return access
}

// MARK: - Usage model + fetch

struct Gauge { var pct: Double; var resets: Date? }
struct Usage {
    var fiveHour: Gauge?, sevenDay: Gauge?, sonnet: Gauge?
    var creditsUsed: Double?, creditsLimit: Double?, creditsPct: Double?, currency = ""
}
enum Fetch { case ok(Usage), needsLogin, error(String) }

func parseISO(_ s: String?) -> Date? {
    guard let s = s else { return nil }
    let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let d = f.date(from: s) { return d }
    let g = ISO8601DateFormatter(); return g.date(from: s)
}

func gauge(_ o: [String: Any], _ key: String) -> Gauge? {
    guard let g = o[key] as? [String: Any], let u = (g["utilization"] as? NSNumber)?.doubleValue else { return nil }
    return Gauge(pct: u, resets: parseISO(g["resets_at"] as? String))
}

func parseUsage(_ o: [String: Any]) -> Usage {
    var u = Usage(fiveHour: gauge(o, "five_hour"), sevenDay: gauge(o, "seven_day"), sonnet: gauge(o, "seven_day_sonnet"))
    if let e = o["extra_usage"] as? [String: Any], (e["is_enabled"] as? Bool) == true {
        u.creditsUsed  = ((e["used_credits"] as? NSNumber)?.doubleValue ?? 0) / 100
        u.creditsLimit = ((e["monthly_limit"] as? NSNumber)?.doubleValue ?? 0) / 100
        u.creditsPct   = (e["utilization"] as? NSNumber)?.doubleValue
        u.currency     = (e["currency"] as? String) ?? ""
    }
    return u
}

func usageRequest(_ access: String) -> URLRequest {
    var req = URLRequest(url: URL(string: USAGE_URL)!)
    req.setValue("Bearer \(access)", forHTTPHeaderField: "Authorization")
    req.setValue(BETA, forHTTPHeaderField: "anthropic-beta")
    req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
    req.setValue("claude-cli/2.0.0 (external)", forHTTPHeaderField: "User-Agent")
    return req
}

func fetchUsage() -> Fetch {
    guard let tok = readToken() else { return .needsLogin }
    var access = tok.access
    let now = Date().timeIntervalSince1970 * 1000
    if tok.expiresAt <= now + 60_000 {                 // expired or about to → refresh first
        guard let na = refresh(tok) else { return .needsLogin }
        access = na
    }
    guard var r = httpSync(usageRequest(access)) else { return .error("no response") }
    if r.status == 401 {                                // token rejected → one refresh retry
        guard let na = refresh(tok), let r2 = httpSync(usageRequest(na)) else { return .needsLogin }
        r = r2
    }
    guard r.status == 200, let o = try? JSONSerialization.jsonObject(with: r.data) as? [String: Any]
    else { return .error("HTTP \(r.status)") }
    return .ok(parseUsage(o))
}

// MARK: - Formatting

func pctInt(_ d: Double) -> Int { Int(d.rounded()) }

func currencySymbol(_ c: String) -> String {
    switch c.uppercased() { case "EUR": return "€"; case "USD": return "$"; case "GBP": return "£"; default: return c.isEmpty ? "" : c + " " }
}

func textBar(_ frac: Double, width: Int = 10) -> String {
    let filled = max(0, min(width, Int((frac * Double(width)).rounded())))
    return String(repeating: "\u{2588}", count: filled) + String(repeating: "\u{2591}", count: width - filled)
}

func resetText(_ d: Date?, now: Date) -> String {
    guard let d = d else { return "" }
    let secs = Int(d.timeIntervalSince(now)); if secs <= 0 { return "now" }
    let h = secs / 3600, m = (secs % 3600) / 60
    let df = DateFormatter(); df.dateFormat = "HH:mm"
    return h > 0 ? "\(h)h\(m)m → \(df.string(from: d))" : "\(m)m → \(df.string(from: d))"
}

// MARK: - Battery icon

/// A row of rounded segments that fill left→right with the usage fraction (Claude "pixel" look).
func segmentImage(frac: Double, color: NSColor, segments: Int = 5) -> NSImage {
    let sw: CGFloat = 4, sh: CGFloat = 9, gap: CGFloat = 2.5, r: CGFloat = 1.2, h: CGFloat = 14
    let total = CGFloat(segments) * sw + CGFloat(segments - 1) * gap
    let img = NSImage(size: NSSize(width: total, height: h), flipped: false) { _ in
        // any nonzero usage lights at least one segment, so it never looks "off"
        let filled = frac <= 0 ? 0 : max(1, min(segments, Int((Double(segments) * frac).rounded())))
        let y = (h - sh) / 2
        for i in 0..<segments {
            let rect = NSRect(x: CGFloat(i) * (sw + gap), y: y, width: sw, height: sh)
            (i < filled ? color : NSColor.labelColor.withAlphaComponent(0.28)).setFill()
            NSBezierPath(roundedRect: rect, xRadius: r, yRadius: r).fill()
        }
        return true
    }
    img.isTemplate = false
    return img
}

/// Two inline segment meters on one line:  [5h dots] 40%   [7d dots] 9%
/// Unlit segments are hollow outlines so a low reading still looks like a full meter.
/// Numbers are drawn in the menu-bar text color (white on dark menu bar, black on light).
func dualBarImage(p5: Double, p7: Double, dark: Bool) -> NSImage {
    let segs = 5
    let sw: CGFloat = 3.5, sh: CGFloat = 8, gap: CGFloat = 2, rr: CGFloat = 1, h: CGFloat = 16
    let barW = CGFloat(segs) * sw + CGFloat(segs - 1) * gap
    let textColor: NSColor = dark ? .white : .black
    let font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium)
    let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: textColor]
    let t5 = "\(Int(p5.rounded()))%" as NSString, t7 = "\(Int(p7.rounded()))%" as NSString
    let s5 = t5.size(withAttributes: attrs), s7 = t7.size(withAttributes: attrs)
    let numGap: CGFloat = 3, grpGap: CGFloat = 8
    let totalW = barW + numGap + s5.width + grpGap + barW + numGap + s7.width
    let img = NSImage(size: NSSize(width: ceil(totalW) + 1, height: h), flipped: false) { _ in
        var x: CGFloat = 0
        func bar(_ pct: Double) {
            let frac = pct / 100
            let filled = frac <= 0 ? 0 : max(1, min(segs, Int((Double(segs) * frac).rounded())))
            let y = (h - sh) / 2
            for i in 0..<segs {
                let r = NSRect(x: x + CGFloat(i) * (sw + gap), y: y, width: sw, height: sh)
                if i < filled {
                    gaugeColor(frac).setFill()
                    NSBezierPath(roundedRect: r, xRadius: rr, yRadius: rr).fill()
                } else {
                    let p = NSBezierPath(roundedRect: r.insetBy(dx: 0.4, dy: 0.4), xRadius: rr, yRadius: rr)
                    p.lineWidth = 0.8; textColor.withAlphaComponent(0.4).setStroke(); p.stroke()
                }
            }
            x += barW
        }
        func num(_ s: NSString, _ sz: NSSize) {
            s.draw(at: NSPoint(x: x, y: (h - sz.height) / 2), withAttributes: attrs); x += sz.width
        }
        bar(p5); x += numGap; num(t5, s5); x += grpGap
        bar(p7); x += numGap; num(t7, s7)
        return true
    }
    img.isTemplate = false
    return img
}

// Claude clay → deeper rust → dark rust-red as the gauge approaches its limit.
func gaugeColor(_ frac: Double) -> NSColor {
    if frac >= 0.9  { return NSColor(srgbRed: 0.56, green: 0.18, blue: 0.11, alpha: 1) }  // dark rust-red
    if frac >= 0.75 { return NSColor(srgbRed: 0.71, green: 0.31, blue: 0.23, alpha: 1) }  // deep rust
    return NSColor(srgbRed: 0.80, green: 0.47, blue: 0.36, alpha: 1)                      // Claude clay #CC785C
}

// MARK: - One-shot report

func printReport(_ f: Fetch, now: Date) {
    switch f {
    case .needsLogin: print("Not logged in / token can't refresh. Run `claude` then /login.")
    case .error(let e): print("Couldn't fetch usage: \(e)")
    case .ok(let u):
        print("Claude plan usage")
        if let g = u.fiveHour { print(String(format: "5-hour            %@ %3d%%   resets %@", textBar(g.pct/100), pctInt(g.pct), resetText(g.resets, now: now))) }
        if let g = u.sevenDay { print(String(format: "Weekly · all      %@ %3d%%   resets %@", textBar(g.pct/100), pctInt(g.pct), resetText(g.resets, now: now))) }
        if let g = u.sonnet   { print(String(format: "Weekly · Sonnet   %@ %3d%%", textBar(g.pct/100), pctInt(g.pct))) }
        if let used = u.creditsUsed, let lim = u.creditsLimit {
            let s = currencySymbol(u.currency)
            print(String(format: "Extra credits     %@ %3d%%   %@%.2f of %@%.2f", textBar((u.creditsPct ?? 0)/100), pctInt(u.creditsPct ?? 0), s, used, s, lim))
        }
    }
}

// MARK: - App

let launchPlist = ("~/Library/LaunchAgents/com.claudeusagebar.plist" as NSString).expandingTildeInPath
let launchLabel = "com.claudeusagebar"

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    var statusItem: NSStatusItem!
    var latest: Fetch = .error("loading")
    var timer: Timer?
    let mono = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)

    func applicationDidFinishLaunching(_ note: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.imagePosition = .imageLeft
        statusItem.button?.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        let menu = NSMenu(); menu.delegate = self; statusItem.menu = menu
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 120, repeats: true) { [weak self] _ in self?.refresh() }
    }

    func refresh() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let f = fetchUsage()
            DispatchQueue.main.async { self?.latest = f; self?.updateButton() }
        }
    }

    func updateButton() {
        guard let btn = statusItem.button else { return }
        switch latest {
        case .ok(let u):
            let dark = btn.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            btn.image = dualBarImage(p5: u.fiveHour?.pct ?? 0, p7: u.sevenDay?.pct ?? 0, dark: dark)
            btn.title = ""
        case .needsLogin:
            btn.image = segmentImage(frac: 0, color: .systemRed); btn.title = " login"
        case .error:
            btn.image = segmentImage(frac: 0, color: .tertiaryLabelColor); btn.title = " —"
        }
    }

    func menuWillOpen(_ menu: NSMenu) { refresh() }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let now = Date()
        func header(_ t: String) {
            let it = NSMenuItem(title: t, action: nil, keyEquivalent: "")
            it.attributedTitle = NSAttributedString(string: t, attributes: [.font: NSFont.boldSystemFont(ofSize: 12), .foregroundColor: NSColor.secondaryLabelColor])
            it.isEnabled = false; menu.addItem(it)
        }
        func row(_ t: String) {
            let it = NSMenuItem(title: t, action: nil, keyEquivalent: "")
            it.attributedTitle = NSAttributedString(string: t, attributes: [.font: mono]); it.isEnabled = false; menu.addItem(it)
        }
        func plain(_ t: String) {
            let it = NSMenuItem(title: t, action: nil, keyEquivalent: "")
            it.attributedTitle = NSAttributedString(string: t, attributes: [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.secondaryLabelColor])
            it.isEnabled = false; menu.addItem(it)
        }

        header("Claude plan usage")
        switch latest {
        case .ok(let u):
            if let g = u.fiveHour {
                row(String(format: "5-hour    %@ %d%%", textBar(g.pct/100), pctInt(g.pct)))
                if let r = g.resets { row("          resets " + resetText(r, now: now)) }
            }
            if let g = u.sevenDay {
                row(String(format: "Weekly    %@ %d%%  · all models", textBar(g.pct/100), pctInt(g.pct)))
                if let r = g.resets { row("          resets " + resetText(r, now: now)) }
            }
            if let g = u.sonnet {
                row(String(format: "Sonnet    %@ %d%%  · weekly", textBar(g.pct/100), pctInt(g.pct)))
            }
            if let used = u.creditsUsed, let lim = u.creditsLimit {
                let s = currencySymbol(u.currency)
                menu.addItem(.separator())
                row(String(format: "Credits   %@ %d%%", textBar((u.creditsPct ?? 0)/100), pctInt(u.creditsPct ?? 0)))
                row(String(format: "          %@%.2f of %@%.2f used", s, used, s, lim))
            }
        case .needsLogin:
            plain("Claude Code login expired.")
            plain("Run `claude`, then /login — the widget")
            plain("picks up the refreshed token automatically.")
        case .error(let e):
            plain("Couldn't reach the usage endpoint:")
            plain(e)
        }
        menu.addItem(.separator())
        add(menu, "Refresh now", #selector(doRefresh))
        let li = add(menu, "Launch at login", #selector(toggleLogin))
        li.state = FileManager.default.fileExists(atPath: launchPlist) ? .on : .off
        menu.addItem(.separator())
        add(menu, "Quit Claude Usage", #selector(quit))
    }

    @discardableResult func add(_ menu: NSMenu, _ title: String, _ sel: Selector) -> NSMenuItem {
        let it = NSMenuItem(title: title, action: sel, keyEquivalent: ""); it.target = self; menu.addItem(it); return it
    }
    @objc func doRefresh() { refresh() }
    @objc func quit() { NSApp.terminate(nil) }
    @objc func toggleLogin() {
        let fm = FileManager.default
        if fm.fileExists(atPath: launchPlist) {
            _ = run("/bin/launchctl", ["bootout", "gui/\(getuid())/\(launchLabel)"]); try? fm.removeItem(atPath: launchPlist)
        } else {
            let exec = Bundle.main.executablePath ?? CommandLine.arguments[0]
            let plist = """
            <?xml version="1.0" encoding="UTF-8"?>
            <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
            <plist version="1.0"><dict>
              <key>Label</key><string>\(launchLabel)</string>
              <key>ProgramArguments</key><array><string>\(exec)</string></array>
              <key>RunAtLoad</key><true/><key>KeepAlive</key><false/>
            </dict></plist>
            """
            try? fm.createDirectory(atPath: (launchPlist as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            try? plist.write(toFile: launchPlist, atomically: true, encoding: .utf8)
            _ = run("/bin/launchctl", ["bootstrap", "gui/\(getuid())", launchPlist])
        }
    }
    func run(_ p: String, _ a: [String]) -> Int32 {
        let pr = Process(); pr.executableURL = URL(fileURLWithPath: p); pr.arguments = a
        pr.standardError = Pipe(); do { try pr.run() } catch { return -1 }; pr.waitUntilExit(); return pr.terminationStatus
    }
}

// MARK: - Entry point

// `--preview`: render the menu-bar icon at low/mid/high on dark + light chips → PNG, and open it.
// No network or Keychain access — purely a visual test of the icon design.
if CommandLine.arguments.contains("--preview") {
    _ = NSApplication.shared
    let samples: [(String, Double, Double)] = [("low", 8, 5), ("mid", 41, 9), ("high", 78, 55), ("max", 96, 90)]
    let labelW: CGFloat = 40, chipW: CGFloat = 170, gap: CGFloat = 14, rowH: CGFloat = 30, vgap: CGFloat = 8, pad: CGFloat = 14
    let W = pad + labelW + chipW + gap + chipW + pad
    let H = pad * 2 + CGFloat(samples.count) * rowH + CGFloat(samples.count - 1) * vgap
    let out = NSImage(size: NSSize(width: W, height: H))
    out.lockFocus()
    NSColor.white.setFill(); NSRect(x: 0, y: 0, width: W, height: H).fill()
    var y = H - pad - rowH
    for (label, p5, p7) in samples {
        (label as NSString).draw(at: NSPoint(x: pad, y: y + rowH / 2 - 7),
            withAttributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.black])
        let darkRect = NSRect(x: pad + labelW, y: y, width: chipW, height: rowH)
        NSColor(srgbRed: 0.16, green: 0.16, blue: 0.15, alpha: 1).setFill()
        NSBezierPath(roundedRect: darkRect, xRadius: 6, yRadius: 6).fill()
        let di = dualBarImage(p5: p5, p7: p7, dark: true)
        di.draw(at: NSPoint(x: darkRect.minX + 12, y: y + (rowH - di.size.height) / 2), from: .zero, operation: .sourceOver, fraction: 1)
        let lightRect = NSRect(x: darkRect.maxX + gap, y: y, width: chipW, height: rowH)
        NSColor(srgbRed: 0.96, green: 0.95, blue: 0.93, alpha: 1).setFill()
        NSBezierPath(roundedRect: lightRect, xRadius: 6, yRadius: 6).fill()
        let li = dualBarImage(p5: p5, p7: p7, dark: false)
        li.draw(at: NSPoint(x: lightRect.minX + 12, y: y + (rowH - li.size.height) / 2), from: .zero, operation: .sourceOver, fraction: 1)
        y -= rowH + vgap
    }
    out.unlockFocus()
    let path = (NSHomeDirectory() as NSString).appendingPathComponent("Desktop/claude-usage-preview.png")
    if let tiff = out.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
       let png = rep.representation(using: .png, properties: [:]) {
        try? png.write(to: URL(fileURLWithPath: path))
        NSWorkspace.shared.open(URL(fileURLWithPath: path))
        print("Preview saved + opened: \(path)")
    } else { print("Failed to render preview") }
    exit(0)
}

if CommandLine.arguments.contains("--once") {
    printReport(fetchUsage(), now: Date())
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
