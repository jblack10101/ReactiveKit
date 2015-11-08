//
//  The MIT License (MIT)
//
//  Copyright (c) 2015 Srdan Rasic (@srdanrasic)
//
//  Permission is hereby granted, free of charge, to any person obtaining a copy
//  of this software and associated documentation files (the "Software"), to deal
//  in the Software without restriction, including without limitation the rights
//  to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
//  copies of the Software, and to permit persons to whom the Software is
//  furnished to do so, subject to the following conditions:
//
//  The above copyright notice and this permission notice shall be included in
//  all copies or substantial portions of the Software.
//
//  THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
//  IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
//  FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
//  AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
//  LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
//  OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
//  THE SOFTWARE.
//

public protocol StreamType {
  typealias Event
  func observe(on context: ExecutionContext, sink: Event -> ()) -> DisposableType
}

extension StreamType {
  
  @warn_unused_result
  public func share(limit: Int = Int.max, context: ExecutionContext = Queue.Main.context) -> ActiveStream<Event> {
    return create(limit) { sink in
      return self.observe(on: context, sink: sink)
    }
  }
}

extension StreamType {
  
  @warn_unused_result
  public func map<U>(transform: Event -> U) -> Stream<U> {
    return create { sink in
      return self.observe(on: ImmediateExecutionContext) { event in
        sink(transform(event))
      }
    }
  }
  
  @warn_unused_result
  public func filter(include: Event -> Bool) -> Stream<Event> {
    return create { sink in
      return self.observe(on: ImmediateExecutionContext) { event in
        if include(event) {
          sink(event)
        }
      }
    }
  }
  
  @warn_unused_result
  public func switchTo(context: ExecutionContext) -> Stream<Event> {
    return create { sink in
      return self.observe(on: context, sink: sink)
    }
  }
  
  @warn_unused_result
  public func zipPrevious() -> Stream<(Event?, Event)> {
    return create { sink in
      var previous: Event? = nil
      return self.observe(on: ImmediateExecutionContext) { event in
        sink(previous, event)
        previous = event
      }
    }
  }
  
  @warn_unused_result
  public func throttle(seconds: Double, on queue: Queue) -> Stream<Event> {
    return create { sink in
      
      var shouldDispatch: Bool = true
      var latestEvent: Event! = nil
      
      return self.observe(on: ImmediateExecutionContext) { event in
        latestEvent = event
        guard shouldDispatch == true else { return }
        
        shouldDispatch = false
        
        queue.after(seconds) {
          let event = latestEvent!
          latestEvent = nil
          shouldDispatch = true
          sink(event)
        }
      }
    }
  }
  
  @warn_unused_result
  public func skip(var count: Int) -> Stream<Event> {
    return create { sink in
      return self.observe(on: ImmediateExecutionContext) { event in
        if count > 0 {
          count--
        } else {
          sink(event)
        }
      }
    }
  }
  
  @warn_unused_result
  public func startWith(event: Event) -> Stream<Event> {
    return create { sink in
      sink(event)
      return self.observe(on: ImmediateExecutionContext) { event in
        sink(event)
      }
    }
  }
  
  @warn_unused_result
  public func combineLatestWith<S: StreamType>(other: S) -> Stream<(Event, S.Event)> {
    return create { sink in
      var selfEvent: Event! = nil
      var otherEvent: S.Event! = nil
      
      let onBothNext = { () -> () in
        if let myEvent = selfEvent, let itsEvent = otherEvent {
          sink((myEvent, itsEvent))
        }
      }
      
      let selfDisposable = self.observe(on: ImmediateExecutionContext) { event in
        selfEvent = event
        onBothNext()
      }
      
      let otherDisposable = other.observe(on: ImmediateExecutionContext) { event in
        otherEvent = event
        onBothNext()
      }
      
      return CompositeDisposable([selfDisposable, otherDisposable])
    }
  }
  
}

extension StreamType where Event: OptionalType {
  
