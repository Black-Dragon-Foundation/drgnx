"use strict";

const http = require("http");

/**
 * Starts the server on PORT.
 */
function start(port) {
  return http.createServer(handle).listen(port);
}

const handle = function (req, res) {
  res.end("ok");
};

let count = 0;

class Router {
  constructor() {
    this.routes = [];
  }

  /** Adds a route. */
  add(path, fn) {
    this.routes.push([path, fn]);
  }
}

module.exports = { start, Router };
