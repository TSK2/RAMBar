// RAMBar — 메뉴바에 메모리 압력 점 + 사용률(%)을 띄우는 초경량 앱
// 빌드: ./build.sh  (Xcode 없이 Command Line Tools만 있으면 됨)

import AppKit
import ServiceManagement

// MARK: - 시스템 메모리 읽기

struct MemStats {
    var total: UInt64
    var app: UInt64
    var wired: UInt64
    var compressed: UInt64
    var cached: UInt64
    var swapUsed: UInt64
    var pressure: Int32   // 1 정상, 2 경고, 4 위험

    // 활성 상태 보기(Activity Monitor)의 "사용된 메모리"와 같은 계산
    var used: UInt64 { app + wired + compressed }
    var percent: Int { Int((Double(used) / Double(total) * 100).rounded()) }
}

private let host = mach_host_self()
private let pageSize = UInt64(vm_kernel_page_size)

func readStats() -> MemStats? {
    var vm = vm_statistics64()
    var count = mach_msg_type_number_t(
        MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.stride)
    let kr = withUnsafeMutablePointer(to: &vm) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            host_statistics64(host, HOST_VM_INFO64, $0, &count)
        }
    }
    guard kr == KERN_SUCCESS else { return nil }

    let anon = UInt64(vm.internal_page_count)
    let purgeable = UInt64(vm.purgeable_count)
    let external = UInt64(vm.external_page_count)

    var level: Int32 = 1
    var size = MemoryLayout<Int32>.size
    sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &size, nil, 0)

    var swap = xsw_usage()
    var swapSize = MemoryLayout<xsw_usage>.size
    sysctlbyname("vm.swapusage", &swap, &swapSize, nil, 0)

    return MemStats(
        total: ProcessInfo.processInfo.physicalMemory,
        app: (anon > purgeable ? anon - purgeable : 0) * pageSize,
        wired: UInt64(vm.wire_count) * pageSize,
        compressed: UInt64(vm.compressor_page_count) * pageSize,
        cached: (external + purgeable) * pageSize,
        swapUsed: swap.xsu_used,
        pressure: level
    )
}

func gb(_ bytes: UInt64) -> String {
    String(format: "%.2f GB", Double(bytes) / 1_073_741_824)
}

func mbText(_ bytes: UInt64) -> String {
    let mb = Double(bytes) / 1_048_576
    return mb >= 1024 ? String(format: "%.1f GB", mb / 1024) : String(format: "%.0f MB", mb)
}

// MARK: - 앱별 메모리 / 창 여부

/// 프로세스 하나의 실제 메모리 사용량 (활성 상태 보기의 "메모리" 열과 같은 phys_footprint)
func footprint(_ pid: pid_t) -> UInt64 {
    var ri = rusage_info_v4()
    let r = withUnsafeMutablePointer(to: &ri) {
        $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
            proc_pid_rusage(pid, RUSAGE_INFO_V4, $0)
        }
    }
    return r == 0 ? ri.ri_phys_footprint : 0
}

/// 앱 + 그 앱이 띄운 하위 프로세스(Chrome/Electron 헬퍼 등)의 메모리 합계
func appFootprints(for pids: Set<pid_t>) -> [pid_t: UInt64] {
    let n = proc_listallpids(nil, 0)
    guard n > 0 else { return [:] }
    var all = [pid_t](repeating: 0, count: Int(n) + 64)
    let got = Int(proc_listallpids(&all, Int32(all.count * MemoryLayout<pid_t>.size)))
    all = Array(all.prefix(max(0, got)))

    var parent: [pid_t: pid_t] = [:]
    for pid in all {
        var bsd = proc_bsdinfo()
        let sz = Int32(MemoryLayout<proc_bsdinfo>.size)
        if proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &bsd, sz) == sz {
            parent[pid] = pid_t(bsd.pbi_ppid)
        }
    }

    var result: [pid_t: UInt64] = [:]
    for pid in all {
        // 조상을 따라 올라가며 목록에 있는 앱을 찾으면 그 앱에 합산
        var cur = pid, hops = 0
        while hops < 32 {
            if pids.contains(cur) { result[cur, default: 0] += footprint(pid); break }
            guard let p = parent[cur], p > 1 else { break }
            cur = p; hops += 1
        }
    }
    return result
}

/// 실제 창(일반 레이어, 충분한 크기)을 하나라도 가진 PID.
/// 메뉴바 잔상(높이 ≤ 40)·숨은 500x500 기본 창은 무시. 최소화·다른 데스크탑의 창은 "창 있음"으로 취급(안전한 쪽).
func pidsWithWindows() -> Set<pid_t> {
    let list = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] ?? []
    var set = Set<pid_t>()
    for w in list {
        guard let pid = w[kCGWindowOwnerPID as String] as? pid_t,
              (w[kCGWindowLayer as String] as? Int) == 0,
              let b = w[kCGWindowBounds as String] as? [String: CGFloat] else { continue }
        let width = b["Width"] ?? 0, height = b["Height"] ?? 0
        if width < 100 || height <= 40 { continue }
        if width == 500 && height == 500 { continue }
        set.insert(pid)
    }
    return set
}

