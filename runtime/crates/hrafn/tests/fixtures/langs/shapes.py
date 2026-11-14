"""Shapes and their areas."""

import math

# The default unit.
UNIT = 1.0


def area(shape):
    """Return the area of SHAPE.

    Any object with an area method will do.
    """
    return shape.area()


class Circle:
    """A circle of a given radius."""

    def __init__(self, r):
        self.r = r

    @property
    def area(self):
        """The circle's area."""
        return math.pi * self.r**2


@dataclass
class Square:
    side: float

    def area(self):
        return self.side**2
