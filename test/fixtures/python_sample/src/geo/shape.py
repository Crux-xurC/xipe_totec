import math
import target
from target import add as plus
from .units import scale

open("shape_side_effect.txt", "w").write("x")


def area(r):
    return math.pi * scale(r) * r


def grow(x):
    return plus(target.square(x), scale(x))
