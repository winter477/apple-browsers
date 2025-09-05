//
//  MacPacketTunnelProvider.swift
//
//  Copyright © 2023 DuckDuckGo. All rights reserved.
//
//  Licensed under the Apache License, Version 2.0 (the "License");
//  you may not use this file except in compliance with the License.
//  You may obtain a copy of the License at
//
//  http://www.apache.org/licenses/LICENSE-2.0
//
//  Unless required by applicable law or agreed to in writing, software
//  distributed under the License is distributed on an "AS IS" BASIS,
//  WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
//  See the License for the specific language governing permissions and
//  limitations under the License.
//

import Foundation
import Combine
import Common
import VPN
import NetworkExtension
import Networking
import PixelKit
import Subscription
import os.log
import WireGuard

final class MacPacketTunnelProvider: PacketTunnelProvider {

    static var isAppex: Bool {
#if NETP_SYSTEM_EXTENSION
        false
#else
        true
#endif
    }

    static var subscriptionsAppGroup: String? {
        isAppex ? Bundle.main.appGroup(bundle: .subs) : nil
    }

    // MARK: - Error Reporting

    private static func networkProtectionDebugEvents(controllerErrorStore: NetworkProtectionTunnelErrorStore) -> EventMapping<NetworkProtectionError> {
        return EventMapping { event, _, _, _ in
            let domainEvent: NetworkProtectionPixelEvent
#if DEBUG
            // Makes sure we see the error in the yellow NetP alert.
            controllerErrorStore.lastErrorMessage = "[Debug] Error event: \(event.localizedDescription)"
#endif
            switch event {
            case .noServerRegistrationInfo:
                domainEvent = .networkProtectionTunnelConfigurationNoServerRegistrationInfo
            case .couldNotSelectClosestServer:
                domainEvent = .networkProtectionTunnelConfigurationCouldNotSelectClosestServer
            case .couldNotGetPeerPublicKey:
                domainEvent = .networkProtectionTunnelConfigurationCouldNotGetPeerPublicKey
            case .couldNotGetPeerHostName:
                domainEvent = .networkProtectionTunnelConfigurationCouldNotGetPeerHostName
            case .couldNotGetInterfaceAddressRange:
                domainEvent = .networkProtectionTunnelConfigurationCouldNotGetInterfaceAddressRange
            case .failedToFetchServerList(let eventError):
                domainEvent = .networkProtectionClientFailedToFetchServerList(eventError)
            case .failedToParseServerListResponse:
                domainEvent = .networkProtectionClientFailedToParseServerListResponse
            case .failedToEncodeRegisterKeyRequest:
                domainEvent = .networkProtectionClientFailedToEncodeRegisterKeyRequest
            case .failedToFetchRegisteredServers(let eventError):
                domainEvent = .networkProtectionClientFailedToFetchRegisteredServers(eventError)
            case .failedToParseRegisteredServersResponse:
                domainEvent = .networkProtectionClientFailedToParseRegisteredServersResponse
            case .invalidAuthToken:
                domainEvent = .networkProtectionClientInvalidAuthToken
            case .serverListInconsistency:
                return
            case .failedToCastKeychainValueToData(let field):
                domainEvent = .networkProtectionKeychainErrorFailedToCastKeychainValueToData(field: field)
            case .keychainReadError(let field, let status):
                domainEvent = .networkProtectionKeychainReadError(field: field, status: status)
            case .keychainWriteError(let field, let status):
                domainEvent = .networkProtectionKeychainWriteError(field: field, status: status)
            case .keychainUpdateError(let field, let status):
                domainEvent = .networkProtectionKeychainUpdateError(field: field, status: status)
            case .keychainDeleteError(let status):
                domainEvent = .networkProtectionKeychainDeleteError(status: status)
            case .wireGuardCannotLocateTunnelFileDescriptor:
                domainEvent = .networkProtectionWireguardErrorCannotLocateTunnelFileDescriptor
            case .wireGuardInvalidState(let reason):
                domainEvent = .networkProtectionWireguardErrorInvalidState(reason: reason)
            case .wireGuardDnsResolution:
                domainEvent = .networkProtectionWireguardErrorFailedDNSResolution
            case .wireGuardSetNetworkSettings(let error):
                domainEvent = .networkProtectionWireguardErrorCannotSetNetworkSettings(error)
            case .startWireGuardBackend(let error):
                domainEvent = .networkProtectionWireguardErrorCannotStartWireguardBackend(error)
            case .setWireguardConfig(let error):
                domainEvent = .networkProtectionWireguardErrorCannotSetWireguardConfig(error)
            case .noAuthTokenFound:
                domainEvent = .networkProtectionNoAuthTokenFoundError
            case .vpnAccessRevoked(let error):
                domainEvent = .networkProtectionVPNAccessRevoked(error)
            case .failedToFetchServerStatus(let error):
                domainEvent = .networkProtectionClientFailedToFetchServerStatus(error)
            case .failedToParseServerStatusResponse(let error):
                domainEvent = .networkProtectionClientFailedToParseServerStatusResponse(error)
            case .unhandledError(function: let function, line: let line, error: let error):
                domainEvent = .networkProtectionUnhandledError(function: function, line: line, error: error)
            case .failedToFetchLocationList,
                    .failedToParseLocationListResponse:
                // Needs Privacy triage for macOS Geoswitching pixels
                return
            case .unmanagedSubscriptionError(let error):
                domainEvent = .networkProtectionUnmanagedSubscriptionError(error)
            }

            PixelKit.fire(domainEvent, frequency: .legacyDailyAndCount, includeAppVersionParameter: true)
        }
    }

