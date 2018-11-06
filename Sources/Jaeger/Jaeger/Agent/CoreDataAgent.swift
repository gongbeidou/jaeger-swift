//
//  CoreDataAgent.swift
//  Jaeger
//
//  Created by Simon-Pierre Roy on 11/6/18.
//

import UIKit
import CoreData

/**
 Constants for the CoreDataAgent.
 */
fileprivate enum Constants {
    /// The shared `JSONEncoder`.
    static let jsonEncoder =  JSONEncoder()
    /// The shared `JSONDecoder`.
    static let jsonDecoder =  JSONDecoder()
    /// The model name for the Core Data model.
    static let modelName = "OTCoreDataAgent"
}

/**
 The configuration used by the `CoreDataAgent` agent to set up the core data stack and saving behavior.
 */
public struct CDAgentConfiguration {
    
    /**
     Creates a new configuration.
     
     - Parameter averageMaximumSpansPerSecond: The maximum number of spans per seconds to be saved in memory before the next saving operation on disk.
     - Parameter savingInterval: The time between each saving operation on disk.
     - Parameter sendingInterval: The time between each sending tasks to the collector.
     - Parameter coreDataFolderURL: An optional URL to a folder where the core data files will be saved. When not specified the `NSPersistentContainer.defaultDirectoryURL()` will be used.
     
     - Warning:
     Every parameter should be strictly positive and the sending interval should be greater than the saving interval.
     */
    public init?(averageMaximumSpansPerSecond: Int,
                 savingInterval: TimeInterval,
                 sendingInterval: TimeInterval,
                 coreDataFolderURL: URL?) {
        
        guard averageMaximumSpansPerSecond > 0,
            savingInterval > 0,
            sendingInterval > 0,
            savingInterval < sendingInterval else {
                return nil
        }
        
        self.coreDataFolderURL = coreDataFolderURL
        self.maximumSpansPerSecond = averageMaximumSpansPerSecond
        self.savingInterval = savingInterval
        self.sendingInterval = sendingInterval
        let maxPerSaving = (Double(averageMaximumSpansPerSecond) * savingInterval).rounded(.up)
        let maxPerSending = (Double(averageMaximumSpansPerSecond) * sendingInterval).rounded(.up)
        self.maximunSpansPerSavingInterval =  Int(maxPerSaving)
        self.maximunSpansPerSendingInterval = Int(maxPerSending)
    }
    
    /// The maximum number of spans per seconds to be saved in memory before the next saving operation on disk.
    public let maximumSpansPerSecond: Int
    /// The time between each saving operation on disk.
    public let savingInterval: TimeInterval
    /// The time between each sending tasks to the collector.
    public let sendingInterval: TimeInterval
    /** The maximum number of spans to be saved in memory before the next saving operation on disk.
     This is the product between the `maximumSpansPerSecond` and the `savingInterval`.
     */
    public let maximunSpansPerSavingInterval: Int
    /**  The maximum number of spans fetched from the disk before sending to the collector.
     This is the product between the `maximumSpansPerSecond` and the `sendingInterval`.
     */
    public let maximunSpansPerSendingInterval: Int
    /// An optional URL to a folder where the core data files will be saved. When not specified the `NSPersistentContainer.defaultDirectoryURL()` will be used.
    public let coreDataFolderURL: URL?
}

/**
 An agent using a Core Data Stack to save a binary representation of a span. The agent will save the spans periodically on disk in order to minimize the memory footprint  and optimize disk writing operations. At regular intervals, spans will be fetched from the disk and send to the provided `SpanSender`.
 
 A SQLite store type is used for the persistent store.
 */
public final class CoreDataAgent<RawSpan: SpanConvertible>: Agent {
    
    /// The point of entry to report spans to a collector.
    public let spanSender: SpanSender
    
    /// The configuration applied to this instance.
    private let config: CDAgentConfiguration
    /// The provided core data stack used to save the spans.
    private let coreStack: CoreDataStack
    /** The shared background context used to synchronize background operations for Core Data.
     Use the associated serial queue to execute thread safe operations when needed.*/
    private let backgroundContext: NSManagedObjectContext
    /**  The current number of spans added to the background context since the last save operation.
     Only access the count from the `backgroundContext` queue for thread safety.*/
    private var currentSavingCount: Int = 0
    /// The tracker used to monitor network accessibility.
    private let reachabilityTracker: ReachabilityTracker
    
    /// The timer used to execute saving tasks.
    private lazy var savingTimer = Timer.scheduledTimer(withTimeInterval: TimeInterval(self.config.savingInterval), repeats: true) { [weak self] _ in
        self?.executeSavingTasks()
    }
    /// The timer used to execute fetching and sending tasks.
    private lazy var sendingTimer = Timer.scheduledTimer(withTimeInterval: TimeInterval(self.config.sendingInterval), repeats: true) { [weak self] _ in
        self?.executeSendingTasks()
    }
    
    /**
     Creates a new agent from a specified configuration and span sender.
     
     - Parameter config: The configuration for the core data stack and agent.
     - Parameter sender: The point of entry to report spans to a collector.
     */
    public convenience init(config: CDAgentConfiguration, sender: SpanSender) {
        guard let modelURL = Bundle.main.url(forResource: Constants.modelName, withExtension: "mom"),
            let model = NSManagedObjectModel(contentsOf: modelURL) else { fatalError() }
        let storeType: CoreDataStack.StoreType = .sql
        
        if let url = config.coreDataFolderURL {
            let stack = CoreDataStack(modelName: Constants.modelName, folderURL: url, model: model, type: storeType)
            self.init(config: config, sender: sender, stack: stack)
        } else {
            let stack =  CoreDataStack(modelName: Constants.modelName, model: model, type: storeType)
            self.init(config: config, sender: sender, stack: stack)
        }
    }
    
