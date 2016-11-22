import UIKit

#if os(watchOS)
	import WatchKit
#else
	import AVFoundation
	import CoreTelephony
	import ReachabilitySwift
#endif


internal final class DefaultTracker: Tracker {

	private static var instances = [ObjectIdentifier: WeakReference<DefaultTracker>]()
	private static let sharedDefaults = UserDefaults.standardDefaults.child(namespace: "webtrekk")

	#if !os(watchOS)
	private let application = UIApplication.sharedApplication()
	private var applicationDidBecomeActiveObserver: NSObjectProtocol?
	private var applicationWillEnterForegroundObserver: NSObjectProtocol?
	private var applicationWillResignActiveObserver: NSObjectProtocol?
	private var backgroundTaskIdentifier = UIBackgroundTaskInvalid
	#endif

	private let defaults: UserDefaults
	private var isFirstEventOfSession = true
	private var isSampling = false
	private let requestManager: RequestManager
	private var requestManagerStartTimer: NSTimer?
	private let requestQueueBackupFile: NSURL?
	private var requestQueueLoaded = false
	private let requestUrlBuilder: RequestUrlBuilder
    private let campaign: Campaign

	internal let everId: String
	internal var global = GlobalProperties()
	internal var plugins = [TrackerPlugin]()


	internal init(configuration: TrackerConfiguration) {
		checkIsOnMainThread()

		let sharedDefaults = DefaultTracker.sharedDefaults
		var defaults = sharedDefaults.child(namespace: configuration.webtrekkId)

		var migratedRequestQueue: [NSURL]?
		if let webtrekkId = configuration.webtrekkId.nonEmpty where !(sharedDefaults.boolForKey(DefaultsKeys.migrationCompleted) ?? false) {
			sharedDefaults.set(key: DefaultsKeys.migrationCompleted, to: true)

			if WebtrekkTracking.migratesFromLibraryV3, let migration = Migration.migrateFromLibraryV3(webtrekkId: webtrekkId) {
				precondition(!DefaultTracker._everIdIsLoaded)

				sharedDefaults.set(key: DefaultsKeys.everId, to: migration.everId)

				if let appVersion = migration.appVersion {
					defaults.set(key: DefaultsKeys.appVersion, to: appVersion)
				}
				if !DefaultTracker.isOptedOutWasSetManually, let isOptedOut = migration.isOptedOut {
					sharedDefaults.set(key: DefaultsKeys.isOptedOut, to: isOptedOut ? true : nil)
				}
				if let samplingRate = migration.samplingRate, isSampling = migration.isSampling {
					defaults.set(key: DefaultsKeys.isSampling, to: isSampling)
					defaults.set(key: DefaultsKeys.samplingRate, to: samplingRate)
				}

				migratedRequestQueue = migration.requestQueue

				logInfo("Migrated from Webtrekk Library v3: \(migration)")
			}
		}

		var configuration = configuration
		if let configurationData = defaults.dataForKey(DefaultsKeys.configuration) {
			do {
				let savedConfiguration = try XmlTrackerConfigurationParser().parse(xml: configurationData)
				if savedConfiguration.version > configuration.version {
					logDebug("Using saved configuration (version \(savedConfiguration.version)).")
					configuration = savedConfiguration
				}
			}
			catch let error {
				logError("Cannot load saved configuration. Will fall back to initial configuration. Error: \(error)")
			}
		}

		let validatedConfiguration = DefaultTracker.validatedConfiguration(configuration)

		if validatedConfiguration.webtrekkId != configuration.webtrekkId {
			defaults = sharedDefaults.child(namespace: validatedConfiguration.webtrekkId)
		}

		configuration = validatedConfiguration

		self.configuration = configuration
		self.defaults = defaults
		self.everId = DefaultTracker._everId
		self.isFirstEventAfterAppUpdate = defaults.boolForKey(DefaultsKeys.isFirstEventAfterAppUpdate) ?? false
		self.isFirstEventOfApp = defaults.boolForKey(DefaultsKeys.isFirstEventOfApp) ?? true
		self.requestManager = RequestManager(queueLimit: configuration.requestQueueLimit)
		self.requestQueueBackupFile = DefaultTracker.requestQueueBackupFileForWebtrekkId(configuration.webtrekkId)
		self.requestUrlBuilder = RequestUrlBuilder(serverUrl: configuration.serverUrl, webtrekkId: configuration.webtrekkId)

        self.campaign = Campaign(trackID: configuration.webtrekkId)
        
        campaign.processCampaign()
		
        DefaultTracker.instances[ObjectIdentifier(self)] = WeakReference(self)

		requestManager.delegate = self

		if let migratedRequestQueue = migratedRequestQueue where !DefaultTracker.isOptedOut {
			requestManager.prependRequests(migratedRequestQueue)
		}

		setUp()

		checkForDuplicateTrackers()
	}