    private let notificationCenter: NetworkProtectionNotificationCenter = DistributedNotificationCenter.default()

    // MARK: - PacketTunnelProvider.Event reporting

    private static var vpnLogger = VPNLogger()

    private static var packetTunnelProviderEvents: EventMapping<PacketTunnelProvider.Event> = .init { event, _, _, _ in

#if NETP_SYSTEM_EXTENSION
        let defaults = UserDefaults.standard
#else
        let defaults = UserDefaults.netP
#endif
        switch event {
        case .userBecameActive:
            PixelKit.fire(
                NetworkProtectionPixelEvent.networkProtectionActiveUser,
                frequency: .legacyDailyNoSuffix,
                withAdditionalParameters: [PixelKit.Parameters.vpnCohort: PixelKit.cohort(from: defaults.vpnFirstEnabled)],
                includeAppVersionParameter: true)
        case .connectionTesterStatusChange(let status, let server):
            vpnLogger.log(status, server: server)

            switch status {
            case .failed(let duration):
                let pixel: NetworkProtectionPixelEvent = {
                    switch duration {
                    case .immediate:
                        return .networkProtectionConnectionTesterFailureDetected(server: server)
                    case .extended:
                        return .networkProtectionConnectionTesterExtendedFailureDetected(server: server)
                    }
                }()

                PixelKit.fire(
                    pixel,
                    frequency: .legacyDailyAndCount,
                    includeAppVersionParameter: true)
            case .recovered(let duration, let failureCount):
                let pixel: NetworkProtectionPixelEvent = {
                    switch duration {
                    case .immediate:
                        return .networkProtectionConnectionTesterFailureRecovered(server: server, failureCount: failureCount)
                    case .extended:
                        return .networkProtectionConnectionTesterExtendedFailureRecovered(server: server, failureCount: failureCount)
                    }
                }()

                PixelKit.fire(
                    pixel,
                    frequency: .legacyDailyAndCount,
                    includeAppVersionParameter: true)
            }
        case .reportConnectionAttempt(attempt: let attempt):
            vpnLogger.log(attempt)

            switch attempt {
            case .connecting:
                PixelKit.fire(
                    NetworkProtectionPixelEvent.networkProtectionEnableAttemptConnecting,
                    frequency: .legacyDailyAndCount,
                    includeAppVersionParameter: true)
            case .success:
                PixelKit.fire(
                    NetworkProtectionPixelEvent.networkProtectionEnableAttemptSuccess,
                    frequency: .legacyDailyAndCount,
                    includeAppVersionParameter: true)
            case .failure:
                PixelKit.fire(
                    NetworkProtectionPixelEvent.networkProtectionEnableAttemptFailure,
                    frequency: .legacyDailyAndCount,
                    includeAppVersionParameter: true)
            }
        case .reportTunnelFailure(result: let result):
            vpnLogger.log(result)

            switch result {
            case .failureDetected:
                PixelKit.fire(
                    NetworkProtectionPixelEvent.networkProtectionTunnelFailureDetected,
                    frequency: .legacyDailyAndCount,
                    includeAppVersionParameter: true)
            case .failureRecovered:
                PixelKit.fire(
                    NetworkProtectionPixelEvent.networkProtectionTunnelFailureRecovered,
                    frequency: .legacyDailyAndCount,
                    includeAppVersionParameter: true)
            case .networkPathChanged:
                break
            }
        case .reportLatency(let result, let location):
            vpnLogger.log(result)

            switch result {
            case .error:
                PixelKit.fire(
                    NetworkProtectionPixelEvent.networkProtectionLatencyError,
                    frequency: .legacyDailyNoSuffix,
                    includeAppVersionParameter: true)
            case .quality(let quality):
                guard quality != .unknown else { return }
                PixelKit.fire(
                    NetworkProtectionPixelEvent.networkProtectionLatency(quality: quality),
                    frequency: .legacyDailyAndCount,
                    withAdditionalParameters: ["location": location.stringValue],
                    includeAppVersionParameter: true)
            }
        case .rekeyAttempt(let step):
            vpnLogger.log(step, named: "Rekey")

            switch step {
            case .begin:
                PixelKit.fire(
                    NetworkProtectionPixelEvent.networkProtectionRekeyAttempt,
                    frequency: .legacyDailyAndCount,
                    includeAppVersionParameter: true)
            case .failure(let error):
                PixelKit.fire(
                    NetworkProtectionPixelEvent.networkProtectionRekeyFailure(error),
                    frequency: .legacyDailyAndCount,
                    includeAppVersionParameter: true)
            case .success:
                PixelKit.fire(
                    NetworkProtectionPixelEvent.networkProtectionRekeyCompleted,
                    frequency: .legacyDailyAndCount,
                    includeAppVersionParameter: true)
            }
        case .tunnelStartAttempt(let step):
            vpnLogger.log(step, named: "Tunnel Start")

            switch step {
            case .begin:
                PixelKit.fire(
                    NetworkProtectionPixelEvent.networkProtectionTunnelStartAttempt,
                    frequency: .legacyDailyAndCount,
                    includeAppVersionParameter: true)
            case .failure(let error):
                PixelKit.fire(
                    NetworkProtectionPixelEvent.networkProtectionTunnelStartFailure(error),
                    frequency: .legacyDailyAndCount,
                    includeAppVersionParameter: true)
            case .success:
                PixelKit.fire(
                    NetworkProtectionPixelEvent.networkProtectionTunnelStartSuccess,
                    frequency: .legacyDailyAndCount,
                    includeAppVersionParameter: true)
            }
        case .tunnelStopAttempt(let step):
            vpnLogger.log(step, named: "Tunnel Stop")

            switch step {
            case .begin:
                PixelKit.fire(
                    NetworkProtectionPixelEvent.networkProtectionTunnelStopAttempt,
                    frequency: .standard,
                    includeAppVersionParameter: true)
            case .failure(let error):
                PixelKit.fire(
                    NetworkProtectionPixelEvent.networkProtectionTunnelStopFailure(error),
                    frequency: .legacyDailyAndCount,
                    includeAppVersionParameter: true)
            case .success:
                PixelKit.fire(
                    NetworkProtectionPixelEvent.networkProtectionTunnelStopSuccess,
                    frequency: .legacyDailyAndCount,
                    includeAppVersionParameter: true)
            }
        case .tunnelUpdateAttempt(let step):
            vpnLogger.log(step, named: "Tunnel Update")

            switch step {
            case .begin:
                PixelKit.fire(
                    NetworkProtectionPixelEvent.networkProtectionTunnelUpdateAttempt,
                    frequency: .legacyDailyAndCount,
                    includeAppVersionParameter: true)
            case .failure(let error):
                PixelKit.fire(
                    NetworkProtectionPixelEvent.networkProtectionTunnelUpdateFailure(error),
                    frequency: .legacyDailyAndCount,
                    includeAppVersionParameter: true)
            case .success:
                PixelKit.fire(
                    NetworkProtectionPixelEvent.networkProtectionTunnelUpdateSuccess,
                    frequency: .legacyDailyAndCount,
                    includeAppVersionParameter: true)
            }
        case .tunnelWakeAttempt(let step):
            vpnLogger.log(step, named: "Tunnel Wake")

            switch step {
            case .begin, .success: break
            case .failure(let error):
                PixelKit.fire(
                    NetworkProtectionPixelEvent.networkProtectionTunnelWakeFailure(error),
                    frequency: .legacyDailyAndCount,
                    includeAppVersionParameter: true)
            }
        case .failureRecoveryAttempt(let step):
            vpnLogger.log(step)

            switch step {
            case .started:
                PixelKit.fire(
                    VPNFailureRecoveryPixel.vpnFailureRecoveryStarted,
                    frequency: .legacyDailyAndCount,
                    includeAppVersionParameter: true
                )
            case .completed(.healthy):
                PixelKit.fire(
                    VPNFailureRecoveryPixel.vpnFailureRecoveryCompletedHealthy,
                    frequency: .legacyDailyAndCount,
                    includeAppVersionParameter: true
                )
            case .completed(.unhealthy):
                PixelKit.fire(
                    VPNFailureRecoveryPixel.vpnFailureRecoveryCompletedUnhealthy,
                    frequency: .legacyDailyAndCount,
                    includeAppVersionParameter: true
                )
            case .failed(let error):
                PixelKit.fire(
                    VPNFailureRecoveryPixel.vpnFailureRecoveryFailed(error),
                    frequency: .legacyDailyAndCount,
                    includeAppVersionParameter: true
                )
            }
        case .serverMigrationAttempt(let step):
            vpnLogger.log(step, named: "Server Migration")

            switch step {
            case .begin:
                PixelKit.fire(
                    NetworkProtectionPixelEvent.networkProtectionServerMigrationAttempt,
                    frequency: .legacyDailyAndCount,
                    includeAppVersionParameter: true)
            case .failure(let error):
                PixelKit.fire(
                    NetworkProtectionPixelEvent.networkProtectionServerMigrationFailure(error),
                    frequency: .legacyDailyAndCount,
                    includeAppVersionParameter: true)
            case .success:
                PixelKit.fire(
                    NetworkProtectionPixelEvent.networkProtectionServerMigrationSuccess,
                    frequency: .legacyDailyAndCount,
                    includeAppVersionParameter: true)
            }
        case .tunnelStartOnDemandWithoutAccessToken:
            vpnLogger.logStartingWithoutAuthToken()

            PixelKit.fire(
                NetworkProtectionPixelEvent.networkProtectionTunnelStartAttemptOnDemandWithoutAccessToken,
                frequency: .legacyDailyAndCount,
                includeAppVersionParameter: true)
        }
    }

