import CryptoSwift
import Foundation


internal final class RequestUrlBuilder {

	internal var baseUrl: NSURL


	internal init(serverUrl: NSURL, webtrekkId: String) {
		self.baseUrl = RequestUrlBuilder.buildBaseUrl(serverUrl: serverUrl, webtrekkId: webtrekkId)
		self.serverUrl = serverUrl
		self.webtrekkId = webtrekkId
	}


	private static func buildBaseUrl(serverUrl serverUrl: NSURL, webtrekkId: String) -> NSURL {
		return (serverUrl.URLByAppendingPathComponent(webtrekkId)?.URLByAppendingPathComponent("wt") ?? NSURL())
	}


	internal var serverUrl: NSURL {
		didSet {
			guard serverUrl != oldValue else {
				return
			}

			baseUrl = RequestUrlBuilder.buildBaseUrl(serverUrl: serverUrl, webtrekkId: webtrekkId)
		}
	}


	internal func urlForRequest(request: TrackerRequest) -> NSURL? {
		let event = request.event
		guard let pageName = event.pageName?.nonEmpty else {
			logError("Tracking event must contain a page name: \(request)")
			return nil
		}

		let properties = request.properties
		let screenSize = "\(properties.screenSize?.width ?? 0)x\(properties.screenSize?.height ?? 0)"

		var parameters = [NSURLQueryItem]()
		parameters.append(name: "p", value: "400,\(pageName),0,\(screenSize),32,0,\(Int64(properties.timestamp.timeIntervalSince1970 * 1000)),0,0,0")
		parameters.append(name: "eid", value: properties.everId)
		parameters.append(name: "fns", value: properties.isFirstEventOfSession ? "1" : "0")
		parameters.append(name: "mts", value: String(Int64(properties.timestamp.timeIntervalSince1970 * 1000)))
		parameters.append(name: "one", value: properties.isFirstEventOfApp ? "1" : "0")
		parameters.append(name: "ps", value: String(properties.samplingRate))
		parameters.append(name: "tz", value: String(Double(properties.timeZone.secondsFromGMT) / 60 / 60))
		parameters.append(name: "X-WT-UA", value: properties.userAgent)

		if let ipAddress = event.ipAddress {
			parameters.append(name: "X-WT-IP", value: ipAddress)
		}
		if let language = properties.locale?.objectForKey(NSLocaleLanguageCode) as? String {
			parameters.append(name: "la", value: language)
		}

		if let event = event as? MediaEvent {
			let actionId: String
			switch event.action {
			case .finish:           actionId = "finish"
			case .initialize:       actionId = "init"
			case .pause:            actionId = "pause"
			case .play:             actionId = "play"
			case .position:         actionId = "pos"
			case .seek:             actionId = "seek"
			case .stop:             actionId = "stop"
			case let .custom(name): actionId = name
			}
			parameters.append(name: "mk", value: actionId)
		}
		else {
			if let requestQueueSize = properties.requestQueueSize {
				parameters.append(name: "cp784", value: String(requestQueueSize))
			}
			if let appVersion = properties.appVersion {
				parameters.append(name: "cs804", value: appVersion)
			}
			if let connectionType = properties.connectionType {
				parameters.append(name: "cs807", value: connectionType.serialized)
			}
			if let advertisingId = properties.advertisingId {
				parameters.append(name: "cs809", value: advertisingId.UUIDString)
			}
			if let advertisingTrackingEnabled = properties.advertisingTrackingEnabled {
				parameters.append(name: "cs813", value: advertisingTrackingEnabled ? "1" : "0")
			}
			if properties.isFirstEventAfterAppUpdate {
				parameters.append(name: "cs815", value: "1")
			}

			parameters += request.crossDeviceProperties.asQueryItems()

			#if !os(watchOS)
				if let interfaceOrientation = properties.interfaceOrientation {
					parameters.append(name: "cp783", value: interfaceOrientation.serialized)
				}
			#endif
		}

		if let actionProperties = (event as? TrackingEventWithActionProperties)?.actionProperties {
			guard let name = actionProperties.name?.nonEmpty else {
				logError("Tracking event must contain an action name: \(request)")
				return nil
			}

			parameters.append(name: "ct", value: name)

			if let details = actionProperties.details {
				parameters += details.mapNotNil { NSURLQueryItem(name: "ck", property: $0, for: request) }
			}
		}
		if let advertisementProperties = (event as? TrackingEventWithAdvertisementProperties)?.advertisementProperties {
			if let action = advertisementProperties.action {
				parameters.append(name: "mca", value: action)
			}
			if let id = advertisementProperties.id {
				parameters.append(name: "mc", value: id)
			}
			if let details = advertisementProperties.details {
				parameters += details.mapNotNil { NSURLQueryItem(name: "cc", property: $0, for: request) }
			}
		}
		if let ecommerceProperties = (event as? TrackingEventWithEcommerceProperties)?.ecommerceProperties {
			parameters += ecommerceProperties.asQueryItems(for: request)
		}
		if let mediaProperties = (event as? TrackingEventWithMediaProperties)?.mediaProperties {
			guard mediaProperties.name?.nonEmpty != nil else {
				logError("Tracking event must contain a media name: \(request)")
				return nil
			}

			parameters += mediaProperties.asQueryItems(for: request)
		}
		if let pageProperties = (event as? TrackingEventWithPageProperties)?.pageProperties {
			parameters += pageProperties.asQueryItems(for: request)
		}
		if let sessionDetails = (event as? TrackingEventWithSessionDetails)?.sessionDetails {
			parameters += sessionDetails.mapNotNil { NSURLQueryItem(name: "cs", property: $0, for: request) }
		}
		if let userProperties = (event as? TrackingEventWithUserProperties)?.userProperties {
			parameters += userProperties.asQueryItems(for: request)
		}

		parameters.append(name: "eor", value: "1")

		guard let urlComponents = NSURLComponents(URL: baseUrl, resolvingAgainstBaseURL: true) else {
			logError("Could not parse baseUrl: \(baseUrl)")
			return nil
		}

		urlComponents.queryItems = parameters

		guard let url = urlComponents.URL else {
			logError("Cannot build URL from components: \(urlComponents)")
			return nil
		}

		return url
	}