	deinit {
		let id = ObjectIdentifier(self)
		let requestManager = self.requestManager

		onMainQueue(synchronousIfPossible: true) {
			DefaultTracker.instances[id] = nil

			if requestManager.started {
				requestManager.stop()
			}
		}

		#if !os(watchOS)
			let notificationCenter = NSNotificationCenter.defaultCenter()
			if let applicationDidBecomeActiveObserver = applicationDidBecomeActiveObserver {
				notificationCenter.removeObserver(applicationDidBecomeActiveObserver)
			}
			if let applicationWillEnterForegroundObserver = applicationWillEnterForegroundObserver {
				notificationCenter.removeObserver(applicationWillEnterForegroundObserver)
			}
			if let applicationWillResignActiveObserver = applicationWillResignActiveObserver {
				notificationCenter.removeObserver(applicationWillResignActiveObserver)
			}
		#endif
	}


	#if os(watchOS)
	internal func applicationDidFinishLaunching() {
		checkIsOnMainThread()

		if requestManagerStartTimer == nil {
			requestManagerStartTimer = NSTimer.scheduledTimerWithTimeInterval(configuration.maximumSendDelay) {
				self.startRequestManager()
			}
		}

		NSTimer.scheduledTimerWithTimeInterval(15) {
			self.updateConfiguration()
		}
	}
	#else
	internal func initTimers() {
		checkIsOnMainThread()

		if requestManagerStartTimer == nil {
			requestManagerStartTimer = NSTimer.scheduledTimerWithTimeInterval(configuration.maximumSendDelay) {
				self.startRequestManager()
			}
		}

		NSTimer.scheduledTimerWithTimeInterval(15) {
			self.updateConfiguration()
		}
	}


	private func applicationDidBecomeActive() {
		checkIsOnMainThread()

		if requestManagerStartTimer == nil {
			requestManagerStartTimer = NSTimer.scheduledTimerWithTimeInterval(configuration.maximumSendDelay) {
				self.startRequestManager()
			}
		}

		if backgroundTaskIdentifier != UIBackgroundTaskInvalid {
			application.endBackgroundTask(backgroundTaskIdentifier)
			backgroundTaskIdentifier = UIBackgroundTaskInvalid
		}
	}


	private func applicationWillResignActive() {
		checkIsOnMainThread()

		defaults.set(key: DefaultsKeys.appHibernationDate, to: NSDate())

		if backgroundTaskIdentifier == UIBackgroundTaskInvalid {
			backgroundTaskIdentifier = application.beginBackgroundTaskWithName("Webtrekk Tracker #\(configuration.webtrekkId)") { [weak self] in
				guard let `self` = self else {
					return
				}

				if self.requestManager.started {
					self.stopRequestManager()
				}

				self.application.endBackgroundTask(self.backgroundTaskIdentifier)
				self.backgroundTaskIdentifier = UIBackgroundTaskInvalid
			}
		}

		if let requestManagerStartTimer = requestManagerStartTimer {
			self.requestManagerStartTimer = nil
			requestManagerStartTimer.fire()
		}

		if backgroundTaskIdentifier != UIBackgroundTaskInvalid {
			saveRequestQueue()
			requestManager.sendAllRequests()
		}
		else {
			stopRequestManager()
		}
	}


	private func applicationWillEnterForeground() {
		checkIsOnMainThread()

		if let hibernationDate = defaults.dateForKey(DefaultsKeys.appHibernationDate) where -hibernationDate.timeIntervalSinceNow < configuration.resendOnStartEventTime {
			isFirstEventOfSession = false
		}
		else {
			isFirstEventOfSession = true
		}
	}
	#endif


	#if !os(watchOS)
	private static let _autotrackingEventHandler = AutotrackingEventHandler()
	internal static var autotrackingEventHandler: protocol<ActionEventHandler, MediaEventHandler, PageViewEventHandler> {
		return _autotrackingEventHandler
	}
	#endif


	private func checkForAppUpdate() {
		checkIsOnMainThread()

		let lastCheckedAppVersion = defaults.stringForKey(DefaultsKeys.appVersion)
		if lastCheckedAppVersion != Environment.appVersion {
			defaults.set(key: DefaultsKeys.appVersion, to: Environment.appVersion)

			if lastCheckedAppVersion != nil {
				isFirstEventAfterAppUpdate = true
			}
		}
	}


	private func checkForDuplicateTrackers() {
		let hasDuplicate = DefaultTracker.instances.values.contains { $0.target?.configuration.webtrekkId == configuration.webtrekkId && $0.target !== self }
		if hasDuplicate {
			logError("Multiple tracker instances for the same Webtrekk ID '\(configuration.webtrekkId)' were created. This is not supported and will corrupt tracking.")
		}
	}


	internal private(set) var configuration: TrackerConfiguration {
		didSet {
			checkIsOnMainThread()

			self.configuration = DefaultTracker.validatedConfiguration(configuration)

			requestManager.queueLimit = configuration.requestQueueLimit

			requestUrlBuilder.serverUrl = configuration.serverUrl
			requestUrlBuilder.webtrekkId = configuration.webtrekkId

			updateSampling()

			#if !os(watchOS)
				updateAutomaticTracking()
			#endif
		}
	}