    static var tokenServiceName: String {
#if NETP_SYSTEM_EXTENSION
        "\(Bundle.main.bundleIdentifier!).authToken"
#else
        NetworkProtectionKeychainTokenStore.Defaults.tokenStoreService
#endif
    }

    static var tokenContainerServiceName: String {
#if NETP_SYSTEM_EXTENSION
        "\(Bundle.main.bundleIdentifier!).authTokenContainer"
#else
        NetworkProtectionKeychainTokenStoreV2.Defaults.tokenStoreService
#endif
    }

    // MARK: - Initialization

    let accountManager: DefaultAccountManager
    let subscriptionManagerV2: DefaultSubscriptionManagerV2
    let tokenStorageV2: NetworkProtectionKeychainTokenStoreV2
    let tokenStoreV1: NetworkProtectionKeychainTokenStore

    @MainActor @objc public init() {
        Logger.networkProtection.log("[+] MacPacketTunnelProvider")
#if NETP_SYSTEM_EXTENSION
        let defaults = UserDefaults.standard
#else
        let defaults = UserDefaults.netP
#endif

        let osVersion = ProcessInfo.processInfo.operatingSystemVersion
        let trimmedOSVersion = "\(osVersion.majorVersion).\(osVersion.minorVersion)"
        APIRequest.Headers.setUserAgent(UserAgent.duckDuckGoUserAgent(systemVersion: trimmedOSVersion))
        NetworkProtectionLastVersionRunStore(userDefaults: defaults).lastExtensionVersionRun = AppVersion.shared.versionAndBuildNumber
        let settings = VPNSettings(defaults: defaults) // Note, settings here is not yet populated with the startup options

        // MARK: - Subscription configuration

        // Align Subscription environment to the VPN environment
        var subscriptionEnvironment = SubscriptionEnvironment.default
        switch settings.selectedEnvironment {
        case .production:
            subscriptionEnvironment.serviceEnvironment = .production
        case .staging:
            subscriptionEnvironment.serviceEnvironment = .staging
        }
        // The SysExt doesn't care about the purchase platform because the only operations executed here are about the Auth token. No purchase or
        // platforms-related operations are performed.
        subscriptionEnvironment.purchasePlatform = .stripe
        Logger.networkProtection.debug("Subscription ServiceEnvironment: \(subscriptionEnvironment.serviceEnvironment.rawValue, privacy: .public)")

        let notificationCenter: NetworkProtectionNotificationCenter = DistributedNotificationCenter.default()
        let controllerErrorStore = NetworkProtectionTunnelErrorStore(notificationCenter: notificationCenter)
        let debugEvents = Self.networkProtectionDebugEvents(controllerErrorStore: controllerErrorStore)

        // MARK: - V1
        let tokenStore = NetworkProtectionKeychainTokenStore(keychainType: Bundle.keychainType,
                                                             serviceName: Self.tokenServiceName,
                                                             errorEvents: debugEvents,
                                                             useAccessTokenProvider: false,
                                                             accessTokenProvider: {
            assertionFailure("Should not be called")
            return nil
        })
        let subscriptionUserDefaults = UserDefaults(suiteName: MacPacketTunnelProvider.subscriptionsAppGroup)!
        let entitlementsCache = UserDefaultsCache<[Entitlement]>(userDefaults: subscriptionUserDefaults,
                                                                 key: UserDefaultsCacheKey.subscriptionEntitlements,
                                                                 settings: UserDefaultsCacheSettings(defaultExpirationInterval: .minutes(20)))

        let subscriptionEndpointService = DefaultSubscriptionEndpointService(currentServiceEnvironment: subscriptionEnvironment.serviceEnvironment,
                                                                             userAgent: UserAgent.duckDuckGoUserAgent())
        let authEndpointService = DefaultAuthEndpointService(currentServiceEnvironment: subscriptionEnvironment.serviceEnvironment,
                                                             userAgent: UserAgent.duckDuckGoUserAgent())
        let accountManager = DefaultAccountManager(accessTokenStorage: tokenStore,
                                                   entitlementsCache: entitlementsCache,
                                                   subscriptionEndpointService: subscriptionEndpointService,
                                                   authEndpointService: authEndpointService)
        self.accountManager = accountManager
        self.tokenStoreV1 = tokenStore

        // MARK: - V2
        let authService = DefaultOAuthService(baseURL: subscriptionEnvironment.authEnvironment.url,
                                              apiService: APIServiceFactory.makeAPIServiceForAuthV2(withUserAgent: UserAgent.duckDuckGoUserAgent()))
        let tokenStoreV2 = NetworkProtectionKeychainTokenStoreV2(keychainType: Bundle.keychainType,
                                                                 serviceName: Self.tokenContainerServiceName,
                                                                 errorEventsHandler: debugEvents)
        let authClient = DefaultOAuthClient(tokensStorage: tokenStoreV2,
                                            legacyTokenStorage: nil,
                                            authService: authService)

        let subscriptionEndpointServiceV2 = DefaultSubscriptionEndpointServiceV2(apiService: APIServiceFactory.makeAPIServiceForSubscription(withUserAgent: UserAgent.duckDuckGoUserAgent()),
                                                                                 baseURL: subscriptionEnvironment.serviceEnvironment.url)
        let pixelHandler = SubscriptionPixelHandler(source: .systemExtension)
        let subscriptionManager = DefaultSubscriptionManagerV2(oAuthClient: authClient,
                                                               userDefaults: subscriptionUserDefaults,
                                                               subscriptionEndpointService: subscriptionEndpointServiceV2,
                                                               subscriptionEnvironment: subscriptionEnvironment,
                                                               pixelHandler: pixelHandler,
                                                               initForPurchase: false)

        let entitlementsCheck: (() async -> Result<Bool, Error>) = {
            Logger.networkProtection.log("Subscription Entitlements check...")
            if !Self.isUsingAuthV2 {
                Logger.networkProtection.log("Using Auth V1")
                return await accountManager.hasEntitlement(forProductName: .networkProtection, cachePolicy: .reloadIgnoringLocalCacheData)
            } else {
                Logger.networkProtection.log("Using Auth V2")
                do {
                    let tokenContainer = try await subscriptionManager.getTokenContainer(policy: .localValid)
                    let isNetworkProtectionEnabled = tokenContainer.decodedAccessToken.hasEntitlement(.networkProtection)
                    Logger.networkProtection.log("NetworkProtectionEnabled if: \( isNetworkProtectionEnabled ? "Enabled" : "Disabled", privacy: .public)")
                    return .success(isNetworkProtectionEnabled)
                } catch {
                    return .failure(error)
                }
            }
        }

        self.tokenStorageV2 = tokenStoreV2
        self.subscriptionManagerV2 = subscriptionManager

        let tokenHandlerProvider: () -> any SubscriptionTokenHandling = {

            if Self.isUsingAuthV2 {
                Logger.networkProtection.debug("tokenHandlerProvider: Using Auth V2")
                return subscriptionManager
            } else {
                Logger.networkProtection.debug("tokenHandlerProvider: Using Auth V1")
                return tokenStore
            }
        }

        // MARK: -

        let tunnelHealthStore = NetworkProtectionTunnelHealthStore(notificationCenter: notificationCenter)
        let notificationsPresenter = NetworkProtectionNotificationsPresenterFactory().make(settings: settings, defaults: defaults)

        super.init(notificationsPresenter: notificationsPresenter,
                   tunnelHealthStore: tunnelHealthStore,
                   controllerErrorStore: controllerErrorStore,
                   snoozeTimingStore: NetworkProtectionSnoozeTimingStore(userDefaults: .netP),
                   wireGuardInterface: DefaultWireGuardInterface(),
                   keychainType: Bundle.keychainType,
                   tokenHandlerProvider: tokenHandlerProvider,
                   debugEvents: debugEvents,
                   providerEvents: Self.packetTunnelProviderEvents,
                   settings: settings,
                   defaults: defaults,
                   entitlementCheck: entitlementsCheck)

        setupPixels()
        accountManager.delegate = self
        Logger.networkProtection.log("[+] MacPacketTunnelProvider Initialised")
    }

