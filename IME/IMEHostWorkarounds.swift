import AppKit

/// 部分宿主（腾讯系 Electron）在切换输入法或 IMK 几何查询时会崩溃，见鼠须管 #951。
enum IMEHostWorkarounds {
    private static let fragileTextInputHosts: Set<String> = [
        "com.tencent.WeWorkMac",
        "com.tencent.xinWeChat",
    ]

    static func frontmostBundleID() -> String? {
        NSWorkspace.shared.frontmostApplication?.bundleIdentifier
    }

    /// 不向客户端调用 `attributes(forCharacterIndex:lineHeightRectangle:)` 等几何 API。
    static func skipsClientGeometry(for bundleID: String? = frontmostBundleID()) -> Bool {
        guard let bundleID else { return false }
        return fragileTextInputHosts.contains(bundleID)
    }

    /// 切入该 App 时不要再次 TISSelect，否则宿主可能在 `_selectCurrentInputSource` 里崩。
    static func skipsAutomaticInputSourceReselect(for bundleID: String?) -> Bool {
        guard let bundleID else { return false }
        return fragileTextInputHosts.contains(bundleID)
    }
}
