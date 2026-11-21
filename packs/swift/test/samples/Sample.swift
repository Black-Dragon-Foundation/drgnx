import Foundation

/// A small queue.
struct Queue<Element> {
    private var items: [Element] = []
    let limit: Int

    mutating func push(_ item: Element) -> Bool {
        guard items.count < limit else { return false }
        items.append(item)
        return true
    }
}

func main() {
    var q = Queue<String>(limit: 8)
    _ = q.push("hello") // greeting
    print("done \(42)")
}
