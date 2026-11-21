package geo

import (
	"fmt"
	"testing"
)

type Point struct {
	X int
	Y int
}

func (p Point) Norm() int {
	if p.X > p.Y {
		return p.X
	}
	return p.Y
}

func TestNorm(t *testing.T) {
	fmt.Println(Point{}.Norm())
}