  @warn_unused_result
  public func ignoreNil() -> Stream<Event.Wrapped> {
    return create { sink in
      return self.observe(on: ImmediateExecutionContext) { event in
        if let event = event._unbox {
          sink(event)
        }
      }
    }
  }
}

extension StreamType where Event: Equatable {
  
  @warn_unused_result
  public func distinct() -> Stream<Event> {
    return create { sink in
      var lastEvent: Event? = nil
      return self.observe(on: ImmediateExecutionContext) { event in
        if lastEvent == nil || lastEvent! != event {
          sink(event)
          lastEvent = event
        }
      }
    }
  }
}

public extension StreamType where Event: OptionalType, Event.Wrapped: Equatable {
  
  @warn_unused_result
  public func distinctOptional() -> Stream<Event.Wrapped?> {
    return create { sink in
      var lastEvent: Event.Wrapped? = nil
      return self.observe(on: ImmediateExecutionContext) { event in
        
        switch (lastEvent, event._unbox) {
        case (.None, .Some(let new)):
          sink(new)
        case (.Some, .None):
          sink(nil)
        case (.Some(let old), .Some(let new)) where old != new:
          sink(new)
        default:
          break
        }
        
        lastEvent = event._unbox
      }
    }
  }
}

public extension StreamType where Event: StreamType {
  
  @warn_unused_result
  public func merge() -> Stream<Event.Event> {
    return create { sink in
      let compositeDisposable = CompositeDisposable()
      compositeDisposable += self.observe(on: ImmediateExecutionContext) { observer in
        compositeDisposable += observer.observe(on: ImmediateExecutionContext, sink: sink)
      }
      return compositeDisposable
    }
  }
  
  @warn_unused_result
  public func switchToLatest() -> Stream<Event.Event> {
    return create { sink in
      let serialDisposable = SerialDisposable(otherDisposable: nil)
      let compositeDisposable = CompositeDisposable([serialDisposable])
      
      compositeDisposable += self.observe(on: ImmediateExecutionContext) { observer in
        serialDisposable.otherDisposable?.dispose()
        serialDisposable.otherDisposable = observer.observe(on: ImmediateExecutionContext, sink: sink)
      }
      
      return compositeDisposable
    }
  }
}

public enum StreamFlatMapStrategy {
  case Latest
  case Merge
}

public extension StreamType {
  
  @warn_unused_result
  public func flatMap<S: StreamType>(strategy: StreamFlatMapStrategy, transform: Event -> S) -> Stream<S.Event> {
    switch strategy {
    case .Latest:
      return map(transform).switchToLatest()
    case .Merge:
      return map(transform).merge()
    }
  }
}

@warn_unused_result
public func combineLatest<A: StreamType, B: StreamType>(a: A, _ b: B) -> Stream<(A.Event, B.Event)> {
  return a.combineLatestWith(b)
}

@warn_unused_result
public func combineLatest<A: StreamType, B: StreamType, C: StreamType>(a: A, _ b: B, _ c: C) -> Stream<(A.Event, B.Event, C.Event)> {
  return combineLatest(a, b).combineLatestWith(c).map { ($0.0, $0.1, $1) }
}

@warn_unused_result
public func combineLatest<A: StreamType, B: StreamType, C: StreamType, D: StreamType>(a: A, _ b: B, _ c: C, _ d: D) -> Stream<(A.Event, B.Event, C.Event, D.Event)> {
  return combineLatest(a, b, c).combineLatestWith(d).map { ($0.0, $0.1, $0.2, $1) }
}

@warn_unused_result
public func combineLatest<A: StreamType, B: StreamType, C: StreamType, D: StreamType, E: StreamType>
  (a: A, _ b: B, _ c: C, _ d: D, _ e: E) -> Stream<(A.Event, B.Event, C.Event, D.Event, E.Event)>
{
  return combineLatest(a, b, c, d).combineLatestWith(e).map { ($0.0, $0.1, $0.2, $0.3, $1) }
}

