module Geo.Shape (perimeter, total) where

import qualified Target as T
import Target (add)

perimeter :: Int -> Int -> Int
perimeter a b = 2 * add a b

total :: [T.Shape] -> Double
total = sum . map T.area