    deinit {
        Logger.networkProtectionMemory.log("[-] MacPacketTunnelProvider")
    }

    public override func load(options: StartupOptions) async throws {
        try await super.load(options: options)

        // macOS-specific options
        try loadVPNSettings(from: options)
        loadAuthVersion(from: options)
        if !Self.isUsingAuthV2 {
            try await loadAuthToken(from: options)
        } else {
            try await loadTokenContainer(from: options)
        }
    }

    private func loadVPNSettings(from options: StartupOptions) throws {
        switch options.vpnSettings {
        case .set(let settingsSnapshot):
            settingsSnapshot.applyTo(settings)
        case .useExisting:
            break
        case .reset:
            // VPN settings are required - if we're in reset case, it means they were missing or invalid
            throw TunnelError.settingsMissing
        }
    }

    private func loadAuthVersion(from options: StartupOptions) {
        switch options.isAuthV2Enabled {
        case .set(let newAuthVersion):
            Logger.networkProtection.log("Set new isAuthV2Enabled")
            Self.isUsingAuthV2 = newAuthVersion
        case .useExisting:
            Logger.networkProtection.log("Use existing isAuthV2Enabled")
        case .reset:
            Logger.networkProtection.log("Reset isAuthV2Enabled")
        }
        Logger.networkProtection.log("Load isAuthV2Enabled: \(Self.isUsingAuthV2, privacy: .public)")
    }

