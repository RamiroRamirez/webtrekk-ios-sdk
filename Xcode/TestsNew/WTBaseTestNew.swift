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
//  Created by arsen.vartbaronov on 17/08/16.
//

import XCTest
@testable import Webtrekk
import Foundation
import Nimble

class WTBaseTestNew: HttpBaseTestNew {
    
    var libraryVersion: String?

    override func setUp() {
        super.setUp()
        initWebtrekk()
        checkStartCondition()
    }
    
    override func tearDown() {
        checkFinishCondition()
        releaseWebtrekk()
        super.tearDown()
    }
    
    func getCongigName() -> String?{
        return nil
    }
    
    private func initWebtrekk(){
        
        guard !WebtrekkTracking.isInitialized() else{
            return
        }
        
        WebtrekkTracking.defaultLogger.minimumLevel = .debug
        
        do {
            if let configName = getCongigName(){
                let configFileURL = Bundle.main.url(forResource: configName, withExtension: "xml", subdirectory: "Configurations/")
                try WebtrekkTracking.initTrack(configFileURL)
            }else {
                try WebtrekkTracking.initTrack()
            }
        }catch let error as TrackerError {
            WebtrekkTracking.defaultLogger.logError("Error Webtrekk SDK initialization: \(error.message)")
        }catch {
            WebtrekkTracking.defaultLogger.logError("Unkown error during Webtrekk SDK initialization")
        }
        
        
        let libraryVersionOriginal = Bundle.init(for: WebtrekkTracking.self).object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "9.9.9"
        self.libraryVersion = libraryVersionOriginal.replacingOccurrences(of: ".", with: "")
    }

    private func releaseWebtrekk(){
        rollBackAutoTrackingMethodsSwizz()
        resetWebtrackInstance()
    }
    
    private func resetWebtrackInstance()
    {
        weak var weakTracker = WebtrekkTracking.tracker
        WebtrekkTracking.tracker = nil
        
        while weakTracker != nil {
            RunLoop.current.run(mode: .defaultRunLoopMode, before: Date(timeIntervalSinceNow:2))
        }
    }
        
    private func rollBackAutoTrackingMethodsSwizz(){
        UIViewController.setUpAutomaticTracking()
    }
    
    private func checkStartCondition(){
        expect(self.isBackupFileExists()).to(equal(false))
    }
    
    private func checkFinishCondition(){
        expect(self.isBackupFileExists()).to(equal(false))
    }
    
    private func isBackupFileExists() -> Bool{
        let file = WTBaseTestNew.requestQueueBackupFileForWebtrekkId("123451234512345")
        
        return FileManager.default.itemExistsAtURL(file!)
    }
    
    static func requestQueueBackupFileForWebtrekkId(_ webtrekkId: String) -> URL? {
        
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
            WebtrekkTracking.defaultLogger.logError("Test: Cannot find directory for storing request queue backup file: \(error)")
            return nil
        }
        
        directory = directory.appendingPathComponent("Webtrekk")
        directory = directory.appendingPathComponent(webtrekkId)
        
        if !fileManager.itemExistsAtURL(directory) {
            do {
                try fileManager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [URLResourceKey.isExcludedFromBackupKey.rawValue: true])
            }
            catch let error {
                WebtrekkTracking.defaultLogger.logError("Test: Cannot create directory at '\(directory)' for storing request queue backup file: \(error)")
                return nil
            }
        }
        
        return directory.appendingPathComponent("requestQueue.archive")
    }

}