	private func createRequestForEvent(event: TrackingEvent) -> TrackerRequest? {
		checkIsOnMainThread()

		guard validateEvent(event) else {
			return nil
		}

		var requestProperties = TrackerRequest.Properties(
			everId:       everId,
			samplingRate: configuration.samplingRate,
			timeZone:     NSTimeZone.defaultTimeZone(),
			timestamp:    NSDate(),
			userAgent:    DefaultTracker.userAgent
		)
		requestProperties.locale = NSLocale.currentLocale()

		#if os(watchOS)
			let device = WKInterfaceDevice.currentDevice()
			requestProperties.screenSize = (width: Int(device.screenBounds.width * device.screenScale), height: Int(device.screenBounds.height * device.screenScale))
		#else
			let screen = UIScreen.mainScreen()
			requestProperties.screenSize = (width: Int(screen.bounds.width * screen.scale), height: Int(screen.bounds.height * screen.scale))
		#endif

		if isFirstEventAfterAppUpdate && configuration.automaticallyTracksAppUpdates {
			requestProperties.isFirstEventAfterAppUpdate = true
		}
		if isFirstEventOfApp {
			requestProperties.isFirstEventOfApp = true
		}
		if isFirstEventOfSession {
			requestProperties.isFirstEventOfSession = true
		}
		if configuration.automaticallyTracksAdvertisingId {
			requestProperties.advertisingId = Environment.advertisingIdentifierManager?.advertisingIdentifier
		}
		if configuration.automaticallyTracksAdvertisingOptOut {
			requestProperties.advertisingTrackingEnabled = Environment.advertisingIdentifierManager?.advertisingTrackingEnabled
		}
		if configuration.automaticallyTracksAppVersion {
			requestProperties.appVersion = Environment.appVersion
		}
		if configuration.automaticallyTracksRequestQueueSize {
			requestProperties.requestQueueSize = requestManager.queue.count
		}

		#if !os(watchOS)
			if configuration.automaticallyTracksConnectionType, let connectionType = retrieveConnectionType(){
				requestProperties.connectionType = connectionType
			}

			if configuration.automaticallyTracksInterfaceOrientation {
				requestProperties.interfaceOrientation = application.statusBarOrientation
			}
		#endif

		return TrackerRequest(
			crossDeviceProperties: global.crossDeviceProperties,
			event: event,
			properties: requestProperties
		)
	}


	internal func enqueueRequestForEvent(event: TrackingEvent) {
		checkIsOnMainThread()

		var event = eventByApplyingGlobalProperties(to: event)

		#if !os(watchOS)
			event = eventByApplyingAutomaticPageTracking(to: event)
		#endif

        event = campaignOverride(to :event) ?? event
		
        guard var request = createRequestForEvent(event) else {
			return
		}
        
		for plugin in plugins {
			request = plugin.tracker(self, requestForQueuingRequest: request)
		}

		if shouldEnqueueNewEvents, let requestUrl = requestUrlBuilder.urlForRequest(request) {
			requestManager.enqueueRequest(requestUrl, maximumDelay: configuration.maximumSendDelay)
		}

		for plugin in plugins {
			plugin.tracker(self, didQueueRequest: request)
		}

		isFirstEventAfterAppUpdate = false
		isFirstEventOfApp = false
		isFirstEventOfSession = false
	}
    
    private func campaignOverride(to event: TrackingEvent) -> TrackingEvent? {
        
        guard var _ = event as? TrackingEventWithAdvertisementProperties,
            let _ = event as? TrackingEventWithEcommerceProperties else{
                return nil
        }
        
        if let mc = campaign.getAndDeletSavedMediaCode() {
                var returnEvent = event
                    
                var eventWithAdvertisementProperties = returnEvent as! TrackingEventWithAdvertisementProperties
                eventWithAdvertisementProperties.advertisementProperties.id = mc
                eventWithAdvertisementProperties.advertisementProperties.action = "c"
                returnEvent = eventWithAdvertisementProperties
            
                var eventWithEcommerceProperties = returnEvent as! TrackingEventWithEcommerceProperties
                var detailsToAdd = eventWithEcommerceProperties.ecommerceProperties.details ?? [Int: TrackingValue]()
                detailsToAdd[900] = "1"
                eventWithEcommerceProperties.ecommerceProperties.details = detailsToAdd
                returnEvent = eventWithEcommerceProperties
            
                return returnEvent
            }
        
        return nil
    }

