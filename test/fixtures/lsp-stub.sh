#!/bin/bash
# a language server that answers initialize and shutdown, and nothing else (test fixture)
reply() { printf 'Content-Length: %d\r\n\r\n%s' "${#1}" "$1"; }
serve() {
  local line len=0 body id
  while IFS= read -r line; do
    line=${line%$'\r'}
    case $line in
      Content-Length:*) len=${line#*: } ;;
      "")
        IFS= read -r -N "$len" body
        id=$(printf '%s' "$body" | grep -o '"id":[0-9]*' | head -1 | cut -d: -f2)
        case $body in
          *'"method":"initialize"'*) reply "{\"jsonrpc\":\"2.0\",\"id\":$id,\"result\":{\"capabilities\":{}}}" ;;
          *'"method":"shutdown"'*) reply "{\"jsonrpc\":\"2.0\",\"id\":$id,\"result\":null}" ;;
          *'"method":"exit"'*) exit 0 ;;
        esac ;;
    esac
  done
}
# through a pipe: bash reads a terminal in chunks and would lose the bytes after the first line
cat | serve