	internal var webtrekkId: String {
		didSet {
			guard webtrekkId != oldValue else {
				return
			}

			baseUrl = RequestUrlBuilder.buildBaseUrl(serverUrl: serverUrl, webtrekkId: webtrekkId)
		}
	}
}


private extension CrossDeviceProperties {
	private func asQueryItems() -> [NSURLQueryItem] {
		var items = [NSURLQueryItem]()
		if let address = address {
			switch address {
			case let .plain(value):
				if value.isEmpty() {
					break
				}
				var result = ""
				if let regex = try? NSRegularExpression(pattern: "str\\.?\\s*\\|", options: NSRegularExpressionOptions.CaseInsensitive) {
					result = regex.stringByReplacingMatchesInString(value.toLine() , options: .WithTransparentBounds, range: NSMakeRange(0, value.toLine() .characters.count), withTemplate: "strasse|")
				}
				if result.isEmpty {
					break
				}
				items.append(name: "cdb5", value: result.md5().lowercaseString)
				items.append(name: "cdb6", value: result.sha256().lowercaseString)

			case let .hashed(md5, sha256):
				if let md5 = md5 {
					items.append(name: "cdb5", value: md5.lowercaseString)
				}
				if let sha256 = sha256 {
					items.append(name: "cdb6", value: sha256.lowercaseString)
				}
			}
		}

		if let androidId = androidId {
			items.append(name: "cdb7", value: androidId)
		}

		if let email = emailAddress {
			switch email {
			case let .plain(value):
				let result = value.stringByTrimmingCharactersInSet(NSCharacterSet.whitespaceCharacterSet()).lowercaseString
				items.append(name: "cdb1", value: result.md5().lowercaseString)
				items.append(name: "cdb2", value: result.sha256().lowercaseString)

			case let .hashed(md5, sha256):
				if let md5 = md5 {
					items.append(name: "cdb1", value: md5.lowercaseString)
				}
				if let sha256 = sha256 {
					items.append(name: "cdb2", value: sha256.lowercaseString)
				}
			}
		}
		if let facebookId = facebookId {
			items.append(name: "cdb10", value: facebookId.lowercaseString.sha256().lowercaseString)
		}
		if let googlePlusId = googlePlusId {
			items.append(name: "cdb12", value: googlePlusId.lowercaseString.sha256().lowercaseString)
		}
		if let iosId = iosId {
			items.append(name: "cdb8", value: iosId)
		}
		if let linkedInId = linkedInId {
			items.append(name: "cdb13", value: linkedInId.lowercaseString.sha256().lowercaseString)
		}
		if let phoneNumber = phoneNumber {
			switch phoneNumber {
			case let .plain(value):
				let result = value.componentsSeparatedByCharactersInSet(NSCharacterSet(charactersInString: "0123456789").invertedSet).joinWithSeparator("")
				items.append(name: "cdb3", value: result.md5().lowercaseString)
				items.append(name: "cdb4", value: result.sha256().lowercaseString)

			case let .hashed(md5, sha256):
				if let md5 = md5 {
					items.append(name: "cdb3", value: md5.lowercaseString)
				}
				if let sha256 = sha256 {
					items.append(name: "cdb4", value: sha256.lowercaseString)
				}
			}
		}
		if let twitterId = twitterId {
			items.append(name: "cdb11", value: twitterId.lowercaseString.sha256().lowercaseString)
		}
		if let windowsId = windowsId {
			items.append(name: "cdb9", value: windowsId)
		}
		
		return items
	}
}


