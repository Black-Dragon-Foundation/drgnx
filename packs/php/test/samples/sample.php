<?php
namespace Demo;

/** A small queue. */
final class Queue
{
    private array $items = [];

    public function __construct(private int $limit = 8) {}

    public function push(string $item): bool
    {
        if (count($this->items) >= $this->limit) {
            return false;
        }
        $this->items[] = $item; // greeting
        return true;
    }
}