    private func loadAuthToken(from options: StartupOptions) async throws {
        let tokenHandler = tokenHandlerProvider()
        Logger.networkProtection.log("Load auth token")
        switch options.authToken {
        case .set(let newAuthToken):
            Logger.networkProtection.log("Set new token")
            if let currentAuthToken = try? await tokenHandler.getToken(), currentAuthToken == newAuthToken {
                Logger.networkProtection.log("Token unchanged, using the current one")
                return
            }

            try await tokenHandler.adoptToken(newAuthToken)
        case .useExisting:
            Logger.networkProtection.log("Use existing token")
            do {
                try await tokenHandler.getToken()
            } catch {
                throw TunnelError.startingTunnelWithoutAuthToken(internalError: error)
            }
        case .reset:
            Logger.networkProtection.log("Reset token")
            // This case should in theory not be possible, but it's ideal to have this in place
            // in case an error in the controller on the client side allows it.
            try? await tokenHandler.removeToken()
            throw TunnelError.tokenReset
        }
    }

    private func loadTokenContainer(from options: StartupOptions) async throws {
        let tokenHandler = tokenHandlerProvider()
        Logger.networkProtection.log("Load token container")
        switch options.tokenContainer {
        case .set(let newTokenContainer):
            Logger.networkProtection.log("Set new token container")
            do {
                try await tokenHandler.adoptToken(newTokenContainer)
            } catch {
                Logger.networkProtection.fault("Error adopting token container: \(error, privacy: .public)")
                throw TunnelError.startingTunnelWithoutAuthToken(internalError: error)
            }
        case .useExisting:
            Logger.networkProtection.log("Use existing token container")
            do {
                try await tokenHandler.getToken()
            } catch {
                Logger.networkProtection.fault("Error loading token container: \(error, privacy: .public)")
                throw TunnelError.startingTunnelWithoutAuthToken(internalError: error)
            }
        case .reset:
            Logger.networkProtection.log("Reset token")
            // This case should in theory not be possible, but it's ideal to have this in place
            // in case an error in the controller on the client side allows it.
            try await tokenHandler.removeToken()
            throw TunnelError.tokenReset
        }
    }

