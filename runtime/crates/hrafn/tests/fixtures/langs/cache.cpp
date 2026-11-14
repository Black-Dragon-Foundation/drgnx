// A small cache, as a C++ project would write one: namespaces, templates, classes with inline and out-of-line members.
#include <list>
#include <string>
#include <unordered_map>

#define CACHE_MAX_ENTRIES 1024
#define CACHE_MIN(a, b) ((a) < (b) ? (a) : (b))

namespace store {

using Key = std::string;

enum class Policy { Lru, Fifo };

/// A least-recently-used cache of values by key.
template <typename V>
class Cache {
 public:
  explicit Cache(size_t capacity) : capacity_(capacity) {}
  ~Cache();

  /// The value of KEY, or null.
  const V* get(const Key& key) const {
    auto it = index_.find(key);
    return it == index_.end() ? nullptr : &it->second->second;
  }

  void put(const Key& key, V value);
  bool operator==(const Cache& other) const { return capacity_ == other.capacity_; }

  struct Stats {
    size_t hits = 0;
    size_t misses = 0;
  };

 private:
  size_t capacity_;
  std::list<std::pair<Key, V>> items_;
  std::unordered_map<Key, typename std::list<std::pair<Key, V>>::iterator> index_;
};

template <typename V>
Cache<V>::~Cache() = default;

template <typename V>
void Cache<V>::put(const Key& key, V value) {
  auto it = index_.find(key);
  if (it != index_.end()) {
    items_.erase(it->second);
  }
  items_.emplace_front(key, std::move(value));
  index_[key] = items_.begin();
  while (items_.size() > capacity_) {
    index_.erase(items_.back().first);
    items_.pop_back();
  }
}

}  // namespace store

/// Prints the size.
static int describe(const store::Cache<int>& cache, const std::string& label) {
  return static_cast<int>(label.size()) + CACHE_MIN(1, 2);
}

extern "C" {
int cache_version(void) { return 3; }
}