	#if !os(watchOS)
	private func eventByApplyingAutomaticPageTracking(to event: TrackingEvent) -> TrackingEvent {
		checkIsOnMainThread()

		guard let
			viewControllerType = event.viewControllerType,
			page = configuration.automaticallyTrackedPageForViewControllerType(viewControllerType)
		else {
			return event
		}

		var event = event
		event.ipAddress = page.ipAddress ?? event.ipAddress
		event.pageName = page.pageProperties.name ?? event.pageName

		guard !(event is ActionEvent) else {
			return event
		}

		if var eventWithActionProperties = event as? TrackingEventWithActionProperties, let actionProperties = page.actionProperties {
			eventWithActionProperties.actionProperties = actionProperties.merged(over: eventWithActionProperties.actionProperties)
			event = eventWithActionProperties
		}
		if var eventWithAdvertisementProperties = event as? TrackingEventWithAdvertisementProperties, let advertisementProperties = page.advertisementProperties {
			eventWithAdvertisementProperties.advertisementProperties = advertisementProperties.merged(over: eventWithAdvertisementProperties.advertisementProperties)
			event = eventWithAdvertisementProperties
		}
		if var eventWithEcommerceProperties = event as? TrackingEventWithEcommerceProperties, let ecommerceProperties = page.ecommerceProperties {
			eventWithEcommerceProperties.ecommerceProperties = ecommerceProperties.merged(over: eventWithEcommerceProperties.ecommerceProperties)
            eventWithEcommerceProperties.ecommerceProperties.processKeys(event)
            let eventEcommerceProducts = eventWithEcommerceProperties.ecommerceProperties.products
			if let products = ecommerceProperties.products where !products.isEmpty, let product = products.first {
				if let eventProducts = eventEcommerceProducts where !eventProducts.isEmpty {
					var mergedProducts: [EcommerceProperties.Product] = []
					for eventProduct in eventProducts {
						mergedProducts.append(product.merged(over: eventProduct))
					}
					eventWithEcommerceProperties.ecommerceProperties.products = mergedProducts
				}
				else {
					eventWithEcommerceProperties.ecommerceProperties.products = products
				}
			}
			event = eventWithEcommerceProperties
		}
		if var eventWithMediaProperties = event as? TrackingEventWithMediaProperties, let mediaProperties = page.mediaProperties {
			eventWithMediaProperties.mediaProperties = mediaProperties.merged(over: eventWithMediaProperties.mediaProperties)
			event = eventWithMediaProperties
		}
		if var eventWithPageProperties = event as? TrackingEventWithPageProperties {
			eventWithPageProperties.pageProperties = page.pageProperties.merged(over: eventWithPageProperties.pageProperties)
            eventWithPageProperties.pageProperties.processKeys(event)
			event = eventWithPageProperties
		}
		if var eventWithSessionDetails = event as? TrackingEventWithSessionDetails, let sessionDetails = page.sessionDetails {
			eventWithSessionDetails.sessionDetails = sessionDetails.merged(over: eventWithSessionDetails.sessionDetails)
			event = eventWithSessionDetails
		}
		if var eventWithUserProperties = event as? TrackingEventWithUserProperties, let userProperties = page.userProperties {
			eventWithUserProperties.userProperties = userProperties.merged(over: eventWithUserProperties.userProperties)
            eventWithUserProperties.userProperties.processKeys(event)
			event = eventWithUserProperties
		}

		return event
	}
	#endif


	private func eventByApplyingGlobalProperties(to event: TrackingEvent) -> TrackingEvent {
		checkIsOnMainThread()

		let global = configuration.globalProperties.merged(over: self.global)

		var event = event
		event.ipAddress = global.ipAddress ?? event.ipAddress
		event.pageName = global.pageProperties.name ?? event.pageName
		event.variables = global.variables.merged(over: event.variables)

		guard !(event is ActionEvent) else {
			return event
		}

		if var eventWithActionProperties = event as? TrackingEventWithActionProperties {
			eventWithActionProperties.actionProperties = global.actionProperties.merged(over: eventWithActionProperties.actionProperties)
			event = eventWithActionProperties
		}
		if var eventWithAdvertisementProperties = event as? TrackingEventWithAdvertisementProperties {
			eventWithAdvertisementProperties.advertisementProperties = global.advertisementProperties.merged(over: eventWithAdvertisementProperties.advertisementProperties)
			event = eventWithAdvertisementProperties
		}
		if var eventWithEcommerceProperties = event as? TrackingEventWithEcommerceProperties {
			eventWithEcommerceProperties.ecommerceProperties = global.ecommerceProperties.merged(over: eventWithEcommerceProperties.ecommerceProperties)
            eventWithEcommerceProperties.ecommerceProperties.processKeys(event)
            let eventEcommerceProducts = eventWithEcommerceProperties.ecommerceProperties.products
			if let products = global.ecommerceProperties.products where !products.isEmpty, let product = products.first {
				if let eventProducts = eventEcommerceProducts where !eventProducts.isEmpty {
					var mergedProducts: [EcommerceProperties.Product] = []
					for eventProduct in eventProducts {
						mergedProducts.append(product.merged(over: eventProduct))
					}
					eventWithEcommerceProperties.ecommerceProperties.products = mergedProducts
				}
				else {
					eventWithEcommerceProperties.ecommerceProperties.products = products
				}
			}
			event = eventWithEcommerceProperties
		}
		if var eventWithMediaProperties = event as? TrackingEventWithMediaProperties {
			eventWithMediaProperties.mediaProperties = global.mediaProperties.merged(over: eventWithMediaProperties.mediaProperties)
			event = eventWithMediaProperties
		}
		if var eventWithPageProperties = event as? TrackingEventWithPageProperties {
			eventWithPageProperties.pageProperties = global.pageProperties.merged(over: eventWithPageProperties.pageProperties)
            eventWithPageProperties.pageProperties.processKeys(event)
			event = eventWithPageProperties
		}
		if var eventWithSessionDetails = event as? TrackingEventWithSessionDetails {
			eventWithSessionDetails.sessionDetails = global.sessionDetails.merged(over: eventWithSessionDetails.sessionDetails)
			event = eventWithSessionDetails
		}
		if var eventWithUserProperties = event as? TrackingEventWithUserProperties {
			eventWithUserProperties.userProperties = global.userProperties.merged(over: eventWithUserProperties.userProperties)
            eventWithUserProperties.userProperties.processKeys(event)
			event = eventWithUserProperties
		}

		return event
	}


