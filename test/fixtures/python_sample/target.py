"""The Python adapter's sample target: a top level that must never run."""
import itertools

print("TARGET_SIDE_EFFECT")
open("target_side_effect.txt", "w").write("x")

FACTOR = 3
NAMES: list = ["a", "b"]
COMPUTED = len("abc")  # not a literal: not loaded


def add(a, b):
    return a + b


def square(x):
    # add( in a comment is no call
    s = "square(x) in a string is no call"
    return add(x, 0) * x


def _hidden(x):
    return x * FACTOR


async def later(x):
    return x


def boom():
    raise ValueError("bad\nsecond")


def spin():
    while True:
        pass


def cyc():
    a = []
    a.append(a)
    return a


def lam():
    return lambda x: x


def naturals():
    return itertools.count()


def floaty():
    return 0.1 + 0.2


def multi(
    a,
    b=(1, 2),
):
    return [a, b]


class Point:
    def __init__(self, x):
        self.x = x

    def __eq__(self, other):
        return isinstance(other, Point) and other.x == self.x

    def moved(self):
        return square(self.x)


def point(x):
    return Point(x)


if __name__ == "__main__":
    print("MAIN_RAN")