    enum ConfigurationError: Error {
        case missingProviderConfiguration
        case missingPixelHeaders
    }

    public override func loadVendorOptions(from provider: NETunnelProviderProtocol?) throws {
        try super.loadVendorOptions(from: provider)

        guard let vendorOptions = provider?.providerConfiguration else {
            Logger.networkProtection.log("🔵 Provider is nil, or providerConfiguration is not set")
            throw ConfigurationError.missingProviderConfiguration
        }

        try loadDefaultPixelHeaders(from: vendorOptions)
    }

    private func loadDefaultPixelHeaders(from options: [String: Any]) throws {
        guard let defaultPixelHeaders = options[NetworkProtectionOptionKey.defaultPixelHeaders] as? [String: String] else {
            Logger.networkProtection.log("🔵 Pixel options are not set")
            throw ConfigurationError.missingPixelHeaders
        }

        setupPixels(defaultHeaders: defaultPixelHeaders)
    }

    // MARK: - Override-able Connection Events

    override func prepareToConnect(using provider: NETunnelProviderProtocol?) {
        Logger.networkProtection.log("Preparing to connect...")
        super.prepareToConnect(using: provider)
        guard PixelKit.shared == nil, let options = provider?.providerConfiguration else { return }
        try? loadDefaultPixelHeaders(from: options)
    }