	private static let _everId: String = {
		_everIdIsLoaded = true
		return DefaultTracker.loadEverId()
	}()
	private static var _everIdIsLoaded = false


	private var isFirstEventAfterAppUpdate: Bool {
		didSet {
			checkIsOnMainThread()

			guard isFirstEventAfterAppUpdate != oldValue else {
				return
			}

			defaults.set(key: DefaultsKeys.isFirstEventAfterAppUpdate, to: isFirstEventAfterAppUpdate)
		}
	}


	private var isFirstEventOfApp: Bool {
		didSet {
			checkIsOnMainThread()

			guard isFirstEventOfApp != oldValue else {
				return
			}

			defaults.set(key: DefaultsKeys.isFirstEventOfApp, to: isFirstEventOfApp)
		}
	}


	internal static var isOptedOut = DefaultTracker.loadIsOptedOut() {
		didSet {
			checkIsOnMainThread()

			isOptedOutWasSetManually = true

			guard isOptedOut != oldValue else {
				return
			}

			sharedDefaults.set(key: DefaultsKeys.isOptedOut, to: isOptedOut ? true : nil)

			if isOptedOut {
				for trackerReference in instances.values {
					trackerReference.target?.requestManager.clearPendingRequests()
				}
			}
		}
	}
	private static var isOptedOutWasSetManually = false


	private static func loadEverId() -> String {
		checkIsOnMainThread()

		return sharedDefaults.stringForKey(DefaultsKeys.everId) ?? {
			let everId = String(format: "6%010.0f%08lu", arguments: [NSDate().timeIntervalSince1970, arc4random_uniform(99999999) + 1])
			sharedDefaults.set(key: DefaultsKeys.everId, to: everId)
			return everId
			}()
	}


	private static func loadIsOptedOut() -> Bool {
		checkIsOnMainThread()

		return sharedDefaults.boolForKey(DefaultsKeys.isOptedOut) ?? false
	}


	private func loadRequestQueue() {
		checkIsOnMainThread()

		guard !requestQueueLoaded else {
			return
		}

		requestQueueLoaded = true

		guard let file = requestQueueBackupFile else {
			return
		}

		let fileManager = NSFileManager.defaultManager()
		guard fileManager.itemExistsAtURL(file) else {
			return
		}

		guard !DefaultTracker.isOptedOut else {
			do {
				try fileManager.removeItemAtURL(file)
				logDebug("Ignored request queue at '\(file)': User opted out of tracking.")
			}
			catch let error {
				logError("Cannot remove request queue at '\(file)': \(error)")
			}

			return
		}

		let queue: [NSURL]
		do {
			let data = try NSData(contentsOfURL: file, options: [])

			let object: AnyObject?
			if #available(iOS 9.0, *) {
				object = try NSKeyedUnarchiver.unarchiveTopLevelObjectWithData(data)
			}
			else {
				object = NSKeyedUnarchiver.unarchiveObjectWithData(data)
			}

			guard let _queue = object as? [NSURL] else {
				logError("Cannot load request queue from '\(file)': Data has wrong format: \(object)")
				return
			}

			queue = _queue
		}
		catch let error {
			logError("Cannot load request queue from '\(file)': \(error)")
			return
		}

