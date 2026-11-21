import {
  readFile,
} from "fs";

/* A block comment
   over two lines. */
class Point {
  norm() {
    return this.x + this.y;
  }
}

const add = (a, b) => {
  return a + b;
};

describe("add", () => {
  it("adds", () => {
    expect(add(1, 1)).toBe(2);
  });
});
