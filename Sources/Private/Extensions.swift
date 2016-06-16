import UIKit


extension NSURL {

	@nonobjc
	public func URLByAppendingQueryItems(queryItems: [NSURLQueryItem]) -> NSURL? {
		guard !queryItems.isEmpty else {
			return self
		}

		guard let urlComponents = NSURLComponents(URL: self, resolvingAgainstBaseURL: false) else {
			return nil
		}

		urlComponents.queryItems = (urlComponents.queryItems ?? []) + queryItems

		return urlComponents.URL
	}


	@nonobjc
	public func URLQueryItems() -> [NSURLQueryItem] {
		guard let urlComponents = NSURLComponents(URL: self, resolvingAgainstBaseURL: false) else {
			return []
		}

		return urlComponents.queryItems ?? []
	}
}

extension NSURLQueryItem {

	internal convenience init(name: String, values: [String]) {
		self.init(name: name, value: values.joinWithSeparator(";"))
	}


	internal convenience init(name: ParameterName, value: String?) {
		self.init(name: name.rawValue, value: value)
	}


	internal convenience init(name: ParameterName, withIndex index: Int, value: String) {
		self.init(name: "\(name.rawValue)\(index)", value: value)
	}

}


//extension UIViewController {
//	public override class func initialize() {
//		struct Static {
//			static var token: dispatch_once_t = 0
//		}
//
//		if self !== UIViewController.self {
//			return
//		}
//
//		dispatch_once(&Static.token) {
//			let originalSelector = #selector(viewDidAppear)
//			let swizzledSelector = #selector(webtrekk_viewDidAppear)
//
//			let originalMethod = class_getInstanceMethod(self, originalSelector)
//			let swizzledMethod = class_getInstanceMethod(self, swizzledSelector)
//
//			let didAddMethod = class_addMethod(self, originalSelector, method_getImplementation(swizzledMethod), method_getTypeEncoding(swizzledMethod))
//
//			if didAddMethod {
//				class_replaceMethod(self, swizzledSelector, method_getImplementation(originalMethod), method_getTypeEncoding(originalMethod))
//			} else {
//				method_exchangeImplementations(originalMethod, swizzledMethod)
//			}
//		}
//	}
//
//	// MARK: - Method Swizzling
//
//	func webtrekk_viewDidAppear(animated: Bool) {
//		self.webtrekk_viewDidAppear(animated)
//		do {
//			try Webtrekk.sharedInstance.autoTrack("\(self.dynamicType)")
//		} catch {
//			print("error occured during track \(error)")
//		}
//	}
//}

internal extension SequenceType where Generator.Element: _Optional {

	@warn_unused_result
	internal func filterNonNil() -> [Generator.Element.Wrapped] {
		var result = Array<Generator.Element.Wrapped>()
		for element in self {
			guard let element = element.value else {
				continue
			}

			result.append(element)
		}

		return result
	}
}


extension Array {
	internal mutating func enqueue (value: Element) {
		self.append(value)
	}


	internal mutating func dequeue () -> Element? {
		guard !self.isEmpty else {
			return nil
		}
		return self.removeFirst()
	}


	internal func peek() -> Element? {
		guard !self.isEmpty, let firstItem = self.first else {
			return nil
		}
		return firstItem
	}
}


internal protocol _Optional: NilLiteralConvertible {

	associatedtype Wrapped

	init()
	init(_ some: Wrapped)

	@warn_unused_result
	func map<U>(@noescape f: (Wrapped) throws -> U) rethrows -> U?

	@warn_unused_result
	func flatMap<U>(@noescape f: (Wrapped) throws -> U?) rethrows -> U?
}


extension Optional: _Optional {}


internal extension _Optional {

	internal var value: Wrapped? {
		return map { $0 }
	}
}


internal extension NSURLSession {
	static func defaultSession() -> NSURLSession {
		return NSURLSession(configuration: NSURLSessionConfiguration.defaultSessionConfiguration(),
		                    delegate: nil, delegateQueue: NSOperationQueue.mainQueue())
	}

	internal static func get(url: NSURL, session: NSURLSession = NSURLSession.defaultSession(), loger: Loger? = nil, completion: (NSData?, ErrorType?) -> Void) {
		let task = session.dataTaskWithURL(url) { (data, response, error) -> Void in
			let recoverable: Bool
			if let error = error {
				switch error.code {
				case NSURLErrorBadServerResponse, NSURLErrorCallIsActive, NSURLErrorCancelled, NSURLErrorCannotConnectToHost, NSURLErrorCannotFindHost, NSURLErrorDataNotAllowed, NSURLErrorDNSLookupFailed, NSURLErrorInternationalRoamingOff, NSURLErrorNetworkConnectionLost, NSURLErrorNotConnectedToInternet, NSURLErrorTimedOut, NSURLErrorZeroByteResource:
					loger?.log("Error \"\(error.localizedDescription)\" occured during request of \(url), will be retried.")
					recoverable = true
				default:
					loger?.log("Error \"\(error.localizedDescription)\" occured during request of \(url), will not be retried.")
					recoverable = false
				}
				completion(nil, Error.NetworkError(recoverable: recoverable))
			} else if let response = response as? NSHTTPURLResponse where 200...299 ~= response.statusCode {
				completion(data, nil)
			} else {
				completion(nil, Error.NetworkError(recoverable: false))
			}
		}
		task.resume()
	}
}


public enum Error: ErrorType {
	case NetworkError(recoverable: Bool)
}


internal extension Dictionary {
	mutating func updateValues(fromDictionary: [Key : Value]) {
		for (key, value) in fromDictionary {
			updateValue(value, forKey: key)
		}
	}
}