private extension CrossDeviceProperties.Address {

	private func isEmpty() -> Bool {
		if firstName != nil || lastName != nil || street != nil || streetNumber != nil || zipCode != nil {
			return false
		}
		return true
	}


	private func toLine() -> String {
		return [firstName, lastName, zipCode, street, streetNumber].filterNonNil().joinWithSeparator("|").lowercaseString.stringByReplacingOccurrencesOfString(" ", withString: "").stringByReplacingOccurrencesOfString("ä", withString: "ae").stringByReplacingOccurrencesOfString("ö", withString: "oe").stringByReplacingOccurrencesOfString("ü", withString: "ue").stringByReplacingOccurrencesOfString("ß", withString: "ss").stringByReplacingOccurrencesOfString("_", withString: "").stringByReplacingOccurrencesOfString("-", withString: "")
	}
}


private extension EcommerceProperties {

	private func asQueryItems(for request: TrackerRequest) ->  [NSURLQueryItem] {
		var items = [NSURLQueryItem]()
		if let currencyCode = currencyCode {
			items.append(name: "cr", value: currencyCode)
		}
		if let details = details {
			items += details.mapNotNil { NSURLQueryItem(name: "cb", property: $0, for: request) }
		}
		if let orderNumber = orderNumber {
			items.append(name: "oi", value: orderNumber)
		}
		items += mergeProductQueryItems(for: request)
		if let status = status {
				items.append(name: "st", value: status.rawValue)
		}
		if let totalValue = totalValue {
			items.append(name: "ov", value: "\(totalValue)")
		}
		if let voucherValue = voucherValue {
			items.append(name: "cb563", value: "\(voucherValue)")
		}
		return items
	}


