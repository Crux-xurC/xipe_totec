print("GEO_INIT_SIDE_EFFECT")
from .units import scale
from . import units

# aliases (a name, a chain of attributes): kept on load
rescale = scale
units_scale = units.scale
