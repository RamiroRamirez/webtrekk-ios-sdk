//The MIT License (MIT)
//
//Copyright (c) 2016 Webtrekk GmbH
//
//Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated documentation files (the
//"Software"), to deal in the Software without restriction, including without limitation the rights to use, copy, modify, merge, publish,
//distribute, sublicense, and/or sell copies of the Software, and to permit persons to whom the Software is furnished to do so, subject
//to the following conditions:
//
//The above copyright notice and this permission notice shall be included in all copies or substantial portions of the Software.
//
//THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF
//MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY
//CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE
//SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
//
//  Created by Widgetlabs
//

import UIKit

#if os(watchOS)
	import WatchKit
#elseif os(tvOS)
    import AVFoundation
    import ReachabilitySwift
#else
	import AVFoundation
	import CoreTelephony
	import ReachabilitySwift
#endif


final class DefaultTracker: Tracker {

	private static var instances = [ObjectIdentifier: WeakReference<DefaultTracker>]()
	private static let sharedDefaults = UserDefaults.standardDefaults.child(namespace: "webtrekk")

	#if !os(watchOS)
	fileprivate let application = UIApplication.shared
    private let deepLink = DeepLink()
    #else
    internal var isApplicationActive = false
    #endif
    
    fileprivate var flowObserver: UIFlowObserver!
	private var defaults: UserDefaults?
	private var isFirstEventOfSession = true
	private var isSampling = false
	var requestManager: RequestManager?
	private var requestQueueBackupFile: URL?
	private var requestQueueLoaded = false
	private var requestUrlBuilder: RequestUrlBuilder?
    private var campaign: Campaign?
    private var manualStart: Bool = false;
    var isInitialited: Bool = false
    /**this value override pu parameter if it is setup from code in any other way or configuraion xml*/
    var pageURL: String?