	private func mergeProductQueryItems(for request: TrackerRequest) -> [NSURLQueryItem] {
		
        if self.products == nil && self.productConf == nil {
                return []
		}

		var items = [NSURLQueryItem]()

        if let confName = self.productConf?.name {
            items.append(name: "ba", value: confName)
        } else {
            if let names = products?.map({ $0.name ?? "" }) where names.joinWithSeparator("").nonEmpty != nil {
                items.append(name: "ba", value: names.joinWithSeparator(";"))
            }
        }
		
        if let confPrice = self.productConf?.price {
            items.append(name: "co", value: confPrice)
        } else {
            if let prices = products?.map({ $0.price ?? "" }) where prices.joinWithSeparator("").nonEmpty != nil {
                items.append(name: "co", value: prices.joinWithSeparator(";"))
            }
        }
        
        if let confQuantity = self.productConf?.quantity {
            items.append(name: "qn", value: String(confQuantity))
        } else {
            if let quantity = products?.map({ $0.quantity.map { String($0) } ?? "" }) where quantity.joinWithSeparator("").nonEmpty != nil {
                items.append(name: "qn", value: quantity.joinWithSeparator(";"))
            }
        }

		var categoryIndexes = Set(products?.flatMap { $0.categories.map { Array($0.keys) } ?? [] } ?? [])
        
        if let _ = productConf?.categories?.keys {
            categoryIndexes = categoryIndexes.union(productConf?.categories.map{ Array($0.keys) } ?? [])
        }
        
		for categoryIndex in categoryIndexes {
            var value: String? = self.productConf?.categories?[categoryIndex]?.serialized(for: request)
            
            if value == nil {
                value = products?.map({ $0.categories?[categoryIndex]?.serialized(for: request) ?? "" }).joinWithSeparator(";")
            }
            
            if let _ = value {
                items.append(name: "ca\(categoryIndex)", value: value)
            }
		}

		return items
	}
}


private extension MediaProperties {

	private func asQueryItems(for request: TrackerRequest) -> [NSURLQueryItem] {
		var items = [NSURLQueryItem]()
		if let bandwidth = bandwidth {
			items.append(name: "bw", value: "\(Int64(bandwidth))")
		}
		if let groups = groups {
			items += groups.mapNotNil { NSURLQueryItem(name: "mg", property: $0, for: request) }
		}
		if let duration = duration {
			items.append(name: "mt2", value: "\(Int64(duration))")
		}
		else {
			items.append(name: "mt2", value: "\(0)")
		}
		items.append(name: "mi", value: name)

		if let position = position {
			items.append(name: "mt1", value: "\(Int64(position))")
		}
		else {
			items.append(name: "mt1", value: "\(0)")
		}
		if let soundIsMuted = soundIsMuted {
			items.append(name: "mut", value: soundIsMuted ? "1" : "0")
		}
		if let soundVolume = soundVolume {
			items.append(name: "vol", value: "\(Int64(soundVolume * 100))")
		}
		items.append(name: "x", value: "\(Int64(request.properties.timestamp.timeIntervalSince1970 * 1000))")
		return items
	}
}


private extension PageProperties {

	private func asQueryItems(for request: TrackerRequest) -> [NSURLQueryItem] {
		var items = [NSURLQueryItem]()
		if let details = details {
			items += details.mapNotNil { NSURLQueryItem(name: "cp", property: $0, for: request) }
		}
		if let groups = groups {
			items += groups.mapNotNil { NSURLQueryItem(name: "cg", property: $0, for: request) }
		}
		if let internalSearch = internalSearch {
			items.append(name: "is", value: internalSearch)
		}
		if let url = url {
			items.append(name: "pu", value: url)
		}
		return items
	}
}


private extension UserProperties {

