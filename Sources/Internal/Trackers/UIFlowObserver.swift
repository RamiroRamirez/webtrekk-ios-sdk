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
//  Created by arsen.vartbaronov on 09/11/16.
//
//

import UIKit

#if os(watchOS)
    import WatchKit
#else
    import AVFoundation
#endif

class UIFlowObserver: NSObject {
    
    unowned private let tracker: DefaultTracker
    
    #if !os(watchOS)
    fileprivate let application = UIApplication.shared
    fileprivate var applicationDidBecomeActiveObserver: NSObjectProtocol?
    fileprivate var applicationWillEnterForegroundObserver: NSObjectProtocol?
    fileprivate var applicationWillResignActiveObserver: NSObjectProtocol?
    private var backgroundTaskIdentifier = UIBackgroundTaskInvalid
    private let deepLink = DeepLink()
    #endif


    
    init(tracker: DefaultTracker) {
        self.tracker = tracker
    }
    
    deinit {
        #if !os(watchOS)
            let notificationCenter = NotificationCenter.default
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
    
    func setup() -> Bool{
    
        #if !os(watchOS)
            let notificationCenter = NotificationCenter.default
            applicationDidBecomeActiveObserver = notificationCenter.addObserver(forName: NSNotification.Name.UIApplicationDidBecomeActive, object: nil, queue: nil) { [weak self] _ in
            self?.WTapplicationDidBecomeActive()
            }
            applicationWillEnterForegroundObserver = notificationCenter.addObserver(forName: NSNotification.Name.UIApplicationWillEnterForeground, object: nil, queue: nil) { [weak self] _ in
            self?.WTapplicationWillEnterForeground()
            }
            applicationWillResignActiveObserver = notificationCenter.addObserver(forName: NSNotification.Name.UIApplicationWillResignActive, object: nil, queue: nil) { [weak self] _ in
            self?.WTapplicationWillResignActive()
            }
            return true
        #else
            guard let delegate = WKExtension.shared().delegate ,
                  let delegateClass = object_getClass(delegate) else {
                logError("Can't find extension delgate.")
                return false
            }
            
            // add methods to delegateClass
            let replacedMethods = [#selector(WTapplicationWillResignActive), #selector(WTapplicationWillEnterForeground), #selector(WTapplicationDidEnterBackground), #selector(WTapplicationDidBecomeActive)]
            let extentionOriginalMethodNames = ["applicationWillResignActive", "applicationDidBecomeActive", "applicationDidEnterBackground", "applicationDidBecomeActive"]
            
            for i in 0..<replacedMethods.count {
                
                guard replaceImplementationFromAnotherClass(toClass: delegateClass, methodChanged: Selector(extentionOriginalMethodNames[i]), fromClass: UIFlowObserver.self, methodAdded: replacedMethods[i]) else {
                    logError("Can't initialize WatchApp setup. See log above for details.")
                    return false
                }
             }
            return true
        #endif
    }
    
    
    internal func applicationDidFinishLaunching() {
        checkIsOnMainThread()
        
        let _ = Timer.scheduledTimerWithTimeInterval(15) {
            self.tracker.updateConfiguration()
        }
    }

    
    dynamic func WTapplicationDidBecomeActive() {
    
    #if os(watchOS)
        defer {
            if class_respondsToSelector(object_getClass(self), #selector(WTapplicationDidBecomeActive)) {
                self.WTapplicationDidBecomeActive()
            }
        }
        let tracker = WebtrekkTracking.instance() as! DefaultTracker
        tracker.isApplicationActive = true
    #else
        let tracker = self.tracker
    #endif
    
    checkIsOnMainThread()
    
    tracker.startRequestManager()
    
    #if !os(watchOS)
    if backgroundTaskIdentifier != UIBackgroundTaskInvalid {
        application.endBackgroundTask(backgroundTaskIdentifier)
        backgroundTaskIdentifier = UIBackgroundTaskInvalid
        }
    #endif
    }
    
    
    #if !os(watchOS)
    func finishBackroundTask(){
        
        if backgroundTaskIdentifier != UIBackgroundTaskInvalid {
            application.endBackgroundTask(backgroundTaskIdentifier)
            backgroundTaskIdentifier = UIBackgroundTaskInvalid
        }
    }

    #else
    // for watchOS only
    dynamic func WTapplicationDidEnterBackground() {
        defer {
            if class_respondsToSelector(object_getClass(self), #selector(WTapplicationDidEnterBackground)) {
                self.WTapplicationDidEnterBackground()
            }
        }
        let tracker = WebtrekkTracking.instance() as! DefaultTracker
        tracker.stopRequestManager()
        tracker.isApplicationActive = false
    }
    
    #endif
    
    dynamic func WTapplicationWillResignActive() {
        
        #if os(watchOS)
            defer {
                if class_respondsToSelector(object_getClass(self), #selector(WTapplicationWillResignActive)) {
                    self.WTapplicationWillResignActive()
                }
            }
        let tracker = WebtrekkTracking.instance() as! DefaultTracker
        #else
        let tracker = self.tracker
        #endif
       
        checkIsOnMainThread()
        
        guard tracker.checkIfInitialized() else {
            return
        }
        
        tracker.initHibertationDate()
        
        #if !os(watchOS)
            if backgroundTaskIdentifier == UIBackgroundTaskInvalid {
                backgroundTaskIdentifier = application.beginBackgroundTask(withName: "Webtrekk Tracker #\(self.tracker.configuration.webtrekkId)") { [weak self] in
                    guard let `self` = self else {
                        return
                    }
                    
                    if let started = self.tracker.requestManager?.started, started {
                        self.tracker.stopRequestManager()
                    }
                    
                    self.application.endBackgroundTask(self.backgroundTaskIdentifier)
                    self.backgroundTaskIdentifier = UIBackgroundTaskInvalid
                }
            }
            
            if backgroundTaskIdentifier != UIBackgroundTaskInvalid {
                tracker.saveRequestQueue()
            }
            else {
                tracker.stopRequestManager()
            }
        #endif
    }
    
    dynamic func WTapplicationWillEnterForeground() {
        
        #if os(watchOS)
            defer {
                if class_respondsToSelector(object_getClass(self), #selector(WTapplicationWillEnterForeground)) {
                    self.WTapplicationWillEnterForeground()
                }
            }
            let tracker = WebtrekkTracking.instance() as! DefaultTracker
        #else
            let tracker = self.tracker
        #endif
        
        checkIsOnMainThread()
        
        guard tracker.checkIfInitialized() else {
            return
        }
        tracker.updateFirstSession()
    }
}
