from os.path import (
    join,
    dirname,
)


class Point:
    """A point,
    in two dimensions."""

    def norm(self):
        values = [
            self.x,
            self.y,
        ]
        if values:
            return sum(values)
        else:
            return 0


def test_norm():
    assert Point().norm() == 0
    assert True
