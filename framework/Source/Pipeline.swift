// MARK: -
// MARK: Basic types
import Foundation
import Dispatch

public protocol ImageSource {
    var targets:TargetContainer { get }
    func transmitPreviousImage(to target:ImageConsumer, atIndex:UInt)
}

public protocol ImageConsumer:AnyObject {
    var maximumInputs:UInt { get }
    var sources:SourceContainer { get }
    
    func newFramebufferAvailable(_ framebuffer:Framebuffer, fromSourceIndex:UInt)
}

public protocol ImageProcessingOperation: ImageConsumer, ImageSource {
}

infix operator --> : AdditionPrecedence
//precedencegroup ProcessingOperationPrecedence {
//    associativity: left
////    higherThan: Multiplicative
//}
@discardableResult public func --><T:ImageConsumer>(source:ImageSource, destination:T) -> T {
    source.addTarget(destination)
    return destination
}

// MARK: -
// MARK: Extensions and supporting types

public extension ImageSource {
    func addTarget(_ target:ImageConsumer, atTargetIndex:UInt? = nil) {
        if let targetIndex = atTargetIndex {
            //Consumer add source
            target.setSource(self, atIndex:targetIndex)
            //targets属于ImageSource，即Source增加consumer并指定位置
            targets.append(target, indexAtTarget:targetIndex)
            //
            transmitPreviousImage(to:target, atIndex:targetIndex)
        } else if let indexAtTarget = target.addSource(self) {
            targets.append(target, indexAtTarget:indexAtTarget)
            transmitPreviousImage(to:target, atIndex:indexAtTarget)
        } else {
            debugPrint("Warning: tried to add target beyond target's input capacity")
        }
    }

    func removeAllTargets() {
        for (target, index) in targets {
            target.removeSourceAtIndex(index)
        }
        targets.removeAll()
    }
    
    func updateTargetsWithFramebuffer(_ framebuffer:Framebuffer) {
        if targets.count == 0 { // Deal with the case where no targets are attached by immediately returning framebuffer to cache
            framebuffer.lock()
            framebuffer.unlock()
        } else {
            // Lock first for each output, to guarantee proper ordering on multi-output operations
            for _ in targets {
                framebuffer.lock()
            }
        }
        for (target, index) in targets {
            target.newFramebufferAvailable(framebuffer, fromSourceIndex:index)
        }
    }
}

public extension ImageConsumer {
    func addSource(_ source:ImageSource) -> UInt? {
        return sources.append(source, maximumInputs:maximumInputs)
    }
    
    func setSource(_ source:ImageSource, atIndex:UInt) {
        _ = sources.insert(source, atIndex:atIndex, maximumInputs:maximumInputs)
    }

    func removeSourceAtIndex(_ index:UInt) {
        sources.removeAtIndex(index)
    }
}

class WeakImageConsumer {
    weak var value:ImageConsumer?
    let indexAtTarget:UInt
    init (value:ImageConsumer, indexAtTarget:UInt) {
        self.indexAtTarget = indexAtTarget
        self.value = value
    }
}

public class TargetContainer:Sequence {
    var targets = [WeakImageConsumer]()
    var count:Int { get {return targets.count}}
    let dispatchQueue = DispatchQueue(label:"com.sunsetlakesoftware.GPUImage.targetContainerQueue", attributes: [])

    public init() {
    }
    
    public func append(_ target:ImageConsumer, indexAtTarget:UInt) {
        // TODO: Don't allow the addition of a target more than once
        dispatchQueue.async{
            self.targets.append(WeakImageConsumer(value:target, indexAtTarget:indexAtTarget))
        }
    }
    
    public func makeIterator() -> AnyIterator<(ImageConsumer, UInt)> {
        var index = 0
        
        return AnyIterator { () -> (ImageConsumer, UInt)? in
            return self.dispatchQueue.sync{
                if (index >= self.targets.count) {
                    return nil
                }
                //为什么不是if
                while (self.targets[index].value == nil) {
                    self.targets.remove(at:index)
                    if (index >= self.targets.count) {
                        return nil
                    }
                }
                //因为要一次移除targets所有value为nil的，targets是数组，0如果为nil，移除后，原来的第一个元素就移动到位置0，如果是if，则会错过，下次判断的是index += 1的值
                
                index += 1
                return (self.targets[index - 1].value!, self.targets[index - 1].indexAtTarget)
                //返回值从index - 1开始，因为上一步index += 1，为了后续进行下一次遍历数组输出
                //也可以换种方式：
                //defer {
                //   index += 1
                //}
                //return (self.targets[index].value!, self.targets[index].indexAtTarget)
           }
        }
    }
    
    public func removeAll() {
        dispatchQueue.async{
            self.targets.removeAll()
        }
    }
}

public class SourceContainer {
    var sources:[UInt:ImageSource] = [:]
    
    public init() {
    }
    
    public func append(_ source:ImageSource, maximumInputs:UInt) -> UInt? {
        var currentIndex:UInt = 0
        while currentIndex < maximumInputs {
            if (sources[currentIndex] == nil) {
                sources[currentIndex] = source
                return currentIndex
            }
            currentIndex += 1
        }
        
        return nil
    }
    
    public func insert(_ source:ImageSource, atIndex:UInt, maximumInputs:UInt) -> UInt {
        guard (atIndex < maximumInputs) else { fatalError("ERROR: Attempted to set a source beyond the maximum number of inputs on this operation") }
        sources[atIndex] = source
        return atIndex
    }
    
    public func removeAtIndex(_ index:UInt) {
        sources[index] = nil
    }
}

public class ImageRelay: ImageProcessingOperation {
    public var newImageCallback:((Framebuffer) -> ())?
    
    public let sources = SourceContainer()
    public let targets = TargetContainer()
    public let maximumInputs:UInt = 1
    public var preventRelay:Bool = false
    
    public init() {
    }
    
    public func transmitPreviousImage(to target:ImageConsumer, atIndex:UInt) {
        sources.sources[0]?.transmitPreviousImage(to:self, atIndex:0)
    }

    public func newFramebufferAvailable(_ framebuffer:Framebuffer, fromSourceIndex:UInt) {
        if let newImageCallback = newImageCallback {
            newImageCallback(framebuffer)
        }
        if (!preventRelay) {
            relayFramebufferOnward(framebuffer)
        }
    }
    
    public func relayFramebufferOnward(_ framebuffer:Framebuffer) {
        // Need to override to guarantee a removal of the previously applied lock
        for _ in targets {
            framebuffer.lock()
        }
        framebuffer.unlock()
        for (target, index) in targets {
            target.newFramebufferAvailable(framebuffer, fromSourceIndex:index)
        }
    }
}