    /**
     Creates a new agent from a specified configuration and a core data stack.
     
     - Parameter config: The configuration for the core data stack and agent.
     - Parameter sender: The point of entry to report spans to a collector.
     - Parameter stack: The core data stack.
     - Parameter reachabilityTracker: The tracker used to monitor network accessibility.
     */
    init(config: CDAgentConfiguration,
         sender: SpanSender,
         stack: CoreDataStack,
         reachabilityTracker: ReachabilityTracker = Reachability()) {
        
        self.config = config
        self.spanSender = sender
        self.coreStack = stack
        self.reachabilityTracker = reachabilityTracker
        backgroundContext = coreStack.defaultBackgroundContext
        _ = savingTimer // start timer
        _ = sendingTimer // start timer
        executeSendingTasks() // Send cached data from the last app start.
        addAppWillTerminateActions()
    }
    
    /**
     This function adds and saves the span locally.
     
     - Parameter span: A Span sent by the tracer.
     
     If the maximum threshold is exceeded  for the current saving period, then the span will be ignored.
     */
    public func record(span: Span) {
        backgroundContext.perform { [weak self] in
            guard let strongSelf = self else { return }
            guard (strongSelf.currentSavingCount < strongSelf.config.maximunSpansPerSavingInterval) else { return }
            strongSelf.currentSavingCount += 1
            strongSelf.addAndSaveSpanInContext(span)
        }
    }
    
    /// Add an action to save spans to disk when the application will terminate.
    private func addAppWillTerminateActions() {
        NotificationCenter.default.addObserver(forName: UIApplication.willTerminateNotification, object: nil, queue: nil) { [weak self] _ in
            self?.backgroundContext.performAndWait { [weak self] in
                self?.save()
            }
        }
    }
    
    /**
     This function will add a span to the `backgroundContext`.
     
     - Parameter span: A Span sent by the tracer.
     
     - Warning:
     Only call this method from the `backgroundContext` queue.
     */
    private func addAndSaveSpanInContext(_ span: Span) {
        let rawSpan = RawSpan.convert(span: span)
        
        do {
            let data = try Constants.jsonEncoder.encode(rawSpan)
            CoreDataSpan.insertNewSpan(in: self.backgroundContext,startTime: span.startTime, data: data)
        } catch let error {
            print(error)
        }
    }
    
    /// Call this to save the `backgroundContext` and reset the saving count. (thread safe)
    private func executeSavingTasks() {
        backgroundContext.perform { [weak self] in
            self?.currentSavingCount = 0
            self?.save()
        }
    }
    
    /// Call this to fetch and send spans to the collector. (thread safe)
    private func executeSendingTasks() {
        backgroundContext.perform { [weak self] in
            self?.sendAllSavedSpans()
        }
    }
    
    /**
     This function will save the `backgroundContext`.
     
     - Warning:
     Only call this method from the `backgroundContext` queue.
     */
    private func save() {
        guard backgroundContext.hasChanges else { return }
        
        do {
            try backgroundContext.save()
        } catch let error {
            print(error)
        }
    }
    
    /**
     It will fetch all spans when the network is available and it will forward the data to the `SpanSender`.
     
     - Warning:
     Only call this method from the `backgroundContext` queue.
     */
    private func sendAllSavedSpans() {
        
        guard reachabilityTracker.isNetworkReachable() else { return }
        
        do {
            let fetchRequest: NSFetchRequest<CoreDataSpan> = CoreDataSpan.fetchRequest()
            fetchRequest.fetchLimit = self.config.maximunSpansPerSendingInterval
            let values = try backgroundContext.fetch(fetchRequest)
            guard values.count > 0  else { return }
            handle(results: values)
        } catch let error {
            print(error)
        }
    }
    
    /**
     It will map the core data spans to the original object, delete all data in the persistent store and forward the data to the `SpanSender`.
     
     - Parameter results: A list of core data spans.
     
     - Warning:
     Only call this method from the `backgroundContext` queue.
     */
    private func handle(results: [CoreDataSpan]) {
        let spans: [RawSpan] = results.compactMap {
            return try? Constants.jsonDecoder.decode(RawSpan.self, from: $0.jsonSpan as Data)
        }
        deleteAllSpans()
        self.spanSender.send(spans: spans)
    }
    
    /**
     Delete all data in the persistent store. It will create a delete request according to the store type.
     
     - Warning:
     Only call this method from the `backgroundContext` queue.
     */
    private func deleteAllSpans() {
        
        switch coreStack.storeType {
        case .sql: deleteAllSpansSQLStore()
        case .inMemory: deleteAllSpansInMemoryStore()
        }
    }
    
    /**
     Delete all data in the SQL persistent store.
     
     - Warning:
     Only call this method from the `backgroundContext` queue.
     */
    private func deleteAllSpansSQLStore() {
        let fetchRequest: NSFetchRequest<NSFetchRequestResult> = CoreDataSpan.fetchRequest()
        let deleteResquest = NSBatchDeleteRequest(fetchRequest: fetchRequest)
        deleteResquest.resultType = .resultTypeCount
        
        do {
            try backgroundContext.execute(deleteResquest)
        } catch let error {
            print(error)
        }
    }
    
    /**
     Delete all data in the in-memory persistent store.
     
     - Warning:
     Only call this method from the `backgroundContext` queue.
     */
    private func deleteAllSpansInMemoryStore() {
        let fetchRequest: NSFetchRequest<CoreDataSpan> = CoreDataSpan.fetchRequest()
        do {
            let result = try backgroundContext.fetch(fetchRequest)
            result.forEach { backgroundContext.delete($0) }
            try backgroundContext.save()
        } catch let error {
            print(error)
        }
    }
}
