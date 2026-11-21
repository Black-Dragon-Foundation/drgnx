module Demo.Queue (Queue, push) where

import Data.Maybe (fromMaybe)

-- | A small queue.
data Queue a = Queue { items :: [a], limit :: Int }

push :: a -> Queue a -> Maybe (Queue a)
push x q
  | length (items q) >= limit q = Nothing
  | otherwise = Just q { items = items q ++ [x] } -- greeting
