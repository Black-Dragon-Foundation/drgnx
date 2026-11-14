using System;
using System.Collections.Generic;

namespace Store
{
    public delegate void Evicted(string key);

    public enum Policy { Lru, Fifo }

    /// <summary>A least-recently-used cache of values by key.</summary>
    public class Cache<V> : ICache, IDisposable
    {
        public const int MaxEntries = 1024;

        private readonly Dictionary<string, V> items = new();

        public Cache(int capacity)
        {
            Capacity = capacity;
        }

        ~Cache()
        {
            items.Clear();
        }

        public int Capacity { get; }

        public event Evicted OnEvicted;

        /// <summary>The value of KEY, or default.</summary>
        public V Get(string key)
        {
            return items.TryGetValue(key, out var v) ? v : default;
        }

        public void Put(string key, V value)
        {
            if (items.Count >= Capacity)
            {
                Evict();
            }
            items[key] = value;
        }

        public static bool operator ==(Cache<V> a, Cache<V> b) => ReferenceEquals(a, b);

        public static bool operator !=(Cache<V> a, Cache<V> b) => !(a == b);

        public V this[string key] => Get(key);

        private void Evict()
        {
            var first = new Stats(items.Count);
            Console.WriteLine(first);
            OnEvicted?.Invoke("x");
        }

        public void Dispose() => items.Clear();

        public struct Stats
        {
            public Stats(int count) { Count = count; }

            public int Count { get; }
        }
    }

    public interface ICache
    {
        int Capacity { get; }
    }

    public record Entry(string Key, int Hits);

    public static class Describe
    {
        /// <summary>Prints the size.</summary>
        public static void Print(Cache<int> cache)
        {
            Console.WriteLine(cache.Capacity);
        }
    }
}