@warn_unused_result
public func combineLatest<A: StreamType, B: StreamType, C: StreamType, D: StreamType, E: StreamType, F: StreamType>
  ( a: A, _ b: B, _ c: C, _ d: D, _ e: E, _ f: F) -> Stream<(A.Event, B.Event, C.Event, D.Event, E.Event, F.Event)>
{
  return combineLatest(a, b, c, d, e).combineLatestWith(f).map { ($0.0, $0.1, $0.2, $0.3, $0.4, $1) }
}

@warn_unused_result
public func combineLatest<A: StreamType, B: StreamType, C: StreamType, D: StreamType, E: StreamType, F: StreamType, G: StreamType>
  ( a: A, _ b: B, _ c: C, _ d: D, _ e: E, _ f: F, _ g: G) -> Stream<(A.Event, B.Event, C.Event, D.Event, E.Event, F.Event, G.Event)>
{
  return combineLatest(a, b, c, d, e, f).combineLatestWith(g).map { ($0.0, $0.1, $0.2, $0.3, $0.4, $0.5, $1) }
}

@warn_unused_result
public func combineLatest<A: StreamType, B: StreamType, C: StreamType, D: StreamType, E: StreamType, F: StreamType, G: StreamType, H: StreamType>
  ( a: A, _ b: B, _ c: C, _ d: D, _ e: E, _ f: F, _ g: G, _ h: H) -> Stream<(A.Event, B.Event, C.Event, D.Event, E.Event, F.Event, G.Event, H.Event)>
{
  return combineLatest(a, b, c, d, e, f, g).combineLatestWith(h).map { ($0.0, $0.1, $0.2, $0.3, $0.4, $0.5, $0.6, $1) }
}

@warn_unused_result
public func combineLatest<A: StreamType, B: StreamType, C: StreamType, D: StreamType, E: StreamType, F: StreamType, G: StreamType, H: StreamType, I: StreamType>
  ( a: A, _ b: B, _ c: C, _ d: D, _ e: E, _ f: F, _ g: G, _ h: H, _ i: I) -> Stream<(A.Event, B.Event, C.Event, D.Event, E.Event, F.Event, G.Event, H.Event, I.Event)>
{
  return combineLatest(a, b, c, d, e, f, g, h).combineLatestWith(i).map { ($0.0, $0.1, $0.2, $0.3, $0.4, $0.5, $0.6, $0.7, $1) }
}

@warn_unused_result
public func combineLatest<A: StreamType, B: StreamType, C: StreamType, D: StreamType, E: StreamType, F: StreamType, G: StreamType, H: StreamType, I: StreamType, J: StreamType>
  ( a: A, _ b: B, _ c: C, _ d: D, _ e: E, _ f: F, _ g: G, _ h: H, _ i: I, _ j: J) -> Stream<(A.Event, B.Event, C.Event, D.Event, E.Event, F.Event, G.Event, H.Event, I.Event, J.Event)>
{
  return combineLatest(a, b, c, d, e, f, g, h, i).combineLatestWith(j).map { ($0.0, $0.1, $0.2, $0.3, $0.4, $0.5, $0.6, $0.7, $0.8, $1) }
}

@warn_unused_result
public func combineLatest<A: StreamType, B: StreamType, C: StreamType, D: StreamType, E: StreamType, F: StreamType, G: StreamType, H: StreamType, I: StreamType, J: StreamType, K: StreamType>
  ( a: A, _ b: B, _ c: C, _ d: D, _ e: E, _ f: F, _ g: G, _ h: H, _ i: I, _ j: J, _ k: K) -> Stream<(A.Event, B.Event, C.Event, D.Event, E.Event, F.Event, G.Event, H.Event, I.Event, J.Event, K.Event)>
{
  return combineLatest(a, b, c, d, e, f, g, h, i, j).combineLatestWith(k).map { ($0.0, $0.1, $0.2, $0.3, $0.4, $0.5, $0.6, $0.7, $0.8, $0.9, $1) }
}