// MARK: - 앱

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let menu = NSMenu()
    private let pressureItem = NSMenuItem()
    private let usedItem = NSMenuItem()
    private let appItem = NSMenuItem()
    private let wiredItem = NSMenuItem()
    private let compressedItem = NSMenuItem()
    private let cachedItem = NSMenuItem()
    private let swapItem = NSMenuItem()
    private let loginItem = NSMenuItem(title: "로그인 시 자동 실행", action: #selector(toggleLogin(_:)), keyEquivalent: "")
    private var timer: Timer?
    private var windowless: [NSRunningApplication] = []

    private let excluded: Set<String> = ["com.apple.finder"]
    private let maxApps = 12

    func applicationDidFinishLaunching(_ notification: Notification) {
        for item in [pressureItem, usedItem, appItem, wiredItem, compressedItem, cachedItem, swapItem] {
            item.isEnabled = false
        }
        loginItem.target = self
        menu.delegate = self
        menu.autoenablesItems = false
        statusItem.menu = menu
        rebuildMenu()

        refresh()
        // .common 모드에 등록해야 메뉴를 열어둔 동안에도 숫자가 계속 갱신됨
        let t = Timer(timeInterval: 2.0, target: self, selector: #selector(refresh), userInfo: nil, repeats: true)
        t.tolerance = 0.5   // 전력 절약용 여유
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    // 메뉴를 열 때만 앱 목록을 계산 (평소엔 비용 0)
    func menuNeedsUpdate(_ menu: NSMenu) {
        refresh()
        rebuildMenu()
    }

    private func rebuildMenu() {
        menu.removeAllItems()
        for item in [pressureItem, usedItem, .separator(),
                     appItem, wiredItem, compressedItem, cachedItem, swapItem, .separator()] {
            menu.addItem(item)
        }
        addAppSection()
        menu.addItem(.separator())
        let am = NSMenuItem(title: "활성 상태 보기 열기", action: #selector(openActivityMonitor), keyEquivalent: "")
        am.target = self
        menu.addItem(am)
        menu.addItem(loginItem)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "RAMBar 종료", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

    private func addAppSection() {
        let me = ProcessInfo.processInfo.processIdentifier
        let apps = NSWorkspace.shared.runningApplications.filter {
            $0.activationPolicy == .regular && $0.processIdentifier != me
                && !excluded.contains($0.bundleIdentifier ?? "")
        }
        let mem = appFootprints(for: Set(apps.map(\.processIdentifier)))
        let withWin = pidsWithWindows()
        let sorted = apps.sorted { (mem[$0.processIdentifier] ?? 0) > (mem[$1.processIdentifier] ?? 0) }
        windowless = sorted.filter { !$0.isHidden && !withWin.contains($0.processIdentifier) }

        let header = NSMenuItem(title: "실행 중인 앱 · 클릭하면 종료", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)

        let font = NSFont.menuFont(ofSize: 0)
        let style = NSMutableParagraphStyle()
        style.tabStops = [NSTextTab(textAlignment: .right, location: 260)]

        for app in sorted.prefix(maxApps) {
            let pid = app.processIdentifier
            let noWin = windowless.contains { $0.processIdentifier == pid }
            let t = NSMutableAttributedString(string: app.localizedName ?? "?",
                                              attributes: [.font: font, .paragraphStyle: style])
            if noWin {
                t.append(NSAttributedString(string: "  창 없음",
                    attributes: [.font: NSFont.menuFont(ofSize: 11), .foregroundColor: NSColor.systemOrange,
                                 .paragraphStyle: style]))
            }
            t.append(NSAttributedString(string: "\t" + mbText(mem[pid] ?? 0),
                attributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular),
                             .foregroundColor: NSColor.secondaryLabelColor, .paragraphStyle: style]))

            let item = NSMenuItem(title: app.localizedName ?? "?", action: #selector(quitApp(_:)), keyEquivalent: "")
            item.attributedTitle = t
            item.target = self
            item.representedObject = app
            if let icon = app.icon?.copy() as? NSImage {
                icon.size = NSSize(width: 16, height: 16)
                item.image = icon
            }
            menu.addItem(item)
        }

        if !windowless.isEmpty {
            let total = windowless.reduce(UInt64(0)) { $0 + (mem[$1.processIdentifier] ?? 0) }
            let all = NSMenuItem(title: "창 없는 앱 모두 종료 (\(windowless.count)개, \(mbText(total)))",
                                 action: #selector(quitWindowless), keyEquivalent: "")
            all.target = self
            menu.addItem(all)
        }
    }

    @objc private func quitApp(_ sender: NSMenuItem) {
        (sender.representedObject as? NSRunningApplication)?.terminate()   // Cmd+Q와 같은 정상 종료
        refreshSoon()
    }

    @objc private func quitWindowless() {
        windowless.forEach { $0.terminate() }
        refreshSoon()
    }

    private func refreshSoon() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in self?.refresh() }
    }

    @objc private func refresh() {
        guard let s = readStats(), let button = statusItem.button else { return }

        let (color, label): (NSColor, String) = switch s.pressure {
        case 4: (.systemRed, "위험")
        case 2: (.systemYellow, "경고")
        default: (.systemGreen, "정상")
        }

        let font = NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        let title = NSMutableAttributedString(
            string: "●", attributes: [.foregroundColor: color, .font: font])
        title.append(NSAttributedString(string: " \(s.percent)%", attributes: [.font: font]))
        button.attributedTitle = title

        pressureItem.title = "메모리 압력: \(label)"
        usedItem.title = "사용: \(gb(s.used)) / \(gb(s.total))  (\(s.percent)%)"
        appItem.title = "  앱 메모리: \(gb(s.app))"
        wiredItem.title = "  와이어드: \(gb(s.wired))"
        compressedItem.title = "  압축됨: \(gb(s.compressed))"
        cachedItem.title = "  캐시된 파일: \(gb(s.cached))"
        swapItem.title = "  스왑 사용: \(gb(s.swapUsed))"
        loginItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
    }

    @objc private func openActivityMonitor() {
        NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Utilities/Activity Monitor.app"))
    }

    @objc private func toggleLogin(_ sender: NSMenuItem) {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            NSSound.beep()
        }
        sender.state = SMAppService.mainApp.status == .enabled ? .on : .off
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)   // Dock 아이콘 없이 메뉴바에만
app.run()