    // MARK: - Start

    @MainActor
    override func startTunnel(options: [String: NSObject]? = nil) async throws {

        try await super.startTunnel(options: options)

        if !Self.isUsingAuthV2 {
            // Auth V2 cleanup in case of rollback
            Logger.subscription.debug("Cleaning up Auth V2 token")
            try? tokenStorageV2.saveTokenContainer(nil)
        }
    }

    // MARK: - Pixels

    private func setupPixels(defaultHeaders: [String: String] = [:]) {
        let dryRun: Bool
#if DEBUG
        dryRun = true
#else
        dryRun = false
#endif

        let source: String

#if NETP_SYSTEM_EXTENSION && !APPSTORE
        source = "vpnSystemExtension"
#elseif NETP_SYSTEM_EXTENSION && APPSTORE
        source = "vpnSystemExtensionAppStore"
#else
        source = "vpnAppExtension"
#endif

        PixelKit.setUp(dryRun: dryRun,
                       appVersion: AppVersion.shared.versionNumber,
                       source: source,
                       defaultHeaders: defaultHeaders,
                       defaults: .netP) { (pixelName: String, headers: [String: String], parameters: [String: String], _, _, onComplete: @escaping PixelKit.CompletionBlock) in

            let url = URL.pixelUrl(forPixelNamed: pixelName)
            let apiHeaders = APIRequest.Headers(additionalHeaders: headers)
            let configuration = APIRequest.Configuration(url: url, method: .get, queryParameters: parameters, headers: apiHeaders)
            let request = APIRequest(configuration: configuration)

            request.fetch { _, error in
                onComplete(error == nil, error)
            }
        }
    }

}