		logDebug("Loaded \(queue.count) queued request(s) from '\(file)'.")
		requestManager.prependRequests(queue)
	}


	#if !os(watchOS)
	private func retrieveConnectionType() -> TrackerRequest.Properties.ConnectionType? {
		guard let reachability = try? Reachability.reachabilityForInternetConnection() else {
			return nil
		}
		if reachability.isReachableViaWiFi() {
			return .wifi
		}
		else if reachability.isReachableViaWWAN() {
			if let carrierType = CTTelephonyNetworkInfo().currentRadioAccessTechnology {
				switch carrierType {
				case CTRadioAccessTechnologyGPRS, CTRadioAccessTechnologyEdge, CTRadioAccessTechnologyCDMA1x:
					return .cellular_2G

				case CTRadioAccessTechnologyWCDMA, CTRadioAccessTechnologyHSDPA, CTRadioAccessTechnologyHSUPA, CTRadioAccessTechnologyCDMAEVDORev0, CTRadioAccessTechnologyCDMAEVDORevA, CTRadioAccessTechnologyCDMAEVDORevB, CTRadioAccessTechnologyeHRPD:
					return .cellular_3G

				case CTRadioAccessTechnologyLTE:
					return .cellular_4G

				default:
					return .other
				}
			}
			else {
				return .other
			}
		}
		else if reachability.isReachable() {
			return .other
		}
		else {
			return .offline
		}
	}
	#endif


	private static func requestQueueBackupFileForWebtrekkId(webtrekkId: String) -> NSURL? {
		checkIsOnMainThread()

		let searchPathDirectory: NSSearchPathDirectory
		#if os(iOS) || os(OSX) || os(watchOS)
			searchPathDirectory = .ApplicationSupportDirectory
		#elseif os(tvOS)
			searchPathDirectory = .CachesDirectory
		#endif

		let fileManager = NSFileManager.defaultManager()

		var directory: NSURL
		do {
			directory = try fileManager.URLForDirectory(searchPathDirectory, inDomain: .UserDomainMask, appropriateForURL: nil, create: true)
		}
		catch let error {
			logError("Cannot find directory for storing request queue backup file: \(error)")
			return nil
		}

		directory = (directory.URLByAppendingPathComponent("Webtrekk") ?? NSURL())
		directory = (directory.URLByAppendingPathComponent(webtrekkId) ?? NSURL())

		if !fileManager.itemExistsAtURL(directory) {
			do {
				try fileManager.createDirectoryAtURL(directory, withIntermediateDirectories: true, attributes: [NSURLIsExcludedFromBackupKey: true])
			}
			catch let error {
				logError("Cannot create directory at '\(directory)' for storing request queue backup file: \(error)")
				return nil
			}
		}

		return directory.URLByAppendingPathComponent("requestQueue.archive")
	}


	internal func sendPendingEvents() {
		checkIsOnMainThread()

		startRequestManager()

		requestManager.sendAllRequests()
	}


	private func setUp() {
		checkIsOnMainThread()

		#if !os(watchOS)
			setUpObservers()
			updateAutomaticTracking()
		#endif

		updateSampling()
	}


	#if !os(watchOS)
	private func setUpObservers() {
		checkIsOnMainThread()

		let notificationCenter = NSNotificationCenter.defaultCenter()
		applicationDidBecomeActiveObserver = notificationCenter.addObserverForName(UIApplicationDidBecomeActiveNotification, object: nil, queue: nil) { [weak self] _ in
			self?.applicationDidBecomeActive()
		}
		applicationWillEnterForegroundObserver = notificationCenter.addObserverForName(UIApplicationWillEnterForegroundNotification, object: nil, queue: nil) { [weak self] _ in
			self?.applicationWillEnterForeground()
		}
		applicationWillResignActiveObserver = notificationCenter.addObserverForName(UIApplicationWillResignActiveNotification, object: nil, queue: nil) { [weak self] _ in
			self?.applicationWillResignActive()
		}
	}
	#endif


	private var shouldEnqueueNewEvents: Bool {
		checkIsOnMainThread()

		return isSampling && !DefaultTracker.isOptedOut
	}


	private func saveRequestQueue() {
		checkIsOnMainThread()

		guard let file = requestQueueBackupFile else {
			return
		}
		guard requestQueueLoaded || !requestManager.queue.isEmpty else {
			return
		}

		// make sure backup is loaded before overwriting it
		loadRequestQueue()

		let queue = requestManager.queue
		guard !queue.isEmpty else {
			let fileManager = NSFileManager.defaultManager()
			if fileManager.itemExistsAtURL(file) {
				do {
					try NSFileManager.defaultManager().removeItemAtURL(file)
					logDebug("Deleted request queue at '\(file).")
				}
				catch let error {
					logError("Cannot remove request queue at '\(file)': \(error)")
				}
			}

			return
		}

		let data = NSKeyedArchiver.archivedDataWithRootObject(queue)
		do {
			try data.writeToURL(file, options: .AtomicWrite)
			logDebug("Saved \(queue.count) queued request(s) to '\(file).")
		}
		catch let error {
			logError("Cannot save request queue to '\(file)': \(error)")
		}
	}


	private func startRequestManager() {
		checkIsOnMainThread()

		requestManagerStartTimer?.invalidate()
		requestManagerStartTimer = nil

		guard !requestManager.started else {
			return
		}

		#if !os(watchOS)
			guard application.applicationState == .Active else {
				return
			}
		#endif

		loadRequestQueue()
		requestManager.start()
	}


	private func stopRequestManager() {
		checkIsOnMainThread()

		guard requestManager.started else {
			return
		}

		requestManager.stop()
		saveRequestQueue()
	}


	internal func trackAction(event: ActionEvent) {
		checkIsOnMainThread()

		handleEvent(event)
	}


	internal func trackMediaAction(event: MediaEvent) {
		checkIsOnMainThread()

		handleEvent(event)
	}


	internal func trackPageView(event: PageViewEvent) {
		checkIsOnMainThread()

		handleEvent(event)
	}


	@warn_unused_result
	internal func trackerForMedia(mediaName: String, pageName: String) -> MediaTracker {
		checkIsOnMainThread()

		return DefaultMediaTracker(handler: self, mediaName: mediaName, pageName: pageName)
	}


	#if !os(watchOS)
	internal func trackerForMedia(mediaName: String, pageName: String, automaticallyTrackingPlayer player: AVPlayer) -> MediaTracker {
		checkIsOnMainThread()

		let tracker = trackerForMedia(mediaName, pageName: pageName)
		AVPlayerTracker.track(player: player, with: tracker)

		return tracker
	}
	#endif


	@warn_unused_result
	internal func trackerForPage(pageName: String) -> PageTracker {
		checkIsOnMainThread()

		return DefaultPageTracker(handler: self, pageName: pageName)
	}


	#if !os(watchOS)
	private func updateAutomaticTracking() {
		checkIsOnMainThread()

		let handler = DefaultTracker._autotrackingEventHandler

		if configuration.automaticallyTrackedPages.isEmpty {
			if let index = handler.trackers.indexOf({ $0 === self}) {
				handler.trackers.removeAtIndex(index)
			}
		}
		else {
			if !handler.trackers.contains({ $0 === self }) {
				handler.trackers.append(self)
			}

			UIViewController.setUpAutomaticTracking()
		}
	}
	#endif


	private func updateConfiguration() {
		checkIsOnMainThread()

		guard let updateUrl = configuration.configurationUpdateUrl else {
			return
		}

		requestManager.fetch(url: updateUrl) { data, error in
			if let error = error {
				logError("Cannot load configuration from \(updateUrl): \(error)")
				return
			}
			guard let data = data else {
				logError("Cannot load configuration from \(updateUrl): Server returned no data.")
				return
			}

			let configuration: TrackerConfiguration
			do {
				configuration = try XmlTrackerConfigurationParser().parse(xml: data)
			}
			catch let error {
				logError("Cannot parse configuration located at \(updateUrl): \(error)")
				return
			}

			guard configuration.version > self.configuration.version else {
				logInfo("Local configuration is up-to-date with version \(self.configuration.version).")
				return
			}
			guard configuration.webtrekkId == self.configuration.webtrekkId else {
				logError("Cannot apply new configuration located at \(updateUrl): Current webtrekkId (\(self.configuration.webtrekkId)) does not match new webtrekkId (\(configuration.webtrekkId)).")
				return
			}

			logInfo("Updating from configuration version \(self.configuration.version) to version \(configuration.version) located at \(updateUrl).")
			self.defaults.set(key: DefaultsKeys.configuration, to: data)

			self.configuration = configuration
		}
	}


	private func updateSampling() {
		checkIsOnMainThread()

		if let isSampling = defaults.boolForKey(DefaultsKeys.isSampling), samplingRate = defaults.intForKey(DefaultsKeys.samplingRate) where samplingRate == configuration.samplingRate {
			self.isSampling = isSampling
		}
		else {
			if configuration.samplingRate > 1 {
				self.isSampling = Int64(arc4random()) % Int64(configuration.samplingRate) == 0
			}
			else {
				self.isSampling = true
			}

			defaults.set(key: DefaultsKeys.isSampling, to: isSampling)
			defaults.set(key: DefaultsKeys.samplingRate, to: configuration.samplingRate)
		}
	}


    static let userAgent: String = {
		checkIsOnMainThread()

		let properties = [
			Environment.deviceModelString,
            Environment.operatingSystemName + " " + Environment.operatingSystemVersionString,
			NSLocale.currentLocale().localeIdentifier
			].joinWithSeparator("; ")

		return "Tracking Library \(WebtrekkTracking.version) (\(properties))"
	}()


	private static func validatedConfiguration(configuration: TrackerConfiguration) -> TrackerConfiguration {
		checkIsOnMainThread()

		var configuration = configuration
		var problems = [String]()
		var isError = false

		if configuration.webtrekkId.isEmpty {
			configuration.webtrekkId = "ERROR"
			problems.append("webtrekkId must not be empty!! -> changed to 'ERROR'")

			isError = true
		}

		#if !os(watchOS)
			var pageIndex = 0
			configuration.automaticallyTrackedPages = configuration.automaticallyTrackedPages.filter { page in
				defer { pageIndex += 1 }

				guard page.pageProperties.name?.nonEmpty != nil else {
					problems.append("automaticallyTrackedPages[\(pageIndex)] must not be empty")
					return false
				}

				return true
			}
		#endif

		func checkProperty<Value: Comparable>(name: String, value: Value, allowedValues: ClosedInterval<Value>) -> Value {
			guard !allowedValues.contains(value) else {
				return value
			}

			let newValue = allowedValues.clamp(value)
			problems.append("\(name) (\(value)) must be \(TrackerConfiguration.allowedMaximumSendDelays.conditionText) -> was corrected to \(newValue)")
			return newValue
		}

		configuration.maximumSendDelay       = checkProperty("maximumSendDelay",       value: configuration.maximumSendDelay,       allowedValues: TrackerConfiguration.allowedMaximumSendDelays)
		configuration.requestQueueLimit      = checkProperty("requestQueueLimit",      value: configuration.requestQueueLimit,      allowedValues: TrackerConfiguration.allowedRequestQueueLimits)
		configuration.samplingRate           = checkProperty("samplingRate",           value: configuration.samplingRate,           allowedValues: TrackerConfiguration.allowedSamplingRates)
		configuration.resendOnStartEventTime = checkProperty("resendOnStartEventTime", value: configuration.resendOnStartEventTime, allowedValues: TrackerConfiguration.allowedResendOnStartEventTimes)
		configuration.version                = checkProperty("version",                value: configuration.version,                allowedValues: TrackerConfiguration.allowedVersions)

		if !problems.isEmpty {
			(isError ? logError : logWarning)("Illegal values in tracker configuration: \(problems.joinWithSeparator(", "))")
		}

		return configuration
	}


	private func validateEvent(event: TrackingEvent) -> Bool {
		checkIsOnMainThread()

		guard event.pageName?.nonEmpty != nil else {
			logError("Cannot track event without .pageName set: \(event)")
			return false
		}

		if let event = event as? TrackingEventWithActionProperties {
			guard event.actionProperties.name?.nonEmpty != nil else {
				logError("Cannot track event without .actionProperties.name set: \(event)")
				return false
			}
		}

		if let event = event as? TrackingEventWithMediaProperties {
			guard event.mediaProperties.name?.nonEmpty != nil else {
				logError("Cannot track event without .mediaProperties.name set: \(event)")
				return false
			}
		}

		return true
	}
}