	internal var global = GlobalProperties()
	internal var plugins = [TrackerPlugin]()
    
    
    func initializeTracking(configuration: TrackerConfiguration) -> Bool{
        
        checkIsOnMainThread()
        
        self.flowObserver = UIFlowObserver(tracker: self)
        
        guard !self.isInitialited else {
            logError("Webtrekk SDK has been already initialized.")
            return false
        }
        
        let sharedDefaults = DefaultTracker.sharedDefaults
        var defaults = sharedDefaults.child(namespace: configuration.webtrekkId)
        
        var migratedRequestQueue: [URL]?
        if let webtrekkId = configuration.webtrekkId.nonEmpty , !(sharedDefaults.boolForKey(DefaultsKeys.migrationCompleted) ?? false) {
            sharedDefaults.set(key: DefaultsKeys.migrationCompleted, to: true)
            
            if WebtrekkTracking.migratesFromLibraryV3, let migration = Migration.migrateFromLibraryV3(webtrekkId: webtrekkId) {
                
                sharedDefaults.set(key: DefaultsKeys.everId, to: migration.everId)
                
                if let appVersion = migration.appVersion {
                    defaults.set(key: DefaultsKeys.appVersion, to: appVersion)
                }
                if !DefaultTracker.isOptedOutWasSetManually, let isOptedOut = migration.isOptedOut {
                    sharedDefaults.set(key: DefaultsKeys.isOptedOut, to: isOptedOut ? true : nil)
                }
                if let samplingRate = migration.samplingRate, let isSampling = migration.isSampling {
                    defaults.set(key: DefaultsKeys.isSampling, to: isSampling)
                    defaults.set(key: DefaultsKeys.samplingRate, to: samplingRate)
                }
                
                migratedRequestQueue = migration.requestQueue as [URL]?
                
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
        
        guard let validatedConfiguration = DefaultTracker.validatedConfiguration(configuration) else {
            logError("Invalid configuration initialization error")
            return false
        }
        
        if validatedConfiguration.webtrekkId != configuration.webtrekkId {
            defaults = DefaultTracker.sharedDefaults.child(namespace: validatedConfiguration.webtrekkId)
        }
        
        configuration = validatedConfiguration
        
        self.configuration = configuration
        self.defaults = defaults
        
        checkForAppUpdate()
        
        self.isFirstEventAfterAppUpdate = defaults.boolForKey(DefaultsKeys.isFirstEventAfterAppUpdate) ?? false
        self.isFirstEventOfApp = defaults.boolForKey(DefaultsKeys.isFirstEventOfApp) ?? true
        self.manualStart = configuration.maximumSendDelay == 0
        self.requestManager = RequestManager(queueLimit: configuration.requestQueueLimit, manualStart: self.manualStart)
        self.requestQueueBackupFile = DefaultTracker.requestQueueBackupFileForWebtrekkId(configuration.webtrekkId)
        self.requestUrlBuilder = RequestUrlBuilder(serverUrl: configuration.serverUrl, webtrekkId: configuration.webtrekkId)
        
        self.campaign = Campaign(trackID: configuration.webtrekkId)
        
        campaign?.processCampaign()
        
        DefaultTracker.instances[ObjectIdentifier(self)] = WeakReference(self)
        
        requestManager?.delegate = self
        
        if let migratedRequestQueue = migratedRequestQueue , !DefaultTracker.isOptedOut {
            requestManager?.prependRequests(migratedRequestQueue)
        }
        
        guard setUp() else {
            return false
        }
        
        checkForDuplicateTrackers()
        
        logInfo("Initialization is completed")
        self.isInitialited = true
        return true
    }
    
    
    func checkIfInitialized() -> Bool{
        if !self.isInitialited {
            logError("Webtrekk SDK isn't initialited")
        }
        
        return self.isInitialited
    }


	deinit {
		let id = ObjectIdentifier(self)
		
        onMainQueue(synchronousIfPossible: true) {
			DefaultTracker.instances[id] = nil

			if let requestManager = self.requestManager, requestManager.started {
				requestManager.stop()
			}
		}
	}

    func initHibertationDate(){
        
        defaults?.set(key: DefaultsKeys.appHibernationDate, to: Date())
    }
    
    func updateFirstSession(){
        if let hibernationDate = defaults?.dateForKey(DefaultsKeys.appHibernationDate) , -hibernationDate.timeIntervalSinceNow < configuration.resendOnStartEventTime {
            isFirstEventOfSession = false
        }
        else {
            isFirstEventOfSession = true
        }
    }
    
    internal func initTimers() {
        checkIsOnMainThread()
        
        startRequestManager()
        
        let _ = Timer.scheduledTimerWithTimeInterval(15) {
            self.updateConfiguration()
        }
    }



    typealias AutoEventHandler = ActionEventHandler & MediaEventHandler & PageViewEventHandler
    static let autotrackingEventHandler: AutoEventHandler = AutotrackingEventHandler()

	private func checkForAppUpdate() {
		checkIsOnMainThread()

		let lastCheckedAppVersion = defaults?.stringForKey(DefaultsKeys.appVersion)
		if lastCheckedAppVersion != Environment.appVersion {
			defaults?.set(key: DefaultsKeys.appVersion, to: Environment.appVersion)

            self.isFirstEventAfterAppUpdate = true
		}
	}


	private func checkForDuplicateTrackers() {
		let hasDuplicate = DefaultTracker.instances.values.contains { $0.target?.configuration.webtrekkId == configuration.webtrekkId && $0.target !== self }
		if hasDuplicate {
			logError("Multiple tracker instances for the same Webtrekk ID '\(configuration.webtrekkId)' were created. This is not supported and will corrupt tracking.")
		}
	}


	internal fileprivate(set) var configuration: TrackerConfiguration! {
		didSet {
			checkIsOnMainThread()
            
			requestManager?.queueLimit = configuration.requestQueueLimit

			requestUrlBuilder?.serverUrl = configuration.serverUrl
			requestUrlBuilder?.webtrekkId = configuration.webtrekkId

			updateSampling()

			updateAutomaticTracking()
		}
	}

    private func generateRequestProperties() -> TrackerRequest.Properties {
        
        var requestProperties = TrackerRequest.Properties(
            everId:       everId,
            samplingRate: configuration.samplingRate,
            timeZone:     TimeZone.current,
            timestamp:    Date(),
            userAgent:    DefaultTracker.userAgent
        )
        requestProperties.locale = Locale.current
        
        #if os(watchOS)
            let device = WKInterfaceDevice.current()
            requestProperties.screenSize = (width: Int(device.screenBounds.width * device.screenScale), height: Int(device.screenBounds.height * device.screenScale))
        #else
            let screen = UIScreen.main
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
            requestProperties.requestQueueSize = requestManager?.queue.count
        }
        
        #if !os(watchOS) && !os(tvOS)
            if configuration.automaticallyTracksConnectionType, let connectionType = retrieveConnectionType(){
                requestProperties.connectionType = connectionType
            }
            
            if configuration.automaticallyTracksInterfaceOrientation {
                requestProperties.interfaceOrientation = application.statusBarOrientation
            }
        #endif
        
        return requestProperties
    }


	internal func enqueueRequestForEvent(_ event: TrackingEvent) {
		checkIsOnMainThread()

        guard self.checkIfInitialized() else {
            return
        }
        
        let requestProperties = generateRequestProperties()
        
        //merge lowest priority global properties over request properties.
        let requestBuilder = RequestTrackerBuilder(self.campaign!, pageURL: self.pageURL, configuration: self.configuration!, global: self.global)
        
        #if !os(watchOS)
            requestBuilder.setDeepLink(deepLink: self.deepLink)
        #endif
        
        guard var request = requestBuilder.createRequest(event, requestProperties: requestProperties) else {
            return
        }
        
		for plugin in plugins {
			request = plugin.tracker(self, requestForQueuingRequest: request)
		}

		if shouldEnqueueNewEvents, let requestUrl = requestUrlBuilder?.urlForRequest(request) {
			requestManager?.enqueueRequest(requestUrl, maximumDelay: configuration.maximumSendDelay)
		}

		for plugin in plugins {
			plugin.tracker(self, didQueueRequest: request)
		}

		isFirstEventAfterAppUpdate = false
		isFirstEventOfApp = false
		isFirstEventOfSession = false
	}
    
    /** get and set everID. If you set Ever ID it started to use new value for all requests*/
    var everId: String {
        get {
            checkIsOnMainThread()
            
            // cash ever id in internal parameter to avoid multiple request to setting.
            if everIdInternal == nil {
                everIdInternal = try? DefaultTracker.generateEverId()
                return everIdInternal!
            } else {
                return everIdInternal!
            }
        }
        
        set(newEverID) {
            checkIsOnMainThread()
            
            //check if ever id has correct format
            if let isMatched = newEverID.isMatchForRegularExpression("\\d{19}") , isMatched {
                // set ever id value in setting and in cash
                DefaultTracker.sharedDefaults.set(key: DefaultsKeys.everId, to: newEverID)
                self.everIdInternal = newEverID
            } else {
                WebtrekkTracking.defaultLogger.logError("Incorrect ever id format: \(newEverID)")
            }
        }
    }
    
    static func generateEverId() throws -> String {
        
        var everId = DefaultTracker.sharedDefaults.stringForKey(DefaultsKeys.everId)
        
        if everId != nil  {
            return everId!
        }else {
            everId = String(format: "6%010.0f%08lu", arguments: [Date().timeIntervalSince1970, arc4random_uniform(99999999) + 1])
            DefaultTracker.sharedDefaults.set(key: DefaultsKeys.everId, to: everId)
            
            guard everId != nil else {
                let msg = "Can't generate ever id"
                let _ = TrackerError(message: msg)
                return ""
            }
            
            return everId!
        }
        
        
    }
    
    //cash for ever id
    private var everIdInternal: String?
    
    private var isFirstEventAfterAppUpdate: Bool = false {
		didSet {
			checkIsOnMainThread()

			guard isFirstEventAfterAppUpdate != oldValue else {
				return
			}

			defaults?.set(key: DefaultsKeys.isFirstEventAfterAppUpdate, to: isFirstEventAfterAppUpdate)
		}
	}


	private var isFirstEventOfApp: Bool = true {
		didSet {
			checkIsOnMainThread()

			guard isFirstEventOfApp != oldValue else {
				return
			}

			defaults?.set(key: DefaultsKeys.isFirstEventOfApp, to: isFirstEventOfApp)
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
					trackerReference.target?.requestManager?.clearPendingRequests()
				}
			}
		}
	}
	private static var isOptedOutWasSetManually = false


	private static func loadIsOptedOut() -> Bool {
		checkIsOnMainThread()

		return sharedDefaults.boolForKey(DefaultsKeys.isOptedOut) ?? false
	}


	private func loadRequestQueue() {
		checkIsOnMainThread()

        guard self.checkIfInitialized() else {
            return
        }

		guard !requestQueueLoaded else {
			return
		}

		requestQueueLoaded = true

		guard let file = requestQueueBackupFile else {
			return
		}

		let fileManager = FileManager.default
		guard fileManager.itemExistsAtURL(file) else {
			return
		}

		guard !DefaultTracker.isOptedOut else {
			do {
				try fileManager.removeItem(at: file)
				logDebug("Ignored request queue at '\(file)': User opted out of tracking.")
			}
			catch let error {
				logError("Cannot remove request queue at '\(file)': \(error)")
			}

			return
		}

		let queue: [URL]
		do {
			let data = try Data(contentsOf: file, options: [])

			let object: AnyObject?
			if #available(iOS 9.0, *) {
				object = try NSKeyedUnarchiver.unarchiveTopLevelObjectWithData(data as NSData)
			}
			else {
				object = NSKeyedUnarchiver.unarchiveObject(with: data) as AnyObject?
			}

			guard let _queue = object as? [URL] else {
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
		requestManager?.prependRequests(queue)
	}


	#if !os(watchOS) && !os(tvOS)
	private func retrieveConnectionType() -> TrackerRequest.Properties.ConnectionType? {
		guard let reachability = Reachability.init() else {
			return nil
		}
		if reachability.isReachableViaWiFi {
			return .wifi
		}
		else if reachability.isReachableViaWWAN {
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
		else if reachability.isReachable {
			return .other
		}
		else {
			return .offline
		}
	}
	#endif


	private static func requestQueueBackupFileForWebtrekkId(_ webtrekkId: String) -> URL? {
		checkIsOnMainThread()

		let searchPathDirectory: FileManager.SearchPathDirectory
		#if os(iOS) || os(OSX) || os(watchOS)
			searchPathDirectory = .applicationSupportDirectory
		#elseif os(tvOS)
			searchPathDirectory = .cachesDirectory
		#endif

		let fileManager = FileManager.default

		var directory: URL
		do {
			directory = try fileManager.url(for: searchPathDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
		}
		catch let error {
			logError("Cannot find directory for storing request queue backup file: \(error)")
			return nil
		}

		directory = directory.appendingPathComponent("Webtrekk")
		directory = directory.appendingPathComponent(webtrekkId)

		if !fileManager.itemExistsAtURL(directory) {
			do {
				try fileManager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [URLResourceKey.isExcludedFromBackupKey.rawValue: true])
			}
			catch let error {
				logError("Cannot create directory at '\(directory)' for storing request queue backup file: \(error)")
				return nil
			}
		}

		return directory.appendingPathComponent("requestQueue.archive")
	}

    /**Functions sends all request from cache to server. Function can be used only for manual send mode, when <sendDelay>0</sendDelay>
     otherwise it produce error log and don't do anything*/
	internal func sendPendingEvents() {
		checkIsOnMainThread()
        
        guard checkIfInitialized() else {
            return
        }

        guard self.manualStart else {
            WebtrekkTracking.defaultLogger.logError("No manual send mode (sendDelay == 0). Command is ignored. ")
            return
        }
        
        self.requestManager?.sendAllRequests()
	}


	private func setUp() -> Bool {
		checkIsOnMainThread()

        guard self.flowObserver.setup() else {
            return false
        }
		
        #if !os(watchOS)
            setupAutoDeepLinkTrack()
		#endif

		updateSampling()
        
        return true
	}

	private var shouldEnqueueNewEvents: Bool {
		checkIsOnMainThread()

		return isSampling && !DefaultTracker.isOptedOut
	}


	func saveRequestQueue() {
		checkIsOnMainThread()
        
        guard self.checkIfInitialized() else {
            return
        }

		guard let file = requestQueueBackupFile else {
			return
		}
		guard requestQueueLoaded || !(requestManager?.queue.isEmpty)! else {
			return
		}

		// make sure backup is loaded before overwriting it
		loadRequestQueue()

		guard let queue = requestManager?.queue, !queue.isEmpty else {
			let fileManager = FileManager.default
			if fileManager.itemExistsAtURL(file) {
				do {
					try FileManager.default.removeItem(at: file)
					logDebug("Deleted request queue at '\(file).")
				}
				catch let error {
					logError("Cannot remove request queue at '\(file)': \(error)")
				}
			}

			return
		}

		let data = NSKeyedArchiver.archivedData(withRootObject: queue)
		do {
			try data.write(to: file, options: .atomicWrite)
			logDebug("Saved \(queue.count) queued request(s) to '\(file).")
		}
		catch let error {
			logError("Cannot save request queue to '\(file)': \(error)")
		}
	}


	func startRequestManager() {
		checkIsOnMainThread()
        
        guard checkIfInitialized() else {
            return
        }

		guard let started = requestManager?.started, !started else {
			return
		}

		loadRequestQueue()
		requestManager?.start()
	}


	func stopRequestManager() {
		checkIsOnMainThread()
        
        guard checkIfInitialized() else {
            return
        }

		guard (requestManager?.started)! else {
			return
		}

		requestManager?.stop()
		saveRequestQueue()
	}


	internal func trackAction(_ event: ActionEvent) {
		checkIsOnMainThread()

		handleEvent(event)
	}


	internal func trackMediaAction(_ event: MediaEvent) {
		checkIsOnMainThread()

		handleEvent(event)
	}


	internal func trackPageView(_ event: PageViewEvent) {
		checkIsOnMainThread()

		handleEvent(event)
	}


	
	internal func trackerForMedia(_ mediaName: String, pageName: String) -> MediaTracker {
		checkIsOnMainThread()

		return DefaultMediaTracker(handler: self, mediaName: mediaName, pageName: pageName)
	}


	#if !os(watchOS)
	internal func trackerForMedia(_ mediaName: String, pageName: String, automaticallyTrackingPlayer player: AVPlayer) -> MediaTracker {
		checkIsOnMainThread()

		let tracker = trackerForMedia(mediaName, pageName: pageName)
		AVPlayerTracker.track(player: player, with: tracker)

		return tracker
	}
	#endif


	
	internal func trackerForPage(_ pageName: String) -> PageTracker {
		checkIsOnMainThread()

		return DefaultPageTracker(handler: self, pageName: pageName)
	}
    
    /** return recommendation class instance for getting recommendations. Each call returns new instance. Returns nil if SDK isn't initialized*/
    func getRecommendations() -> Recommendation? {
        guard checkIfInitialized() else {
            return nil
        }
        
        return RecomendationImpl(configuration: self.configuration)
    }


    #if !os(watchOS)
    fileprivate func setupAutoDeepLinkTrack()
    {
        //init deep link to get automatic object
        deepLink.deepLinkInit()
    }
    #endif
    

	fileprivate func updateAutomaticTracking() {
		checkIsOnMainThread()

		let handler = DefaultTracker.autotrackingEventHandler as! AutotrackingEventHandler

		if self.configuration.automaticallyTrackedPages.isEmpty {
			if let index = handler.trackers.index(where: { [weak self] in $0.target === self}) {
				handler.trackers.remove(at: index)
			}
		}
		else {
			if !handler.trackers.contains(where: {[weak self] in $0.target === self }) {
				handler.trackers.append(WeakReference(self))
			}

            #if !os(watchOS)
			UIViewController.setUpAutomaticTracking()
            #else
            WKInterfaceController.setUpAutomaticTracking()
            #endif
		}
	}


	func updateConfiguration() {
		checkIsOnMainThread()

		guard let updateUrl = self.configuration.configurationUpdateUrl else {
			return
		}

		let _ = requestManager?.fetch(url: updateUrl) { data, error in
			if let error = error {
				logError("Cannot load configuration from \(updateUrl): \(error)")
				return
			}
			guard let data = data else {
				logError("Cannot load configuration from \(updateUrl): Server returned no data.")
				return
			}

			var configuration: TrackerConfiguration
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

            guard let validatedConfiguration = DefaultTracker.validatedConfiguration(configuration) else {
                logError("Invalid updated configuration initialization error")
                return
            }
            
            configuration = validatedConfiguration
            
			guard configuration.webtrekkId == self.configuration.webtrekkId else {
				logError("Cannot apply new configuration located at \(updateUrl): Current webtrekkId (\(self.configuration.webtrekkId)) does not match new webtrekkId (\(configuration.webtrekkId)).")
				return
			}

			logInfo("Updating from configuration version \(self.configuration.version) to version \(configuration.version) located at \(updateUrl).")
			self.defaults?.set(key: DefaultsKeys.configuration, to: data)

			self.configuration = configuration
		}
	}


	private func updateSampling() {
		checkIsOnMainThread()

		if let isSampling = defaults?.boolForKey(DefaultsKeys.isSampling), let samplingRate = defaults?.intForKey(DefaultsKeys.samplingRate) , samplingRate == configuration.samplingRate {
			self.isSampling = isSampling
		}
		else {
			if configuration.samplingRate > 1 {
				self.isSampling = Int64(arc4random()) % Int64(configuration.samplingRate) == 0
			}
			else {
				self.isSampling = true
			}

			defaults?.set(key: DefaultsKeys.isSampling, to: isSampling)
			defaults?.set(key: DefaultsKeys.samplingRate, to: configuration.samplingRate)
		}
	}


    static let userAgent: String = {
		checkIsOnMainThread()

		let properties = [
			Environment.deviceModelString,
            Environment.operatingSystemName + " " + Environment.operatingSystemVersionString,
			Locale.current.identifier
			].joined(separator: "; ")

		return "Tracking Library \(WebtrekkTracking.version) (\(properties))"
	}()


	private static func validatedConfiguration(_ configuration: TrackerConfiguration) -> TrackerConfiguration? {
		checkIsOnMainThread()

		var configuration = configuration
		var problems = [String]()
		var isError = false

		guard !configuration.webtrekkId.isEmpty else {
			configuration.webtrekkId = "ERROR"
			problems.append("webtrekkId must not be empty!! -> changed to 'ERROR'")

            return nil
		}
        
        guard !configuration.serverUrl.absoluteString.isEmpty else {
            
            problems.append("trackDomain must not be empty!! -> changed to 'ERROR'")
            
            return nil
        }

        var pageIndex = 0
        configuration.automaticallyTrackedPages = configuration.automaticallyTrackedPages.filter { page in
            defer { pageIndex += 1 }

            guard page.pageProperties.name?.nonEmpty != nil else {
                problems.append("automaticallyTrackedPages[\(pageIndex)] must not be empty")
                isError = true
                return false
            }
            
            RequestTrackerBuilder.produceWarningForProperties(properties: page)

            return true
        }
        
        RequestTrackerBuilder.produceWarningForProperties(properties: configuration.globalProperties)

		func checkProperty<Value: Comparable>(_ name: String, value: Value, allowedValues: ClosedRange<Value>) -> Value {
			guard !allowedValues.contains(value) else {
				return value
			}

			let newValue = allowedValues.clamp(value)
			problems.append("\(name) (\(value)) must be \(TrackerConfiguration.allowedMaximumSendDelays.conditionText) -> was corrected to \(newValue)")
            isError = true
			return newValue
		}

		configuration.maximumSendDelay       = checkProperty("maximumSendDelay",       value: configuration.maximumSendDelay,       allowedValues: TrackerConfiguration.allowedMaximumSendDelays)
		configuration.requestQueueLimit      = checkProperty("requestQueueLimit",      value: configuration.requestQueueLimit,      allowedValues: TrackerConfiguration.allowedRequestQueueLimits)
		configuration.samplingRate           = checkProperty("samplingRate",           value: configuration.samplingRate,           allowedValues: TrackerConfiguration.allowedSamplingRates)
		configuration.resendOnStartEventTime = checkProperty("resendOnStartEventTime", value: configuration.resendOnStartEventTime, allowedValues: TrackerConfiguration.allowedResendOnStartEventTimes)
		configuration.version                = checkProperty("version",                value: configuration.version,                allowedValues: TrackerConfiguration.allowedVersions)

		if !problems.isEmpty {
			(isError ? logError : logWarning)("Illegal values in tracker configuration: \(problems.joined(separator: ", "))")
		}

		return configuration
	}


    #if !os(watchOS)

    /** set media code. Media code will be sent with next page request only. Only setter is working. Getter always returns ""d*/
    var mediaCode: String {
        get {
            return ""
        }
        
        set (newMediaCode) {
            checkIsOnMainThread()
            deepLink.setMediaCode(newMediaCode)
        }
    }
    #endif
    
}


extension DefaultTracker: ActionEventHandler {

	internal func handleEvent(_ event: ActionEvent) {
		checkIsOnMainThread()

		enqueueRequestForEvent(event)
	}
}


extension DefaultTracker: MediaEventHandler {

	internal func handleEvent(_ event: MediaEvent) {
		checkIsOnMainThread()

		enqueueRequestForEvent(event)
	}
}


extension DefaultTracker: PageViewEventHandler {

	internal func handleEvent(_ event: PageViewEvent) {
		checkIsOnMainThread()

		enqueueRequestForEvent(event)
	}
}


extension DefaultTracker: RequestManager.Delegate {

	internal func requestManager(_ requestManager: RequestManager, didFailToSendRequest request: URL, error: RequestManager.ConnectionError) {
		checkIsOnMainThread()

		requestManagerDidFinishRequest()
	}


	internal func requestManager(_ requestManager: RequestManager, didSendRequest request: URL) {
		checkIsOnMainThread()
	}


	private func requestManagerDidFinishRequest() {
		checkIsOnMainThread()
        
        guard self.checkIfInitialized() else {
            return
        }
		
        saveRequestQueue()

		#if !os(watchOS)
			if requestManager!.queue.isEmpty {
                
                self.flowObserver.finishBackroundTask()

				if application.applicationState != .active {
					stopRequestManager()
				}
			}
		#endif
	}
}



fileprivate final class AutotrackingEventHandler: ActionEventHandler, MediaEventHandler, PageViewEventHandler {

    fileprivate var trackers = [WeakReference<DefaultTracker>]()


    private func broadcastEvent<Event: TrackingEvent>(_ event: Event, handler: (DefaultTracker) -> (Event) -> Void) {
        var event = event

        for trackerOpt in trackers {
            guard let viewControllerType = event.viewControllerType, let tracker = trackerOpt.target
                , tracker.configuration.automaticallyTrackedPageForViewControllerType(viewControllerType) != nil
            else {
                continue
            }

            handler(tracker)(event)
        }
    }


    fileprivate func handleEvent(_ event: ActionEvent) {
        checkIsOnMainThread()

        broadcastEvent(event, handler: DefaultTracker.handleEvent(_:))
    }


    fileprivate func handleEvent(_ event: MediaEvent) {
        checkIsOnMainThread()

        broadcastEvent(event, handler: DefaultTracker.handleEvent(_:))
    }


    fileprivate func handleEvent(_ event: PageViewEvent) {
        checkIsOnMainThread()

        broadcastEvent(event, handler: DefaultTracker.handleEvent(_:))
    }
}



struct DefaultsKeys {

	fileprivate static let appHibernationDate = "appHibernationDate"
	fileprivate static let appVersion = "appVersion"
	fileprivate static let configuration = "configuration"
	static let everId = "everId"
	fileprivate static let isFirstEventAfterAppUpdate = "isFirstEventAfterAppUpdate"
	fileprivate static let isFirstEventOfApp = "isFirstEventOfApp"
	fileprivate static let isSampling = "isSampling"
	fileprivate static let isOptedOut = "optedOut"
	fileprivate static let migrationCompleted = "migrationCompleted"
	fileprivate static let samplingRate = "samplingRate"
}

private extension TrackingValue {
    
    mutating func resolve(variables: [String: String]) -> Bool {
        switch self {
        case let .customVariable(key):
            if let value = variables[key] {
                self = .constant(value)
                return true
            }
        default:
            return false
        }
        return false
    }
}