final class DefaultWireGuardInterface: WireGuardInterface {
    func turnOn(settings: UnsafePointer<CChar>, handle: Int32) -> Int32 {
        wgTurnOn(settings, handle)
    }

    func turnOff(handle: Int32) {
        wgTurnOff(handle)
    }

    func getConfig(handle: Int32) -> UnsafeMutablePointer<CChar>? {
        return wgGetConfig(handle)
    }

    func setConfig(handle: Int32, config: String) -> Int64 {
        return wgSetConfig(handle, config)
    }

    func bumpSockets(handle: Int32) {
        wgBumpSockets(handle)
    }

    func disableSomeRoamingForBrokenMobileSemantics(handle: Int32) {
        wgDisableSomeRoamingForBrokenMobileSemantics(handle)
    }

    func setLogger(context: UnsafeMutableRawPointer?, logFunction: (@convention(c) (UnsafeMutableRawPointer?, Int32, UnsafePointer<CChar>?) -> Void)?) {
        wgSetLogger(context, logFunction)
    }
}

extension MacPacketTunnelProvider: AccountManagerKeychainAccessDelegate {

    public func accountManagerKeychainAccessFailed(accessType: AccountKeychainAccessType, error: any Error) {

        guard let expectedError = error as? AccountKeychainAccessError else {
            assertionFailure("Unexpected error type: \(error)")
            Logger.networkProtection.fault("Unexpected error type: \(error)")
            return
        }

        PixelKit.fire(PrivacyProErrorPixel.privacyProKeychainAccessError(accessType: accessType,
                                                                         accessError: expectedError,
                                                                         source: KeychainErrorSource.vpn,
                                                                         authVersion: KeychainErrorAuthVersion.v1),
                      frequency: .legacyDailyAndCount)
    }
}