extension DefaultTracker: ActionEventHandler {

	internal func handleEvent(event: ActionEvent) {
		checkIsOnMainThread()

		enqueueRequestForEvent(event)
	}
}


extension DefaultTracker: MediaEventHandler {

	internal func handleEvent(event: MediaEvent) {
		checkIsOnMainThread()

		enqueueRequestForEvent(event)
	}
}


extension DefaultTracker: PageViewEventHandler {

	internal func handleEvent(event: PageViewEvent) {
		checkIsOnMainThread()

		enqueueRequestForEvent(event)
	}
}


extension DefaultTracker: RequestManager.Delegate {

	internal func requestManager(requestManager: RequestManager, didFailToSendRequest request: NSURL, error: RequestManager.Error) {
		checkIsOnMainThread()

		requestManagerDidFinishRequest()
	}


	internal func requestManager(requestManager: RequestManager, didSendRequest request: NSURL) {
		checkIsOnMainThread()

		requestManagerDidFinishRequest()
	}


	private func requestManagerDidFinishRequest() {
		checkIsOnMainThread()

		saveRequestQueue()

		#if !os(watchOS)
			if requestManager.queue.isEmpty {
				if backgroundTaskIdentifier != UIBackgroundTaskInvalid {
					application.endBackgroundTask(backgroundTaskIdentifier)
					backgroundTaskIdentifier = UIBackgroundTaskInvalid
				}

				if application.applicationState != .Active {
					stopRequestManager()
				}
			}
		#endif
	}
}



