import Combine
import Foundation

@MainActor
final class ProxyStore: ObservableObject {
    var proxyGroups: [ProxyGroup] = [] {
        willSet { self.publishChangeIfNeeded(current: self.proxyGroups, next: newValue) }
    }

    var groupLatencyLoading: Set<String> = [] {
        willSet { self.publishChangeIfNeeded(current: self.groupLatencyLoading, next: newValue) }
    }

    var proxyLatencyTesting: Set<ProxyLatencyTestKey> = [] {
        willSet { self.publishChangeIfNeeded(current: self.proxyLatencyTesting, next: newValue) }
    }

    var proxyDelaySamples: [String: [Int]] = [:] {
        willSet { self.publishChangeIfNeeded(current: self.proxyDelaySamples, next: newValue) }
    }

    var proxyNodeTypes: [String: String] = [:] {
        willSet { self.publishChangeIfNeeded(current: self.proxyNodeTypes, next: newValue) }
    }

    var isProxySyncing = false {
        willSet { self.publishChangeIfNeeded(current: self.isProxySyncing, next: newValue) }
    }

    var providerProxyCount = 0 {
        willSet { self.publishChangeIfNeeded(current: self.providerProxyCount, next: newValue) }
    }

    var providerRuleCount = 0 {
        willSet { self.publishChangeIfNeeded(current: self.providerRuleCount, next: newValue) }
    }

    var proxyProvidersDetail: [String: ProviderDetail] = [:] {
        willSet { self.publishChangeIfNeeded(current: self.proxyProvidersDetail, next: newValue) }
    }

    var sortedProxyProviderNames: [String] {
        self.proxyProvidersDetail.keys.sorted {
            $0.localizedCaseInsensitiveCompare($1) == .orderedAscending
        }
    }

    var providerUpdating: Set<String> = [] {
        willSet { self.publishChangeIfNeeded(current: self.providerUpdating, next: newValue) }
    }

    var providerRefreshStatus: ProviderRefreshStatus = .idle {
        willSet { self.publishChangeIfNeeded(current: self.providerRefreshStatus, next: newValue) }
    }

    var rulesCount = 0 {
        willSet { self.publishChangeIfNeeded(current: self.rulesCount, next: newValue) }
    }

    var ruleProviders: [String: ProviderDetail] = [:] {
        willSet { self.publishChangeIfNeeded(current: self.ruleProviders, next: newValue) }
    }

    var ruleItems: [RuleItem] = [] {
        willSet { self.publishChangeIfNeeded(current: self.ruleItems, next: newValue) }
    }

    var isRuleProvidersRefreshing = false {
        willSet { self.publishChangeIfNeeded(current: self.isRuleProvidersRefreshing, next: newValue) }
    }

    private var pendingMeasuredDelays: [(name: String, value: Int)] = []
    private var measuredDelayFlushTask: Task<Void, Never>?
    private var hasPendingChangeNotification = false
    private var changeNotificationTask: Task<Void, Never>?

    /// Latency results arrive in bursts while a group/all-group health check runs. Applying them one
    /// by one invalidated the whole proxy UI (and every open node list) dozens of times per second,
    /// which is what made scrolling drop frames. Buffer them and publish once per window instead.
    func applyMeasuredDelays(_ delays: [String: Int]) {
        guard !delays.isEmpty else { return }
        self.pendingMeasuredDelays.append(contentsOf: delays.map { (name: $0.key, value: $0.value) })
        guard self.measuredDelayFlushTask == nil else { return }
        self.measuredDelayFlushTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: Self.measuredDelayFlushWindowNanoseconds)
            guard let self else { return }
            self.measuredDelayFlushTask = nil
            self.flushMeasuredDelays()
        }
    }

    private func flushMeasuredDelays() {
        self.measuredDelayFlushTask?.cancel()
        self.measuredDelayFlushTask = nil
        guard !self.pendingMeasuredDelays.isEmpty else { return }

        let measured = self.pendingMeasuredDelays
        self.pendingMeasuredDelays.removeAll(keepingCapacity: true)

        var samples = self.proxyDelaySamples
        for item in measured {
            var series = samples[item.name] ?? []
            series.append(item.value)
            if series.count > ProxyDelayHistory.limit {
                series = Array(series.suffix(ProxyDelayHistory.limit))
            }
            samples[item.name] = series
        }
        self.proxyDelaySamples = samples
    }

    private static let measuredDelayFlushWindowNanoseconds: UInt64 = 120_000_000
    private static let changeCoalescingWindowNanoseconds: UInt64 = 16_000_000

    private func publishChangeIfNeeded<Value: Equatable>(current: Value, next: Value) {
        guard current != next else { return }
        self.hasPendingChangeNotification = true
        guard self.changeNotificationTask == nil else { return }
        self.changeNotificationTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: Self.changeCoalescingWindowNanoseconds)
            guard let self else { return }
            self.changeNotificationTask = nil
            guard self.hasPendingChangeNotification else { return }
            self.hasPendingChangeNotification = false
            self.objectWillChange.send()
        }
    }
}
