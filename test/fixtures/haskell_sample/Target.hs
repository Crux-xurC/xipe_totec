-- the export list hides `hidden`: GHCi (with *Target in scope) still calls it
module Target (add, square, nats, Shape (..), area, shapes, table, adder, spin, first, Opaque, opaque) where

import qualified Data.Map as Map

data Shape = Circle Double | Rect {w :: Int, h :: Int} deriving (Show, Read, Eq)

newtype Opaque = Opaque Int

add :: Int -> Int -> Int
add a b = a + b

square :: Int -> Int
square x = add (x * x) 0 -- a comment naming spin, not a call

hidden :: Int -> Int
hidden x = x * 100

nats :: [Integer]
nats = [0 ..]

area :: Shape -> Double
area (Circle r) = 3 * r * r
area (Rect a b) = fromIntegral (a * b)

shapes :: Int -> [Shape]
shapes n = [if even i then Circle (fromIntegral i) else Rect i (i + 1) | i <- [0 .. n - 1]]

table :: Map.Map String Int
table = Map.fromList [("a", 1), ("b", 2)]

adder :: Int -> Int -> Int
adder n = \x -> add x n

spin :: Int -> Int
spin n = spin (n + 1)

first :: [a] -> a
first (x : _) = x
first [] = error "first: empty list"

opaque :: Opaque
opaque = Opaque 3

label :: String
label = "square x = not a definition"