#if !os(watchOS)
	private final class AutotrackingEventHandler: ActionEventHandler, MediaEventHandler, PageViewEventHandler {

		private var trackers = [DefaultTracker]()


		private func broadcastEvent<Event: TrackingEvent>(event: Event, handler: (DefaultTracker) -> (Event) -> Void) {
			var event = event

			for tracker in trackers {
				guard let viewControllerType = event.viewControllerType
					where tracker.configuration.automaticallyTrackedPageForViewControllerType(viewControllerType) != nil
				else {
					continue
				}

				handler(tracker)(event)
			}
		}


		private func handleEvent(event: ActionEvent) {
			checkIsOnMainThread()

			broadcastEvent(event, handler: DefaultTracker.handleEvent(_:))
		}


		private func handleEvent(event: MediaEvent) {
			checkIsOnMainThread()

			broadcastEvent(event, handler: DefaultTracker.handleEvent(_:))
		}


		private func handleEvent(event: PageViewEvent) {
			checkIsOnMainThread()

			broadcastEvent(event, handler: DefaultTracker.handleEvent(_:))
		}
	}
#endif



private struct DefaultsKeys {

	private static let appHibernationDate = "appHibernationDate"
	private static let appVersion = "appVersion"
	private static let configuration = "configuration"
	private static let everId = "everId"
	private static let isFirstEventAfterAppUpdate = "isFirstEventAfterAppUpdate"
	private static let isFirstEventOfApp = "isFirstEventOfApp"
	private static let isSampling = "isSampling"
	private static let isOptedOut = "optedOut"
	private static let migrationCompleted = "migrationCompleted"
	private static let samplingRate = "samplingRate"
}