	private func asQueryItems(for request: TrackerRequest) -> [NSURLQueryItem] {
		var items = [NSURLQueryItem]()
		if let details = details {
			items += details.mapNotNil { NSURLQueryItem(name: "uc", property: $0, for: request) }
		}
		if let birthday = birthday {
			items = items.filter({$0.name != "uc707"})
			items.append(name: "uc707", value: birthday.serialized)
		}
		if let city = city {
			items = items.filter({$0.name != "uc708"})
			items.append(name: "uc708", value: city)
		}
		if let country = country {
			items = items.filter({$0.name != "uc709"})
			items.append(name: "uc709", value: country)
		}
		if let emailAddress = emailAddress {
			items = items.filter({$0.name != "uc700"})
			items.append(name: "uc700", value: emailAddress)
		}
		if let emailReceiverId = emailReceiverId {
			items = items.filter({$0.name != "uc701"})
			items.append(name: "uc701", value: emailReceiverId)
		}
		if let firstName = firstName {
			items = items.filter({$0.name != "uc703"})
			items.append(name: "uc703", value: firstName)
		}
		if let gender = gender {
			items = items.filter({$0.name != "uc706"})
			items.append(name: "uc706", value: String(gender.rawValue))
		}
		if let id = id {
			items.append(name: "cd", value: id)
		}
		if let lastName = lastName {
			items = items.filter({$0.name != "uc704"})
			items.append(name: "uc704", value: lastName)
		}
		if let newsletterSubscribed = newsletterSubscribed {
			items = items.filter({$0.name != "uc702"})
			items.append(name: "uc702", value: newsletterSubscribed ? "1" : "2")
		}
		if let phoneNumber = phoneNumber {
			items = items.filter({$0.name != "uc705"})
			items.append(name: "uc705", value: phoneNumber)
		}
		if let street = street {
			items = items.filter({$0.name != "uc711"})
			items.append(name: "uc711", value: street)
		}
		if let streetNumber = streetNumber {
			items = items.filter({$0.name != "uc712"})
			items.append(name: "uc712", value: streetNumber)
		}
		if let zipCode = zipCode {
			items = items.filter({$0.name != "uc710"})
			items.append(name: "uc710", value: zipCode)
		}

		return items
	}
}



private extension TrackerRequest.Properties.ConnectionType {

	private var serialized: String {
		switch self {
		case .cellular_2G: return "2G"
		case .cellular_3G: return "3G"
		case .cellular_4G: return "LTE"
		case .offline:     return "offline"
		case .other:       return "unknown"
		case .wifi:        return "WIFI"
		}
	}
}



private extension Array where Element: NSURLQueryItem {

	private mutating func append(name name: String, value: String?) {
		append(Element.init(name: name, value: value))
	}
}



private extension TrackingValue {

	private func serialized(for request: TrackerRequest) -> String? {
		switch self {
		case let .constant(value):
			return value

		case let .defaultVariable(variable):
			switch variable {
			case .advertisingId:              return request.properties.advertisingId?.UUIDString
			case .advertisingTrackingEnabled: return request.properties.advertisingTrackingEnabled.map { $0 ? "1" : "0" }
			case .appVersion:                 return request.properties.appVersion
			case .connectionType:             return request.properties.connectionType?.serialized
			case .interfaceOrientation:       return request.properties.interfaceOrientation?.serialized
			case .isFirstEventAfterAppUpdate: return request.properties.isFirstEventAfterAppUpdate ? "1" : "0"
			case .requestQueueSize:           return request.properties.requestQueueSize.map { String($0) }
			}

		case let .customVariable(name):
			return request.event.variables[name]
		}
	}
}


private extension NSURLQueryItem {

	private convenience init?(name: String, property: (Int, TrackingValue), for request: TrackerRequest) {
		guard let value = property.1.serialized(for: request) else {
			return nil
		}

		self.init(name: "\(name)\(property.0)", value: value)
	}
}


#if !os(watchOS)
private extension UIInterfaceOrientation {

	private var serialized: String {
		switch self {
		case .LandscapeLeft, .LandscapeRight: return "landscape"
		case .Portrait, .PortraitUpsideDown:  return "portrait"
		case .Unknown:                        return "undefined"
		}
	}
}
#endif


private extension UserProperties.Birthday {

	private var serialized: String {
		return String(format: "%04d%02d%02d", year, month, day)
	}
}
