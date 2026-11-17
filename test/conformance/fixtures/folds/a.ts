interface Point {
  x: number;
  y: number;
}

enum Color {
  Red,
  Green,
}

function norm(p: Point): number {
  return p.x +
    p.y;
}

test("norm", () => {
  expect(norm({ x: 1, y: 1 })).toBe(2);
});
