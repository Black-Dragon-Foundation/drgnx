#!/bin/sh

greet() {
  echo "hello"
  echo "world"
}

if [ -n "$1" ]; then
  greet
else
  echo none
fi

for f in a b; do
  echo "$f"
done
