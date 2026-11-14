package org.example;

import java.util.ArrayDeque;

/**
 * A bounded queue.
 */
public class Queue<T> {
    private final ArrayDeque<T> items = new ArrayDeque<>();

    /** Makes an empty queue. */
    public Queue() {}

    /**
     * Adds ITEM at the end.
     */
    @Override
    public void push(T item) {
        items.addLast(item);
    }

    public T pop() {
        return items.pollFirst();
    }

    static class Node {
        int value;
    }
}

interface Sized {
    int size();
}

enum Color {
    RED,
    GREEN;
}

record Point(int x, int y) {}
