package store

import "sync"

// MaxItems is how many items a store holds.
const MaxItems = 100

var (
	defaultStore *Store
	hits         int
)

// Store keeps items by key.
// It is safe for concurrent use.
type Store struct {
	mu    sync.Mutex
	items map[string]string
}

type Getter interface {
	Get(key string) (string, bool)
}

type Key = string

// New makes an empty store.
func New() *Store {
	return &Store{items: map[string]string{}}
}

// Get returns the item under KEY.
func (s *Store) Get(key string) (string, bool) {
	s.mu.Lock()
	defer s.mu.Unlock()
	v, ok := s.items[key]
	return v, ok
}
