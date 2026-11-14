package demo

import kotlin.math.max

/** A small queue. */
class Queue<T>(private val limit: Int = 8) {
    private val items = ArrayDeque<T>()

    fun push(item: T): Boolean {
        if (items.size >= limit) return false
        items.addLast(item)
        return true
    }

    fun pop(): T? = items.removeFirstOrNull()
}

fun main() {
    val q = Queue<String>()
    q.push("hello") // greeting
    println("size: ${max(1, 2)}")
}
